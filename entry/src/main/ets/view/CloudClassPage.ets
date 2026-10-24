/**
 * CloudClassPage —— 云课堂（智教云）
 *
 * 直接内嵌网页版。原因：统一认证对原生直连有二次验证（MFA）拦截，
 * API 直连的两条路径（URL ticket / localStorage 会话解密）在本机多次实测均不可用；
 * 而 WebView 是真实浏览器环境，SSO 必定放行、页面功能完整。
 *
 * 适配要点：
 *  - 入口用 ICloudPortal，自动 302 到统一认证 → 有 CASTGC 时免密直进
 *  - 开启 DOM Storage（云课堂前端依赖 localStorage 存会话）
 *  - 加载进度条 + 失败重试
 *  - 非 http(s) scheme（tel/mailto/第三方 App）直接拦截，避免 WebView 白屏
 */
import { webview } from '@kit.ArkWeb';
import { AppState } from '../common/AppState';
import { Const } from '../common/Constants';
import { DataStore } from '../common/DataStore';
import { LogStore } from '../common/LogStore';
import { Theme } from '../common/ThemeUtil';
import { WallpaperTone } from '../common/WallpaperTone';
import { BackButton } from './common/BackButton';
import { Immersive } from './common/Immersive';
import { MaterialButton } from './common/MaterialButton';
import { WallpaperFill } from './common/WallpaperFill';
import { T } from '../common/I18n';

@Component
export struct CloudClassPage {
  /** 界面语言版本号：切换语言后自增，订阅它即可重建本组件 */
  @StorageProp('langRev') langRev: number = 0;
  @StorageProp('topInsetPx') topInsetPx: number = 0;
  @StorageProp('bottomInsetPx') bottomInsetPx: number = 0;
  @StorageProp('themeColor') themeColor: string = 'green';
  @StorageProp('barStyle') barStyle: string = 'new';
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageProp('wallpaperTone') wallpaperTone: number = -1;

  @State progress: number = 0;
  @State loadError: boolean = false;
  /** 网页内是否可后退 / 可前进（驱动按钮可用态） */
  @State canBack: boolean = false;
  @State canForward: boolean = false;
  /** 落到统一认证登录页（凭据已过期）：显示重登入口 */
  @State needRelogin: boolean = false;
  private navTimer: number = -1;
  private webCtl: webview.WebviewController = new webview.WebviewController();
  /** 入口地址（重试复用）：ICloudPortal 会自动跳统一认证 */
  private readonly entryUrl: string = `${Const.CC_BASE_URL}/ICloudPortal/`;

  aboutToAppear(): void {
    LogStore.log('云课堂', '网页版', '进入', this.entryUrl);
    // 免二次认证的关键：先把已保存的统一认证凭据注入 WebView 的 authserver Cookie，
    // 这样 SSO 跳转时服务端直接放行，不会停在登录页要求重新输入账号密码。
    this.injectAuthCookies();
    // 800ms 轮询前进/后退可用态：云课堂是 SPA，页内路由变化不触发 onPageEnd，
    // 只能主动查询（开销极小：仅两个同步标志位读取）
    this.navTimer = setInterval(() => {
      this.syncNavState();
    }, 800);
  }

  /** 注入统一认证 Cookie（CASTGC + 可信设备指纹），避免每次进云课堂都要重新认证 */
  private injectAuthCookies(): void {
    const host: string = 'https://authserver.njmu.edu.cn/';
    try {
      // ① 全量回放登录时保存的 authserver Cookie（含 MULTIFACTOR_BROWSER_FINGERPRINT）
      const raw: string = DataStore.get(DataStore.KEY_CAS_AUTH_COOKIES);
      if (raw.length > 0) {
        const parts: string[] = raw.split(';');
        for (let i: number = 0; i < parts.length; i++) {
          const seg: string = parts[i].trim();
          const eq: number = seg.indexOf('=');
          if (eq <= 0) {
            continue;
          }
          const name: string = seg.substring(0, eq).trim();
          const value: string = seg.substring(eq + 1).trim();
          webview.WebCookieManager.setCookie(host, `${name}=${value}; Domain=authserver.njmu.edu.cn; Path=/`);
        }
      }
      // ② 兜底：单独注入 CASTGC（部分登录路径只存了这一项）
      const tgc: string = DataStore.get(DataStore.KEY_CAS_TGC);
      if (tgc.length > 0) {
        webview.WebCookieManager.setCookie(host,
          `CASTGC=${tgc}; Domain=authserver.njmu.edu.cn; Path=/`);
      }
      LogStore.log('云课堂', '凭据注入', '完成', `CASTGC=${tgc.length > 0 ? '有' : '无'}`);
    } catch (e) {
      LogStore.log('云课堂', '凭据注入', '失败', LogStore.errorOf(e as Object));
    }
  }

  /** 离开页面即停止网页加载与状态轮询（避免后台继续跑 JS / 拉流） */
  aboutToDisappear(): void {
    if (this.navTimer >= 0) {
      clearInterval(this.navTimer);
      this.navTimer = -1;
    }
    try {
      this.webCtl.stop();
    } catch (e) {
      // ignore
    }
  }

  /** 若当前跳到统一认证登录页，说明本地凭据已失效，提示用户重登（避免反复停在登录页） */
  private detectNeedLogout(): void {
    try {
      const url: string = this.webCtl.getUrl();
      const hit: boolean = url.indexOf('authserver.njmu.edu.cn') >= 0 && url.indexOf('login') >= 0;
      if (hit !== this.needRelogin) {
        this.needRelogin = hit;
        if (hit) {
          LogStore.log('云课堂', '认证', '需重新登录', url.substring(0, 80));
        }
      }
    } catch (e) {
      // 页面未就绪
    }
  }

  private syncNavState(): void {
    try {
      const b: boolean = this.webCtl.accessBackward();
      const f: boolean = this.webCtl.accessForward();
      if (b !== this.canBack) {
        this.canBack = b;
      }
      if (f !== this.canForward) {
        this.canForward = f;
      }
    } catch (e) {
      // 页面未就绪时忽略
    }
  }

  /** 返回应用上一页（不是网页内后退） */
  private backToApp(): void {
    try {
      this.webCtl.stop();
    } catch (e) {
      // ignore
    }
    AppState.stack.pop();
  }

  /** 网页内后退 */
  private webBack(): void {
    if (!this.canBack) {
      return;
    }
    try {
      this.webCtl.backward();
    } catch (e) {
      LogStore.log('云课堂', '网页', '后退失败', LogStore.errorOf(e as Object));
    }
  }

  /** 网页内前进 */
  private webForward(): void {
    if (!this.canForward) {
      return;
    }
    try {
      this.webCtl.forward();
    } catch (e) {
      LogStore.log('云课堂', '网页', '前进失败', LogStore.errorOf(e as Object));
    }
  }

  private reload(): void {
    this.loadError = false;
    this.progress = 0;
    try {
      this.webCtl.refresh();
    } catch (e) {
      try {
        this.webCtl.loadUrl(this.entryUrl);
      } catch (e2) {
        LogStore.log('云课堂', '网页版', '刷新失败', LogStore.errorOf(e2 as Object));
      }
    }
  }

  /** 顶栏网页导航按钮：不可用时降透明度并禁用点击 */
  @Builder
  navButton(label: string, enabled: boolean, onTap: () => void) {
    Text(label)
      .fontSize(18)
      .fontColor(enabled
        ? WallpaperTone.onWallpaper(this.wallpaperTone, this.isDarkMode)
        : 'rgba(255,255,255,0.32)')
      .width(30)
      .height(30)
      .textAlign(TextAlign.Center)
      .borderRadius(15)
      .backgroundColor(enabled ? 'rgba(255,255,255,0.20)' : 'rgba(255,255,255,0.07)')
      .onClick(() => {
        if (enabled) {
          onTap();
        }
      })
  }

  build() {
    NavDestination() {
      Stack() {
        WallpaperFill()
        Column() {
          // 顶栏
          Stack({ alignContent: Alignment.TopStart }) {
            Column()
              .width('100%')
              .height(this.getUIContext().px2vp(this.topInsetPx) + 60)
              .linearGradient({ angle: 180, colors: Theme.barGradient(this.themeColor, this.barStyle) })
              .backgroundBlurStyle(Immersive.blur(BlurStyle.Thin, this.barStyle === 'legacy'))
            Row({ space: 4 }) {
              // 返回应用（独立于网页历史）
              BackButton({ onBack: () => { this.backToApp(); } })
              Text(T('云课堂'))
                .fontSize(19)
                .fontWeight(FontWeight.Bold)
                .fontColor(WallpaperTone.onWallpaper(this.wallpaperTone, this.isDarkMode))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              // 网页前进 / 后退 / 刷新
              this.navButton('‹', this.canBack, () => { this.webBack(); })
              this.navButton('›', this.canForward, () => { this.webForward(); })
              this.navButton('⟳', true, () => { this.reload(); })
            }
            .width('100%')
            .height(this.getUIContext().px2vp(this.topInsetPx) + 60)
            .alignItems(VerticalAlign.Top)
            .padding({ left: 10, right: 16, top: this.getUIContext().px2vp(this.topInsetPx) + 12, bottom: 12 })
          }
          .width('100%')
          .height(this.getUIContext().px2vp(this.topInsetPx) + 60)

          // 加载进度条
          if (this.progress > 0 && this.progress < 100) {
            Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
              .color(Theme.colorOf(this.themeColor))
              .height(2)
              .width('100%')
          }

          // 凭据过期提示：停在统一认证登录页时给出重登入口，避免反复认证
          if (this.needRelogin) {
            Row({ space: 8 }) {
              Text(T('统一认证登录已过期'))
                .fontSize(11)
                .fontColor('#FFFFFF')
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(T('去重登'))
                .fontSize(11)
                .fontColor('#FFFFFF')
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .backgroundColor('rgba(255,255,255,0.24)')
                .borderRadius(10)
                .onClick(() => {
                  const cb: (() => void) | null = AppState.onForceRelogin;
                  if (cb !== null) {
                    cb();
                  }
                })
            }
            .width('100%')
            .padding({ left: 12, right: 8, top: 7, bottom: 7 })
            .backgroundColor('#E08A00')
          }

          Stack() {
            Web({ src: this.entryUrl, controller: this.webCtl })
              .width('100%')
              .height('100%')
              .javaScriptAccess(true)
              .domStorageAccess(true)
              .fileAccess(false)
              .geolocationAccess(false)
              .cacheMode(CacheMode.Default)
              .onProgressChange((e) => {
                if (e !== undefined) {
                  this.progress = e.newProgress;
                }
              })
              .onPageEnd(() => {
                this.loadError = false;
                this.progress = 100;
                this.detectNeedLogout();
              })
              .onErrorReceive((e) => {
                if (e !== undefined && e.error) {
                  this.loadError = true;
                  LogStore.log('云课堂', '网页版', '加载失败',
                    `${e.error.getErrorInfo()} ${e.error.getErrorCode()}`);
                }
              })
              // 非 http(s) 链接（tel/mailto/第三方 App scheme）直接拦截，避免 WebView 白屏
              .onLoadIntercept((event) => {
                if (event === undefined) {
                  return false;
                }
                const url: string = event.data.getRequestUrl();
                const ok: boolean = url.startsWith('http://') || url.startsWith('https://') ||
                  url.startsWith('about:') || url.startsWith('data:');
                if (!ok) {
                  LogStore.log('云课堂', '外链', '拦截', url.substring(0, 60));
                  return true;
                }
                return false;
              })

            if (this.loadError) {
              Column() {
                Text(T('网页加载失败'))
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                Text(T('请检查网络后重试；若长时间打不开，可到「我的」重新登录统一认证'))
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .textAlign(TextAlign.Center)
                  .margin({ top: 8, left: 32, right: 32 })
                MaterialButton({
                  btnRadius: 18,
                  btnBg: Theme.colorOf(this.themeColor),
                  btnBorderW: 0,
                  btnMargin: { top: 18 },
                  btnOnClick: () => { this.reload(); }
                }) {
                  Text(T('重新加载'))
                    .fontSize(14)
                    .fontColor('#FFFFFF')
                    .width(110)
                    .height(36)
                    .textAlign(TextAlign.Center)
                }
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .backgroundColor($r('app.color.bg_page'))
            }
          }
          .layoutWeight(1)
          .width('100%')
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
    }
    .backgroundColor($r('app.color.bg_page'))
    .hideTitleBar(true)
    .systemTransition(NavigationSystemTransitionType.SLIDE_RIGHT)
  }
}
