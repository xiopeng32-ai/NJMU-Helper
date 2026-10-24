/**
 * CasApi —— 南医大统一身份认证（CAS 单点登录，不依赖 WebView）
 *
 * 目标：authserver.njmu.edu.cn（金智 IDS 统一身份认证平台）
 * 标准 CAS 协议流程：
 *  1) GET  authserver 登录页，提取 pwdEncryptSalt + execution + lt 隐藏域；
 *  2) checkNeedCaptcha 判断是否需要验证码（需要则抛出 CasCaptchaRequiredError，UI 转网页版兜底）；
 *  3) AES 加密密码（金智 IDS 方案），POST 登录表单（rememberMe 对应"7天免登录"）；
 *  4) 手动跟随 302 链（autoRedirect=false），按 host+path 维护 Cookie 罐，最终拿到 CASTGC（TGT 票据，相当于授权 code）；
 *  5) 携带 CASTGC + service=教务SSO端点 再次访问 authserver，换取 ST（ticket 服务票据）；
 *  6) 携带 ticket 访问教务系统 SSO 回调端点（/sso/jzlogin），换取 jwglxt 的 JSESSIONID + MOD_AUTH_CAS + route Cookie；
 *  7) 后续爬取课表/成绩/考试页面复用该 jwglxt 会话。
 *
 * 使用 @hms.collaboration.rcp：autoRedirect 默认 true，这里显式关闭并手动跟随，
 * 以在每一步注入/收集"按路径匹配"的 Cookie，规避同名 JSESSIONID 跨路径串味导致无限重定向/901。
 */
import rcp from '@hms.collaboration.rcp';
import { util } from '@kit.ArkTS';
import { aesEncryptPassword } from '../common/AesUtil';
import { LogStore } from '../common/LogStore';
import { DataStore } from '../common/DataStore';
import { Const } from '../common/Constants';

/** CAS（统一身份认证）登录入口 —— 南医大 authserver.njmu.edu.cn（金智 IDS） */
const CAS_LOGIN_URL: string = Const.CAS_LOGIN_URL;
/** 浏览器 UA（与服务端交互需要，部分网关按 UA 放行） */
const CAS_UA: string =
  'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/** 需要验证码时抛出，携带服务端验证码图片（base64，无前缀）；调用方展示图片让用户输入后重试 */
export class CasCaptchaRequiredError extends Error {
  /** 验证码图片 base64（可能为空：无法拉取图片时 UI 走网页登录兜底） */
  captchaImage: string = '';

  constructor(msg: string, image: string = '') {
    super(msg);
    this.name = 'CasCaptchaRequiredError';
    this.captchaImage = image;
  }
}

/** 一跳响应 */
interface Hop {
  status: number;
  headers: rcp.ResponseHeaders;
  body: string;
  url: string;
}

/** Cookie 罐中的单条记录（按 host+path 隔离同名 Cookie） */
interface CookieEntry {
  name: string;
  value: string;
  path: string;
}

/** 解析后的 URL 组成部分 */
interface UrlParts {
  host: string;
  path: string;
}

/** 一次 CAS 登录的产出：教务系统会话 Cookie 串 + CASTGC（7天免登录用） */
export interface CasLoginResult {
  cookie: string;
  castgc: string;
}

/** 简易 Cookie 罐：host -> (name|path -> {name,value,path})，按路径隔离同名 Cookie */
class CookieJar {
  private jar: Map<string, Map<string, CookieEntry>> = new Map();

  private hostOf(url: string): string {
    const idx: number = url.indexOf('://');
    const rest: string = idx >= 0 ? url.substring(idx + 3) : url;
    const slash: number = rest.indexOf('/');
    return slash >= 0 ? rest.substring(0, slash) : rest;
  }

  private reqPathOf(url: string): string {
    const idx: number = url.indexOf('://');
    const rest: string = idx >= 0 ? url.substring(idx + 3) : url;
    const slash: number = rest.indexOf('/');
    if (slash < 0) {
      return '/';
    }
    const q: number = rest.indexOf('?', slash);
    return q >= 0 ? rest.substring(slash, q) : rest.substring(slash);
  }

  /** 从响应头解析并存入 Set-Cookie（支持多条、带 path 属性） */
  setCookies(url: string, header: rcp.ResponseHeaders): void {
    const sc: string | string[] | undefined = header['set-cookie'] as (string | string[] | undefined);
    if (sc === undefined) {
      return;
    }
    const list: string[] = Array.isArray(sc) ? sc : [String(sc)];
    const host: string = this.hostOf(url);
    if (!this.jar.has(host)) {
      this.jar.set(host, new Map());
    }
    const m: Map<string, CookieEntry> = this.jar.get(host)!;
    for (let i = 0; i < list.length; i++) {
      const seg: string[] = list[i].split(';');
      const eq: number = seg[0].indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const name: string = seg[0].substring(0, eq).trim();
      const value: string = seg[0].substring(eq + 1).trim();
      let path: string = '/';
      for (let j = 1; j < seg.length; j++) {
        const t: string = seg[j].trim();
        if (t.toLowerCase().startsWith('path=')) {
          path = t.substring(5).trim();
          if (path.length === 0) {
            path = '/';
          }
        }
      }
      m.set(name + '|' + path, { name, value, path });
    }
  }

  /** 取某个请求 URL 应携带的 Cookie 头（按路径前缀匹配，path=/ 全匹配） */
  cookieHeader(url: string): string {
    const host: string = this.hostOf(url);
    const m: Map<string, CookieEntry> | undefined = this.jar.get(host);
    if (m === undefined) {
      return '';
    }
    const reqPath: string = this.reqPathOf(url);
    const out: string[] = [];
    m.forEach((c) => {
      if (reqPath.startsWith(c.path) || c.path === '/') {
        out.push(c.name + '=' + c.value);
      }
    });
    return out.join('; ');
  }

  /** 直接注入一条 cookie（冷启动自动重登时复用持久化 CASTGC） */
  putCookie(host: string, name: string, value: string, path: string = '/'): void {
    if (!this.jar.has(host)) {
      this.jar.set(host, new Map());
    }
    this.jar.get(host)!.set(name + '|' + path, { name, value, path });
  }

  /** 取某 host 下指定 path 的某 name Cookie 值 */
  cookieValue(host: string, path: string, name: string): string {
    const full: string = this.cookieHeader('https://' + host + path);
    const parts: string[] = full.split(';');
    for (let i: number = 0; i < parts.length; i++) {
      const seg: string = parts[i].trim();
      const eq: number = seg.indexOf('=');
      if (eq > 0 && seg.substring(0, eq).trim() === name) {
        return seg.substring(eq + 1).trim();
      }
    }
    return '';
  }

  /** 导出某 host 的全部 Cookie 串（"n1=v1; n2=v2"），用于持久化可信设备凭据 */
  dumpHost(host: string): string {
    const m: Map<string, CookieEntry> | undefined = this.jar.get(host);
    if (m === undefined) {
      return '';
    }
    const out: string[] = [];
    m.forEach((c: CookieEntry) => {
      out.push(`${c.name}=${c.value}`);
    });
    return out.join('; ');
  }

  /** 从 Cookie 串导入（回放此前保存的可信设备凭据，如 MULTIFACTOR_BROWSER_FINGERPRINT） */
  importHeader(host: string, header: string, path: string = '/'): void {
    if (header.length === 0) {
      return;
    }
    const parts: string[] = header.split(';');
    for (let i: number = 0; i < parts.length; i++) {
      const seg: string = parts[i].trim();
      const eq: number = seg.indexOf('=');
      if (eq > 0) {
        this.putCookie(host, seg.substring(0, eq).trim(), seg.substring(eq + 1).trim(), path);
      }
    }
  }
}

/** 解析绝对 URL 的 host 与 path（ArkTS 不依赖标准 URL） */
function parseUrl(url: string): UrlParts {
  const idx: number = url.indexOf('://');
  const rest: string = idx >= 0 ? url.substring(idx + 3) : url;
  const slash: number = rest.indexOf('/');
  const host: string = slash >= 0 ? rest.substring(0, slash) : rest;
  let path: string = slash >= 0 ? rest.substring(slash) : '/';
  const q: number = path.indexOf('?');
  if (q >= 0) {
    path = path.substring(0, q);
  }
  return { host, path };
}

export class CasApi {
  // ── 验证码会话保持 ──
  // 金智 IDS 的图形验证码与会话（authserver JSESSIONID）绑定：
  // 第一次登录发现需要验证码时不能销毁会话，必须复用同一 session+CookieJar
  // 拉取验证码图片并在用户输入后继续 POST，否则验证码必然校验失败。
  private static pendingSession: rcp.Session | null = null;
  private static pendingJar: CookieJar | null = null;
  private static pendingSalt: string = '';
  private static pendingExecution: string = '';
  private static pendingLt: string = '';

  /** 从 authserver 拉取一张新的图形验证码（base64，无 data 前缀）。必须使用未销毁的登录会话。 */
  static async fetchCaptchaImage(session: rcp.Session, jar: CookieJar): Promise<string> {
    const url: string = `https://${Const.AUTH_HOST}/authserver/captcha.htl?ts=${new Date().getTime()}`;
    const request: rcp.Request = new rcp.Request(url, 'GET', {
      'User-Agent': CAS_UA,
      'Referer': CAS_LOGIN_URL,
      'Accept': 'image/avif,image/webp,image/png,image/jpeg,*/*',
      'Cookie': jar.cookieHeader(url)
    }, undefined);
    const bin: rcp.Response = await session.fetch(request);
    jar.setCookies(url, bin.headers);
    const buf: ArrayBuffer | undefined = bin.body;
    if (buf === undefined || buf.byteLength < 64) {
      throw new Error('验证码图片拉取失败');
    }
    const helper: util.Base64Helper = new util.Base64Helper();
    return helper.encodeToStringSync(new Uint8Array(buf));
  }

  /** 刷新验证码：用户点击验证码图片时调用（复用挂起的登录会话）。失败返回空串。 */
  static async refreshCaptcha(): Promise<string> {
    if (CasApi.pendingSession === null || CasApi.pendingJar === null) {
      return '';
    }
    try {
      const b64: string = await CasApi.fetchCaptchaImage(CasApi.pendingSession, CasApi.pendingJar);
      return b64;
    } catch (e) {
      return '';
    }
  }

  /** 释放挂起的登录会话（登录成功/彻底失败后调用；session 实际关闭交由调用处 finally） */
  private static clearPending(): void {
    CasApi.pendingSession = null;
    CasApi.pendingJar = null;
    CasApi.pendingSalt = '';
    CasApi.pendingExecution = '';
    CasApi.pendingLt = '';
  }

  /**
   * 执行原生 CAS 统一认证登录，返回教务系统会话 Cookie 串（含 jwglxt JSESSIONID 与 route）与 CASTGC（用于 7天免登录）。
   * @param captcha 图形验证码（首次登录留空；服务端要求验证码时抛 CasCaptchaRequiredError 并携带图片，用户输入后重传）
   */
  static async nativeCasLogin(account: string, password: string, remember7d: boolean, captcha: string = ''): Promise<CasLoginResult> {
    // 复用挂起会话（验证码重试链路），否则新建
    let session: rcp.Session;
    let jar: CookieJar;
    let reuse: boolean = false;
    if (CasApi.pendingSession !== null && CasApi.pendingJar !== null) {
      session = CasApi.pendingSession;
      jar = CasApi.pendingJar;
      reuse = true;
    } else {
      session = rcp.createSession({
        requestConfiguration: {
          transfer: { autoRedirect: false } as rcp.TransferConfiguration
        }
      });
      jar = new CookieJar();
    }
    const authHost: string = Const.AUTH_HOST;
    try {
      // ── STEP 1: 取统一认证登录页，拿 salt / execution / lt（验证码重试时复用上次的表单参数）──
      let salt: string = '';
      let execution: string = '';
      let lt: string = '';
      if (reuse && CasApi.pendingExecution.length > 0) {
        salt = CasApi.pendingSalt;
        execution = CasApi.pendingExecution;
        lt = CasApi.pendingLt;
      } else {
        const p1: Hop = await CasApi.fetch(session, jar, CAS_LOGIN_URL, 'GET');
        salt = CasApi.pick(p1.body, /name="pwdEncryptSalt"\s+value="([^"]*)"/) ||
          CasApi.pick(p1.body, /id="pwdEncryptSalt"\s+value="([^"]*)"/);
        execution = CasApi.pick(p1.body, /name="execution"\s+value="([^"]*)"/);
        lt = CasApi.pick(p1.body, /name="lt"\s+value="([^"]*)"/);
        if (salt.length === 0 || execution.length === 0) {
          CasApi.clearPending();
          throw new Error('无法解析统一认证登录页（salt/execution 缺失）');
        }
        // 挂起会话参数（供验证码重试复用）
        CasApi.pendingSession = session;
        CasApi.pendingJar = jar;
        CasApi.pendingSalt = salt;
        CasApi.pendingExecution = execution;
        CasApi.pendingLt = lt;
      }

      // ── STEP 2: 是否需要验证码 ──
      if (captcha.length === 0) {
        const capUrl: string = `https://${authHost}/authserver/checkNeedCaptcha.htl?username=${encodeURIComponent(account)}&_=${new Date().getTime()}`;
        const cap: Hop = await CasApi.fetch(session, jar, capUrl, 'GET', {
          'Referer': CAS_LOGIN_URL,
          'X-Requested-With': 'XMLHttpRequest',
          'Accept': 'application/json'
        });
        const needCap: boolean = /"isNeed"\s*:\s*true/.test(cap.body) || /id="captchaId"/.test(cap.body);
        if (needCap) {
          // 会话保持挂起，拉取验证码图片交由用户识别
          let b64: string = '';
          try {
            b64 = await CasApi.fetchCaptchaImage(session, jar);
          } catch (e) {
            CasApi.clearPending();
          }
          throw new CasCaptchaRequiredError('该账号需要图形验证码', b64);
        }
      }

      // ── STEP 3: AES 加密密码并 POST 登录（携带验证码）──
      const enc: string = await aesEncryptPassword(password, salt);
      const form: string = 'username=' + encodeURIComponent(account) +
        '&password=' + encodeURIComponent(enc) +
        '&captcha=' + encodeURIComponent(captcha) +
        '&rememberMe=' + (remember7d ? 'true' : 'false') +
        '&_eventId=submit&cllt=userNameLogin&dllt=generalLogin&lt=' + encodeURIComponent(lt) +
        '&execution=' + encodeURIComponent(execution);
      const p2: Hop = await CasApi.fetch(session, jar, CAS_LOGIN_URL, 'POST', {
        'Referer': CAS_LOGIN_URL,
        'Origin': `https://${authHost}`,
        'Content-Type': 'application/x-www-form-urlencoded'
      }, form);

      // 登录失败（密码错/账号锁）：CAS 返回 200 + 错误提示
      if (p2.status >= 200 && p2.status < 300) {
        const tip: string = CasApi.pick(p2.body, /id="showErrorTip"[^>]*>([^<]*)</) ||
          CasApi.pick(p2.body, /id="msg"[^>]*>([^<]*)</) ||
          CasApi.pick(p2.body, /class="auth_error[^"]*"[^>]*>([^<]*)</);
        // 验证码错误：刷新验证码并要求重新输入（会话保持挂起）。
        // 注意：登录失败页本身就含"验证码"表单文案，不能用页面级关键词误判，只认错误提示/专用元素。
        if (/验证码/.test(tip) || /id="captchaError"/.test(p2.body) || /验证码错误|验证码不正确|验证码有误/.test(p2.body)) {
          let b64: string = '';
          try {
            b64 = await CasApi.fetchCaptchaImage(session, jar);
          } catch (e) {
            CasApi.clearPending();
          }
          throw new CasCaptchaRequiredError('验证码错误，请重新输入', b64);
        }
        if (tip.length > 0 || /用户名|密码|账号|锁定|冻结/.test(p2.body)) {
          CasApi.clearPending();
          throw new Error(tip.length > 0 ? tip : '学号或密码错误');
        }
      }

      // ── STEP 4: 跟随 302 链，收集 CASTGC（TGT 授权票据，相当于 OAuth code）──
      await CasApi.follow(session, jar, p2, 12);
      const castgc: string = jar.cookieValue(authHost, '/authserver', 'CASTGC');
      if (castgc.length === 0) {
        CasApi.clearPending();
        throw new Error('统一认证未返回 CASTGC（登录可能失败）');
      }
      // 登录已成功：结束挂起的验证码会话（session 由 finally 关闭）
      CasApi.clearPending();

      LogStore.log('登录', 'SSO', '成功', '已获取 CASTGC，正在换取教务系统会话');

      // ── STEP 5: 携带 CASTGC + service 换取 ST（ticket 服务票据）──
      const ticket: string = await CasApi.exchangeTicket(session, jar, castgc);

      // ── STEP 6: 携带 ticket 访问教务 SSO 回调端点，换取 jwglxt 会话 ──
      await CasApi.openJwxtWithTicket(session, jar, ticket);

      // ── STEP 6.5: 兜底——若 SSO 回调后仍未建立 jwglxt 会话，直接访问教务系统主页，
      //    强制触发会话落地（南医大 CAS 回跳链较长，openJwxtWithTicket 的 follow 可能未走完）。
      let jwHost: string = Const.JW_HOST;
      let jwglxtSid: string = jar.cookieValue(jwHost, '/jwglxt', 'JSESSIONID');
      if (jwglxtSid.length === 0) {
        const home: Hop = await CasApi.fetch(session, jar, `${Const.JW_BASE_URL}/jwglxt/xtgl/index_initMenu.html`, 'GET', {
          'Referer': 'https://authserver.njmu.edu.cn/'
        });
        await CasApi.follow(session, jar, home, 12);
        jwglxtSid = jar.cookieValue(jwHost, '/jwglxt', 'JSESSIONID');
      }

      // 取 jwglxt 的 JSESSIONID + MOD_AUTH_CAS + route（按 /jwglxt 路径匹配）
      // 2026-10 抓包实测：jwpt.njmu.edu.cn 教务会话 = JSESSIONID(Path=/jwglxt) + MOD_AUTH_CAS + route
      const modAuthCas: string = jar.cookieValue(jwHost, '/', 'MOD_AUTH_CAS');
      const route: string = jar.cookieValue(jwHost, '/', 'route');
      if (jwglxtSid.length === 0) {
        const anySid: string = jar.cookieValue(jwHost, '/', 'JSESSIONID');
        if (anySid.length === 0) {
          throw new Error('教务系统会话建立失败（未拿到 jwglxt JSESSIONID）');
        }
        CasApi.persistAuthCookies(jar);
        return CasApi.buildCookie(anySid, modAuthCas, route, castgc);
      }
      CasApi.persistAuthCookies(jar);
      return CasApi.buildCookie(jwglxtSid, modAuthCas, route, castgc);
    } finally {
      // 验证码等待期保持会话挂起（pendingSession 仍指向本 session），其余情况一律关闭
      if (CasApi.pendingSession !== session) {
        try {
          session.close();
        } catch (e) {
          // ignore
        }
      }
    }
  }

  /** 组装教务会话 Cookie 串（JSESSIONID + MOD_AUTH_CAS + route） */
  private static buildCookie(sid: string, modAuthCas: string, route: string, castgc: string): CasLoginResult {
    const parts: string[] = ['JSESSIONID=' + sid];
    if (modAuthCas.length > 0) {
      parts.push('MOD_AUTH_CAS=' + modAuthCas);
    }
    if (route.length > 0) {
      parts.push('route=' + route);
    }
    return { cookie: parts.join('; '), castgc };
  }

  /**
   * 保存 authserver 域全部 Cookie（尤其是 MULTIFACTOR_BROWSER_FINGERPRINT 可信设备指纹）。
   * 首次登录必然触发 MFA，登录成功后服务端下发该指纹（400 天），
   * 之后换取任何子系统 ST 时都必须回放，否则会被判为不可信设备、退回登录页而不发 ticket。
   */
  private static persistAuthCookies(jar: CookieJar): void {
    try {
      const all: string = jar.dumpHost(Const.AUTH_HOST);
      if (all.length === 0) {
        return;
      }
      DataStore.put(DataStore.KEY_CAS_AUTH_COOKIES, all);
      const hasFp: boolean = all.indexOf('MULTIFACTOR_BROWSER_FINGERPRINT') >= 0;
      LogStore.log('登录', '统一认证', '保存设备凭据', `Cookie=${all.split(';').length}项 设备指纹=${hasFp ? '有' : '无'}`);
    } catch (e) {
      // ignore
    }
  }

  /** 回放已保存的 authserver 域 Cookie（含设备指纹）；CASTGC 由调用方用最新值覆盖 */
  private static restoreAuthCookies(jar: CookieJar): void {
    try {
      const raw: string = DataStore.get(DataStore.KEY_CAS_AUTH_COOKIES);
      if (raw.length === 0) {
        return;
      }
      jar.importHeader(Const.AUTH_HOST, raw, '/authserver');
    } catch (e) {
      // ignore
    }
  }

  /**
   * 携带 CASTGC + service 访问 authserver，换取 ST（ticket）。
   * CAS 协议：已登录状态下请求 login?service=xxx 会 302 回跳 service 并附带 ticket=ST-xxxx。
   * 从回跳的 Location 中解析出 ticket 返回。
   */
  private static async exchangeTicket(session: rcp.Session, jar: CookieJar, castgc: string): Promise<string> {
    const serviceUrl: string = encodeURIComponent(Const.JW_SSO_BRIDGE_URL);
    const url: string = `${CAS_LOGIN_URL}?service=${serviceUrl}`;
    // 回放可信设备凭据（含 MULTIFACTOR_BROWSER_FINGERPRINT），避免换票被判为新设备触发 MFA
    CasApi.restoreAuthCookies(jar);
    // 确保请求携带 CASTGC Cookie（jar 已在登录链中收集，这里兜底再注入）
    jar.putCookie(Const.AUTH_HOST, 'CASTGC', castgc, '/authserver');
    const resp: Hop = await CasApi.fetch(session, jar, url, 'GET');
    // 未登录会返回 200 登录页；已登录（有 CASTGC）会 302 回跳 service
    if (resp.status >= 300 && resp.status < 400) {
      const loc: string | string[] | undefined = resp.headers['location'] as (string | string[] | undefined);
      const target: string = Array.isArray(loc) ? loc[0] : String(loc ?? '');
      const t: string = CasApi.pickTicket(target);
      if (t.length > 0) {
        return t;
      }
    }
    // 兜底：从响应体里找 ticket（部分 CAS 用 meta refresh 或 JS 跳转）
    const fromBody: string = CasApi.pickTicket(resp.body);
    if (fromBody.length > 0) {
      return fromBody;
    }
    // 仍无 ticket：跟随跳转链，途中捕获 ticket；只要最终拿到 jwglxt 会话即视为成功
    let caughtTicket: string = '';
    await CasApi.follow(session, jar, resp, 16, (t: string) => {
      if (caughtTicket.length === 0) {
        caughtTicket = t;
      }
    });
    if (caughtTicket.length > 0) {
      return caughtTicket;
    }
    // 跟随链走完仍无 ticket，但若已建立 jwglxt 会话（JSESSIONID 落入 jar），也视为成功
    const sid: string = jar.cookieValue(Const.JW_HOST, '/jwglxt', 'JSESSIONID');
    if (sid.length > 0) {
      return '___DIRECT_SESSION___';
    }
    throw new Error('统一认证换取 ST 失败（未返回 ticket）');
  }

  /** 携带 ticket 访问教务 SSO 回调端点，建立 jwglxt 会话 */
  private static async openJwxtWithTicket(session: rcp.Session, jar: CookieJar, ticket: string): Promise<void> {
    const base: string = Const.JW_SSO_BRIDGE_URL;
    const sep: string = base.indexOf('?') >= 0 ? '&' : '?';
    const url: string = ticket === '___DIRECT_SESSION___' ? base : `${base}${sep}ticket=${encodeURIComponent(ticket)}`;
    const p3: Hop = await CasApi.fetch(session, jar, url, 'GET', {
      'Referer': 'https://authserver.njmu.edu.cn/'
    });
    await CasApi.follow(session, jar, p3, 20);
  }

  /** 冷启动自动重登：仅用持久化的 CASTGC 重新换取 jwxt 会话（不重新输入密码）。
   *  走统一认证 SSO：CASTGC → ST(ticket) → /sso/jzlogin → jwglxt 会话。 */
  static async silentRelogin(castgc: string): Promise<string> {
    const session: rcp.Session = rcp.createSession({
      requestConfiguration: {
        transfer: { autoRedirect: false } as rcp.TransferConfiguration
      }
    });
    const jar: CookieJar = new CookieJar();
    jar.putCookie(Const.AUTH_HOST, 'CASTGC', castgc, '/authserver');
    try {
      // 用 CASTGC 换 ST，再拿 ST 打开教务系统
      const ticket: string = await CasApi.exchangeTicket(session, jar, castgc);
      await CasApi.openJwxtWithTicket(session, jar, ticket);
      // 关键：必须带上本次桥接产生的 route（负载均衡粘滞 cookie），
      // 与登录成功时 nativeCasLogin 返回的 cookie 格式保持一致；
      // 否则无 route 时请求被路由到其它后端节点，JSESSIONID 不被识别，取数全部失败。
      const jwHost: string = Const.JW_HOST;
      const route: string = jar.cookieValue(jwHost, '/', 'route');
      const modAuthCas: string = jar.cookieValue(jwHost, '/', 'MOD_AUTH_CAS');
      const jwglxtSid: string = jar.cookieValue(jwHost, '/jwglxt', 'JSESSIONID');
      if (jwglxtSid.length === 0) {
        const anySid: string = jar.cookieValue(jwHost, '/', 'JSESSIONID');
        if (anySid.length === 0) {
          throw new Error('CASTGC 自动重登失败');
        }
        return CasApi.buildCookieString(anySid, modAuthCas, route);
      }
      return CasApi.buildCookieString(jwglxtSid, modAuthCas, route);
    } finally {
      try {
        session.close();
      } catch (e) {
        // ignore
      }
    }
  }

  /**
   * 用 CASTGC 换取任意 CAS service 的 ST 服务票据（供云课堂等其它子系统复用）。
   * 已登录（有 CASTGC）时请求 login?service=xxx 会 302 回跳 service 并附带 ticket=ST-xxxx。
   * @param castgc CAS 授权票据（TGT）
   * @param serviceUrl 目标 service 的 URL（未编码，方法内编码）
   * @returns ST 服务票据（如 ST-xxxx）；失败抛异常
   */
  static async exchangeStForService(castgc: string, serviceUrl: string): Promise<string> {
    const session: rcp.Session = rcp.createSession({
      requestConfiguration: {
        transfer: { autoRedirect: false } as rcp.TransferConfiguration
      }
    });
    const jar: CookieJar = new CookieJar();
    // ★ 回放可信设备凭据（含 MULTIFACTOR_BROWSER_FINGERPRINT + 已保存的其他 authserver Cookie），
    //   否则服务端判定为新设备 → 触发 MFA → 退回登录页而不下发 ticket
    CasApi.restoreAuthCookies(jar);
    jar.putCookie(Const.AUTH_HOST, 'CASTGC', castgc, '/authserver');
    try {
      const url: string = `${CAS_LOGIN_URL}?service=${encodeURIComponent(serviceUrl)}`;
      const resp: Hop = await CasApi.fetch(session, jar, url, 'GET');
      if (resp.status >= 300 && resp.status < 400) {
        const loc: string | string[] | undefined = resp.headers['location'] as (string | string[] | undefined);
        const target: string = Array.isArray(loc) ? loc[0] : String(loc ?? '');
        const t: string = CasApi.pickTicket(target);
        if (t.length > 0) {
          return t;
        }
      }
      const fromBody: string = CasApi.pickTicket(resp.body);
      if (fromBody.length > 0) {
        return fromBody;
      }
      let caught: string = '';
      await CasApi.follow(session, jar, resp, 16, (t: string) => {
        if (caught.length === 0) {
          caught = t;
        }
      });
      if (caught.length > 0) {
        return caught;
      }
      throw new Error('统一认证换取 ST 失败（未返回 ticket）');
    } finally {
      try {
        session.close();
      } catch (e) {
        // ignore
      }
    }
  }

  /** 组装教务会话 Cookie 串（无 castgc 版本，供 silentRelogin 返回 string） */
  private static buildCookieString(sid: string, modAuthCas: string, route: string): string {
    const parts: string[] = ['JSESSIONID=' + sid];
    if (modAuthCas.length > 0) {
      parts.push('MOD_AUTH_CAS=' + modAuthCas);
    }
    if (route.length > 0) {
      parts.push('route=' + route);
    }
    return parts.join('; ');
  }

  // ── 内部工具 ──

  private static async fetch(session: rcp.Session, jar: CookieJar, url: string, method: 'GET' | 'POST',
    extraHeaders: Record<string, string> = {}, body?: string): Promise<Hop> {
    const ck: string = jar.cookieHeader(url);
    const headers: rcp.RequestHeaders = {
      'User-Agent': CAS_UA,
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9'
    };
    (Object.keys(extraHeaders) as string[]).forEach((k: string) => {
      headers[k] = extraHeaders[k];
    });
    if (ck.length > 0) {
      headers['Cookie'] = ck;
    }
    const request: rcp.Request = new rcp.Request(url, method, headers, (body as rcp.RequestContent) ?? '');
    const resp: rcp.Response = await session.fetch(request);
    jar.setCookies(url, resp.headers);
    const text: string = resp.toString() ?? '';
    return { status: resp.statusCode ?? 0, headers: resp.headers, body: text, url };
  }

  /** 手动跟随 302 链（redirect 变 GET，http 升 https）。封顶 max 跳。
   *  兼容两种跳转：
   *   1) HTTP 3xx + Location 头（标准 302）；
   *   2) HTTP 200 + 响应体内的 meta refresh / JS location 跳转（南医大 CAS 部分页面用此方式）。
   *  每跳都从目标 URL 与响应体提取 ticket（ST），命中即记录，避免漏拿 ST。 */
  private static async follow(session: rcp.Session, jar: CookieJar, start: Hop, max: number, onTicket?: (t: string) => void): Promise<void> {
    let cur: Hop = start;
    for (let i = 0; i < max; i++) {
      let next: string = '';
      // 优先走 302 Location 头
      if (cur.status >= 300 && cur.status < 400) {
        const loc: string | string[] | undefined = cur.headers['location'] as (string | string[] | undefined);
        if (loc !== undefined) {
          next = Array.isArray(loc) ? loc[0] : String(loc);
        }
      }
      // 兜底：从响应体提取跳转目标（meta refresh 或 JS location）
      if (next.length === 0) {
        next = CasApi.pickJumpTarget(cur.body);
      }
      if (next.length === 0) {
        return;
      }
      if (next.startsWith('/')) {
        const u: UrlParts = parseUrl(cur.url);
        next = `https://${u.host}${next}`;
      }
      // 明文 http 在 rcp 下被禁（1007900201），统一升 https
      if (next.startsWith('http://')) {
        next = 'https://' + next.substring('http://'.length);
      }
      // 目标 URL 里若带 ticket，记录之（供 exchangeTicket 判定 ST）
      if (onTicket !== undefined) {
        const t: string = CasApi.pickTicket(next);
        if (t.length > 0) {
          onTicket(t);
        }
      }
      cur = await CasApi.fetch(session, jar, next, 'GET');
      continue;
    }
  }

  /** 从响应体提取跳转目标：meta refresh 的 content URL、或 JS 的 location.href / window.location 赋值 */
  private static pickJumpTarget(body: string): string {
    if (body.length === 0) {
      return '';
    }
    // <meta http-equiv="refresh" content="0;url=/xxx">
    let m: RegExpMatchArray | null = body.match(/<meta[^>]+http-equiv=["']?refresh["']?[^>]+content=["']?[^"']*url=([^"'\s;>]+)/i);
    if (m) {
      return CasApi.unescapeJump(m[1]);
    }
    m = body.match(/content=["']?\d+;\s*url=([^"'\s;>]+)/i);
    if (m) {
      return CasApi.unescapeJump(m[1]);
    }
    // JS 跳转：location.href = '...' / window.location = "..."
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

  /** 跳转 URL 反转义（处理 &amp; 等 HTML 实体） */
  private static unescapeJump(url: string): string {
    return url.replace(/&amp;/g, '&').replace(/&#38;/g, '&').replace(/&#x26;/gi, '&');
  }

  private static pick(html: string, re: RegExp): string {
    const m: RegExpMatchArray | null = html.match(re);
    return m ? m[1] : '';
  }

  /** 从 URL 或 HTML 中解析 ticket（CAS 协议：ST-xxxx 或 ticket=xxx） */
  private static pickTicket(text: string): string {
    if (text.length === 0) {
      return '';
    }
    // 优先匹配 ticket=xxx 形式
    let m: RegExpMatchArray | null = text.match(/[?&]ticket=([^&"'\s]+)/);
    if (m) {
      return m[1];
    }
    // 匹配 ST- 开头的服务票据
    m = text.match(/(ST-[A-Za-z0-9\-]+)/);
    if (m) {
      return m[1];
    }
    return '';
  }
}
