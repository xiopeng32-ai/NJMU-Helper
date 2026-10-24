/**
 * 应用入口：未登录 -> 登录页，已登录 -> 主框架
 */
import { JwApi } from '../api/JwApi';
import { HttpClient } from '../api/HttpClient';
import { DataStore } from '../common/DataStore';
import { AppState } from '../common/AppState';
import { DateUtil } from '../common/DateUtil';
import { LoginView } from '../view/LoginView';
import { MainView } from '../view/MainView';
import { PrivacyGatePage } from '../view/PrivacyGatePage';
import { TermInfo, UserProfile } from '../model/Models';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { DailyWallpaper } from '../common/DailyWallpaper';
import { NotifyLifecycle } from '../common/NotifyLifecycle';
import { NotifyScheduler } from '../common/NotifyScheduler';
import { AppearanceStore } from '../common/AppearanceStore';
import { T } from '../common/I18n';

@Entry
@Component
struct Index {
  /** 界面语言版本号：切换语言后自增，订阅它即可重建本组件 */
  @StorageProp('langRev') langRev: number = 0;
  @State logged: boolean = false;
  /** 登录兜底定时器句柄（登录成功后必须清掉，否则回调会在已进主页后继续跑） */
  private loginTimers: number[] = [];
  @State autoRelogin: boolean = false;
  /** 前往登录页模式（不退出登录，仅跳转登录界面，可从登录页返回首页） */
  @State showLoginOnly: boolean = false;
  /** 主页"重登"按钮触发时的全局遮罩（与 LoginView 自动重登共用 loading 效果） */
  @State forceReloginLoading: boolean = false;
  /** 系统深色模式（功能浏览水印颜色适配） */
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /** 全局字重响应式订阅：表达式读 this.fwMode 才登记依赖，fwValue 声明即订阅 */
  @StorageProp('fontWeightMode') fwMode: string = 'follow';
  @StorageProp('fontWeightValue') fwValue: number = 400;
  /** 首启隐私引导页：未同意隐私协议时覆盖全屏，依次展示 隐私协议→开发者声明→账号风控 */
  @State privacyGate: boolean = false;

  /** 功能浏览模式水印已移除（用户要求去除模拟数据预览水印），保留空实现避免调用点改动 */
  private scheduleMockWatermark(): void {
  }

  /** 页面出现：初始化 AppStorage 兜底值并加载主界面 */
  aboutToDisappear(): void {
    for (const t of this.loginTimers) {
      clearTimeout(t);
    }
    this.loginTimers = [];
  }

  aboutToAppear(): void {
    // 每日壁纸：已保存图像地址时，每天首次启动自动下载并应用新壁纸（静默，失败不影响启动）
    try {
      DailyWallpaper.ensureToday(this.getUIContext().getHostContext() as common.UIAbilityContext);
    } catch (e) {
    }

    // 首次启动隐私引导：未同意隐私协议 → 全屏覆盖引导页（隐私协议→开发者声明），
    // 同意/暂不同意后才进入下方登录/主界面逻辑（LoginView 不再自动弹隐私弹窗）。
    this.privacyGate = !DataStore.isPrivacyAgreed();

    // ★ 冷启动真实模式判定（关键修复）：
    //   USE_MOCK 是内存态、每次冷启动重置为 true，若直接用它判断「是否已登录」，
    //   会导致 cachedProfile 恒为 null → hasCache 恒 false → 「已登录秒开主页」分支永远不进，
    //   每次启动都被迫重新走登录流程（首页数据也因此反复从空缓存开始）。
    //   改为按「本地是否存在任何真实登录痕迹」判定：有缓存资料 / CASTGC / 会话 Cookie / 记住的账号密码。
    const probeProfile: UserProfile | null = DataStore.loadCachedProfile();
    const probeHasProfile: boolean = probeProfile !== null && probeProfile.name.length > 0
      && probeProfile.studentId !== 'demo';
    const probeHasCredentials: boolean =
      DataStore.get(DataStore.KEY_CAS_TGC).length > 0 ||
        DataStore.get(DataStore.KEY_SESSION_COOKIE).length > 0 ||
        (DataStore.get(DataStore.KEY_AUTO_ACCOUNT).length > 0 && DataStore.get(DataStore.KEY_AUTO_PWD).length > 0);
    if (probeHasProfile || probeHasCredentials) {
      JwApi.USE_MOCK = false;
    }

    // 功能浏览模式（USE_MOCK=true）：仅启用离线模式（禁止真实网络请求，避免误访教务系统）。
    // ⚠ 周次按**真实日期**推算（用户要求：日历/课表的日期定位必须是真实周次，不能固定演示值）；
    //   口径与真实模式一致（学期外 <1 时兜底第 1 周）。
    if (JwApi.USE_MOCK) {
      const mockW: number = DateUtil.weekOfTerm(AppState.term, new Date());
      AppState.mockCurrentWeek = mockW < 1 ? 1 : mockW;
      HttpClient.setOfflineMode(true);
    } else {
      HttpClient.setOfflineMode(false);
    }
    // 启动时恢复学期：优先用户上次选择的学期，否则当前默认学期（最新学年第一学期）。
    // ⚠ 必须统一经 JwApi.setTerm（内部 applyCustomStart）初始化——历史 bug：
    //   仅在「有历史学期 id」时才调 setTerm，从未切过学期的用户重启后自定义开学时间不生效（回到 9-01）。
    const termId: string = DataStore.get(DataStore.KEY_DS_TERM);
    const startTerms: TermInfo[] = JwApi.buildLocalTerms();
    let picked: TermInfo | null = null;
    for (const t of startTerms) {
      if (t.id === termId) {
        picked = t;
        break;
      }
    }
    // 兜底必须用"当前日期推算的学期"（如 2026-10 → 2026-2027-1），
    // 不能取列表第一个（历史学期或未来学期都会错），否则所有接口用错误 xnm 查询返回空数据。
    JwApi.setTerm(picked !== null ? picked : DateUtil.buildCurrentTerm());
    // 学期就绪后补一次提醒排程：EntryAbility.onCreate 的 app-start 早于这里，
    // 不补的话 1~8 月（默认学期周次越界）会把提醒排空且本轮不再恢复
    NotifyScheduler.rescheduleAll('term-ready').catch(() => {
    });

    // ── 冷启动会话恢复策略（核心：服务大厅登录态在 → 必须先"从服务大厅重新打开新教务系统"再取数据）──
    //  有 CASTGC（服务大厅登录成功且保持登录态）：教务系统会话不可持久化 →
    //    冷启动第一步总是用 CASTGC 桥接（GET /sso/jzlogin）重新打开"新教务系统"换取全新 jwglxt 会话，
    //    第二步才取数据（refreshAll）。TGC 过期时仅自动重登模式用账号密码走服务大厅补登；手动重登则保留缓存等"重登"。
    //  无 CASTGC（教务登录 RSA）：按重登方式 → 自动重登用账号密码 RSA 直登刷新；手动重登不自动刷新。
    const autoAcct: string = DataStore.get(DataStore.KEY_AUTO_ACCOUNT);
    const autoPwd: string = DataStore.get(DataStore.KEY_AUTO_PWD);
    const loginMode: string = DataStore.getLoginMode();
    const sessionCookie: string = DataStore.get(DataStore.KEY_SESSION_COOKIE);
    const cachedProfile: UserProfile | null = JwApi.USE_MOCK ? null : DataStore.loadCachedProfile();
    const hasCache: boolean = cachedProfile !== null && cachedProfile.name.length > 0 && cachedProfile.studentId !== 'demo';

    // 已登录过（有缓存资料）：直接进主页（秒开，无闪登录页），后台静默恢复会话并刷新。
    if (hasCache && !JwApi.USE_MOCK) {
      AppState.profile = cachedProfile;
      AppState.account = cachedProfile!.studentId;
      this.logged = true;
      JwApi.USE_MOCK = false;
      // 清演示周次残留：演示周次会让首页按错误周次匹配真实课表，导致"下一节课"永远为空
      AppState.mockCurrentWeek = 0;
      HttpClient.setOfflineMode(false);
      // 注册主页"重登"按钮回调（HomeView 在 aboutToAppear 触发）
      AppState.onForceRelogin = () => {
        this.forceRelogin();
      };
      // 会话恢复中：首页数据加载须等待（防止用旧教务会话取数失败）
      AppState.sessionReady = false;
      // 冷启动会话恢复策略（按登录方式区分）：
      //  1) 网页登录 / 统一认证 CAS（service）：有 CASTGC 时用 CASTGC 静默桥接换取全新 jwglxt 会话，
      //     这是教务会话不可持久化场景下唯一可靠的恢复路径；
      //  2) 教务 RSA 直登（original）：有账号密码时用 RSA 直登刷新会话；
      //  3) 兜底：用本地会话 Cookie（可能已过期，后台刷新会失败并触发"重登"提示）。
      const loginMethod: string = DataStore.getLoginMethod();
      const loginSystem: string = DataStore.get(DataStore.KEY_LOGIN_SYSTEM);
      const casTgc: string = DataStore.get(DataStore.KEY_CAS_TGC);
      const sessionCookie: string = DataStore.get(DataStore.KEY_SESSION_COOKIE);
      const useCas: boolean = (loginMethod === 'web' || loginSystem === 'service') && casTgc.length > 0;
      if (loginMode !== 'legacy') {
        if (loginMethod === 'web' && sessionCookie.length > 0) {
          // 网页登录：优先直接用网页登录时持久化的 jwglxt 会话 Cookie（WebView 里的真实会话）。
          // 原生 CAS 换 ST 在南医大已失效（authserver 对非浏览器 UA 不返回 ticket），
          // 走 CASTGC 静默桥接必然失败，故不再依赖它；会话 Cookie 过期时由后台刷新触发"重登"提示。
          HttpClient.setCookie(sessionCookie);
          JwApi.refreshAll().catch(() => {});
          AppState.sessionReady = true;
        } else if (useCas) {
          // 统一认证（原生 CAS 登录成功持久化 CASTGC）：优先用 CASTGC 静默重登（教务会话不可持久化，必须重新桥接）
          JwApi.silentCasRelogin()
            .then((ok: boolean) => {
              if (ok) {
                JwApi.refreshAll().catch(() => {});
              }
              AppState.sessionReady = true;
            })
            .catch(() => {
              AppState.sessionReady = true;
            });
        } else if (autoAcct.length > 0 && autoPwd.length > 0) {
          JwApi.login(autoAcct, DataStore.decodePwd(autoPwd), '', 'original')
            .then(() => {
              JwApi.refreshAll().catch(() => {});
              AppState.sessionReady = true;
            })
            .catch(() => {
              AppState.sessionReady = true;
            });
        } else if (sessionCookie.length > 0) {
          // 无自动凭据时用本地会话 Cookie 恢复
          HttpClient.setCookie(sessionCookie);
          JwApi.refreshAll().catch(() => {});
          AppState.sessionReady = true;
        } else {
          AppState.sessionReady = true;
        }
      } else {
        // 手动重登：不自动刷新，直接放行（首页用缓存展示）
        AppState.sessionReady = true;
      }
      return;
    }

    // 无缓存资料：走账号+密码自动重登（弹登录页遮罩）或手动登录。
    if (autoAcct.length > 0 && autoPwd.length > 0 && loginMode !== 'legacy') {
      this.autoRelogin = true;
      this.loginTimers.push(setTimeout(() => {
        if (!this.logged) {
          this.getUIContext().getPromptAction().showToast({ message: '登录失败，请稍后再试', duration: 2000 });
          this.logged = true; // 进入主页，使用本地缓存数据
        }
      }, 10000));
      AppState.onForceRelogin = () => {
        this.forceRelogin();
      };
      return;
    }
    // 无任何凭据：手动登录页（注册重登回调即可）
    AppState.onForceRelogin = () => {
      this.forceRelogin();
    };
  }

  /**
   * 主页"重登"按钮：弹"真正重新登录"确认对话框，
   * 用户确认后切换到 LoginView 自动重登模式（遮罩+静默登录），
   * 登录成功回到主页 + 刷新数据；登录失败/超时兜底回主页用缓存。
   */
  private forceRelogin(): void {
    // 识别当前登录系统：服务大厅登录 → 重新从服务大厅登录并自动打开教务系统；教务登录 → 账号密码重登
    const sys: string = DataStore.get(DataStore.KEY_LOGIN_SYSTEM);
    const reloginMsg: string = sys === 'service'
      ? '当前为「服务大厅登录」。将重新从服务大厅登录，并自动打开教务系统刷新数据；登录期间不允许操作其他功能。'
      : '当前为「教务登录」。将使用保存的账号密码重新登录教务系统；登录期间不允许操作其他功能。';
    this.getUIContext().getPromptAction().showDialog({
      title: '真正重新登录',
      message: reloginMsg,
      buttons: [
        { text: T('取消'), color: '#888888' },
        { text: '重新登录', color: '#FF9800' }
      ]
    }).then((r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index !== 1) {
        return;
      }
      // 用户确认：切到登录页自动重登模式
      this.autoRelogin = true;
      this.showLoginOnly = true;
      this.forceReloginLoading = true;
      // 超时兜底（分两阶段，避免"服务大厅实际已登录、却提示登录失败"的状态冲突）：
      // ① 20s 未完成但登录已进入收尾阶段（会话已建立，正在校验资料）→ 延长 30s 等待；
      // ② 仍未完成 → 提示失败并回到主页用缓存。
      this.loginTimers.push(setTimeout(() => {
        if (!this.forceReloginLoading) {
          return;
        }
        if (JwApi.stage() === 'profile') {
          this.loginTimers.push(setTimeout(() => {
            if (this.forceReloginLoading) {
              this.forceReloginLoading = false;
              this.getUIContext().getPromptAction().showToast({ message: '登录收尾超时，请稍后再试', duration: 2000 });
              this.showLoginOnly = false;
            }
          }, 20000));
          return;
        }
        this.forceReloginLoading = false;
        this.getUIContext().getPromptAction().showToast({ message: '登录失败，请稍后再试', duration: 2000 });
        this.showLoginOnly = false;
      }, 12000));
    }).catch(() => {
      // 弹窗失败时不做任何事
    });
  }

  build() {
    Stack() {
      if (this.logged) {
        if (this.showLoginOnly) {
          // 前往登录页（不退出）：登录页左上角显示返回按钮，可返回首页
          LoginView({
            showBack: true,
            // ★ 必须把 autoRelogin 真正传给 LoginView：此前硬编码 false，
            //   导致点「立即重登」后登录页不会自动登录，只留下全屏遮罩转圈（绿屏卡死）
            autoRelogin: this.autoRelogin,
            onBack: () => {
              this.showLoginOnly = false;
              this.autoRelogin = false;
              this.forceReloginLoading = false;
            },
            onSuccess: () => {
              // 在登录页完成登录后返回主页
              this.showLoginOnly = false;
              this.autoRelogin = false;
              this.forceReloginLoading = false;
              this.scheduleMockWatermark();
              if (!JwApi.USE_MOCK) {
                HttpClient.setOfflineMode(false);
                JwApi.refreshAll().catch(() => {});
              } else {
                HttpClient.setOfflineMode(true);
              }
            }
          })
        } else {
          MainView({
            onLogout: () => {
              // 退出登录：撤销提醒、停实况窗、删快照（防止换账号后残留旧提醒/假新增）
              NotifyLifecycle.purge('logout').catch(() => {
              });
              this.logged = false;
            },
            onGotoLogin: () => {
              this.showLoginOnly = true;
            }
          })
        }
      } else {
        LoginView({
          autoRelogin: this.autoRelogin,
          onSuccess: () => {
            this.logged = true;
            this.autoRelogin = false;
            this.forceReloginLoading = false;
            this.showLoginOnly = false;
            this.scheduleMockWatermark();
            // 登录成功后：如果是真实登录（USE_MOCK=false）才开启网络、刷新数据
            if (!JwApi.USE_MOCK) {
              HttpClient.setOfflineMode(false);
              JwApi.refreshAll().then(() => {
                // 数据已刷新：若部分接口回退缓存，提示用户（获取状态提示）
                const st = AppStorage.get<Record<string, Object>>('dataRefreshStatus');
                if (st !== undefined && st !== null) {
                  const allFresh: boolean = st['allFresh'] === true;
                  const fromCacheCount: number = Number(st['fromCacheCount'] ?? 0);
                  if (!allFresh && fromCacheCount > 0) {
                    const totalCount: number = Number(st['totalCount'] ?? 0);
                    this.getUIContext().getPromptAction().showToast({
                      message: `部分数据获取失败，已展示上次获取的数据（${fromCacheCount}/${totalCount} 项）`,
                      duration: 2500
                    });
                  }
                }
              }).catch(() => {
                // 忽略
              });
            } else {
              // 功能浏览模式：确保离线模式开启
              HttpClient.setOfflineMode(true);
            }
          }
        })
      }
      // 功能浏览模式水印已移除（用户要求去除模拟数据预览水印）。
      // "重登" 全局遮罩：叠加在主页之上，提示正在重新登录，并允许随时取消（避免卡死无法返回）
      if (this.forceReloginLoading) {
        Column() {
          LoadingProgress()
            .width(42)
            .height(42)
            .color('#FFFFFF')
          Text(T('正在重新登录…'))
            .fontSize(14)
            .fontColor('#FFFFFF')
            .margin({ top: 14 })
          Text(T('取消'))
            .fontSize(13)
            .fontColor('#FFFFFF')
            .padding({ left: 20, right: 20, top: 8, bottom: 8 })
            .backgroundColor('rgba(255,255,255,0.22)')
            .borderRadius(16)
            .margin({ top: 18 })
            .onClick(() => {
              // 用户主动取消：立即撤掉遮罩与登录页，回到首页继续看离线数据
              this.forceReloginLoading = false;
              this.autoRelogin = false;
              this.showLoginOnly = false;
              this.getUIContext().getPromptAction().showToast({ message: '已取消重登，当前显示离线数据', duration: 1800 });
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(0,0,0,0.55)')
      }
      // 首启隐私引导页（覆盖在最顶层；未同意时才会显示，同意后关闭）
      if (this.privacyGate) {
        PrivacyGatePage({
          onDone: (agreed: boolean) => {
            this.privacyGate = false;
            // 若此前有自动重登挂起且用户暂不同意：取消自动重登，停留登录页手动操作
            if (!agreed && this.autoRelogin) {
              this.autoRelogin = false;
            }
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
