/**
 * CloudClassApi —— 南医云课堂（智教云 TeachingCenterStudentWeb）数据接口层
 *
 * 依据抓包记录《云课堂接入抓包记录.md》全链路逆向实现（纯 API 直连，无需 WebView）：
 *  1) 复用统一身份认证 CAS（authserver）登录拿 CASTGC（与教务同源，复用 CasApi）
 *  2) 用 CASTGC 换 ST → 访问云课堂 ssoserver 回调 → 解析 32 位 hex 业务 ticket
 *  3) 用 ticket 调 authoritycontrolplatformapi/api/v1/tickets/{ticket} 换 sessionId + userId
 *  4) DES 解密 sessionId 得 x-Token（UUID）
 *  5) 每个业务请求带签名头四件套 x-Token/x-Nonce/x-Sign/x-Time + Referer/X-Requested-With
 *
 * 签名体系（前端硬编码）：
 *  - validCode = md5(参数串 + "&signKey=123123")   （query 参数）
 *  - x-Nonce   = md5(userId + x-Time + uuid4)
 *  - x-Sign    = md5(x-Nonce + x-Time + "njlz@123")
 *  - x-Token   = DES-CBC 解密 sessionId（key/iv = "njlz@123"）
 *
 * 会话 Cookie：JSESSIONID + ClientToken（2h）+ route（zjy 域），CASTGC（authserver 域，换 ticket 用）。
 */
import rcp from '@hms.collaboration.rcp';
import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { CasApi } from './CasApi';
import { Const } from '../common/Constants';
import { DataStore } from '../common/DataStore';
import { LogStore } from '../common/LogStore';
import { ccValidCodeEmpty, ccValidCodeWithId, ccDesDecrypt, ccSignHeaders } from './CcCrypto';
import {
  CloudSession, CloudTerm, CloudCourse, CloudClass, CloudNotice,
  RecordCourse, RecordVideo, RecordVideoDetail, CloudPage
} from '../model/CloudModels';

/** 云课堂会话持久化 key */
const KEY_CC_SESSION: string = 'cc_session';
const KEY_CC_CASTGC: string = 'cc_castgc';

/** tickets 接口响应 */
interface TicketResp {
  userId: string;
  sessionId: string;
  clientId: string;
}

/** 用户信息（userresource 精简） */
interface CloudUserInfo {
  userName: string;
  userNo: string;
}

/** 课堂实录视频分页请求体 */
interface RecordVideoPageReq {
  userId: string;
  groupIds: string;
  openStatus: string;
  week: string;
  schoolYear: string;
  term: string;
  validCode: string;
  page: number;
  pageSize: number;
}

/** 通知列表请求体 */
interface RecordNoticeReq {
  schoolYear: string;
  status: number;
  studentId: string;
  term: string;
}

/** 简易 Cookie 罐（zjy 域 + authserver 域） */
class CcCookieJar {
  private map: Map<string, string> = new Map(); // name -> value

  setFromHeader(host: string, setCookie: string | string[] | undefined): void {
    if (setCookie === undefined) {
      return;
    }
    const list: string[] = Array.isArray(setCookie) ? setCookie : [String(setCookie)];
    for (const item of list) {
      const seg: string = item.split(';')[0].trim();
      const eq: number = seg.indexOf('=');
      if (eq > 0) {
        this.map.set(seg.substring(0, eq), seg.substring(eq + 1));
      }
    }
  }

  put(name: string, value: string): void {
    this.map.set(name, value);
  }

  get(name: string): string {
    return this.map.get(name) ?? '';
  }

  header(): string {
    const parts: string[] = [];
    this.map.forEach((v: string, k: string) => {
      parts.push(`${k}=${v}`);
    });
    return parts.join('; ');
  }
}

/** 一跳响应 */
interface CcHop {
  status: number;
  headers: rcp.ResponseHeaders;
  body: string;
}

export class CloudClassApi {
  /** 云课堂会话（内存） */
  private static session: CloudSession | null = null;
  /** 云课堂会话 Cookie（zjy 域：JSESSIONID + ClientToken + route） */
  private static cookie: string = '';
  /** 云课堂 CASTGC（authserver 域，用于静默续期） */
  private static castgc: string = '';
  /** 单飞锁（login 并发去重） */
  private static loginInflight: Promise<CloudSession> | null = null;
  /** 单飞锁（relogin） */
  private static reloginInflight: Promise<CloudSession> | null = null;

  /** 是否已登录（有内存会话且未超 2h） */
  static isLoggedIn(): boolean {
    if (CloudClassApi.session === null) {
      return false;
    }
    // ClientToken 2h 硬边界（留 5 分钟余量）
    return Date.now() - CloudClassApi.session.loginAt < 115 * 60 * 1000;
  }

  /** 读取当前会话（可能为 null） */
  static getSession(): CloudSession | null {
    return CloudClassApi.session;
  }

  /** 读取持久化 CASTGC（冷启动静默续期） */
  static loadCastgc(): string {
    if (CloudClassApi.castgc.length > 0) {
      return CloudClassApi.castgc;
    }
    return DataStore.get(KEY_CC_CASTGC);
  }

  /** 退出：清内存会话与 Cookie（保留 CASTGC 供下次静默登录） */
  static logout(): void {
    CloudClassApi.session = null;
    CloudClassApi.cookie = '';
  }

  /**
   * 登录：CAS 认证（复用 CasApi）→ 云课堂 SSO → 换 sessionId。
   * @param account 学号
   * @param password 密码
   * @param remember7d 是否 7 天免登录
   */
  static async login(account: string, password: string, remember7d: boolean): Promise<CloudSession> {
    if (CloudClassApi.loginInflight !== null) {
      return CloudClassApi.loginInflight;
    }
    const task: Promise<CloudSession> = CloudClassApi.loginInner(account, password, remember7d);
    CloudClassApi.loginInflight = task;
    try {
      return await task;
    } finally {
      CloudClassApi.loginInflight = null;
    }
  }

  private static async loginInner(account: string, password: string, remember7d: boolean): Promise<CloudSession> {
    // 1) CAS 统一认证登录（复用 CasApi，与教务完全同源），拿 CASTGC
    const casRes = await CasApi.nativeCasLogin(account, password, remember7d);
    const castgc: string = casRes.castgc;
    if (castgc.length === 0) {
      throw new Error('统一认证未返回 CASTGC');
    }
    CloudClassApi.castgc = castgc;
    DataStore.put(KEY_CC_CASTGC, castgc);

    // 2) 用 CASTGC 换云课堂 ST，再走 ssoserver 换业务 ticket
    const session: CloudSession = await CloudClassApi.openCloudClassWithCastgc(castgc);
    CloudClassApi.session = session;
    LogStore.log('云课堂', '登录', '成功', `用户=${session.userName} 学号=${session.userNo}`);
    return session;
  }

  /** 静默续期：仅用持久化 CASTGC 重新建立云课堂会话（不重新输密码） */
  static async silentRelogin(): Promise<CloudSession> {
    if (CloudClassApi.reloginInflight !== null) {
      return CloudClassApi.reloginInflight;
    }
    const castgc: string = CloudClassApi.loadCastgc();
    if (castgc.length === 0) {
      throw new Error('无持久化登录态');
    }
    const task: Promise<CloudSession> = CloudClassApi.openCloudClassWithCastgc(castgc);
    CloudClassApi.reloginInflight = task;
    try {
      const s: CloudSession = await task;
      CloudClassApi.session = s;
      return s;
    } finally {
      CloudClassApi.reloginInflight = null;
    }
  }

  /**
   * 用 CASTGC 建立云课堂会话（核心 SSO 链路）：
   *  CASTGC → exchangeStForService(CC_SSO_SERVICE) → ST
   *  → GET CC_SSO_SERVICE?ticket=ST-xxx（手动 follow 302）→ 解析 32hex 业务 ticket
   *  → GET tickets/{ticket} → sessionId + userId
   *  → DES 解密 sessionId → x-Token
   */
  private static async openCloudClassWithCastgc(castgc: string): Promise<CloudSession> {
    // 2a) 换 ST
    const st: string = await CasApi.exchangeStForService(castgc, Const.CC_SSO_SERVICE);

    // 2b) 访问云课堂 SSO 回调，手动 follow 302，收集 zjy 域 Cookie，解析 32hex 业务 ticket
    const jar: CcCookieJar = new CcCookieJar();
    const session: rcp.Session = rcp.createSession({
      requestConfiguration: {
        transfer: { autoRedirect: false } as rcp.TransferConfiguration
      }
    });
    let bizTicket: string = '';
    try {
      let url: string = `${Const.CC_SSO_SERVICE}?ticket=${encodeURIComponent(st)}`;
      for (let i = 0; i < 12; i++) {
        const resp: CcHop = await CloudClassApi.ccFetch(session, jar, url, 'GET');
        // 从 Location 或 body 解析业务 ticket（32 位 hex）
        let next: string = '';
        if (resp.status >= 300 && resp.status < 400) {
          const loc: string | string[] | undefined = resp.headers['location'] as (string | string[] | undefined);
          next = Array.isArray(loc) ? loc[0] : String(loc ?? '');
        }
        if (next.length === 0) {
          next = CloudClassApi.pickJumpTarget(resp.body);
        }
        // 从 next 或 body 提取 32hex ticket
        const t: string = CloudClassApi.pickBizTicket(next.length > 0 ? next : resp.body);
        if (t.length > 0) {
          bizTicket = t;
        }
        if (next.length === 0) {
          break;
        }
        if (next.startsWith('/')) {
          next = `https://zjy.njmu.edu.cn${next}`;
        }
        if (next.startsWith('http://')) {
          next = 'https://' + next.substring('http://'.length);
        }
        url = next;
      }
    } finally {
      try {
        session.close();
      } catch (e) {
        // ignore
      }
    }

    if (bizTicket.length === 0) {
      throw new Error('云课堂 SSO 未返回业务 ticket');
    }

    // 保存 zjy 域 Cookie（JSESSIONID + ClientToken + route）
    CloudClassApi.cookie = jar.header();

    // 2c) 用业务 ticket 换 sessionId + userId
    const vc: string = await ccValidCodeEmpty();
    const ticketUrl: string = `${Const.CC_API_AUTH}/api/v1/tickets/${bizTicket}?ticket=${bizTicket}&validCode=${vc}`;
    const resp: CcHop = await CloudClassApi.ccFetch(session, jar, ticketUrl, 'GET');
    if (resp.status !== 200) {
      throw new Error(`ticket 换取失败（HTTP ${resp.status}）`);
    }
    const tr: TicketResp = JSON.parse(resp.body) as TicketResp;
    if (!tr.userId || !tr.sessionId) {
      throw new Error('ticket 响应缺 userId/sessionId');
    }
    // 2d) DES 解密 sessionId → x-Token
    const xToken: string = await ccDesDecrypt(tr.sessionId);

    // 2e) 拉取用户信息（姓名/学号）
    let userName: string = '';
    let userNo: string = '';
    try {
      const info = await CloudClassApi.getUserInfoInternal(tr.userId, xToken);
      userName = info.userName;
      userNo = info.userNo;
    } catch (e) {
      // 用户信息拉取失败不阻断登录
    }

    const out: CloudSession = {
      userId: tr.userId,
      sessionId: tr.sessionId,
      xToken: xToken,
      loginAt: Date.now(),
      userName: userName,
      userNo: userNo
    };
    DataStore.put(KEY_CC_SESSION, JSON.stringify(out));
    return out;
  }

  /** 内部：拉取用户信息（userresource） */
  private static async getUserInfoInternal(userId: string, xToken: string): Promise<CloudUserInfo> {
    const vc: string = await ccValidCodeWithId(userId);
    const headers: Record<string, string> = await ccSignHeaders(userId, xToken, Const.CC_REFERER);
    const url: string = `${Const.CC_API_AUTH}/api/v1/users/${userId}/userresource?validCode=${vc}`;
    const body: string = await CloudClassApi.ccRequest(url, 'GET', headers, '');
    const obj: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
    const info: CloudUserInfo = {
      userName: String(obj['userName'] ?? ''),
      userNo: String(obj['userNo'] ?? String(obj['userAccountNo'] ?? ''))
    };
    return info;
  }

  // ══════════ 业务接口 ══════════

  /** 当前学期（termResource，仅返回 1 条） */
  static async getCurrentTerm(): Promise<CloudTerm | null> {
    const s: CloudSession = await CloudClassApi.ensureSession();
    const vc: string = await ccValidCodeEmpty();
    const url: string = `${Const.CC_API_COURSE}/v1/terms/termResource?validCode=${vc}`;
    const body: string = await CloudClassApi.ccSignedRequest(s, url, 'GET', '');
    const arr: Record<string, Object>[] = JSON.parse(body) as Record<string, Object>[];
    if (arr.length === 0) {
      return null;
    }
    return CloudClassApi.mapTerm(arr[0]);
  }

  /** 近 N 个学期（含历史） */
  static async getTerms(prevNum: number = 6): Promise<CloudTerm[]> {
    const s: CloudSession = await CloudClassApi.ensureSession();
    const vc: string = await ccValidCodeEmpty();
    const url: string = `${Const.CC_API_COURSE}/v1/term/recent?futureTermNum=0&previousTermNum=${prevNum}&validCode=${vc}`;
    const body: string = await CloudClassApi.ccSignedRequest(s, url, 'GET', '');
    const arr: Record<string, Object>[] = JSON.parse(body) as Record<string, Object>[];
    const out: CloudTerm[] = [];
    for (const it of arr) {
      out.push(CloudClassApi.mapTerm(it));
    }
    return out;
  }

  /** 我的课程（无分页，一次全量） */
  static async getMyCourses(schoolYear: string, term: string): Promise<CloudCourse[]> {
    const s: CloudSession = await CloudClassApi.ensureSession();
    const vc: string = await ccValidCodeEmpty();
    const url: string = `${Const.CC_API_COURSE}/v1/courseTables/studentCourseList?schoolYear=${schoolYear}&term=${term}&userId=${s.userId}&validCode=${vc}`;
    const body: string = await CloudClassApi.ccSignedRequest(s, url, 'GET', '');
    const arr: Record<string, Object>[] = JSON.parse(body) as Record<string, Object>[];
    const out: CloudCourse[] = [];
    for (const raw of arr) {
      const classes: CloudClass[] = [];
      const tc: Object = raw['teachingClasses'] ?? [];
      const tcArr: Record<string, Object>[] = Array.isArray(tc) ? (tc as Record<string, Object>[]) : [];
      for (const c of tcArr) {
        classes.push({
          classId: String(c['classId'] ?? ''),
          className: String(c['className'] ?? ''),
          classType: String(c['classType'] ?? ''),
          classMembers: Number(c['classMembers'] ?? 0)
        });
      }
      out.push({
        courseId: String(raw['courseId'] ?? ''),
        courseCode: String(raw['courseCode'] ?? ''),
        courseName: String(raw['courseName'] ?? ''),
        collegeName: String(raw['collegeName'] ?? ''),
        teacherId: String(raw['teacherId'] ?? ''),
        teacherName: String(raw['teacherName'] ?? ''),
        courseCategory: String(raw['courseCategory'] ?? ''),
        teachingClasses: classes,
        schoolYear: schoolYear,
        term: term
      });
    }
    return out;
  }

  /** 课堂实录：有录播的课程汇总 */
  static async getRecordCourses(schoolYear: string, term: string): Promise<RecordCourse[]> {
    const s: CloudSession = await CloudClassApi.ensureSession();
    const vc: string = await ccValidCodeEmpty();
    const url: string = `${Const.CC_API_TEACH}/v1/videoinfo/student/courses?studentId=${s.userId}&schoolYear=${schoolYear}&term=${term}&validCode=${vc}`;
    const body: string = await CloudClassApi.ccSignedRequest(s, url, 'GET', '');
    const arr: Record<string, Object>[] = JSON.parse(body) as Record<string, Object>[];
    const out: RecordCourse[] = [];
    for (const raw of arr) {
      const weeksRaw: Object = raw['weeks'] ?? [];
      const weeks: string[] = Array.isArray(weeksRaw) ? (weeksRaw as string[]) : [];
      out.push({
        courseId: String(raw['courseId'] ?? ''),
        courseName: String(raw['courseName'] ?? ''),
        classIds: String(raw['classIds'] ?? ''),
        classNames: String(raw['classNames'] ?? ''),
        weeks: weeks,
        maxUpdateDate: String(raw['maxUpdateDate'] ?? ''),
        coverUrl: CloudClassApi.absCover(String(raw['coverPicInnerIp'] ?? raw['coverPicOuterIp'] ?? ''), String(raw['coverPicPath'] ?? '')),
        teacherNames: String(raw['teacherNames'] ?? '')
      });
    }
    return out;
  }

  /** 课堂实录：某班视频分页列表 */
  static async getRecordVideos(groupIds: string, schoolYear: string, term: string,
    page: number = 1, pageSize: number = 10): Promise<CloudPage<RecordVideo>> {
    const s: CloudSession = await CloudClassApi.ensureSession();
    const vc: string = await ccValidCodeEmpty();
    const url: string = `${Const.CC_API_TEACH}/v1/videoinfos/page?validCode=${vc}`;
    const payload: RecordVideoPageReq = {
      userId: s.userId,
      groupIds: groupIds,
      openStatus: '1',
      week: '',
      schoolYear: schoolYear,
      term: term,
      validCode: vc,
      page: page,
      pageSize: pageSize
    };
    const body: string = await CloudClassApi.ccSignedRequest(s, url, 'POST', JSON.stringify(payload));
    const obj: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
    const listRawObj: Object = obj['videoInfoResourceList'] ?? [];
    const listRaw: Record<string, Object>[] = Array.isArray(listRawObj) ? (listRawObj as Record<string, Object>[]) : [];
    const list: RecordVideo[] = [];
    for (const raw of listRaw) {
      list.push({
        id: String(raw['id'] ?? ''),
        videoInfoName: String(raw['videoInfoName'] ?? ''),
        week: String(raw['week'] ?? ''),
        teacherNames: String(raw['teacherNames'] ?? ''),
        className: String(raw['className'] ?? ''),
        courseId: String(raw['courseId'] ?? ''),
        courseName: String(raw['courseName'] ?? ''),
        thumbnailUrl: CloudClassApi.absCover(String(raw['innerIp'] ?? raw['outerIp'] ?? ''), String(raw['thumbnailPath'] ?? '')),
        startTime: String(raw['startTime'] ?? ''),
        endTime: String(raw['endTime'] ?? ''),
        classroomName: String(raw['classroomName'] ?? ''),
        weekDay: String(raw['weekDay'] ?? ''),
        segment: Number(raw['segment'] ?? 0),
        playUrl: ''
      });
    }
    return {
      page: Number(obj['page'] ?? page),
      pageSize: Number(obj['pageSize'] ?? pageSize),
      pageCount: Number(obj['pageCount'] ?? 0),
      total: Number(obj['total'] ?? 0),
      list: list
    };
  }

  /** 课堂实录视频详情（含三路画面 MP4 直链） */
  static async getVideoDetail(videoId: string): Promise<RecordVideoDetail> {
    const s: CloudSession = await CloudClassApi.ensureSession();
    const vc: string = await ccValidCodeWithId(videoId);
    const url: string = `${Const.CC_API_TEACH}/v1/videoinfo/${videoId}?validCode=${vc}`;
    const body: string = await CloudClassApi.ccSignedRequest(s, url, 'GET', '');
    const raw: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
    const playUrls: string[] = CloudClassApi.collectMp4(raw);
    const detail: RecordVideoDetail = {
      id: videoId,
      videoInfoName: String(raw['videoInfoName'] ?? ''),
      courseName: String(raw['courseName'] ?? ''),
      teacherNames: String(raw['teacherNames'] ?? ''),
      startTime: String(raw['startTime'] ?? ''),
      endTime: String(raw['endTime'] ?? ''),
      classroomName: String(raw['classroomName'] ?? ''),
      playUrls: playUrls,
      pptUrls: []
    };
    return detail;
  }

  /** 通知（上课提醒） */
  static async getNotifications(schoolYear: string, term: string): Promise<CloudNotice[]> {
    const s: CloudSession = await CloudClassApi.ensureSession();
    const vc: string = await ccValidCodeEmpty();
    const url: string = `${Const.CC_API_TEACH}/api/v1/studentNotification/list?validCode=${vc}`;
    const payload: RecordNoticeReq = {
      schoolYear: schoolYear,
      status: 0,
      studentId: s.userId,
      term: term
    };
    const body: string = await CloudClassApi.ccSignedRequest(s, url, 'POST', JSON.stringify(payload));
    const arr: Record<string, Object>[] = JSON.parse(body) as Record<string, Object>[];
    const out: CloudNotice[] = [];
    for (const raw of arr) {
      out.push({
        notificationType: Number(raw['notificationType'] ?? 0),
        content: String(raw['content'] ?? ''),
        notificationDate: String(raw['notificationDate'] ?? ''),
        schoolYear: String(raw['schoolYear'] ?? schoolYear),
        term: String(raw['term'] ?? term),
        courseId: String(raw['courseId'] ?? '')
      });
    }
    return out;
  }

  // ══════════ 内部工具 ══════════

  /** 确保会话有效（过期则静默续期） */
  private static async ensureSession(): Promise<CloudSession> {
    if (CloudClassApi.session !== null && CloudClassApi.isLoggedIn()) {
      return CloudClassApi.session;
    }
    return CloudClassApi.silentRelogin();
  }

  /** 签名业务请求（GET/POST），返回响应体字符串 */
  private static async ccSignedRequest(s: CloudSession, url: string,
    method: 'GET' | 'POST', body: string): Promise<string> {
    const headers: Record<string, string> = await ccSignHeaders(s.userId, s.xToken, Const.CC_REFERER);
    return CloudClassApi.ccRequest(url, method, headers, body);
  }

  /** 通用 HTTP 请求（带 Cookie + 签名头），返回响应体字符串 */
  private static async ccRequest(url: string, method: 'GET' | 'POST',
    headers: Record<string, string>, body: string): Promise<string> {
    const client: http.HttpRequest = http.createHttp();
    try {
      const h: Record<string, string> = {};
      h['User-Agent'] = 'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';
      h['Accept'] = 'application/json,text/plain,*/*';
      if (CloudClassApi.cookie.length > 0) {
        h['Cookie'] = CloudClassApi.cookie;
      }
      const keys: string[] = Object.keys(headers);
      for (let i = 0; i < keys.length; i++) {
        h[keys[i]] = headers[keys[i]];
      }
      const options: http.HttpRequestOptions = {
        method: method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: h,
        extraData: body,
        connectTimeout: 15000,
        readTimeout: 20000,
        expectDataType: http.HttpDataType.STRING
      };
      const response: http.HttpResponse = await client.request(url, options);
      const code: number = response.responseCode as number;
      let text: string = '';
      if (typeof response.result === 'string') {
        text = response.result as string;
      } else {
        text = JSON.stringify(response.result);
      }
      if (code !== 200) {
        LogStore.log('云课堂', '请求', '失败', `HTTP ${code} url=${url}`);
        throw new Error(`云课堂请求失败（HTTP ${code}）`);
      }
      return text;
    } finally {
      client.destroy();
    }
  }

  /** rcp 请求（登录 SSO 链路用，autoRedirect=false），收集 Cookie */
  private static async ccFetch(session: rcp.Session, jar: CcCookieJar, url: string,
    method: 'GET' | 'POST'): Promise<CcHop> {
    const headers: rcp.RequestHeaders = {
      'User-Agent': 'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    };
    const ck: string = jar.header();
    if (ck.length > 0) {
      headers['Cookie'] = ck;
    }
    const request: rcp.Request = new rcp.Request(url, method, headers, '');
    const resp: rcp.Response = await session.fetch(request);
    const sc: string | string[] | undefined = resp.headers['set-cookie'] as (string | string[] | undefined);
    jar.setFromHeader('zjy.njmu.edu.cn', sc);
    return { status: resp.statusCode ?? 0, headers: resp.headers, body: resp.toString() ?? '' };
  }

  /** 从跳转目标/body 提取 32 位 hex 业务 ticket */
  private static pickBizTicket(text: string): string {
    if (text.length === 0) {
      return '';
    }
    const m: RegExpMatchArray | null = text.match(/ticket=([0-9a-f]{32})/i);
    return m ? m[1] : '';
  }

  /** 从响应体提取跳转目标（meta refresh / JS location） */
  private static pickJumpTarget(body: string): string {
    if (body.length === 0) {
      return '';
    }
    let m: RegExpMatchArray | null = body.match(/<meta[^>]+content=["']?[^"']*url=([^"'\s;>]+)/i);
    if (m) {
      return m[1].replace(/&amp;/g, '&');
    }
    m = body.match(/location\.href\s*=\s*["']([^"']+)["']/i);
    if (m) {
      return m[1];
    }
    m = body.match(/window\.location\s*=\s*["']([^"']+)["']/i);
    if (m) {
      return m[1];
    }
    return '';
  }

  /** 拼接封面/缩略图绝对地址（注意视频 URL 有双斜杠，不能 path.join） */
  private static absCover(host: string, path: string): string {
    if (path.length === 0) {
      return '';
    }
    if (path.startsWith('http')) {
      return path;
    }
    const base: string = host.length > 0 ? host : 'https://zjy.njmu.edu.cn';
    return `${base}${path.startsWith('/') ? '' : '/'}${path}`;
  }

  /** 从视频详情里递归收集 MP4 播放地址（三路画面） */
  private static collectMp4(obj: Record<string, Object>): string[] {
    const out: string[] = [];
    CloudClassApi.collectMp4Inner(obj, out);
    return out;
  }

  /** 递归收集 MP4 辅助（避免闭包类型收窄问题） */
  private static collectMp4Inner(o: Object, out: string[]): void {
    if (o === null || o === undefined) {
      return;
    }
    if (typeof o === 'string') {
      const s: string = o as string;
      if (s.indexOf('.mp4') >= 0) {
        if (out.indexOf(s) < 0) {
          out.push(s);
        }
      }
      return;
    }
    if (Array.isArray(o)) {
      const arr: Object[] = o as Object[];
      for (let i = 0; i < arr.length; i++) {
        CloudClassApi.collectMp4Inner(arr[i], out);
      }
      return;
    }
    if (typeof o === 'object') {
      const rec: Record<string, Object> = o as Record<string, Object>;
      const keys: string[] = Object.keys(rec);
      for (let i = 0; i < keys.length; i++) {
        CloudClassApi.collectMp4Inner(rec[keys[i]], out);
      }
    }
  }

  /** 学期对象映射 */
  private static mapTerm(raw: Record<string, Object>): CloudTerm {
    return {
      id: String(raw['id'] ?? ''),
      schoolYear: String(raw['schoolYear'] ?? ''),
      term: String(raw['term'] ?? ''),
      startDate: String(raw['startDate'] ?? ''),
      endDate: String(raw['endDate'] ?? ''),
      description: String(raw['description'] ?? '')
    };
  }
}
