/**
 * 应用内网页视图：用于"网页版教务系统"、"找回密码"和外部链接。
 *
 * 关键点：
 * 1) 登录本 App 后，HttpClient 已保存教务系统会话 Cookie。这里在网页加载前
 *    把同一份 Cookie 注入到 WebView 的 Cookie 存储（按域名），从而使网页版也保持登录状态。
 * 2) "网页版登录"模式（AppState.webLoginMode=true）：用户在 WebView 内完成真实登录后，
 *    页面会离开 login_slogin 跳转到主页。此时把 WebView 的会话 Cookie 读回 HttpClient，
 *    拉取学生资料，并自动调用 onWebLogin 回调进入主页，无需手动回退。
 * 若尚未登录（游客模式 / 未登录态），Cookie 为空，网页会显示教务系统登录页，属正常行为。
 * 3) controller 附着后通过 onControllerReady 回调把 WebviewController 交给外层，
 *    供"外部链接"页（WebViewPage）的左上角"更多"菜单操作：前进后退/刷新/UA/历史记录/释放内存等。
 */
import { webview } from '@kit.ArkWeb';
import { AppState } from '../common/AppState';
import { Const } from '../common/Constants';
import { DataStore } from '../common/DataStore';
import { HttpClient } from '../api/HttpClient';
import { JwApi } from '../api/JwApi';
import { UserProfile } from '../model/Models';
import { LogStore } from '../common/LogStore';

@Component
export struct WebSurface {
  /** 页面加载完成后回传网页标题（供外部链接页更新标题栏；默认空回调） */
  onTitleChange: (title: string) => void = () => {
  };
  /** WebviewController 附着后回调（供外层菜单操作前进后退/刷新/UA/历史等） */
  onControllerReady: (ctrl: webview.WebviewController) => void = () => {
  };
  /** 页面加载完成（onPageEnd）后回调（外层可执行初始滚动让位等） */
  onLoadEnd: () => void = () => {
  };
  /** 主文档加载失败回调（外层提示网络问题；子资源失败不触发） */
  onLoadFail: () => void = () => {
  };
  /** 页面加载中标记：WebView 上方居中显示加载动画（切换 服务大厅/教务系统 时可见） */
  @State pageLoading: boolean = false;
  /**
   * 手动识别登录状态触发器：外部自增时**立即执行一次**会话抓取（tryGrabSession）。
   * 兜底场景：轮询漏判/登录成功没反应时，用户点「手动识别登录」按钮手动完成判定。
   */
  @Prop @Watch('onManualScanChanged') scanTrigger: number = 0;
  /**
   * 网页登录目标（hall/jw）：外部切换 服务大厅 ↔ 教务系统 时经 @Watch **由本组件自己重载**——
   * 此前靠外层 webCtrl.loadUrl，时机不对（controller 未就绪等）会出现「切换没反应，
   * 关闭面板重开才生效」。以 lastLoaded 去重避免重复加载。
   */
  @Prop @Watch('onTargetChanged') targetMode: string = '';
  private lastLoaded: string = '';
  /** 是否使用电脑端 UA（智慧学工默认开启） */
  desktopUa: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  /** 防止网页版登录成功回调被重复触发 */
  private loggedIn: boolean = false;
  /** 服务大厅模式：是否已触发桥接（避免重复跳转死循环） */
  private bridging: boolean = false;
  /** 桥接尝试次数（用于首次失败后的有限重试，避免停在服务大厅不自动登录） */
  private bridgeAttempts: number = 0;
  /** 网页登录期间的会话抓取轮询（兜底：不依赖 onPageEnd 与 URL 判定，主动抓取教务系统会话） */
  private pollTimer: number = -1;
  /** 会话抓取是否进行中（防止轮询重入导致并发校验） */
  private grabbing: boolean = false;
  /** 是否已尝试过"原生静默桥接"兜底（服务大厅网页登录场景，仅尝试一次） */
  private silentTried: boolean = false;
  /** 上次网页版登录目标（切换目标时重置 bridging） */
  private lastTarget: string = AppState.webLoginTarget;
  /** 自动提交登录是否已触发过一次（防止三次重试重复提交导致账号被误判） */
  private autoSubmitFired: boolean = false;

  /** 电脑端 UA（智慧学工等 PC 版页面） */
  private static readonly DESKTOP_UA: string =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /** WebView 组件出现：加载目标网页 */
  aboutToAppear(): void {
    this.loggedIn = false;
    this.bridging = false;
    this.bridgeAttempts = 0;
    this.silentTried = false;
    this.autoSubmitFired = false;
    this.lastTarget = AppState.webLoginTarget;
    // 初始 src 已是当前目标地址：记录 lastLoaded，避免 @Watch 首次触发重复加载
    this.lastLoaded = AppState.webUrl;
    // 校园 SSO 域名注入会话 Cookie（教务系统 + 统一认证/服务大厅；外部链接如 GitHub 不注入，避免隐私泄漏）
    if (AppState.webUrl.indexOf('jwpt.njmu.edu.cn') >= 0) {
      WebSurface.injectCookies(AppState.webUrl);
    }
    // 网页登录模式且有登录回调（仅"网页版登录"场景）：启动会话抓取轮询
    // （网页端查询等只同步 Cookie 的场景 onWebLogin 为 null，不轮询、不自动进主页）
    if (AppState.webLoginMode && AppState.onWebLogin !== null) {
      this.startLoginPoll();
    }
  }

  /** 手动识别触发：立即抓取一次会话（已判定登录成功则忽略） */
  onManualScanChanged(): void {
    if (this.scanTrigger > 0 && !this.loggedIn) {
      this.tryGrabSession().catch(() => {
      });
    }
  }

  /** 登录目标切换：重置桥接状态并加载对应登录页 */
  onTargetChanged(): void {
    if (this.targetMode.length === 0 || this.loggedIn) {
      return;
    }
    const url: string = this.targetMode === 'hall' ? Const.CAS_LOGIN_URL : Const.WEB_LOGIN_URL;
    if (url === this.lastLoaded) {
      return;
    }
    this.lastLoaded = url;
    this.bridging = false;
    this.bridgeAttempts = 0;
    this.silentTried = false;
    this.pageLoading = true;
    try {
      this.controller.loadUrl(url);
    } catch (e) {
      // controller 尚未挂载（极端时序）：忽略，页面自身的 src/轮询会继续兜底
    }
  }

  /** WebView 组件销毁：停止轮询，避免定时器泄漏 */
  aboutToDisappear(): void {
    this.stopLoginPoll();
  }

  /** 把 HttpClient 的教务系统会话 Cookie 写入 WebView 的域名 Cookie 存储，保持登录态；
   *  统一认证域名（authserver.njmu.edu.cn）同时注入 CASTGC，使 SSO 页面保持登录态 */
  private static injectCookies(url: string): void {
    // 教务系统会话（仅教务系统域名注入）
    if (url.indexOf('jwpt.njmu.edu.cn') >= 0) {
      const cookie: string = HttpClient.getCookie();
      if (cookie.length > 0) {
        const pairs: string[] = cookie.split(';');
        for (let i = 0; i < pairs.length; i++) {
          const kv: string = pairs[i].trim();
          if (kv.length === 0) {
            continue;
          }
          try {
            webview.WebCookieManager.setCookie(url, `${kv}; Domain=jwpt.njmu.edu.cn; Path=/`);
          } catch (e) {
            // 单条失败不影响其它
          }
        }
      }
    }
    // 统一认证会话（CASTGC 等），authserver 页面保持登录态
    if (url.indexOf('authserver.njmu.edu.cn') >= 0) {
      WebSurface.injectSsoCookies();
    }
  }

  /** 注入统一认证 CASTGC 会话 Cookie（写入 authserver 域名 Cookie 存储）：
   *  CASTGC（authserver）→ 教务系统 SSO 回调自动走 CAS 单点登录。 */
  private static injectSsoCookies(): void {
    // 统一认证 TGT（原生 CAS / 网页版登录均可能持久化）
    const tgc: string = DataStore.get(DataStore.KEY_CAS_TGC);
    if (tgc.length > 0) {
      try {
        webview.WebCookieManager.setCookie('https://authserver.njmu.edu.cn/',
          `CASTGC=${tgc}; Domain=authserver.njmu.edu.cn; Path=/`);
      } catch (e) {
        // ignore
      }
    }
    // 网页版登录捕获的会话 Cookie（host\ncookie 成对）
    const raw: string = DataStore.get(DataStore.KEY_SSO_COOKIES);
    if (raw.length === 0) {
      return;
    }
    const pairs: string[] = raw.split('\n');
    for (let i = 0; i + 1 < pairs.length; i += 2) {
      const host: string = pairs[i].trim();
      const cookieStr: string = pairs[i + 1];
      if (host.length === 0 || cookieStr.length === 0) {
        continue;
      }
      const kvs: string[] = cookieStr.split(';');
      for (let j = 0; j < kvs.length; j++) {
        const kv: string = kvs[j].trim();
        if (kv.length === 0) {
          continue;
        }
        try {
          webview.WebCookieManager.setCookie('https://' + host + '/',
            `${kv}; Domain=${host}; Path=/`);
        } catch (e) {
          // 单条失败不影响其它
        }
      }
    }
  }

  /** 自动勾选「记住我/7天免登录」复选框（正方教务 login_slogin 有 Spring Security rememberMe；
   *  金智 IDS authserver 登录页经实测**无**此复选框，CASTGC 恒为会话级 Cookie，故本函数在
   *  authserver 场景是安全空操作）。找不到复选框时不做任何事，不影响登录。 */
  private static autoCheckRememberMe(ctrl: webview.WebviewController): void {
    const inject: string =
      `(function(){` +
      `var el=document.getElementById('rememberMe');` +
      `if(!el){el=document.querySelector('input[name="rememberMe"]');}` +
      `if(!el){el=document.querySelector('input[type="checkbox"]');}` +
      `if(el&&!el.checked){el.checked=true;` +
      `if(typeof el.dispatchEvent==='function'){` +
      `el.dispatchEvent(new Event('change',{bubbles:true}));` +
      `el.dispatchEvent(new Event('click',{bubbles:true}));}` +
      `}return !!el;})()`;
    try {
      ctrl.runJavaScript(inject, () => {
      });
      // 延迟重试两次，覆盖异步渲染的复选框
      setTimeout(() => {
        try {
          ctrl.runJavaScript(inject, () => {
          });
        } catch (e) {
          // ignore
        }
      }, 800);
      setTimeout(() => {
        try {
          ctrl.runJavaScript(inject, () => {
          });
        } catch (e) {
          // ignore
        }
      }, 2000);
    } catch (e) {
      // ignore：注入失败不影响登录，仅失去"7天免登录"
    }
  }

  /** 统一认证登录页预填账号+密码：用户在登录页已输入的内容注入到 authserver 输入框，减少手动输入。
   *  金智 IDS 账号输入框 id=username；密码框 id=password（name=passwordText，明文），
   *  前端 encrypt.js 会在提交时把 passwordText 加密写入隐藏的 saltPassword(name=password)，
   *  故这里只需填 passwordText 并触发 input 事件，加密逻辑由页面 JS 自动完成。
   *  密码仅存内存（AppState.webPrefillPassword），注入后即时清空，不落盘。 */
  private static autoFillAccount(ctrl: webview.WebviewController): void {
    const account: string = AppState.webPrefillAccount;
    const password: string = AppState.webPrefillPassword;
    if (account.length === 0 && password.length === 0) {
      return;
    }
    const accountJson: string = JSON.stringify(account);
    const passwordJson: string = JSON.stringify(password);
    const inject: string =
      `(function(){` +
      `var ok=false;` +
      // 限定在「账号密码登录」tab（#pwdLoginDiv）内，避免命中手机动态码登录 tab 的同名输入框
      `var scope=document.getElementById('pwdLoginDiv');` +
      `if(!scope){scope=document;}` +
      `if(${accountJson}.length>0){` +
      `var u=scope.querySelector('#username, input[name="username"]');` +
      `if(u&&u.value.length===0){u.value=${accountJson};` +
      `u.dispatchEvent(new Event('input',{bubbles:true}));` +
      `u.dispatchEvent(new Event('change',{bubbles:true}));ok=true;}` +
      `}` +
      `if(${passwordJson}.length>0){` +
      `var p=scope.querySelector('#password, input[name="passwordText"], input[type="password"]');` +
      `if(p&&p.value.length===0){p.value=${passwordJson};` +
      `p.dispatchEvent(new Event('input',{bubbles:true}));` +
      `p.dispatchEvent(new Event('change',{bubbles:true}));ok=true;}` +
      `}` +
      `return ok;})()`;
    try {
      ctrl.runJavaScript(inject, () => {
      });
      setTimeout(() => {
        try {
          ctrl.runJavaScript(inject, () => {
          });
        } catch (e) {
          // ignore
        }
      }, 800);
      // 预填完成后立即清空内存中的密码（账号保留，供登录成功后记录历史账号）
      AppState.webPrefillPassword = '';
    } catch (e) {
      AppState.webPrefillPassword = '';
      // ignore：预填失败不影响登录
    }
  }

  /**
   * 自动提交登录：账号密码预填完成后，模拟点击登录页的「登录」按钮，实现无感自动登录。
   *
   * 金智 IDS 登录按钮是 `<a id="login_submit" class="login-btn">登录</a>`（非 <button>），
   * 点击事件由页面内联 JS 绑定：读取 #password（passwordText 明文）→ encrypt.js 加密写入
   * 隐藏域 #saltPassword（name=password）→ 提交 #pwdFromId 表单。故只需触发 click，加密与提交
   * 全由页面 JS 完成，无需我们在原生侧复刻加密。
   *
   * 自动提交的两个安全闸门（避免盲提交导致账号被误判/锁定）：
   * 1. 验证码闸门：needCaptcha 非空、或验证码容器 #captchaDiv 可见（未带 hide）时，**不自动提交**，
   *    只预填账号密码，留给用户手动输验证码后点击登录（此时无感登录客观不可行）；
   * 2. 密码闸门：未预填到密码（password 为空）时不提交，避免空密码触发错误计数。
   */
  private autoSubmitLogin(ctrl: webview.WebviewController): void {
    // 防重入：三次延迟重试里，一旦真正触发过提交（返回 ok），后续重试直接跳过，
    // 避免重复 click 导致账号被服务端误判（连续失败计数/验证码）。
    if (this.autoSubmitFired) {
      return;
    }
    // 注入 JS 精确复刻 login.js 的登录触发链路（金智 IDS customThemez/static/dzjs/login.js）：
    //   $(#login_submit).click() → checkForm()（校验 username/password 非空 + 按需校验验证码）
    //   → $("#saltPassword").val(encryptPassword(#password, #pwdEncryptSalt)) → $(".loginFromClass").submit()
    // 因此只需在预填账号密码后模拟 #login_submit 的 click，加密与提交由页面 JS 全权完成。
    const inject: string =
      `(function(){` +
      // 验证码闸门（login.js reloadCaptcha 用 .show()/.hide() 改 display，class 可能仍是 hide，
      // 故必须用 getComputedStyle 判断真实可见性，不能只看 className）：
      `var cap=document.getElementById('captchaDiv');` +
      `if(cap){var cs=null;try{cs=getComputedStyle(cap);}catch(e){}` +
      `if(cs&&cs.display&&cs.display!=='none'){return 'captcha';}}` +
      // needCaptcha 全局变量兜底（login.js checkNeedCaptcha 异步置 true，且 captchaSwitch==1 时提交需验证码）
      `var need=0;try{need=(typeof needCaptcha!=='undefined'&&needCaptcha&&String(needCaptcha).length>0)?1:0;}catch(e){}` +
      `if(need&&document.getElementById('captcha')&&document.getElementById('captcha').value.length===0){return 'captcha';}` +
      // 找登录按钮（金智 IDS：<a id="login_submit" href="javascript:void(0)" class="login-btn">登录</a>）
      `var btn=document.getElementById('login_submit');` +
      `if(!btn){btn=document.querySelector('a.login-btn');}` +
      `if(!btn){btn=document.querySelector('button[type="submit"]');}` +
      `if(!btn){btn=document.querySelector('input[type="submit"]');}` +
      `if(!btn){return 'no_btn';}` +
      // 账号闸门：checkForm 校验 username 非空，账号空时不会提交
      `var u=document.getElementById('username');` +
      `if(!u||u.value.length===0){return 'no_account';}` +
      // 密码闸门：checkForm 校验 password 非空，且 checkForm 靠读 #password 值来加密
      `var p=document.getElementById('password');` +
      `if(!p||p.value.length===0){return 'no_pwd';}` +
      // 模拟点击登录按钮：click 触发 login.js 的处理器（checkForm → encryptPassword → submit）
      `btn.click();` +
      `return 'ok';})()`;
    try {
      ctrl.runJavaScript(inject, (err: Error, result: string) => {
        if (err) {
          LogStore.log('网页登录', '自动登录', '异常', LogStore.errorOf(err));
          return;
        }
        if (result === 'captcha') {
          // 需要验证码：无法无感登录，仅提示（账号密码已预填，用户输完验证码手动点登录）
          LogStore.log('网页登录', '自动登录', '跳过', '检测到验证码');
        } else if (result === 'no_pwd') {
          LogStore.log('网页登录', '自动登录', '跳过', '未预填到密码');
        } else if (result === 'no_account') {
          LogStore.log('网页登录', '自动登录', '跳过', '未预填到账号');
        } else if (result === 'no_btn') {
          LogStore.log('网页登录', '自动登录', '跳过', '未找到登录按钮');
        } else {
          // 已真正触发提交：置防重入标志，后续重试直接跳过
          this.autoSubmitFired = true;
          LogStore.log('网页登录', '自动登录', '成功', '模拟点击登录按钮');
        }
      });
    } catch (e) {
      // ignore：自动提交失败不影响手动登录
    }
  }

  /** 捕获统一认证 CASTGC 会话 Cookie（网页版登录成功后 + 浏览 authserver 页面时调用），
   *  供冷启动自动重登（silentCasRelogin）复用 CASTGC。 */
  private static captureSsoCookies(): void {
    const auth: string = webview.WebCookieManager.getCookie('https://authserver.njmu.edu.cn/');
    if (auth.length === 0) {
      return;
    }
    const parts: string[] = [];
    parts.push('authserver.njmu.edu.cn');
    parts.push(auth);
    // CASTGC 同步到 KEY_CAS_TGC（统一认证登录：冷启动静默重登刷新教务会话用）
    const castgc: string = WebSurface.cookieValueOf(auth, 'CASTGC');
    if (castgc.length > 0) {
      DataStore.put(DataStore.KEY_CAS_TGC, castgc);
    }
    DataStore.put(DataStore.KEY_SSO_COOKIES, parts.join('\n'));
  }

  /** 从 cookie 串中取指定名称的值（如 CASTGC=xxx; Path=/ → CASTGC 的值） */
  private static cookieValueOf(cookieStr: string, name: string): string {
    const prefix: string = name + '=';
    const pairs: string[] = cookieStr.split(';');
    for (let i = 0; i < pairs.length; i++) {
      const kv: string = pairs[i].trim();
      if (kv.indexOf(prefix) === 0) {
        return kv.substring(prefix.length);
      }
    }
    return '';
  }

  /** 网页登录期间启动会话抓取轮询：每 1.5s 主动检查教务系统会话是否可用，
   *  不依赖页面跳转时机与 URL 判定，解决"网页已登录却不自动登录/不抓 Cookie"的问题 */
  private startLoginPoll(): void {
    if (this.pollTimer >= 0) {
      return;
    }
    this.pollTimer = setInterval(() => {
      if (!AppState.webLoginMode || this.loggedIn) {
        this.stopLoginPoll();
        return;
      }
      this.tryGrabSession().catch(() => {
      });
    }, 1500);
  }

  /** 停止会话抓取轮询 */
  private stopLoginPoll(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  /** 主动抓取教务系统会话：读到 Cookie 即交由 handleWebLoginSuccess（内部以资料校验为准，未真正登录会自动回滚）
   *  仍停留在登录页/CAS 页时不抓取——那里会有"未登录"的 JSESSIONID，避免误判。
   *  服务大厅网页登录场景：WebView 无教务系统会话但已捕获 CASTGC 时，用原生静默桥接（HttpClient 侧，
   *  与冷启动重登同一可靠链路）换取会话，最多尝试一次。 */
  private async tryGrabSession(): Promise<void> {
    const url: string = this.controller.getUrl();
    if (url.indexOf('login_slogin') >= 0 || url.indexOf('authserver') >= 0) {
      return;
    }
    const cookie: string = webview.WebCookieManager.getCookie(Const.WEB_PORTAL_URL);
    if (cookie.length > 0) {
      this.handleWebLoginSuccess();
      return;
    }
    // 兜底：WebView 尚无教务系统会话，但服务大厅 CAS 已登录（CASTGC 已被 captureSsoCookies 捕获）
    if (!this.silentTried && AppState.webLoginTarget === 'hall' &&
        DataStore.get(DataStore.KEY_CAS_TGC).length > 0) {
      this.silentTried = true;
      const ok: boolean = await JwApi.silentCasRelogin();
      if (ok) {
        this.handleWebLoginSuccess();
      }
    }
  }

  /** 网页版登录成功后：Cookie 回 HttpClient、缓存资料到本地持久化、自动进入主页 */
  private async handleWebLoginSuccess(): Promise<void> {
    // 防重入：轮询与 onPageEnd 可能同时触发；已完成的登录不再重复处理
    if (this.grabbing || this.loggedIn) {
      return;
    }
    this.grabbing = true;
    try {
      this.loggedIn = true;
      // 两种模式最终都会落到教务系统页面：
      //  教务系统模式：直接登录 jwxt/jwglxt/xtgl/login_slogin.html，成功即跳主页；
      //  服务大厅模式：登录 rhmh 服务大厅后由教务系统桥接页换取 jwglxt 会话（见 onPageEnd）。
      // 必须读取"教务系统域名"的会话 Cookie：用当前页面 URL（若为 jwxt）兜底到教务系统门户地址，
      // 不能用起始的 AppState.webUrl（可能是 rhmh/jwxt 登录页），否则取不到 jwxt 会话。
      const curUrl: string = this.controller.getUrl();
      const cookieUrl: string = curUrl.indexOf('jwpt.njmu.edu.cn') >= 0 ? curUrl : Const.WEB_PORTAL_URL;
      // 优先读 WebView 的教务系统会话；若 WebView 尚无（如服务大厅网页登录后由原生静默桥接换取会话），
      // 回退读取 HttpClient 中已建立的会话，保证"已登录即自动进入主页"。
      let cookie: string = webview.WebCookieManager.getCookie(cookieUrl);
      if (cookie.length === 0) {
        cookie = HttpClient.getCookie();
      }
      if (cookie.length === 0) {
        // 尚未取到教务系统会话（可能仍在桥接跳转中）：回滚标记，交由轮询/后续 onPageEnd 继续尝试，
        // 避免"网页已登录但应用没自动登录"时误判为成功进入主页（主页会取不到数据）。
        this.loggedIn = false;
        return;
      }
      HttpClient.setCookie(cookie);
      // 持久化会话 Cookie 以便冷启动自动重登
      DataStore.put(DataStore.KEY_SESSION_COOKIE, cookie);
      // 网页版登录成功入口：立即记录登录方式与登录系统。
      // 不可放在 getProfile 成功之后——资料校验失败会导致记录缺失，退出弹窗会误显示「登录超时（异常）」。
      DataStore.setLoginMethod('web');
      // 登录系统：服务大厅模式（网页版登录走 authserver CAS）= 服务大厅登录；教务系统直登 = 教务登录
      DataStore.put(DataStore.KEY_LOGIN_SYSTEM, AppState.webLoginTarget === 'hall' ? 'service' : 'original');
      // 捕获统一认证/服务大厅会话 Cookie（网页版"服务大厅"登录后，我的页服务大厅/第二课堂保持登录态）
      WebSurface.captureSsoCookies();
      HttpClient.setOfflineMode(false);
      JwApi.USE_MOCK = false;
      try {
        const profile: UserProfile = await JwApi.getProfile();
        if (profile.name.length > 0) {
          AppState.profile = profile;
          AppState.account = profile.studentId;
          DataStore.cacheProfile(profile);
          DataStore.put(DataStore.KEY_LAST_ACCOUNT, profile.studentId);
        }
      } catch (e) {
        // ignore：资料拉取失败不影响"已登录"判定（会话与登录方式已在前方记录）
      }
      // 登录完成：停止会话抓取轮询并进入主页
      this.stopLoginPoll();
      AppState.webLoginMode = false;
      if (AppState.onWebLogin !== null) {
        AppState.onWebLogin();
      }
    } finally {
      this.grabbing = false;
    }
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Web({ src: AppState.webUrl, controller: this.controller })
        .width('100%')
        .height('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .onPageBegin(() => {
          this.pageLoading = true;
        })
        .onErrorReceive((event) => {
          // 主文档加载失败：提示网络问题（子资源失败不提示）
          if (event && event.request.isMainFrame()) {
            this.pageLoading = false;
            this.onLoadFail();
          }
        })
        .onControllerAttached(() => {
          // 功能浏览模式（USE_MOCK）默认断网：不加载真实网页，避免意外联网；
          // 隐藏调试模式（AppState.debugNetwork）开启后允许联网
          if (JwApi.USE_MOCK && !AppState.debugNetwork) {
            this.controller.loadUrl('about:blank');
            return;
          }
          // 校园域名（教务系统 + 统一认证）注入会话 Cookie；外部链接不注入，避免隐私泄漏
          if (AppState.webUrl.indexOf('jwpt.njmu.edu.cn') >= 0 ||
              AppState.webUrl.indexOf('authserver.njmu.edu.cn') >= 0) {
            WebSurface.injectCookies(AppState.webUrl);
          }
          // 智慧学工等 PC 版页面：使用电脑端 UA
          if (this.desktopUa) {
            this.controller.setCustomUserAgent(WebSurface.DESKTOP_UA);
          }
          this.controller.loadUrl(AppState.webUrl);
          // 把 controller 交给外层（"更多"菜单操作前进后退/刷新/UA/历史等）
          this.onControllerReady(this.controller);
        })
        .onPageEnd(() => {
          this.pageLoading = false;
          const url: string = this.controller.getUrl();
          if (AppState.webLoginMode && !this.loggedIn) {
            // 切换了登录目标：重置桥接状态，按新目标继续
            if (this.lastTarget !== AppState.webLoginTarget) {
              this.bridging = false;
              this.bridgeAttempts = 0;
              this.silentTried = false;
              this.lastTarget = AppState.webLoginTarget;
            }
            const onLoginPage: boolean = url.indexOf('login_slogin') >= 0 || url.indexOf('authserver') >= 0;
            // 统一认证登录页：自动勾选「7天免登录/记住我」，确保 CASTGC 持久化（否则只是会话级 Cookie，
            // 关闭 WebView 后失效，冷启动无法用 CASTGC 静默恢复登录态）。
            if (url.indexOf('authserver') >= 0 && url.indexOf('/login') >= 0) {
              WebSurface.autoCheckRememberMe(this.controller);
              WebSurface.autoFillAccount(this.controller);
              // 预填账号密码后自动提交登录（无感登录）。login.js 的 #login_submit click 处理器
              // 在 window.onload 里才绑定，故分三次延迟重试（600/1400/2400ms），覆盖预填生效与
              // 事件绑定完成两个时序，autoSubmitLogin 内部判定验证码/密码闸门决定是否真的提交。
              const delays: number[] = [600, 1400, 2400];
              for (let i = 0; i < delays.length; i++) {
                setTimeout(() => {
                  if (AppState.webLoginMode && !this.loggedIn) {
                    this.autoSubmitLogin(this.controller);
                  }
                }, delays[i]);
              }
            }
            // 已到达教务系统（脱离登录页）→ 读取 jwglxt 会话 Cookie 并完成登录。
            // 兼容桥接中间页（/sso/jzlogin）：此时 jwglxt 会话可能已建立，先尝试读取。
            const reachedJw: boolean = !onLoginPage &&
              (url.indexOf('jwglxt') >= 0 || url.indexOf('jzlogin') >= 0);
            const inHall: boolean = url.indexOf('jwpt.njmu.edu.cn') >= 0 && !onLoginPage;
            if (reachedJw) {
              this.handleWebLoginSuccess();
            } else if (AppState.webLoginTarget === 'hall' && !onLoginPage &&
                       (inHall || this.bridging) && this.bridgeAttempts < 2) {
              // 服务大厅模式：由服务大厅打开"新教务系统"换取 jwglxt 会话。
              // 2026-10 抓包实测：南医大门户到教务是标准 CAS ticket 握手（service=/sso/jzlogin），
              // 无 gid_ 加密参数；直接用 JW_BRIDGE_FROM_HALL_URL（即 https://jwpt.njmu.edu.cn/sso/jzlogin）。
              // 最多尝试 2 次，避免停在服务大厅页导致"网页已登录却不自动登录"。
              this.bridging = true;
              this.bridgeAttempts++;
              this.controller.loadUrl(Const.JW_BRIDGE_FROM_HALL_URL);
            }
          }
          // 页面加载完成：读取网页标题回传（让"外部链接"页标题栏自动变成网页标题）
          const pageTitle: string = this.controller.getTitle();
          if (pageTitle.length > 0) {
            this.onTitleChange(pageTitle);
          }
          // 通知外层（外部链接页用它做初始滚动让位：网页顶部落到悬浮顶栏下方）
          this.onLoadEnd();
          // 浏览统一认证页面（authserver）时刷新捕获的 CASTGC，保证下次冷启动可静默重登
          if (url.indexOf('authserver.njmu.edu.cn') >= 0) {
            WebSurface.captureSsoCookies();
          }
          // 记录到应用级共享历史（所有网页场景互通：教务系统/新闻网页/外部链接）
          if (url.length > 0 && url.indexOf('about:blank') < 0 && url.indexOf('resource://') < 0) {
            AppState.recordWebHistory(pageTitle, url);
          }
        })
        // 加载动画：页面加载中在 WebView 上方居中显示（切换 服务大厅/教务系统 时可见）
        if (this.pageLoading) {
          LoadingProgress()
            .width(38)
            .height(38)
            .color($r('app.color.brand'))
        }
      }
      .width('100%')
      .layoutWeight(1)
      .alignContent(Alignment.Center)
    }
    .width('100%')
    .height('100%')
  }
}
