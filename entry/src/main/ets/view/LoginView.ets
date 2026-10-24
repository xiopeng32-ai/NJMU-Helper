/**
 * 登录页：顶部学校徽标 + 学号密码登录 + 服务端驱动的验证码
 *
 * 登录策略（与真实教务系统一致）：
 *  - 客户端不做任何"本地校验"：用户输入完账号密码，直接 POST 到教务系统，
 *    由网页返回成功/失败。服务端响应要求验证码时（needCaptcha=true），
 *    才把验证码图片推给用户输入。
 *  - 历史登录账号：本地保存【账号+密码】（密码 XOR 0x5A + base64 编码），点击登录按钮下方的
 *    "历史账号"入口展开，可一键填充账号密码。
 */
import { KeyboardAvoidMode, promptAction, display } from '@kit.ArkUI';
import { mediaquery } from '@kit.ArkUI';
import { ResponsiveUtil } from '../common/ResponsiveUtil';
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { HttpClient } from '../api/HttpClient';
import { JwApi } from '../api/JwApi';
import { CasCaptchaRequiredError, CasApi } from '../api/CasApi';
import { AppState } from '../common/AppState';
import { Const } from '../common/Constants';
import { DataStore } from '../common/DataStore';
import { GlassMaterial } from '../common/GlassMaterial';
import { DissolveBurst } from './common/DissolveBurst';
import { ChevronRight } from './common/ChevronRight';
import { MaterialButton } from './common/MaterialButton';
// 沉浸光感：半模态弹窗内容走 MaterialSheetPanel（WebSurface/Web 内容弹窗例外，保持 bg_page 不透底）
import { MaterialSheetPanel } from './common/MaterialCard';
import { materialAvailable, sheetBlurStyle } from '../common/SystemMaterial';
import { MaterialCardLayer } from './common/MaterialCarrier';
import { LogStore } from '../common/LogStore';
import { DEVELOPER_DECLARATION, DeclarationSection } from '../common/PrivacyText';
import { Theme } from '../common/ThemeUtil';
import { AppearanceStore } from '../common/AppearanceStore';
import { LoginResult } from '../model/Models';
import { LogPage } from './LogPage';
import { WebSurface } from './WebSurface';
import { T } from '../common/I18n';

@Component
export struct LoginView {
  /** 界面语言版本号：切换语言后自增，订阅它即可重建本组件 */
  @StorageProp('langRev') langRev: number = 0;
  @StorageProp('topInsetPx') topInsetPx: number = 0;
  /** 灰字广播订阅：颜色表达式需传 this.grayTick 才登记响应式依赖（否则改色不实时刷新） */
  @StorageProp('grayTick') grayTick: number = 0;
  @StorageProp('themeColor') themeColor: string = 'green';
  @State account: string = '';
  @State password: string = '';
  @State captchaInput: string = '';
  @State captcha: string = '';
  @State captchaImage: string = '';
  @State showCaptcha: boolean = false;
  @State remember: boolean = false; // 默认不勾选（用户隐私优先，每次启动重新输入密码）
  /** 7天免登录：勾选后网页版/服务大厅登录成功会持久化教务系统会话 Cookie，便于下次自动重登 */
  @State remember7d: boolean = AppState.remember7d;
  @State loading: boolean = false;
  @State showWeb: boolean = false;
  /** 网页登录「手动识别登录状态」触发序号（自增触发 WebSurface 立即抓取一次会话） */
  @State webScanSeq: number = 0;
  /** 网页版登录目标（jw=教务系统直登 / hall=服务大厅），标题栏切换用 */
  @State webLoginTarget: string = AppState.webLoginTarget;
  /** 网页版登录 WebView 控制器（标题栏切换网址时重新加载用） */
  private webCtrl: webview.WebviewController | null = null;
  @State showHistory: boolean = false;
  /** 正在删除的历史账号（粒子消散 + 淡出收起动画用） */
  @State deletingAcct: string = '';
  /** 粒子消散触发序号（自增触发新一轮爆散） */
  @State burstSeq: number = 0;
  @State historyList: Record<string, string>[] = [];
  @State isLandscape: boolean = false;
  @State showPwd: boolean = false; // 密码明文/密文切换
  @State showPrivacy: boolean = false; // 隐私协议弹窗（首次启动未同意时显示）
  @State showDeclaration: boolean = false; // 开发者声明弹窗（同意隐私后用户首次任意点击时展示）
  @State declarationArmed: boolean = false; // 隐私已同意、等待用户首次点击触发开发者声明
  @State privacyAgreedAt: string = ''; // 隐私协议同意时间（右下角展示用）
  @State showRiskTip: boolean = false; // 账号风控提醒弹窗（开发者声明之后首次展示）
  @State loginMode: string = 'auto'; // 重登方式（auto=自动重登 / legacy=手动重登），切换后实时刷新显示
  @State loginSystem: string = 'service'; // 登录系统（默认：service=统一身份认证 CAS；original=教务系统 RSA 直登）
  @State sheetWidth: Dimension = '100%'; // 半模态面板宽度（≥600vp 视为平板，与课程表页面一致）
  /** 日志调试模式（AppStorage 响应式）：登录页连点图标 5 次 + 密码可开启；功能浏览模式同样生效 */
  @StorageProp('logEnabled') logEnabled: boolean = false;
  /** 全局字重响应式订阅：表达式读 this.fwMode 才登记依赖，fwValue 声明即订阅 */
  @StorageProp('fontWeightMode') fwMode: string = 'follow';
  @StorageProp('fontWeightValue') fwValue: number = 400;
  @StorageProp('logCollecting') logCollecting: boolean = true;
  /** 应用图标连点计数（5 次内有效） */
  @State logTapCount: number = 0;
  /** 日志调试密码输入弹窗开关 */
  @State showLogSheet: boolean = false;
  @State logPwd: string = '';
  /** 连点计时器（超时重置计数） */
  private logTapTimer: number = -1;
  /** 登录是否已取消（侧滑返回 / 20s 超时自动取消） */
  private loginCancelled: boolean = false;
  /** 登录超时计时器（20s 无响应自动取消，便于日志收集） */
  private loginTimer: number = -1;
  /** 是否内嵌展示日志详情页（登录页不在 Navigation 栈，不能 pushPath，改用内嵌切换） */
  @State showLogPage: boolean = false;

  private privacyController: webview.WebviewController = new webview.WebviewController();
  private accountController: TextInputController = new TextInputController();
  private passwordController: TextInputController = new TextInputController();
  onSuccess: () => void = () => {
  };
  /** 自动重登模式（冷启动恢复登录态）：显示加载符号、禁用交互、静默登录 */
  autoRelogin: boolean = false;
  /** 前往登录页模式（不退出登录）：左上角显示返回按钮 */
  showBack: boolean = false;
  /** 返回按钮回调（showBack 时显示，点击返回应用首页） */
  onBack: () => void = () => {
  };
  private landscapeListener: mediaquery.MediaQueryListener | null = null;
  /** 窗口宽度断点监听（PC 窗口缩放时切换布局） */
  private wideListener: mediaquery.MediaQueryListener | null = null;
  /** 当前窗口是否横向 / 是否宽 ≥ 600vp（两者组合出布局判定） */
  private landscapeMq: boolean = false;
  private wideMq: boolean = false;

  /** 页面出现：读取历史账号并填充、注册屏幕方向监听、检查隐私协议 */
  aboutToAppear(): void {
    // 键盘避让设为 RESIZE：键盘弹出时页面缩小而非上移，登录按钮可滚动到键盘上方点击
    try {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } catch (e) {
      // ignore
    }
    // 半模态面板宽度：平板（≥600vp）取 min(屏宽*0.7, 840)vp 加宽并封顶；手机全宽。与课程表页面一致。
    try {
      const d = display.getDefaultDisplaySync();
      const screenVp: number = this.getUIContext().px2vp(d.width);
      this.sheetWidth = screenVp >= 600 ? `${Math.min(Math.round(screenVp * 0.7), 840)}vp` : '100%';
    } catch (e) {
      this.sheetWidth = '100%';
    }
    // 记录隐私同意时间（供 privacySheet 兜底展示；正常首次引导由 Index 的 PrivacyGatePage 完成）
    this.privacyAgreedAt = DataStore.getPrivacyAgreedAt();
    // 重登方式：读取本地配置（未设置默认自动重登）
    this.loginMode = DataStore.getLoginMode().length > 0 ? DataStore.getLoginMode() : 'auto';
    // 登录系统：默认走南医大统一身份认证（service，CAS），用户可手动切换为教务 RSA 直登（original）。
    // 读取持久化选择；未保存过则默认统一身份认证。
    const savedSystem: string = DataStore.get(DataStore.KEY_LOGIN_SYSTEM);
    if (savedSystem === 'original') {
      this.loginSystem = 'original';
    } else {
      this.loginSystem = 'service';
    }
    // 自动重登模式：用保存的凭据静默登录（显示加载、禁用交互），不再让用户手动输入。
    // 南医大原生 CAS 换 ST 已失效，唯一可靠入口是网页登录（WebView 自动填号 + 自动点登录），
    // 故自动重登直接打开网页登录，不再走必然失败的原生 doLogin()。
    if (this.autoRelogin) {
      const autoAcct: string = DataStore.get(DataStore.KEY_AUTO_ACCOUNT);
      const autoPwd: string = DataStore.decodePwd(DataStore.get(DataStore.KEY_AUTO_PWD));
      if (autoAcct.length > 0 && autoPwd.length > 0) {
        this.account = autoAcct;
        this.password = autoPwd;
        this.accountController.addText(autoAcct);
        this.passwordController.addText(autoPwd);
        // 直接打开网页登录：WebSurface 会自动预填账号密码 + 自动勾选记住我 + 自动点登录
        this.loading = true;
        setTimeout(() => {
          this.openWebLogin();
        }, 150);
      } else {
        // 无保存凭据：无法自动重登，退回手动登录页
        this.loading = false;
        this.autoRelogin = false;
      }
      return;
    }
    // 恢复「记住密码」勾选状态（持久化）：退出登录/重启后仍记住，自动填充已保存密码
    this.remember = DataStore.loadRemember();
    // 读取历史账号（最近登录的账号+密码）。勾选「记住密码」时自动填充该账号已保存的密码，
    // 未勾选则只填账号，避免出现"取消勾选却仍然保存了密码"的体验割裂。
    this.historyList = DataStore.getAccountList();
    if (this.historyList.length > 0) {
      this.account = this.historyList[0]['account'] ?? '';
      if (this.remember) {
        this.password = DataStore.decodePwd(this.historyList[0]['password'] ?? '');
      }
    }
    // 通过 controller 把账号/密码真正写入输入框（TextInput 的 text 参数构造后不响应 @State，
    // 仅设置 this.account/this.password 变量不会刷新输入框，导致"记住密码"视觉上仍是空的）
    if (this.account.length > 0) {
      this.accountController.addText(this.account);
    }
    if (this.password.length > 0) {
      this.passwordController.addText(this.password);
    }
    this.listenLandscape();
  }

  /** 监听窗口尺寸/方向变化：窗口缩放或旋转时实时切换布局（判定规则见 ResponsiveUtil） */
  private listenLandscape(): void {
    const mq = this.getUIContext().getMediaQuery();
    this.landscapeMq = mq.matchMediaSync(ResponsiveUtil.QUERY_LANDSCAPE).matches;
    this.wideMq = mq.matchMediaSync(ResponsiveUtil.QUERY_WIDE).matches;
    this.applyLayout();
    this.landscapeListener = mq.matchMediaSync(ResponsiveUtil.QUERY_LANDSCAPE);
    this.landscapeListener.on('change', (res: mediaquery.MediaQueryResult) => {
      this.landscapeMq = res.matches;
      this.applyLayout();
    });
    this.wideListener = mq.matchMediaSync(ResponsiveUtil.QUERY_WIDE);
    this.wideListener.on('change', (res: mediaquery.MediaQueryResult) => {
      this.wideMq = res.matches;
      this.applyLayout();
    });
  }

  /** 组合出布局判定：宽 ≥ 600vp 且横向 → 大屏布局，否则手机端布局（见 ResponsiveUtil.isWideLayout） */
  private applyLayout(): void {
    this.isLandscape = ResponsiveUtil.isWideLayout(this.wideMq, this.landscapeMq);
  }

  /** 页面消失（侧滑返回 / 路由离开）：若登录进行中则取消登录（方便收集日志，避免后台残留请求） */
  aboutToDisappear(): void {
    // 注销 MediaQuery 监听（只置 null 不会取消注册，回调会持续持有已销毁的组件）
    if (this.landscapeListener !== null) {
      this.landscapeListener.off('change');
      this.landscapeListener = null;
    }
    if (this.wideListener !== null) {
      this.wideListener.off('change');
      this.wideListener = null;
    }

    this.landscapeListener = null;
    this.wideListener = null;
    if (this.loading) {
      this.cancelLogin(T('页面返回取消登录'));
    }
  }

  /** 取消登录：置取消标志、停止 loading、清除超时计时器、记录日志 */
  private cancelLogin(reason: string): void {
    this.loginCancelled = true;
    this.loading = false;
    if (this.loginTimer >= 0) {
      clearTimeout(this.loginTimer);
      this.loginTimer = -1;
    }
    LogStore.log('登录', '登录', '取消', reason);
  }

  /** 生成随机 4 位验证码字符（mock 模式） */
  private randomCode(): string {
    const chars: string = 'ABCDEFGHJKLMNPQRSTUVWXY23456789';
    let out: string = '';
    for (let i = 0; i < 4; i++) {
      out += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return out;
  }

  /** 加载/刷新验证码：mock 用本地随机码占位；真实模式从服务端拉取验证码图片。
   *  日志调试开启时把验证码图片保存为附件（供日志导出 zip 收集，辅助定位登录失败原因）。 */
  private loadCaptcha(): void {
    if (JwApi.USE_MOCK) {
      this.captcha = this.randomCode();
      this.captchaInput = '';
      return;
    }
    this.captchaInput = '';
    // 统一身份认证（CAS）链路：验证码与会话绑定，从挂起的 CAS 登录会话刷新；
    // 教务系统直登：走教务验证码接口。
    if (this.loginSystem === 'service') {
      CasApi.refreshCaptcha().then((b64: string) => {
        this.captchaImage = b64;
        this.saveCaptchaAttachment(b64);
      }).catch(() => {
        this.captchaImage = '';
      });
      return;
    }
    JwApi.getCaptcha().then((b64: string) => {
      this.captchaImage = b64;
      this.saveCaptchaAttachment(b64);
    }).catch(() => {
      this.captchaImage = '';
    });
  }

  /** 验证码 base64 存为附件文件（仅日志调试开启时；供日志导出打包 zip） */
  private saveCaptchaAttachment(b64: string): void {
    if (!LogStore.enabled() || b64.length === 0) {
      return;
    }
    try {
      const ctx: common.Context | null = AppState.context;
      if (ctx === null) {
        return;
      }
      const dir: string = `${ctx.cacheDir}/${LogStore.ATTACH_DIR}`;
      try {
        fileIo.mkdirSync(dir);
      } catch (e) {
        // 目录已存在，忽略
      }
      const b64Helper: util.Base64Helper = new util.Base64Helper();
      const bytes: Uint8Array = b64Helper.decodeSync(b64);
      const path: string = `${dir}/captcha_${new Date().getTime()}.jpg`;
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, bytes.buffer);
      fileIo.closeSync(file);
      LogStore.addAttachment(path);
    } catch (e) {
      // ignore（附件保存失败不影响登录）
    }
  }

  /**
   * 登录：不做本地校验，直接请求教务系统，等待网页返回结果。
   * 服务端要求验证码时，才把验证码图片推给用户输入后重试。
   */
  private async doLogin(): Promise<void> {
    // 必须先同意隐私协议
    if (!DataStore.isPrivacyAgreed()) {
      this.showPrivacy = true;
      return;
    }
    // 首次登录：未设置重登方式时默认使用"自动重登"（用户可在登录卡片下方的固定入口随时更改）
    if (DataStore.getLoginMode().length === 0) {
      DataStore.setLoginMode('auto');
      this.loginMode = 'auto';
    }
    if (this.account.trim().length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: T('请输入学号') });
      return;
    }
    if (this.password.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: T('请输入密码') });
      return;
    }
    // 真实登录：强制走真实接口，关闭离线模式
    // 若上一次是功能浏览模式，先清掉被演示数据污染的缓存（否则首页会显示演示学生数据）
    if (JwApi.USE_MOCK) {
      JwApi.clearMockPollutedCache();
    }
    JwApi.USE_MOCK = false;
    HttpClient.setOfflineMode(false);
    // 清掉功能浏览模式残留的演示周次，否则首页会按演示周次匹配真实课表（课全不显示）
    AppState.mockCurrentWeek = 0;
    HttpClient.clearSessionExpired();
    this.loading = true;
    this.loginCancelled = false;
    // 登录超时保护（分两阶段，避免"服务大厅网页已登录、应用却提示超时"的状态冲突）：
    // ① 20s 未返回但登录已进入收尾阶段（会话已建立，正在校验资料）→ 延长等待并提示；
    // ② 20s 未返回且会话未建立 → 按超时取消（便于日志收集定位原因）。
    if (this.loginTimer >= 0) {
      clearTimeout(this.loginTimer);
    }
    this.loginTimer = setTimeout(() => {
      if (!this.loading) {
        return;
      }
      if (JwApi.stage() === 'profile') {
        this.getUIContext().getPromptAction().showToast({ message: T('服务大厅已登录，正在完成登录…'), duration: 2000 });
        this.loginTimer = setTimeout(() => {
          if (this.loading) {
            this.cancelLogin(T('登录收尾超时（会话已建立、资料校验未完成），已自动取消'));
            this.getUIContext().getPromptAction().showToast({ message: T('登录收尾超时，请重试') });
          }
        }, 30000);
        return;
      }
      this.cancelLogin(T('登录等待超时（20s），已自动取消'));
      this.getUIContext().getPromptAction().showToast({ message: T('登录超时，已自动取消') });
    }, 20000);
    const captchaVal: string = this.showCaptcha ? this.captchaInput.trim() : '';
    let result: LoginResult;
    try {
      result = await JwApi.login(this.account.trim(), this.password, captchaVal, this.loginSystem);
    } catch (e) {
      if (this.loginTimer >= 0) {
        clearTimeout(this.loginTimer);
        this.loginTimer = -1;
      }
      if (this.loginCancelled) {
        return;
      }
      this.loading = false;
      // 服务端要求图形验证码：展示验证码图片让用户输入后重试（原生 CAS 链路已支持验证码）；
      // 无法拉取到验证码图片时，自动打开网页版（WebView）CAS 页兜底。
      if (e instanceof CasCaptchaRequiredError) {
        if (e.captchaImage.length > 0) {
          this.showCaptcha = true;
          this.captchaImage = e.captchaImage;
          this.captchaInput = '';
          this.saveCaptchaAttachment(e.captchaImage);
          this.getUIContext().getPromptAction().showToast({ message: T('请输入图形验证码后重试'), duration: 2000 });
        } else {
          this.getUIContext().getPromptAction().showToast({ message: T('该账号需要验证码，正在打开网页登录…'), duration: 2000 });
          this.openWebLogin();
        }
      } else {
        this.getUIContext().getPromptAction().showToast({ message: T('登录失败，请检查账号密码或网络'), duration: 2500 });
      }
      return;
    }
    if (this.loginTimer >= 0) {
      clearTimeout(this.loginTimer);
      this.loginTimer = -1;
    }
    // 已被侧滑返回/超时取消：不再处理结果（防止返回后仍弹 Toast / 跳转）
    if (this.loginCancelled) {
      return;
    }
    this.loading = false;

    if (result.success && result.profile !== null) {
      AppState.profile = result.profile;
      AppState.account = this.account.trim();
      // 记录历史账号：勾选"记住密码"保存密码；未勾选时保留该账号已保存的密码（不覆盖为空）
      const historyPwd: string = this.savedPasswordOf(this.account.trim());
      const pwdToSave: string = this.remember ? this.password : historyPwd;
      DataStore.addAccount(this.account.trim(), pwdToSave);
      this.historyList = DataStore.getAccountList();
      // 保存自动重登凭据（冷启动时静默重新登录刷新会话，否则服务端会话过期后功能不可用）
      DataStore.put(DataStore.KEY_AUTO_ACCOUNT, this.account.trim());
      DataStore.put(DataStore.KEY_AUTO_PWD, DataStore.encodePwd(this.password));
      // 登录方式：教务登录→pwd；服务大厅登录（CAS）已在 loginViaCas 内写 cas，勿覆盖
      if (this.loginSystem === 'original') {
        DataStore.setLoginMethod('pwd');
      }
      this.getUIContext().getPromptAction().showToast({ message: T('登录成功') });
      this.onSuccess();
    } else {
      // 只有服务端要求验证码，才显示验证码输入框并推送图片
      if (result.needCaptcha) {
        if (!this.showCaptcha) {
          this.showCaptcha = true;
        }
        this.loadCaptcha();
      }
      this.getUIContext().getPromptAction().showToast({ message: result.message, duration: 2500 });
    }
  }

  /** 打开网页版登录（WebView）：标题栏可切换"教务系统 / 服务大厅"两个登录网址，
   *  登录成功后按目标类型取 Cookie 并自动登录教务系统（服务大厅模式由 WebSurface 桥接 jwglxt）。
   *  网页登录是**真实登录入口**，mock/功能浏览模式下也必须可用（首次使用无会话时尤其依赖它）。
   *  南医大统一认证强制验证码 + 原生 ST 交换不可用，网页登录是唯一可靠入口，故作为主登录方式。 */
  private openWebLogin(): void {
    // 待预填账号密码：用户在登录页已输入的学号+密码，网页登录打开后注入到 authserver 对应输入框
    AppState.webPrefillAccount = this.account.trim();
    AppState.webPrefillPassword = this.password;
    AppState.webLoginMode = true;
    // 打开网页登录后复位 loading（自动重登模式此前置 true，避免一直转圈）
    this.loading = false;
    // 记住本次登录账号+密码（供网页登录成功后写入历史账号与自动重登凭据）
    const loginAcct: string = this.account.trim();
    const loginPwd: string = this.password;
    AppState.onWebLogin = () => {
      // 网页登录成功＝真实登录：退出 mock/离线模式，让真实会话立即生效
      if (JwApi.USE_MOCK) {
        JwApi.clearMockPollutedCache();
      }
      JwApi.USE_MOCK = false;
      HttpClient.setOfflineMode(false);
      AppState.mockCurrentWeek = 0;
      HttpClient.clearSessionExpired();
      // 记录登录账号 + 密码（网页登录成功后，密码可信，供历史账号自动填充）
      if (loginAcct.length > 0) {
        DataStore.addAccount(loginAcct, loginPwd.length > 0 ?
          loginPwd : this.savedPasswordOf(loginAcct));
        this.historyList = DataStore.getAccountList();
        // 保存自动重登凭据（冷启动静默重新登录用）：此前网页登录遗漏了这步，
        // 导致关闭 App 后自动重登拿不到密码、被迫回到手动登录。
        if (loginPwd.length > 0) {
          DataStore.put(DataStore.KEY_AUTO_ACCOUNT, loginAcct);
          DataStore.put(DataStore.KEY_AUTO_PWD, DataStore.encodePwd(loginPwd));
        }
      }
      // 用后即清：密码不留内存
      AppState.webPrefillPassword = '';
      this.showWeb = false;
      this.onSuccess();
    };
    this.webLoginTarget = AppState.webLoginTarget;
    // 南医大统一身份认证：打开 authserver 登录页，service 指向教务 SSO 端点
    AppState.webUrl = Const.CAS_LOGIN_URL +
      '?service=' + encodeURIComponent(Const.JW_SSO_BRIDGE_URL);
    AppState.webTitle = T('网页登录');
    this.showWeb = true;
  }

  /** 网页登录标题栏切换目标（服务大厅 ↔ 教务系统）：更新目标状态即可，
   *  WebView 重载由 WebSurface 的 targetMode @Watch 驱动（此前依赖外层 webCtrl.loadUrl，
   *  controller 时序不对时出现「切换没反应，重开面板才生效」） */
  private switchWebTarget(target: string): void {
    if (this.webLoginTarget === target) {
      return;
    }
    this.webLoginTarget = target;
    AppState.webLoginTarget = target;
    // 南医大统一身份认证：打开 authserver 登录页，service 指向教务 SSO 端点
    AppState.webUrl = Const.CAS_LOGIN_URL +
      '?service=' + encodeURIComponent(Const.JW_SSO_BRIDGE_URL);
  }

  /** 当前重登方式文案（自动重登 / 手动重登） */
  private loginModeText(): string {
    return this.loginMode === 'auto' ? T('自动重登') : T('手动重登');
  }

  /** 当前登录系统文案（统一身份认证 / 教务系统直登） */
  private loginSystemText(): string {
    return this.loginSystem === 'service' ? T('统一身份认证') : T('教务系统直登');
  }

  /** 切换登录系统（service=统一身份认证 CAS / original=教务系统 RSA 直登），切换后实时刷新显示
   *  重登方式联动：统一认证（service）默认手动重登（教务会话不可持久化，靠 CASTGC 静默桥接）；
   *  教务直登（original）默认自动重登（保存的账号密码自动登录）。 */
  private setLoginSystem(system: string): void {
    this.loginSystem = system;
    DataStore.put(DataStore.KEY_LOGIN_SYSTEM, system);
    if (system === 'service') {
      // 统一身份认证登录：手动重登（冷启动用 CASTGC 从统一认证重新桥接教务系统）
      DataStore.setLoginMode('legacy');
      this.loginMode = 'legacy';
    } else {
      // 教务直登：自动重登（保存的账号密码自动登录教务系统）
      DataStore.setLoginMode('auto');
      this.loginMode = 'auto';
    }
  }

  /** 更改重登方式（固定入口，可随时切换，切换后立即刷新显示） */
  private changeLoginMode(): void {
    const current: string = this.loginModeText();
    this.getUIContext().getPromptAction().showActionMenu({
      title: `选择重登方式（当前：${current}）`,
      buttons: [
        { text: T('自动重登'), color: '#005BAC' },
        { text: T('手动重登'), color: '#888888' }
      ]
    }).then((res: promptAction.ActionMenuSuccessResponse) => {
      if (res.index === 0) {
        DataStore.setLoginMode('auto');
        this.loginMode = 'auto';
        this.getUIContext().getPromptAction().showToast({ message: T('已切换为自动重登') });
      } else if (res.index === 1) {
        DataStore.setLoginMode('legacy');
        this.loginMode = 'legacy';
        this.getUIContext().getPromptAction().showToast({ message: T('已切换为手动重登') });
      }
    }).catch(() => {
      // 取消选择
    });
  }

  /** 切换登录系统（统一身份认证 ↔ 教务系统直登） */
  private changeLoginSystem(): void {
    const current: string = this.loginSystemText();
    this.getUIContext().getPromptAction().showActionMenu({
      title: `选择登录方式（当前：${current}）`,
      buttons: [
        { text: T('统一身份认证'), color: '#005BAC' },
        { text: T('教务系统直登'), color: '#888888' }
      ]
    }).then((res: promptAction.ActionMenuSuccessResponse) => {
      if (res.index === 0) {
        this.setLoginSystem('service');
        this.getUIContext().getPromptAction().showToast({ message: T('已切换为统一身份认证') });
      } else if (res.index === 1) {
        this.setLoginSystem('original');
        this.getUIContext().getPromptAction().showToast({ message: T('已切换为教务系统直登') });
      }
    }).catch(() => {
      // 取消选择
    });
  }

  /** 弹窗说明两种重登方式的区别（问号图标点击） */
  private showLoginModeInfo(): void {
    this.getUIContext().getPromptAction().showDialog({
      title: T('重登方式说明'),
      message: '「教务登录」默认自动重登：每次重新打开应用用保存的账号密码自动登录教务系统，免去手动点击。\n\n「服务大厅登录」为手动重登：教务系统会话不可持久化，重新打开应用会自动从服务大厅重新打开教务系统刷新（无需重新输入密码）；仅当该刷新失败时才需在首页点击「重登」按钮。\n\n重登方式可在下方随时手动更改。',
      buttons: [
        { text: '我知道了', color: '#005BAC', primary: true }
      ]
    });
  }

  /** 打开找回密码网页（学校统一身份认证平台），跳转系统浏览器打开。
   *  仅是打开外部网页，不消耗 mock 数据，任何模式下都可用。 */
  private openForgotPassword(): void {
    AppState.openExternalLink(Const.FORGOT_PASSWORD_URL);
  }

  /** 日志调试：应用图标连点 5 次触发开关（已开启 → 退出确认；未开启 → 密码输入）。
   *  开启后真实登录/功能浏览模式都会正常收集日志，管理在"我的 → 日志详情"。 */
  private onLogoTapped(): void {
    this.logTapCount++;
    if (this.logTapTimer >= 0) {
      clearTimeout(this.logTapTimer);
    }
    // 3 秒内未继续点击则重置计数
    this.logTapTimer = setTimeout(() => {
      this.logTapCount = 0;
    }, 3000);
    if (this.logTapCount < 5) {
      return;
    }
    this.logTapCount = 0;
    this.toggleLogDebug();
  }

  /** 日志调试开关（日志入口点击 / 连点图标满 5 次共用）：
   *  已开启 → 弹"是否退出"；未开启 → 弹密码输入（admin） */
  private toggleLogDebug(): void {
    if (AppState.logEnabled) {
      // 已开启：询问是否退出（同时关闭功能浏览联网，清除已收集日志与附件）
      this.getUIContext().getPromptAction().showDialog({
        title: T('日志调试已开启'),
        message: T('当前正在收集登录与使用日志，且功能浏览模式允许联网。是否退出调试模式？'),
        buttons: [
          { text: T('取消'), color: '#888888' },
          { text: T('退出调试模式'), color: '#DB5252', primary: true }
        ]
      }).then((res) => {
        if (res.index === 1) {
          AppState.logEnabled = false;
          AppState.debugNetwork = false;
          LogStore.clearAll(); // 退出日志调试：自动删除已收集日志与附件
          this.getUIContext().getPromptAction().showToast({ message: '已退出调试模式，日志已清除' });
        }
      });
    } else {
      // 未开启：弹密码输入
      this.logPwd = '';
      this.showLogSheet = true;
    }
  }

  /** 提交日志调试密码：admin（登录页入口——开启日志收集，并同时允许功能浏览模式联网） */
  private submitLogPwd(): void {
    if (this.logPwd !== 'admin') {
      this.getUIContext().getPromptAction().showToast({ message: T('密码错误') });
      return;
    }
    this.showLogSheet = false;
    if (AppState.logEnabled) {
      this.getUIContext().getPromptAction().showToast({ message: T('日志调试已开启') });
      return;
    }
    AppState.logEnabled = true;
    // 功能浏览模式允许联网（debugNetwork）：进入功能浏览时网络请求不再被离线模式拦截
    AppState.debugNetwork = true;
    LogStore.log('日志调试', '开启', '成功', '登录页入口开启（日志收集 + 功能浏览允许联网）');
    this.getUIContext().getPromptAction().showToast({ message: T('日志调试已开启，开始收集登录与使用日志') });
  }

  /** 日志调试密码输入弹窗 */
  @Builder
  logDebugSheet() {
    // 弹窗内容套 MaterialSheetPanel：材质由 Toggle 承载层渲染，bindSheet 必须显式透明底（见宿主选项）。
    // SheetSize.FIT_CONTENT（高度随内容）→ panelFillHeight: false；原根容器的 bg_page 底色删除
    // （材质生效时让出底色，不生效时由面板自身补 $r('app.color.bg_card') 兜底）；
    // TextInput 属表单控件，走 Stack 承载层画沉浸光感（见输入行注释）。
    MaterialSheetPanel({ panelRadius: 20, panelPadding: 0, panelFillHeight: false, panelShowClose: true, panelOnClose: (): void => { this.showLogSheet = false; } }) {
      Column() {
        Text(T('日志调试'))
          .fontSize(17)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .margin({ top: 16, bottom: 8 })

        Text(T('输入密码以开启日志调试（收集登录与使用日志，用于定位登录失败等问题的原因）'))
          .fontSize(12)
          .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          .width('100%')
          .margin({ bottom: 12 })

        // 密码输入框：TextInput 属表单控件，不能走 Toggle 承载层 → Stack 兄弟结构：
        // MaterialCardLayer 纯视觉承载层画沉浸光感（受全局开关控制），输入框自身透明底；
        // 材质关闭时回落原 comp_background_tertiary 实色底。
        Stack() {
          if (materialAvailable()) {
            MaterialCardLayer({ layerRadius: $r('sys.float.corner_radius_level12'), layerShadow: false })
          }
          TextInput({ text: this.logPwd, placeholder: T('请输入密码') })
            .height(48)
            .enterKeyType(EnterKeyType.Done)
            .borderRadius($r('sys.float.corner_radius_level12'))
            .fontSize($r('sys.float.Body_L'))
            .fontWeight(this.fwMode === 'follow' ? FontWeight.Regular : AppearanceStore.fontWeight(FontWeight.Regular))
            .backgroundColor(materialAvailable() ? Color.Transparent : $r('sys.color.comp_background_tertiary'))
            .caretStyle({ color: $r('sys.color.font_emphasize') })
            .type(InputType.Normal)
            .fontColor(Theme.colorOf(this.themeColor))
            .placeholderFont({ size: $r('sys.float.Body_L'), weight: FontWeight.Regular })
            .width('100%')
            .onChange((v: string) => {
              this.logPwd = v;
            })
            .onSubmit(() => {
              this.submitLogPwd();
            })
        }
        .width('100%')
        .borderRadius($r('sys.float.corner_radius_level12'))

        Button(T('确认'))
          .fontSize(14)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
          .fontColor(Color.White)
          .backgroundColor(Theme.colorOf(this.themeColor))
          .height(40)
          .width('100%')
          .borderRadius(20)
          .margin({ top: 12, bottom: 16 })
          .onClick(() => {
            this.submitLogPwd();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20 })
    }
  }

  /** 功能浏览（原"游客模式"）：临时切到 mock 数据，用占位账号直接登录（无需真实学号密码）。 */
  private async demoLogin(): Promise<void> {
    JwApi.USE_MOCK = true;
    HttpClient.setOfflineMode(true); // 禁用所有网络请求
    this.loading = true;
    const result: LoginResult = await JwApi.login('demo123456', 'demo123456');
    this.loading = false;
    if (result.success && result.profile !== null) {
      AppState.profile = result.profile;
      AppState.account = 'demo';
      this.getUIContext().getPromptAction().showToast({ message: T('已进入功能浏览模式') });
      this.onSuccess();
    } else {
      this.getUIContext().getPromptAction().showToast({ message: '功能浏览启动失败，请重试' });
    }
  }

  /** 同意隐私协议：记录时间、关闭弹窗；开发者声明改为用户之后首次任意点击时弹出（armed 等待触发） */
  private agreePrivacy(): void {
    DataStore.setPrivacyAgreed();
    this.privacyAgreedAt = DataStore.getPrivacyAgreedAt();
    this.showPrivacy = false;
    // 短延时后进入"待触发"状态：点"同意"本身不算，需等下一次点击
    setTimeout(() => {
      this.declarationArmed = true;
    }, 600);
  }

  /** 用户任意点击时调用：隐私已同意且开发者声明未展示过 → 弹出开发者声明（仅一次） */
  private maybeShowDeclaration(): void {
    if (this.showPrivacy || this.showDeclaration) {
      return; // 隐私协议/声明弹窗打开中不触发
    }
    if (!this.declarationArmed || !DataStore.isPrivacyAgreed()) {
      return;
    }
    if (DataStore.isDeclarationShown()) {
      return; // 已展示过（本次会话或历史）
    }
    DataStore.setDeclarationShown();
    this.showDeclaration = true;
  }

  /** 暂不同意隐私协议：关闭弹窗，未登录账号前仅可使用"功能浏览" */
  private declinePrivacy(): void {
    this.showPrivacy = false;
  }

  /** 查询某账号在历史记录中已保存的密码（无则空串） */
  private savedPasswordOf(account: string): string {
    const list: Record<string, string>[] = DataStore.getAccountList();
    for (const it of list) {
      if (it['account'] === account) {
        return DataStore.decodePwd(it['password'] ?? '');
      }
    }
    return '';
  }

  /** 选中历史账号 → 填充账号密码并折叠面板
   *  历史记录中保存了密码（勾选"记住密码"登录）则一并填充，否则只填账号 */
  private pickHistory(item: Record<string, string>): void {
    const acct: string = item['account'] ?? '';
    this.account = acct;
    const savedPwd: string = DataStore.decodePwd(item['password'] ?? '');
    this.password = savedPwd;
    // TextInput 构造器 text 参数不会响应 @State 变化，必须通过 controller 强制刷新
    this.accountController.deleteText();
    if (acct.length > 0) {
      this.accountController.addText(acct);
    }
    this.passwordController.deleteText();
    if (savedPwd.length > 0) {
      this.passwordController.addText(savedPwd);
    }
    this.showHistory = false;
    this.showCaptcha = false;
    this.captchaInput = '';
  }

  /** 删除单个历史账号：先播粒子消散 + 行淡出收起，再真正移除数据 */
  private deleteHistory(index: number): void {
    if (index < 0 || index >= this.historyList.length || this.deletingAcct.length > 0) {
      return;
    }
    const removedAcct: string = this.historyList[index]['account'] ?? '';
    this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseIn }, () => {
      this.deletingAcct = removedAcct;
      this.burstSeq++;
    });
    setTimeout(() => {
      this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
        const idx: number = this.historyList.findIndex((item: Record<string, string>): boolean => (item['account'] ?? '') === removedAcct);
        if (idx >= 0) {
          this.historyList.splice(idx, 1);
        }
        // 持久化剩余列表
        DataStore.put(DataStore.KEY_ACCOUNTS, JSON.stringify(this.historyList));
        // 若删除的是"最近登录"，回退到剩余列表第一个
        if (DataStore.get(DataStore.KEY_LAST_ACCOUNT) === removedAcct) {
          DataStore.put(DataStore.KEY_LAST_ACCOUNT,
            this.historyList.length > 0 ? (this.historyList[0]['account'] ?? '') : '');
        }
        // 全部删完时收起面板
        if (this.historyList.length === 0) {
          this.showHistory = false;
        }
        this.deletingAcct = '';
      });
    }, 380);
  }

  /** 清空历史账号列表并持久化 */
  private clearHistory(): void {
    DataStore.put(DataStore.KEY_ACCOUNTS, '[]');
    DataStore.put(DataStore.KEY_LAST_ACCOUNT, '');
    this.historyList = [];
    this.showHistory = false;
  }

  @Builder
  inputRow(placeholder: string, value: string,
    onInput: (v: string) => void, controller: TextInputController) {
    // 输入行：TextInput 属表单控件，不能走 Toggle 承载层 → Stack 兄弟结构：
    // MaterialCardLayer 纯视觉承载层画沉浸光感（layerForce 常驻，登录页不随全局开关消失），
    // 输入行自身透明底；材质关闭回落原 comp_background_tertiary 实色底。
    Stack() {
      if (materialAvailable()) {
        MaterialCardLayer({ layerRadius: $r('sys.float.corner_radius_level12'), layerShadow: false, layerForce: true })
      }
      Row() {
        TextInput({ placeholder: placeholder, controller: controller, text: value })
          .type(InputType.Normal)
          .height(48)
          .enterKeyType(EnterKeyType.Done)
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Regular : AppearanceStore.fontWeight(FontWeight.Regular))
          .caretStyle({ color: $r('sys.color.font_emphasize') })
          .fontColor(Theme.colorOf(this.themeColor))
          .placeholderFont({ size: $r('sys.float.Body_L'), weight: FontWeight.Regular })
          // 半透明灰底：玻璃/材质上输入框边界更清晰（用户反馈「加点灰色方便查看」）
          .backgroundColor('#14808080')
          .padding({ left: 14, right: 8 })
          .layoutWeight(1)
          .onChange(onInput)
      }
      .width('100%')
      .backgroundColor(materialAvailable() ? Color.Transparent : $r('sys.color.comp_background_tertiary'))
      .borderRadius($r('sys.float.corner_radius_level12'))
    }
    .width('100%')
    .margin({ bottom: 12 })
    .borderRadius($r('sys.float.corner_radius_level12'))
  }

  /** 密码输入行：眼睛切换明文/密文 + ✕ 一键清空
   *  注意：text 必须直接引用响应式 this.password（不可经 @Builder 值参数传入），
   *  否则切换明文/密文导致 TextInput 重建时 text 取到过期快照 → 密码被清空。 */
  @Builder
  passwordRow(placeholder: string, controller: TextInputController) {
    // 同 inputRow：Stack 兄弟结构承载沉浸光感（layerForce 常驻），材质关闭回落实色底
    Stack() {
      if (materialAvailable()) {
        MaterialCardLayer({ layerRadius: $r('sys.float.corner_radius_level12'), layerShadow: false, layerForce: true })
      }
      Row() {
      TextInput({ placeholder: placeholder, controller: controller, text: this.password })
        .type(this.showPwd ? InputType.Normal : InputType.Password)
        // 隐藏系统内置的密码可见性切换图标（与自定义眼睛重复）
        .showPasswordIcon(false)
        .height(48)
        .enterKeyType(EnterKeyType.Done)
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(this.fwMode === 'follow' ? FontWeight.Regular : AppearanceStore.fontWeight(FontWeight.Regular))
        .caretStyle({ color: $r('sys.color.font_emphasize') })
        .fontColor(Theme.colorOf(this.themeColor))
        .placeholderFont({ size: $r('sys.float.Body_L'), weight: FontWeight.Regular })
        // 半透明灰底：同 inputRow，玻璃/材质上边界更清晰
        .backgroundColor('#14808080')
        .padding({ left: 14, right: 8 })
        .layoutWeight(1)
        .onChange((v: string) => {
          this.password = v;
        })

      // ✕ 一键清空（有内容时才显示）
      if (this.password.length > 0) {
        Text('✕')
          .fontSize(15)
          .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          .width(30)
          .height(48)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.password = '';
          })
      }

      // 眼睛图标：切换明文/密文（睁眼=明文可见，闭眼=密文隐藏）
      Image(this.showPwd ? $r('app.media.eye') : $r('app.media.eye_off'))
        .width(20)
        .height(20)
        .fillColor($r('app.color.text_tertiary'))
        .margin({ left: 6, right: 14 })
        .onClick(() => {
          this.showPwd = !this.showPwd;
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center) // 眼睛/叉与输入框水平中线对齐
      .backgroundColor(materialAvailable() ? Color.Transparent : $r('sys.color.comp_background_tertiary'))
      .borderRadius($r('sys.float.corner_radius_level12'))
    }
    .width('100%')
    .margin({ bottom: 12 })
    .borderRadius($r('sys.float.corner_radius_level12'))
  }

  @Builder
  captchaRow() {
    Row() {
      // 验证码输入框：同 inputRow 的 Stack 兄弟结构承载沉浸光感（layerForce 常驻）
      Stack() {
        if (materialAvailable()) {
          MaterialCardLayer({ layerRadius: $r('sys.float.corner_radius_level12'), layerShadow: false, layerForce: true })
        }
        Row() {
          TextInput({ placeholder: T('验证码'), text: this.captchaInput })
            .height(48)
            .enterKeyType(EnterKeyType.Done)
            .fontSize($r('sys.float.Body_L'))
            .fontWeight(this.fwMode === 'follow' ? FontWeight.Regular : AppearanceStore.fontWeight(FontWeight.Regular))
            .caretStyle({ color: $r('sys.color.font_emphasize') })
            .type(InputType.Normal)
            .fontColor(Theme.colorOf(this.themeColor))
            .placeholderFont({ size: $r('sys.float.Body_L'), weight: FontWeight.Regular })
            .backgroundColor(Color.Transparent)
            .padding({ left: 14, right: 8 })
            .layoutWeight(1)
            .onChange((v: string) => {
              this.captchaInput = v;
            })
        }
        .width('100%')
        .backgroundColor(materialAvailable() ? Color.Transparent : $r('sys.color.comp_background_tertiary'))
        .borderRadius($r('sys.float.corner_radius_level12'))
      }
      .layoutWeight(1)
      .borderRadius($r('sys.float.corner_radius_level12'))

      if (JwApi.USE_MOCK) {
        Text(this.captcha)
          .fontSize(19)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
          .fontStyle(FontStyle.Italic)
          .letterSpacing(4)
          .fontColor($r('app.color.brand'))
          .backgroundColor(GlassMaterial.cardSurface(AppStorage.get<boolean>('isDarkMode') ?? false)).backgroundBlurStyle(BlurStyle.Thin).border({ width: 1, color: GlassMaterial.borderColor() }).shadow(GlassMaterial.capsuleShadow()).clip(true)
          .textAlign(TextAlign.Center)
          .width(96)
          .height(48)
          .borderRadius(12)
          .margin({ left: 10 })
          .onClick(() => {
            this.loadCaptcha();
          })
      } else if (this.captchaImage.length > 0) {
        Image('data:image/jpeg;base64,' + this.captchaImage)
          .width(96)
          .height(48)
          .borderRadius(12)
          .margin({ left: 10 })
          .objectFit(ImageFit.Contain)
          .onClick(() => {
            this.loadCaptcha();
          })
      } else {
        Text(T('点击获取验证码'))
          .fontSize(13)
          .fontColor($r('app.color.brand'))
          .backgroundColor(GlassMaterial.cardSurface(AppStorage.get<boolean>('isDarkMode') ?? false)).backgroundBlurStyle(BlurStyle.Thin).border({ width: 1, color: GlassMaterial.borderColor() }).shadow(GlassMaterial.capsuleShadow()).clip(true)
          .textAlign(TextAlign.Center)
          .width(96)
          .height(48)
          .borderRadius(12)
          .margin({ left: 10 })
          .onClick(() => {
            this.loadCaptcha();
          })
      }
    }
    .width('100%')
    .margin({ bottom: 6 })
  }

  /** 历史账号展开列表（点击登录按钮下方时显示） */
  @Builder
  historyPanel() {
    Column() {
      Row() {
        Text(T('历史账号'))
          .fontSize(13)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(T('清空'))
          .fontSize(11)
          .fontColor($r('app.color.brand'))
          .onClick(() => {
            this.clearHistory();
          })
      }
      .width('100%')
      .margin({ bottom: 8 })

      List({ space: 6 }) {
        ForEach(this.historyList, (item: Record<string, string>, index: number) => {
          ListItem() {
            // 行套 Stack：DissolveBurst 覆盖其上，删除时从行中心爆散主题色粒子
            Stack() {
            Row() {
              if (index === 0) {
                Text(T('最近'))
                  .fontSize(10)
                  .fontColor($r('app.color.brand_on'))
                  .backgroundColor($r('app.color.brand'))
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(6)
                  .margin({ right: 8 })
              }

              Column() {
                Text(item['account'] ?? '')
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                Text(item['password'] !== undefined && item['password'].length > 0 ? '已保存密码' : T('无密码'))
                  .fontSize(10)
                  .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Button(T('使用'))
                .fontSize(12)
                .fontColor($r('app.color.brand_on'))
                .backgroundColor($r('app.color.brand'))
                .height(30)
                .padding({ left: 12, right: 12 })
                .borderRadius(8)
                .onClick(() => {
                  this.pickHistory(item);
                })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .backgroundColor(GlassMaterial.cardSurface(AppStorage.get<boolean>('isDarkMode') ?? false)).backgroundBlurStyle(BlurStyle.Thin).border({ width: 1, color: GlassMaterial.borderColor() }).shadow(GlassMaterial.capsuleShadow()).clip(true)
            .borderRadius(10)
            // 删除中的行淡出收起
            .opacity(this.deletingAcct === (item['account'] ?? '') ? 0 : 1)
            DissolveBurst({ trigger: this.deletingAcct === (item['account'] ?? '') ? this.burstSeq : 0 })
            }
            // 行删除转场：左移淡出（列表随之收起）
            .transition(TransitionEffect.OPACITY
              .combine(TransitionEffect.translate({ x: -24 }))
              .animation({ duration: 220, curve: Curve.EaseOut }))
          }
          .swipeAction({
            end: this.swipeDeleteButton(index)
          })
        }, (item: Record<string, string>): string => item['account'] ?? '')
      }
      .width('100%')
      .scrollBar(BarState.Off)
      .constraintSize({ maxHeight: 340 })

      Text(T('密码仅保存在本机（加密），不上传任何服务器。'))
        .fontSize(10)
        .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
        .margin({ top: 4 })
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.bg_page'))
    .borderRadius(12)
    .margin({ top: 10 })
  }

  /** 历史账号左滑删除按钮（SwipeAction end 侧） */
  @Builder
  swipeDeleteButton(index: number) {
    Row() {
      Text(T('删除'))
        .fontSize(13)
        .fontColor('#FFFFFF')
    }
    .width(64)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#F0524D')
    .borderRadius(10)
    .onClick(() => {
      this.deleteHistory(index);
    })
  }

  build() {
    // 日志调试开启后，从登录页内嵌查看日志详情（登录页不在 Navigation 栈，不能 pushPath）
    Stack() {
      if (this.showLogPage) {
        LogPage({
          embedded: true,
          onBackCallback: () => {
            this.showLogPage = false;
          }
        })
      } else {
      Column() {
      // 顶部背景：用户指定图片（rawfile 直读，Cover 铺满顶部区域）+ logo
      Stack({ alignContent: Alignment.Top }) {
        Image($rawfile('login_top.jpg'))
          .width('100%')
          .height(this.isLandscape ? 240 : 300)
          .objectFit(ImageFit.Cover)
          .overlay(this.bannerOverlay(), { align: Alignment.TopStart })

        // 前往登录页模式：登录按钮左侧显示灰色返回按钮（见登录按钮区域）
        Scroll() {
          Column() {
            // 顶部 南医助手 圆角 logo（连点 5 次开启日志调试：登录页亦可收集登录数据定位登录失败）
            Column() {
              Image($r('app.media.startIcon'))
                .width(this.isLandscape ? 96 : 120)
                .height(this.isLandscape ? 96 : 120)
                .objectFit(ImageFit.Contain)
                .borderRadius(28)
                .onClick(() => {
                  this.onLogoTapped();
                })
              Text('南医助手')
                .fontSize(22)
                .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
                .fontColor('#FFFFFF')
                .margin({ top: 14 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: this.isLandscape ? 22 : 48, bottom: 28 })

            // 登录卡片：登录页沉浸光感**常驻**（layerForce，不随全局开关消失，与登录按钮一致）
            // → Stack 兄弟结构：MaterialCardLayer 纯视觉承载层画材质，内容 Column 独立叠上；
            // 材质生效时 Column 让出底色/磨砂/边框（每层只有一个视觉），关闭时回落原玻璃卡。
            Stack() {
              if (materialAvailable()) {
                MaterialCardLayer({ layerRadius: 20, layerShadow: true, layerForce: true })
              }
              Column() {
              Text(T('教务系统登录'))
                .fontSize(17)
                .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .margin({ bottom: 4 })
              Text(T('南医大统一身份认证需验证码，请在网页中登录（学号已自动预填）'))
                .fontSize(12)
                .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                .width('100%')
                .margin({ bottom: 18 })

              this.inputRow(T('学号'), this.account, (v: string) => {
                this.account = v;
              }, this.accountController)
              // 密码行内部直接绑定 this.password（避免值参数快照导致切换明文时清空）
              this.passwordRow(T('密码'), this.passwordController)

              if (this.showCaptcha) {
                this.captchaRow()
              }

              Row() {
                Checkbox({ name: 'remember' })
                  .select(this.remember)
                  .selectedColor($r('app.color.brand'))
                  .width(18)
                  .height(18)
                  .onChange((checked: boolean) => {
                    this.remember = checked;
                    // 持久化勾选状态：退出登录/重启后仍记住，可自动填充已保存密码
                    DataStore.saveRemember(checked);
                  })
                Text(T('记住密码'))
                  .fontSize(12)
                  .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                  .margin({ left: 4 })
                // 7天免登录（CASTGC）仅属于新版（服务大厅/CAS）登录系统，原版不显示
                if (this.loginSystem === 'service') {
                  Checkbox({ name: 'remember7d' })
                    .select(this.remember7d)
                    .selectedColor($r('app.color.brand'))
                    .width(18)
                    .height(18)
                    .margin({ left: 10 })
                    .onChange((checked: boolean) => {
                      this.remember7d = checked;
                      AppState.remember7d = checked;
                    })
                  Text(T('7天免登录'))
                    .fontSize(12)
                    .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                    .margin({ left: 4 })
                }
                Blank()
                Text(T('忘记密码？'))
                  .fontSize(12)
                  .fontColor($r('app.color.brand'))
                  .onClick(() => {
                    this.openForgotPassword();
                  })
              }
              .width('100%')
              .margin({ top: 8, bottom: 18 })

              Row() {
                // 前往登录页模式：灰色返回按钮（左侧，与登录按钮等宽等高，合计与原登录按钮相同）
                // → MaterialButton（Toggle 承载层，btnPersistent 常驻：登录页强制默认玻璃的延续）
                if (this.showBack) {
                  Row() {
                    MaterialButton({
                      btnRadius: 12,
                      btnPersistent: true,
                      btnBg: GlassMaterial.cardSurface(AppStorage.get<boolean>('isDarkMode') ?? false),
                      btnBlur: BlurStyle.Thin,
                      btnBorderW: 1,
                      btnBorderC: GlassMaterial.borderColor(),
                      btnEnabled: !this.loading,
                      btnOnClick: (): void => {
                        this.onBack();
                      }
                    }) {
                      Row() {
                        Image($r('app.media.back_arrow'))
                          .width(16)
                          .height(16)
                          .fillColor($r('app.color.text_secondary'))
                        Text(T('返回'))
                          .fontSize(16)
                          .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                          .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                          .margin({ left: 4 })
                      }
                      .justifyContent(FlexAlign.Center)
                      .width('100%')
                      .height(48)
                    }
                  }
                  .layoutWeight(1)
                  .margin({ right: 10 })
                }
                // 登录按钮：沉浸光感**常驻**（btnPersistent，不随全局开关消失）；
                // 观感与其它页面的材质按钮保持一致（纯材质，不叠原色层）
                Row() {
                  MaterialButton({
                    btnRadius: 12,
                    btnPersistent: true,
                    btnMaterialShadow: true,
                    // 绿色语义回归：材质关闭回落品牌绿实底；材质生效时 btnTint（半透明主题绿）
                    // 叠在材质之上保住绿色（0.55 浓度，绿色玻璃感）
                    btnBg: $r('app.color.brand'),
                    btnTint: Theme.colorOf(this.themeColor),
                    btnTintRatio: 0.55,
                    btnEnabled: !this.loading,
                    btnOnClick: (): void => {
                      // 南医大统一认证强制验证码 + 原生 ST 交换不可用：主登录直接走网页登录（WebView），
                      // 账号已在登录页预填、网页端自动勾选"7天免登录"保持登录态。
                      this.openWebLogin();
                    }
                  }) {
                    Row() {
                      Text(T('网页登录（推荐）'))
                        .fontSize(16)
                        .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                        // 按钮底为主题色（彩色玻璃/实底），深浅色模式下都用白色保证对比
                        .fontColor(Color.White)
                    }
                    .justifyContent(FlexAlign.Center)
                    .width('100%')
                    .height(48)
                  }
                }
                .layoutWeight(1)
              }
              .width('100%')

              // 原生登录兜底入口（次要）：南医大原生 CAS 登录已废弃（ST 交换失败），保留供诊断/回退
              Row() {
                Text(T('使用账号密码原生登录（可能失败）'))
                  .fontSize(12)
                  .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .margin({ top: 10 })
              .onClick(() => {
                this.doLogin();
              })

              // 历史账号入口（登录按钮下方，点击才展开）
              if (this.historyList.length > 0) {
                Row() {
                  Text(this.showHistory ? '收起历史账号' : `历史账号（${this.historyList.length}）`)
                    .fontSize(12)
                    .fontColor($r('app.color.brand'))
                  Image($r('app.media.list_bullet'))
                    .width(14)
                    .height(14)
                    .fillColor($r('app.color.brand'))
                    .margin({ left: 4 })
                }
                .width('100%')
                .padding({ top: 10, bottom: 6 })
                .justifyContent(FlexAlign.Center)
                .onClick(() => {
                  // 展开/收起带过渡动画，避免跳变
                  this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
                    this.showHistory = !this.showHistory;
                  })
                })

                if (this.showHistory) {
                  Column() {
                    this.historyPanel()
                  }
                  .width('100%')
                  .transition(TransitionEffect.OPACITY
                    .combine(TransitionEffect.translate({ y: -10 })))
                }
              }
              }
              .width('100%')
              .padding(20)
              .backgroundColor(materialAvailable() ? Color.Transparent : GlassMaterial.cardSurface(AppStorage.get<boolean>('isDarkMode') ?? false))
              .backgroundBlurStyle(materialAvailable() ? BlurStyle.NONE : BlurStyle.Thin)
              .borderWidth(materialAvailable() ? 0 : 1)
              .borderColor(GlassMaterial.BORDER)
              .borderRadius(20)
              .clip(true)
            }
            .width('100%')
            .borderRadius(20)
            .shadow({ radius: 20, color: '#14000000', offsetY: 6 })

            // 底部操作区：重登方式 + 登录系统切换（服务大厅登录 ↔ 教务登录）+ 网页版登录 + 功能浏览
            Column() {
              // 重登方式（固定入口，可随时更改）
              Row() {
                Image($r('app.media.question'))
                  .width(14)
                  .height(14)
                  .margin({ right: 4 })
                  .fillColor($r('app.color.text_tertiary'))
                  .onClick(() => {
                    this.showLoginModeInfo();
                  })
                Text(T('重登方式'))
                  .fontSize(13)
                  .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                Blank()
                Text(this.loginModeText())
                  .fontSize(13)
                  .fontColor($r('app.color.brand'))
                ChevronRight({ iconSize: 10 }).margin({ left: 2 })
              }
              .width('72%')
              .padding({ left: 18, right: 14, top: 10, bottom: 10 })
              .backgroundColor(GlassMaterial.cardSurface(AppStorage.get<boolean>('isDarkMode') ?? false)).backgroundBlurStyle(BlurStyle.Thin).border({ width: 1, color: GlassMaterial.borderColor() }).shadow(GlassMaterial.capsuleShadow()).clip(true)
              .borderRadius(22)
              .margin({ bottom: 10 })
              .enabled(!this.loading)
              .onClick(() => {
                this.changeLoginMode();
              })

              // 登录方式（统一身份认证 ↔ 教务系统直登），可随时切换
              Row() {
                Image($r('app.media.question'))
                  .width(14)
                  .height(14)
                  .margin({ right: 4 })
                  .fillColor($r('app.color.text_tertiary'))
                  .onClick(() => {
                    this.showLoginModeInfo();
                  })
                Text(T('登录方式'))
                  .fontSize(13)
                  .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                Blank()
                Text(this.loginSystemText())
                  .fontSize(13)
                  .fontColor($r('app.color.brand'))
                ChevronRight({ iconSize: 10 }).margin({ left: 2 })
              }
              .width('72%')
              .padding({ left: 18, right: 14, top: 10, bottom: 10 })
              .backgroundColor(GlassMaterial.cardSurface(AppStorage.get<boolean>('isDarkMode') ?? false)).backgroundBlurStyle(BlurStyle.Thin).border({ width: 1, color: GlassMaterial.borderColor() }).shadow(GlassMaterial.capsuleShadow()).clip(true)
              .borderRadius(22)
              .margin({ bottom: 10 })
              .enabled(!this.loading)
              .onClick(() => {
                this.changeLoginSystem();
              })

              // 网页登录：在 WebView 打开统一身份认证登录页（验证码等场景兜底）
              // → MaterialButton（Toggle 承载层，btnPersistent 常驻）
              Row() {
                MaterialButton({
                  btnRadius: 22,
                  btnPersistent: true,
                  btnBg: GlassMaterial.cardSurface(AppStorage.get<boolean>('isDarkMode') ?? false),
                  btnBlur: BlurStyle.Thin,
                  btnBorderW: 1,
                  btnBorderC: GlassMaterial.borderColor(),
                  btnEnabled: !this.loading,
                  btnOnClick: (): void => {
                    this.openWebLogin();
                  }
                }) {
                  Row() {
                    Text(T('网页登录'))
                      .fontSize(15)
                      .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                      .fontColor($r('app.color.brand'))
                  }
                  .justifyContent(FlexAlign.Center)
                  .width('100%')
                  .height(44)
                }
              }
              .width('72%')
              .margin({ bottom: 10 })

              // 功能浏览 → MaterialButton（Toggle 承载层，btnPersistent 常驻）
              Row() {
                MaterialButton({
                  btnRadius: 22,
                  btnPersistent: true,
                  btnBg: GlassMaterial.cardSurface(AppStorage.get<boolean>('isDarkMode') ?? false),
                  btnBlur: BlurStyle.Thin,
                  btnBorderW: 1,
                  btnBorderC: GlassMaterial.borderColor(),
                  btnEnabled: !this.loading,
                  btnOnClick: (): void => {
                    this.demoLogin();
                  }
                }) {
                  Row() {
                    Text(T('功能浏览'))
                      .fontSize(15)
                      .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                      .fontColor($r('app.color.brand'))
                  }
                  .justifyContent(FlexAlign.Center)
                  .width('100%')
                  .height(44)
                }
              }
              .width('72%')
              .margin({ bottom: 10 })

              // 日志调试入口（功能浏览按钮下方）：仅日志调试开启后显示；点击进入日志查看页
              // （开启方式：连点顶部应用图标 5 次 + 密码 admin；真实登录/功能浏览模式均收集日志）
              if (this.logEnabled) {
                Row() {
                  Text(T('日志调试'))
                    .fontSize(13)
                    .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                  Blank()
                  Text(this.logCollecting ? '● 收集中' : '○ 已暂停')
                    .fontSize(12)
                    .fontColor(this.logCollecting ? $r('app.color.brand') : $r('app.color.text_tertiary'))
                  ChevronRight({ iconSize: 10 }).margin({ left: 2 })
                }
                .width('72%')
                .padding({ left: 18, right: 14, top: 10, bottom: 10 })
                .backgroundColor(GlassMaterial.cardSurface(AppStorage.get<boolean>('isDarkMode') ?? false)).backgroundBlurStyle(BlurStyle.Thin).border({ width: 1, color: GlassMaterial.borderColor() }).shadow(GlassMaterial.capsuleShadow()).clip(true)
                .borderRadius(22)
                .margin({ bottom: 10 })
                .onClick(() => {
                  // 登录页不在 Navigation 栈：内嵌展示日志详情（embedded 模式），不走 pushPath
                  this.showLogPage = true;
                })
              }

              Text(T('"功能浏览"使用虚拟数据，用以展示相关功能效果。\n若多次登录失败，可尝试使用网页教务系统进行登录。'))
                .fontSize(11)
                .lineHeight(18)
                .textAlign(TextAlign.Center)
                .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                .margin({ bottom: 16 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .margin({ top: 20 })
            .padding({ left: 24, right: 24 })
          }
          .width('100%')
          // 大屏不拉宽（用户要求：组件保持手机端宽度）：限宽 420，宽屏下 Scroll 交叉轴自动居中
          .constraintSize({ maxWidth: 420 })
          .padding({ left: 24, right: 24, bottom: 32 })
        }
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .height('100%')
        .padding({ top: this.getUIContext().px2vp(this.topInsetPx) })
      }
      .layoutWeight(1)
      .width('100%')
      // 网页版登录/找回密码弹窗（挂内层 Stack，与外层隐私弹窗分离避免同组件多 bindSheet 失效）
      // ⚠ bindSheet 例外（保持 bg_page 不透底）：内容为 WebSurface（网页版登录 WebView），
      // Web 需要不透明底色渲染，沉浸材质面板对网页无意义且透底会出现白屏闪烁，故不套 MaterialSheetPanel。
      .bindSheet($$this.showWeb, this.webSheet, {
        height: SheetSize.LARGE,
        dragBar: false,
        preferType: SheetType.BOTTOM,
        width: this.sheetWidth,
        showClose: true,
        backgroundColor: $r('app.color.bg_page'),
        title: () => {
          this.webSheetTitle();
        }
      })

      // 开发者声明弹窗（同意隐私协议后首次展示）：挂独立占位组件，避免与其它弹窗同宿主冲突
      Column()
        .width('100%')
        .height(1)
        .bindSheet($$this.showDeclaration, this.declarationSheet(), {
          height: SheetSize.FIT_CONTENT,
          dragBar: false,
          preferType: SheetType.BOTTOM,
          width: this.sheetWidth,
          // 关闭按钮由 MaterialSheetPanel 自绘（沉浸光感），系统 showClose 必须关掉避免双按钮
          showClose: false,
          // 必须显式透明：BindOptions.backgroundColor 默认 Color.White，白底会把 MaterialSheetPanel 的材质整块盖住
          backgroundColor: Color.Transparent,
          blurStyle: sheetBlurStyle()
        })

      // 账号风控提醒弹窗（开发者声明之后首次展示）：另挂独立占位组件，避免同宿主 bindSheet 冲突
      Column()
        .width('100%')
        .height(1)
        .bindSheet($$this.showRiskTip, this.riskTipSheet(), {
          height: SheetSize.FIT_CONTENT,
          dragBar: false,
          preferType: SheetType.BOTTOM,
          width: this.sheetWidth,
          // 关闭按钮由 MaterialSheetPanel 自绘（沉浸光感），系统 showClose 必须关掉避免双按钮
          showClose: false,
          // 必须显式透明：BindOptions.backgroundColor 默认 Color.White，白底会把 MaterialSheetPanel 的材质整块盖住
          backgroundColor: Color.Transparent,
          blurStyle: sheetBlurStyle()
        })

      // 日志调试密码弹窗（连点图标 5 次 / 点日志调试入口触发）：另挂独立占位组件，避免同宿主 bindSheet 冲突
      Column()
        .width('100%')
        .height(1)
        .bindSheet($$this.showLogSheet, this.logDebugSheet(), {
          height: SheetSize.FIT_CONTENT,
          dragBar: false,
          preferType: SheetType.BOTTOM,
          width: this.sheetWidth,
          // 关闭按钮由 MaterialSheetPanel 自绘（沉浸光感），系统 showClose 必须关掉避免双按钮
          showClose: false,
          // 键盘弹出时避让：弹层上移/内容可滚，保证输入聚焦后"确认"按钮可见可点
          keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_SCROLL,
          // 必须显式透明：BindOptions.backgroundColor 默认 Color.White，白底会把 MaterialSheetPanel 的材质整块盖住
          backgroundColor: Color.Transparent,
          blurStyle: sheetBlurStyle()
        })

      // 自动重登提示：居中弹窗样式（不遮罩页面、不拦截点击）
      if (this.autoRelogin && this.loading) {
        Column() {
          Text(T('正在自动登录…'))
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
        }
        .padding({ left: 28, right: 28, top: 18, bottom: 18 })
        .backgroundColor(GlassMaterial.cardSurface(AppStorage.get<boolean>('isDarkMode') ?? false)).backgroundBlurStyle(BlurStyle.Thin).border({ width: 1, color: GlassMaterial.BORDER }).shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 }).clip(true)
        .borderRadius(14)
        .shadow({ radius: 24, color: '#33000000', offsetY: 6 })
        .position({ x: '50%', y: '45%' })
        .translate({ x: '-50%' })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    // 开发者声明：同意隐私后不再自动弹出，改为用户任意点击（事件冒泡到根）时首次触发提醒
    .onClick(() => {
      this.maybeShowDeclaration();
    })
    // 隐私协议全屏弹窗（挂外层 Column；网页版登录挂内层 Stack，避免 bindSheet 互相覆盖）
    // ⚠ bindSheet 例外（保持 bg_page 不透底）：面板主体为 Web（privacy.html 协议正文），
    // Web 需要不透明底色渲染，沉浸材质面板对网页无意义，故不套 MaterialSheetPanel。
    .bindSheet($$this.showPrivacy, this.privacySheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      backgroundColor: $r('app.color.bg_page'),
      showClose: false,
      enableOutsideInteractive: true,
      preferType: SheetType.BOTTOM,
      width: this.sheetWidth
    })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  bannerOverlay() {
    // 暗色蒙板：顶部背景图为浅色系，蒙板保证白色 logo 文字清晰
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('#40000000')
  }

  @Builder
  webSheet() {
    WebSurface({
      scanTrigger: this.webScanSeq,
      // 登录目标：@Watch 驱动 WebView 重载（不再依赖外层 controller 时序）
      targetMode: this.webLoginTarget,
      onLoadFail: (): void => {
        // 主文档加载失败：给出可行动的提示
        this.getUIContext().getPromptAction().showToast({
          message: T('网络状态不佳，请检查网络，若仍无法访问，则可能是学校服务器维护中，请稍后再试。'),
          duration: 3500
        });
      },
      onControllerReady: (ctrl: webview.WebviewController) => {
        this.webCtrl = ctrl;
      }
    })
  }

  /** 网页版登录弹窗标题栏：标题 + 右侧"教务系统 / 服务大厅"切换（仅网页版登录模式显示，找回密码不显示） */
  @Builder
  webSheetTitle() {
    Row() {
      // 标题位让给「识别登录状态」胶囊（用户指定：取消「网页登录」标题文本）——
      // 自动轮询漏判（登录成功没反应）时点一下立即抓取会话 Cookie 完成登录判定
      MaterialButton({
        btnRadius: 15,
        btnBg: $r('app.color.bg_chip'),
        btnBlur: GlassMaterial.cardBlur(),
        btnBorderW: GlassMaterial.borderWidth(),
        btnBorderC: GlassMaterial.borderColor(),
        btnOnClick: (): void => {
          this.webScanSeq++;
          this.getUIContext().getPromptAction().showToast({ message: T('正在识别登录状态…') });
        }
      }) {
        Text(T('识别登录状态'))
          .fontSize(13)
          .fontColor($r('app.color.brand'))
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      }
      Blank()
      if (AppState.webLoginMode) {
        Row() {
          Text(T('服务大厅'))
            .fontSize(13)
            .fontColor(this.webLoginTarget === 'hall' ? $r('app.color.brand_on') : $r('app.color.text_secondary'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.webLoginTarget === 'hall' ? $r('app.color.brand') : Color.Transparent)
            .borderRadius(13)
            .onClick(() => {
              this.switchWebTarget('hall');
            })
          Text(T('教务系统'))
            .fontSize(13)
            .fontColor(this.webLoginTarget === 'jw' ? $r('app.color.brand_on') : $r('app.color.text_secondary'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.webLoginTarget === 'jw' ? $r('app.color.brand') : Color.Transparent)
            .borderRadius(13)
            .onClick(() => {
              this.switchWebTarget('jw');
            })
        }
        .backgroundColor(GlassMaterial.cardSurface(AppStorage.get<boolean>('isDarkMode') ?? false)).backgroundBlurStyle(BlurStyle.Thin).border({ width: 1, color: GlassMaterial.borderColor() }).shadow(GlassMaterial.capsuleShadow()).clip(true)
        // 玻璃胶囊：登录页强制默认玻璃（不受卡片材质/沉浸光感开关影响）
        .backgroundBlurStyle(BlurStyle.Thin)
        .border({ width: 1, color: GlassMaterial.BORDER })
        .shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 }).clip(true)
        .borderRadius(16)
        .padding(3)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  /** 隐私协议全屏弹窗：协议正文 + 底部"同意"按钮 + 右下角已同意时间 */
  @Builder
  privacySheet() {
    Column() {
      Text(T('隐私政策'))
        .fontSize(20)
        .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 12 })

      // 协议正文（可滚动；正文取自 rawfile/privacy.html 单一事实源，跟随系统深色）；拦截外链点击：在应用内 WebView 打开，不跳转系统浏览器
      Web({ src: $rawfile('privacy.html'), controller: this.privacyController })
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(Color.Transparent)
        .darkMode(WebDarkMode.Auto)
        .onLoadIntercept((event) => {
          if (event && event.data) {
            const url: string = event.data.getRequestUrl();
            if (url.startsWith('http://') || url.startsWith('https://')) {
              AppState.webUrl = url;
              AppState.webTitle = T('GitHub 开源仓库');
              AppState.webLoginMode = false;
              AppState.onWebLogin = null;
              this.showWeb = true;
              return true;
            }
          }
          return false;
        })

      // 底部操作行：左侧"暂不同意" + 右侧"同意并继续"；左下角显示已同意时间
      Column() {
        // 已同意时间（未同意时显示提示）
        if (this.privacyAgreedAt.length > 0) {
          Text(T('已签订时间: ') + this.privacyAgreedAt)
            .fontSize(11)
            .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .width('100%')
            .textAlign(TextAlign.End)
            .margin({ bottom: 8 })
        } else {
          Text(T('未同意将无法使用账号登录，仅可使用"功能浏览"'))
            .fontSize(11)
            .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .width('100%')
            .textAlign(TextAlign.End)
            .margin({ bottom: 8 })
        }
        Row() {
          Button(T('暂不同意'))
            .fontSize(14)
            .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .backgroundColor(GlassMaterial.cardSurface(AppStorage.get<boolean>('isDarkMode') ?? false)).backgroundBlurStyle(BlurStyle.Thin).border({ width: 1, color: GlassMaterial.borderColor() }).shadow(GlassMaterial.capsuleShadow()).clip(true)
            .height(42)
            .layoutWeight(1)
            .borderRadius(21)
            .onClick(() => {
              this.declinePrivacy();
            })
          Button(T('同意并继续'))
            .fontSize(14)
            .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
            .fontColor($r('app.color.brand_on'))
            .backgroundColor($r('app.color.brand'))
            .height(42)
            .layoutWeight(1)
            .borderRadius(21)
            .margin({ left: 12 })
            .onClick(() => {
              this.agreePrivacy();
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 20 })
      .backgroundColor(GlassMaterial.cardSurface(AppStorage.get<boolean>('isDarkMode') ?? false)).backgroundBlurStyle(BlurStyle.Thin).border({ width: 1, color: GlassMaterial.BORDER }).shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 }).clip(true)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  /** 开发者声明弹窗（同意隐私协议后首次展示：独立开发声明，标题加粗 + 正文排版） */
  @Builder
  declarationSheet() {
    // 弹窗内容套 MaterialSheetPanel：材质由 Toggle 承载层渲染，bindSheet 必须显式透明底（见宿主选项）。
    // SheetSize.FIT_CONTENT（高度随内容）→ panelFillHeight: false；原根容器的 bg_page 底色删除（由面板兜底）。
    MaterialSheetPanel({ panelRadius: 20, panelPadding: 0, panelFillHeight: false, panelShowClose: true, panelOnClose: (): void => { this.showDeclaration = false; } }) {
      Column() {
        // 标题
        Row() {
          Text(T('开发者声明'))
            .fontSize(18)
            .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
            .fontColor($r('app.color.text_primary'))
          Blank()
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 18, bottom: 10 })

        // 声明正文（分段：标题加粗、正文正常）
        Scroll() {
          Column() {
            ForEach(DEVELOPER_DECLARATION, (sec: DeclarationSection) => {
              Column() {
                Text(sec.title)
                  .fontSize(15)
                  .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                  .margin({ bottom: 4 })
                Text(sec.content)
                  .fontSize(13)
                  .lineHeight(22)
                  .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                  .width('100%')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .margin({ bottom: 14 })
            }, (sec: DeclarationSection) => sec.title)
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 4, bottom: 16 })
        }
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)

        // 底部操作行：上一步（回隐私协议）+ 我已知晓
        Row() {
          Button(T('上一步'))
            .fontSize(14)
            .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .backgroundColor(GlassMaterial.cardSurface(AppStorage.get<boolean>('isDarkMode') ?? false)).backgroundBlurStyle(BlurStyle.Thin).border({ width: 1, color: GlassMaterial.borderColor() }).shadow(GlassMaterial.capsuleShadow()).clip(true)
            .height(40)
            .layoutWeight(1)
            .borderRadius(20)
            .onClick(() => {
              this.showDeclaration = false;
              // 稍作停顿再弹隐私协议，避免两个半模态转场重叠
              setTimeout(() => {
                this.showPrivacy = true;
              }, 300);
            })
          Button(T('我已知晓'))
            .fontSize(14)
            .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
            .fontColor($r('app.color.brand_on'))
            .backgroundColor($r('app.color.brand'))
            .height(40)
            .layoutWeight(1)
            .borderRadius(20)
            .margin({ left: 12 })
            .onClick(() => {
              this.showDeclaration = false;
              // 开发者声明之后（仅首次）：展示账号风控提醒
              if (!DataStore.isRiskTipShown()) {
                DataStore.setRiskTipShown();
                setTimeout(() => {
                  this.showRiskTip = true;
                }, 300);
              }
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 4, bottom: 20 })
      }
      .width('100%')
    }
  }

  /** 账号风控提醒弹窗（开发者声明之后首次展示：频繁登录退出的风险提示） */
  @Builder
  riskTipSheet() {
    // 弹窗内容套 MaterialSheetPanel（同开发者声明弹窗）：材质由 Toggle 承载层渲染，bindSheet 必须显式透明底；
    // SheetSize.FIT_CONTENT → panelFillHeight: false；原根容器的 bg_page 底色删除（由面板兜底）。
    MaterialSheetPanel({ panelRadius: 20, panelPadding: 0, panelFillHeight: false, panelShowClose: true, panelOnClose: (): void => { this.showRiskTip = false; } }) {
      Column() {
        // 标题
        Row() {
          Text(T('账号风控提醒'))
            .fontSize(18)
            .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
            .fontColor($r('app.color.text_primary'))
          Blank()
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 18, bottom: 10 })

        // 提醒正文（居中排版，聚焦提示内容）
        Column() {
          Text(T('请勿频繁登录与退出教务系统，以免导致账号风控无法使用！') +
            '建议将应用锁定在后台，以免被清除。\n\n' +
            '若账号风控导致应用无法使用，请清除应用数据，等待24小时及以上，风控将自动解除。\n\n' +
            '若此时应用还是无法登录，则可能是学校服务器更新，应用不一定还能登录，' +
            '请关注更新动态（没有更新就说明应用已无法使用）。')
            .fontSize(14)
            .lineHeight(22)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding({ left: 28, right: 28, top: 4, bottom: 8 })
        .alignItems(HorizontalAlign.Center)

        // 底部操作行：上一步（回开发者声明）+ 我知道了
        Row() {
          Button(T('上一步'))
            .fontSize(14)
            .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .backgroundColor(GlassMaterial.cardSurface(AppStorage.get<boolean>('isDarkMode') ?? false)).backgroundBlurStyle(BlurStyle.Thin).border({ width: 1, color: GlassMaterial.borderColor() }).shadow(GlassMaterial.capsuleShadow()).clip(true)
            .height(40)
            .layoutWeight(1)
            .borderRadius(20)
            .onClick(() => {
              this.showRiskTip = false;
              // 稍作停顿再弹开发者声明，避免两个半模态转场重叠
              setTimeout(() => {
                this.showDeclaration = true;
              }, 300);
            })
          Button(T('我知道了'))
            .fontSize(14)
            .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
            .fontColor($r('app.color.brand_on'))
            .backgroundColor($r('app.color.brand'))
            .height(40)
            .layoutWeight(1)
            .borderRadius(20)
            .margin({ left: 12 })
            .onClick(() => {
              this.showRiskTip = false;
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 12, bottom: 20 })
      }
      .width('100%')
    }
  }
}
