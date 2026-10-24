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
import { ccValidCodeEmpty, ccValidCodeWithId, ccDesDecrypt, ccSignHeaders, ccDecodeLsValue } from './CcCrypto';
import { T } from '../common/I18n';
import {
  CloudSession, CloudTerm, CloudCourse, CloudClass, CloudNotice,
  RecordCourse, RecordVideo, RecordVideoDetail, CloudPage
} from '../model/CloudModels';

/** 云课堂会话持久化 key */
const KEY_CC_SESSION: string = 'cc_session';
const KEY_CC_CASTGC: string = 'cc_castgc';
const KEY_CC_COOKIE: string = 'cc_cookie';

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
  /** "host|name" -> value（按域隔离：SSO 跳转链跨 zjy / authserver 两域，
   *  两者都有 JSESSIONID，扁平存储会互相覆盖导致会话失效） */
  private map: Map<string, string> = new Map();

  setFromHeader(host: string, setCookie: string | string[] | undefined): void {
    if (setCookie === undefined) {
      return;
    }
    const list: string[] = Array.isArray(setCookie) ? setCookie : [String(setCookie)];
    for (const item of list) {
      const seg: string = item.split(';')[0].trim();
      const eq: number = seg.indexOf('=');
      if (eq > 0) {
        this.map.set(`${host}|${seg.substring(0, eq)}`, seg.substring(eq + 1));
      }
    }
  }

  put(host: string, name: string, value: string): void {
    this.map.set(`${host}|${name}`, value);
  }

  get(host: string, name: string): string {
    return this.map.get(`${host}|${name}`) ?? '';
  }

  /** 指定域的 Cookie 串（仅该域自己的 Cookie，不再混入其它域） */
  header(host: string): string {
    const prefix: string = `${host}|`;
    const parts: string[] = [];
    this.map.forEach((v: string, k: string) => {
      if (k.startsWith(prefix)) {
        parts.push(`${k.substring(prefix.length)}=${v}`);
      }
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

  /** 冷启动恢复持久化会话（session + cookie），若未超 2h 直接复用，避免重新走 SSO */
  static restoreSession(): boolean {
    if (CloudClassApi.session !== null) {
      return CloudClassApi.isLoggedIn();
    }
    const raw: string = DataStore.get(KEY_CC_SESSION);
    if (raw.length === 0) {
      return false;
    }
    try {
      const s: CloudSession = JSON.parse(raw) as CloudSession;
      if (s.userId.length === 0 || s.xToken.length === 0) {
        return false;
      }
      CloudClassApi.session = s;
      const ck: string = DataStore.get(KEY_CC_COOKIE);
      if (ck.length > 0) {
        CloudClassApi.cookie = ck;
      }
      const cg: string = DataStore.get(KEY_CC_CASTGC);
      if (cg.length > 0) {
        CloudClassApi.castgc = cg;
      }
      return CloudClassApi.isLoggedIn();
    } catch (e) {
      CloudClassApi.session = null;
      return false;
    }
  }

  /** 读取当前会话（可能为 null） */
  static getSession(): CloudSession | null {
    return CloudClassApi.session;
  }

  /** 读取持久化 CASTGC（冷启动静默续期）。
   *  优先云课堂专用值，其次复用**教务统一认证的 CASTGC**（同源 authserver，可省掉一次完整 CAS 登录）。 */
  static loadCastgc(): string {
    if (CloudClassApi.castgc.length > 0) {
      return CloudClassApi.castgc;
    }
    const own: string = DataStore.get(KEY_CC_CASTGC);
    if (own.length > 0) {
      return own;
    }
    return DataStore.get(DataStore.KEY_CAS_TGC);
  }

  /** 退出：清内存会话与 Cookie（保留 CASTGC 供下次静默登录） */
  static logout(): void {
    CloudClassApi.session = null;
    CloudClassApi.cookie = '';
    DataStore.remove(KEY_CC_SESSION);
    DataStore.remove(KEY_CC_COOKIE);
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
    // 2a) 优先主动换 ST。⚠ 南医大 authserver 对非浏览器直连常不返回 ticket（日志实测
    //     「统一认证换取 ST 失败（未返回 ticket）」），故失败后不中断，改走「云课堂 SSO 入口跟随」：
    //     由 zjy 的 ssoserver 发起 CAS 跳转，服务端自己完成认证并下发业务 ticket。
    let st: string = '';
    try {
      st = await CasApi.exchangeStForService(castgc, Const.CC_SSO_SERVICE);
      LogStore.log('云课堂', 'SSO', 'ST 已获取', `len=${st.length}`);
    } catch (e) {
      LogStore.log('云课堂', 'SSO', '主动换票失败（改走 SSO 入口跟随）', LogStore.errorOf(e as Object));
    }

    // 2b) follow 302 链，收集 Cookie，解析 32hex 业务 ticket
    const jar: CcCookieJar = new CcCookieJar();
    // 跳转链会经 authserver.njmu.edu.cn，必须携带 CASTGC 才能免登录直通
    jar.put(Const.AUTH_HOST, 'CASTGC', castgc);
    const session: rcp.Session = rcp.createSession({
      requestConfiguration: {
        transfer: { autoRedirect: false } as rcp.TransferConfiguration
      }
    });
    // ★ session 必须全程复用：SSO 跳转 + ticket 换取都在同一会话内完成，
    //   此前在 SSO 跳转结束就 close()，随后又用同一个已关闭 session 换 ticket → 登录必然失败。
    try {
      let bizTicket: string = '';
      // 有 ST 直接走 SSO 回调；无 ST 从云课堂 SSO 入口开始（服务端驱动 CAS 认证）
      let url: string = st.length > 0
        ? `${Const.CC_SSO_SERVICE}?ticket=${encodeURIComponent(st)}`
        : Const.CC_LOGIN_URL;
      LogStore.log('云课堂', 'SSO', '开始跳转', st.length > 0 ? 'ST 模式' : `入口跟随 ${url}`);
      let lastStatus: number = 0;
      let lastUrl: string = '';
      let casPageHit: boolean = false;
      for (let i = 0; i < 12; i++) {
        const resp: CcHop = await CloudClassApi.ccFetch(session, jar, url, 'GET');
        lastStatus = resp.status;
        lastUrl = url;
        // 途中出现统一认证登录页 = CASTGC 未被接受（过期/无效），直接定性，避免盲猜
        if (resp.status === 200 && resp.body.indexOf('统一身份认证平台') >= 0) {
          casPageHit = true;
        }
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
        // 诊断：记录本跳主机 + 状态 + Set-Cookie 名称（不记值，避免泄露凭据）
        const ckNames: string = CloudClassApi.cookieNames(resp.headers);
        LogStore.log('云课堂', 'SSO', `跳转 ${i + 1}`,
          `status=${resp.status} host=${CloudClassApi.hostOf(url)} 下发Cookie=[${ckNames}] → ${next.length > 0 ? CloudClassApi.shortenUrl(next) : '无'}`);
        if (next.length === 0) {
          break;
        }
        if (next.startsWith('//')) {
          next = `https:${next}`;
        } else if (next.startsWith('/')) {
          next = `https://zjy.njmu.edu.cn${next}`;
        }
        if (next.startsWith('http://')) {
          next = 'https://' + next.substring('http://'.length);
        }
        url = next;
      }

      if (bizTicket.length === 0) {
        const why: string = casPageHit
          ? '统一认证登录页回流（CASTGC 已失效或未被接受），需重新登录统一认证'
          : `跳转链未命中业务 ticket（末跳 status=${lastStatus} host=${CloudClassApi.hostOf(lastUrl)}）`;
        LogStore.log('云课堂', 'SSO', '失败', why);
        throw new Error(casPageHit ? '统一认证登录态已失效，请重新登录后再试' : `云课堂 SSO 未返回业务 ticket（末跳 ${lastStatus}）`);
      }
      LogStore.log('云课堂', 'SSO', '业务 ticket 已获取', `ticket=${bizTicket.substring(0, 8)}…`);

      // 保存 zjy 域 Cookie（JSESSIONID + ClientToken + route）
      CloudClassApi.cookie = jar.header('zjy.njmu.edu.cn');
      DataStore.put(KEY_CC_COOKIE, CloudClassApi.cookie);

      // 2c) 用业务 ticket 换 sessionId + userId（复用同一 session，携带 SSO 建立的 Cookie）
      const vc: string = await ccValidCodeEmpty();
      const ticketUrl: string = `${Const.CC_API_AUTH}/api/v1/tickets/${bizTicket}?ticket=${bizTicket}&validCode=${vc}`;
      const resp: CcHop = await CloudClassApi.ccFetch(session, jar, ticketUrl, 'GET');
      if (resp.status !== 200) {
        LogStore.logNet('云课堂', 'ticket', T('失败'),
          { url: ticketUrl, status: `${resp.status}`, body: resp.body.substring(0, 300) });
        throw new Error(`ticket 换取失败（HTTP ${resp.status}）`);
      }
      const tr: TicketResp = JSON.parse(resp.body) as TicketResp;
      if (!tr.userId || !tr.sessionId) {
        LogStore.log('云课堂', 'ticket', '响应异常', resp.body.substring(0, 300));
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
      LogStore.log('云课堂', '登录', '会话建立', `userId=${tr.userId} 姓名=${userName}`);
      return out;
    } finally {
      try {
        session.close();
      } catch (e) {
        // ignore
      }
    }
  }

  /**
   * 采用 WebView 已完成 SSO 的会话（推荐路径）。
   * 背景：原生 HTTP 直连走 CAS 换 ST 会被南医大 MFA 策略拦截（判定新设备 → 退回登录页 → 无 ticket），
   *      而 WebView 是真实浏览器环境，SSO 必然成功。此处只需承接其结果：
   *      ① 注入 zjy 域 Cookie（JSESSIONID + ClientToken + route）
   *      ② 用 URL hash 里的 32hex 业务 ticket 换 sessionId + userId
   *      ③ DES 解密 sessionId → x-Token，落库为 CloudSession
   */
  static async adoptWebSession(cookie: string, bizTicket: string): Promise<CloudSession> {
    if (cookie.length === 0) {
      throw new Error('未获取到云课堂会话 Cookie');
    }
    if (bizTicket.length === 0) {
      throw new Error('未获取到云课堂业务 ticket');
    }
    CloudClassApi.cookie = cookie;
    DataStore.put(KEY_CC_COOKIE, cookie);
    const vc: string = await ccValidCodeEmpty();
    const ticketUrl: string = `${Const.CC_API_AUTH}/api/v1/tickets/${bizTicket}?ticket=${bizTicket}&validCode=${vc}`;
    const body: string = await CloudClassApi.ccRequest(ticketUrl, 'GET', {}, '');
    const tr: TicketResp = JSON.parse(body) as TicketResp;
    if (!tr.userId || !tr.sessionId) {
      throw new Error('ticket 响应缺 userId/sessionId');
    }
    const xToken: string = await ccDesDecrypt(tr.sessionId);
    let userName: string = '';
    let userNo: string = '';
    try {
      const info: CloudUserInfo = await CloudClassApi.getUserInfoInternal(tr.userId, xToken);
      userName = info.userName;
      userNo = info.userNo;
    } catch (e) {
      // 用户信息失败不阻断
    }
    const out: CloudSession = {
      userId: tr.userId,
      sessionId: tr.sessionId,
      xToken: xToken,
      loginAt: Date.now(),
      userName: userName,
      userNo: userNo
    };
    CloudClassApi.session = out;
    DataStore.put(KEY_CC_SESSION, JSON.stringify(out));
    LogStore.log('云课堂', '网页登录', '会话建立', `userId=${tr.userId} 姓名=${userName} Cookie=${cookie.length}字节`);
    return out;
  }

  /**
   * 采用 WebView localStorage 中的会话（抓包 v2 实测唯一可行路径）。
   *
   * 为什么不用 ticket：WebView 落地后前端在 0.5s 内已自行消费 ticket 换票，
   * App 再拿 URL 里的 ticket 去换必然 404 `B10010 ticket数据不存在`。
   * 为什么不用 Cookie：ClientToken 的 Path=/ssoserver，按 RFC 6265 对 `/` 路径不匹配，取不到。
   *
   * 可行路径：localStorage 各项均为 `{"data":"<base64>","time":<ms>}`，data 为
   * AES-128-ECB("mysupersecret123") 密文，解出 80 位 hex 后再 DES-CBC("njlz@123") 得 x-Token。
   * 拿到 x-Token + userId 后，业务接口零 Cookie 即可直连（抓包实测 3/3 接口 200）。
   *
   * @param sessionIdRaw localStorage['sessionId'] 原值（JSON 串）
   * @param userInfoRaw  localStorage['userInfo'] 原值（JSON 串）
   */
  static async adoptFromLocalStorage(sessionIdRaw: string, userInfoRaw: string): Promise<CloudSession> {
    let hex: string = '';
    try {
      hex = await ccDecodeLsValue(sessionIdRaw);
    } catch (e) {
      throw new Error(`localStorage.sessionId 解密异常：${(e as Error).message}`);
    }
    if (hex.length < 32) {
      throw new Error(`localStorage.sessionId 解密失败（原文${sessionIdRaw.length}字符，解出${hex.length}字符）`);
    }
    const xToken: string = await ccDesDecrypt(hex);
    if (xToken.length === 0) {
      throw new Error('x-Token 解密失败');
    }
    // userInfo 解出 userId/姓名/学号（只取必要字段落库，不整包持久化明文个人信息）
    let userId: string = '';
    let userName: string = '';
    let userNo: string = '';
    const infoJson: string = await ccDecodeLsValue(userInfoRaw);
    if (infoJson.length > 0) {
      try {
        const o: Record<string, Object> = JSON.parse(infoJson) as Record<string, Object>;
        userId = String(o['userId'] ?? '');
        userName = String(o['userName'] ?? '');
        userNo = String(o['userAccountNo'] ?? String(o['userNo'] ?? ''));
      } catch (e) {
        // 解析失败继续，userId 由调用方兜底
      }
    }
    if (userId.length === 0) {
      throw new Error('localStorage.userInfo 缺少 userId');
    }
    const out: CloudSession = {
      userId: userId,
      sessionId: hex,
      xToken: xToken,
      loginAt: Date.now(),
      userName: userName,
      userNo: userNo
    };
    CloudClassApi.session = out;
    DataStore.put(KEY_CC_SESSION, JSON.stringify(out));
    LogStore.log('云课堂', '网页登录', '会话建立',
      `userId=${userId} 姓名=${userName} xToken=${xToken.substring(0, 8)}…`);
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
    // 防御：接口异常时可能返回对象（如 {"code":401,...}）而非数组，直接当数组用会静默返回空
    let parsed: Object | null = null;
    try {
      parsed = JSON.parse(body) as Object;
    } catch (e) {
      LogStore.log('云课堂', '学期', '解析失败', body.substring(0, 200));
      return null;
    }
    if (!Array.isArray(parsed)) {
      LogStore.log('云课堂', '学期', '非数组响应', body.substring(0, 200));
      return null;
    }
    const arr: Record<string, Object>[] = parsed as Record<string, Object>[];
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

  /** 确保会话有效（优先冷启动恢复；过期则静默续期） */
  private static async ensureSession(): Promise<CloudSession> {
    CloudClassApi.restoreSession();
    if (CloudClassApi.session !== null && CloudClassApi.isLoggedIn()) {
      return CloudClassApi.session;
    }
    return CloudClassApi.silentRelogin();
  }

  /** 签名业务请求（GET/POST），返回响应体字符串。
   *  session 失效（HTTP 401/403）时自动静默重登并重试一次，避免用户看到"云课堂不可用"。 */
  private static async ccSignedRequest(s: CloudSession, url: string,
    method: 'GET' | 'POST', body: string): Promise<string> {
    const headers: Record<string, string> = await ccSignHeaders(s.userId, s.xToken, Const.CC_REFERER);
    try {
      return await CloudClassApi.ccRequest(url, method, headers, body);
    } catch (e) {
      const msg: string = (e as Error).message ?? '';
      const expired: boolean = msg.indexOf('401') >= 0 || msg.indexOf('403') >= 0;
      if (!expired) {
        throw e as Error;
      }
      LogStore.log('云课堂', '会话', '过期重登', msg);
      CloudClassApi.session = null;
      const s2: CloudSession = await CloudClassApi.silentRelogin();
      const h2: Record<string, string> = await ccSignHeaders(s2.userId, s2.xToken, Const.CC_REFERER);
      return await CloudClassApi.ccRequest(url, method, h2, body);
    }
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
    } catch (e) {
      // 网络层异常（DNS/超时/TLS 等）：记录 URL 与错误码，便于定位云课堂不可用原因
      LogStore.logNet('云课堂', '请求', T('异常'),
        { method: method, url: url, error: LogStore.errorOf(e as Object), detail: body.length > 0 ? body.substring(0, 200) : '' });
      throw e as Error;
    } finally {
      client.destroy();
    }
  }

  /** 从 URL 提取主机名（Cookie 按域隔离用） */
  private static hostOf(url: string): string {
    const m: RegExpMatchArray | null = url.match(/^https?:\/\/([^/]+)/i);
    return m ? m[1].toLowerCase() : '';
  }

  /** 日志用：截断过长的 URL（保留 host + 路径前段，避免日志被 ticket 参数淹没） */
  private static shortenUrl(url: string): string {
    if (url.length <= 90) {
      return url;
    }
    return url.substring(0, 90) + '…';
  }

  /** 日志用：本次响应的 Set-Cookie 名称列表（不记值，避免泄露凭据） */
  private static cookieNames(headers: rcp.ResponseHeaders): string {
    const sc: string | string[] | undefined = headers['set-cookie'] as (string | string[] | undefined);
    if (sc === undefined) {
      return '';
    }
    const list: string[] = Array.isArray(sc) ? sc : [String(sc)];
    const names: string[] = [];
    for (const item of list) {
      const seg: string = item.split(';')[0].trim();
      const eq: number = seg.indexOf('=');
      if (eq > 0) {
        names.push(seg.substring(0, eq));
      }
    }
    return names.join(',');
  }

  /** rcp 请求（登录 SSO 链路用，autoRedirect=false），按域收集 Cookie */
  private static async ccFetch(session: rcp.Session, jar: CcCookieJar, url: string,
    method: 'GET' | 'POST'): Promise<CcHop> {
    const headers: rcp.RequestHeaders = {
      'User-Agent': 'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    };
    const host: string = CloudClassApi.hostOf(url);
    const ck: string = jar.header(host);
    if (ck.length > 0) {
      headers['Cookie'] = ck;
    }
    const request: rcp.Request = new rcp.Request(url, method, headers, '');
    const resp: rcp.Response = await session.fetch(request);
    const sc: string | string[] | undefined = resp.headers['set-cookie'] as (string | string[] | undefined);
    jar.setFromHeader(host, sc);
    return { status: resp.statusCode ?? 0, headers: resp.headers, body: resp.toString() ?? '' };
  }

  /** 从跳转目标/body 提取 32 位 hex 业务 ticket（兼容 JSON 字段、URL 编码两种形式） */
  private static pickBizTicket(text: string): string {
    if (text.length === 0) {
      return '';
    }
    let m: RegExpMatchArray | null = text.match(/ticket=([0-9a-f]{32})/i);
    if (m) {
      return m[1];
    }
    m = text.match(/"ticket"\s*:\s*"([0-9a-f]{32})"/i);
    if (m) {
      return m[1];
    }
    m = text.match(/ticket%3D([0-9a-f]{32})/i);
    if (m) {
      return m[1];
    }
    return '';
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
