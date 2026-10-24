import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import { fileIo } from '@kit.CoreFileKit';
import { AppState } from '../common/AppState';
import { AppearanceStore } from '../common/AppearanceStore';
import { DataStore } from '../common/DataStore';
import { I18n } from '../common/I18n';
import { LogStore } from '../common/LogStore';
import { NotifyScheduler } from '../common/NotifyScheduler';
import { PushNotifier } from '../common/PushNotifier';
import { GlassMaterial } from '../common/GlassMaterial';
import { WallpaperTone } from '../common/WallpaperTone';
import { Theme } from '../common/ThemeUtil';
import { NewsApi } from '../api/NewsApi';
import { connection } from '@kit.NetworkKit';
import { HttpClient } from '../api/HttpClient';
import { JwApi } from '../api/JwApi';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  /**
   * 计算并广播"窗口化"状态到 AppStorage('winFloating')：
   * 非全屏 且 窗口矩形小于屏幕（PC 上拖动缩放的浮动窗口）→ true。
   * 全屏 / 最大化时窗口尺寸铺满屏幕，返回 false（底栏保持原有贴底样式）。
   */
  private static publishFloating(win: window.Window): void {
    try {
      const props: window.WindowProperties = win.getWindowProperties();
      const d = display.getDefaultDisplaySync();
      const smaller: boolean = props.windowRect.width < d.width || props.windowRect.height < d.height;
      AppStorage.setOrCreate('winFloating', !props.isFullScreen && smaller);
    } catch (err) {
      AppStorage.setOrCreate('winFloating', false);
    }
  }

  /** Ability 创建：初始化数据存储、头像开关、深色模式监听 */
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // 初始化本地持久化（历史账号 + 数据缓存），并保存全局 Context
    DataStore.init(this.context);
    AppState.context = this.context;
    // 界面语言：读取上次选择（默认跟随系统）→ 解析生效语言 → 同步系统资源语言。
    // 必须在 DataStore.init 之后、任何界面构建之前完成，否则首帧会先按默认值渲染再跳变。
    I18n.init();
    // 多端流转（应用接续）：从另一台设备接续过来时，恢复上次停留的 Tab 与二级页面
    try {
      if (launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION) {
        const params: Record<string, Object> = (want.parameters ?? {}) as Record<string, Object>;
        const tabRaw: number = Number.parseInt(String(params['continueTab'] ?? '-1'), 10);
        const routeRaw: string = String(params['continueRoute'] ?? '');
        // 落到 DataStore：MainView 挂载后读取并消费（AppStorage 在 onCreate 阶段写入可能丢失）
        DataStore.put(AppState.KEY_CONTINUE_TAB, `${Number.isNaN(tabRaw) ? 0 : tabRaw}`);
        DataStore.put(AppState.KEY_CONTINUE_ROUTE, routeRaw);
        DataStore.put(AppState.KEY_CONTINUE_PENDING, '1');
        LogStore.log('流转', '接续接收', 'CONTINUATION',
          `tab=${tabRaw} route=${routeRaw.length > 0 ? routeRaw : '-'}`);
        hilog.info(DOMAIN, 'EntryAbility', '接续恢复 tab=%{public}d route=%{public}s', tabRaw, routeRaw);
      }
    } catch (e) {
      // 接续恢复失败不影响正常启动
    }
    // 无感在线：网络恢复时立刻清掉"无网"缓存并自动重拉数据，
    // 用户从飞行模式/地铁断网恢复后无需手动下拉刷新
    try {
      const netConn: connection.NetConnection = connection.createNetConnection();
      netConn.on('netAvailable', () => {
        HttpClient.resetNetworkCache();
        if (!JwApi.USE_MOCK) {
          JwApi.lastRefreshReset();
          JwApi.refreshAll().catch(() => {
            // ignore
          });
        }
      });
      netConn.register((err: Object) => {
        if (err !== undefined && err !== null) {
          hilog.warn(DOMAIN, 'EntryAbility', 'netAvailable 监听注册失败');
        }
      });
    } catch (e) {
      // 监听注册失败不影响主流程
    }
    // 读取真实版本号（供关于页版本显示与检查更新比对，杜绝硬编码漏改）
    AppState.resolveAppVersion();
    // 通知与提醒：建槽 + 首次排程（失败不阻断启动）
    PushNotifier.ensureSlot().then(() => {
      NotifyScheduler.rescheduleAll('app-start').catch(() => {
      });
    }).catch(() => {
    });
    // 接续能力自检：日志里若始终没有「接续保存」，说明系统未回调 onContinue（设备/账号/开关条件不满足）
    try {
      const ver: string = AppState.appVersion;
      LogStore.log('流转', '能力自检', '完成',
        `continuable=已声明 v${ver}（若接续无反应，请检查两端同华为账号 + 应用接续开关 + 同签名包）`);
    } catch (e) {
      // ignore
    }
    // 处理桌面卡片跳转意图（params.open = 'home' | 'exam-pick'）
    const open: string = (want.parameters?.['open'] as string) ?? '';
    if (open.length > 0) {
      AppState.requestOpenPage(open);
    }
    // 头像显示开关（默认关闭，仅影响圆形头像）
    const showAvatar: boolean = DataStore.get(DataStore.KEY_SHOW_AVATAR) === '1';
    AppStorage.setOrCreate('showAvatar', showAvatar);
    // 全局壁纸 id（'b1'..'b6' 预置 / 'c:<path>' 自定义 / 'none'=未启用；默认不启用保持原观感）
    const wp: string = DataStore.loadWallpaper();
    AppStorage.setOrCreate('wallpaperId', wp.length > 0 ? wp : 'none');
    // 恢复顶栏主题色（中国红/天空蓝/南医蓝/自定义 #RRGGBB）
    Theme.restore();
    // 恢复应用内字体缩放（外观设置页可调；1.0 = 标准）
    try {
      this.context.getApplicationContext().setFontSizeScale(DataStore.loadFontScale());
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set fontSizeScale. Cause: %{public}s', JSON.stringify(e));
    }
    // 通透程度滑条（外观设置页可调：0~100 连续控制毛玻璃模糊强度与透明度）
    AppStorage.setOrCreate('glassStrength', DataStore.loadGlassStrength());
    // 灰色字体颜色覆盖（default/white/black/custom）
    AppStorage.setOrCreate('grayTextMode', DataStore.loadGrayMode());
    AppStorage.setOrCreate('grayTextColor', DataStore.loadGrayCustom());
    // 深色模式：默认为浅色（isDarkOn 返回 false 即表示浅色）
    AppStorage.setOrCreate('isDarkMode', DataStore.isDarkOn());
    // 顶栏样式：新版渐变（默认）/ 旧版实色
    AppStorage.setOrCreate('barStyle', DataStore.barStyle());
    // 顶栏副标题颜色（空=自动）
    AppStorage.setOrCreate('subtitleColor', DataStore.subtitleColor());
    // 全局沉浸光感（外观设置主开关，外观设置页可切换）：从持久化恢复，默认开启
    AppStorage.setOrCreate('immersiveEffect', DataStore.immersiveOn());
    // 壁纸蒙版开关（默认为开）
    AppStorage.setOrCreate('wallpaperMask', DataStore.wallpaperMaskOn());
    // 新闻封面缩略图开关（默认开启）
    AppStorage.setOrCreate('newsThumb', DataStore.newsThumbOn());
    // 新闻内容背景大卡片开关（默认开启）
    AppStorage.setOrCreate('newsBgCard', DataStore.newsBgCardOn());
    // 壁纸明暗（对比度自动适配用，-1=未分析）
    AppStorage.setOrCreate('wallpaperTone', WallpaperTone.load());

    // ── 外观设置恢复（移植自参考项目：卡片沾色 / 主题色流光 / 卡片流光触感 /
    //    高权限自定义主题色 / 字体管理与自定义字体注册）──
    // 对应参考文件：miha_hm `pages/AppearanceSettingsPage.ets` + `utils/CustomFonts.ets`
    // 在 DataStore.init + AppState.context 之后调用，保证自定义字体可读沙箱目录并完成注册。
    AppearanceStore.init();
    // 灰体文本覆盖启动恢复：模式/自定义色先回 AppStorage（此前冷启动会丢失设置），
    // 再载入每页单独色 map、文字样式，并广播（含灰字调用的页面订阅 grayTick，见 GlassMaterial.broadcastGray）
    AppStorage.setOrCreate('grayTextMode', DataStore.loadGrayMode());
    AppStorage.setOrCreate('grayTextColor', DataStore.loadGrayCustom());
    GlassMaterial.loadTextStyle();
    GlassMaterial.loadTextGlowColor();
    AppearanceStore.loadPageBgTint();
    AppearanceStore.loadCardFallback();
    GlassMaterial.loadGrayPageMap();
    GlassMaterial.broadcastGray();
    // 「自动」灰字色：按壁纸亮度计算对比度更高的颜色（1.5s 防抖，壁纸刚变化时先静止再切换）
    GlassMaterial.scheduleAutoGray();
    try {
      this.context.getApplicationContext()
        .setColorMode(DataStore.isDarkOn() ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
          : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  /** 应用回到前台：重新应用当前颜色模式，并关闭后台隐私模式（前台由 DLP 防窥接管） */
  onForeground(): void {
    this.setPrivacyMode(false);
    // 通知与提醒：回到前台立即重排（补齐后台期间错过的提醒/实况窗）
    NotifyScheduler.markForeground(true);
    NotifyScheduler.rescheduleAll('foreground').catch(() => {
    });
    try {
      this.context.getApplicationContext()
        .setColorMode(DataStore.isDarkOn() ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
          : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (e) {
      // ignore
    }
  }

  /** Ability 已存在时再次被拉起（桌面卡片点击） */
  /**
   * 多端流转（应用接续）：把当前使用状态交给目标设备（手机 / 平板 / 2in1）。
   * 返回 AGREE 表示接受接续；目标设备 onCreate 收到 LaunchReason.CONTINUATION 后按 wantParam 恢复。
   * 只传轻量状态（Tab 序号 + 二级页面路由名），业务数据仍走各自本地缓存/接口，避免跨设备传大对象。
   */
  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    // 无论发生什么都返回 AGREE：抛错会让"再次接续"直接失败
    try {
      AppState.saveContinueState();
      const tab: string = DataStore.get(AppState.KEY_CONTINUE_TAB);
      const route: string = DataStore.get(AppState.KEY_CONTINUE_ROUTE);
      wantParam['continueTab'] = tab.length > 0 ? tab : '0';
      wantParam['continueRoute'] = route;
      wantParam['continueAt'] = `${Date.now()}`;
      // 用 LogStore：hilog 只在系统日志里，App 内日志页看不到（此前"日志没有相关显示"的原因）
      LogStore.log('流转', '接续保存', 'AGREE', `tab=${tab} route=${route.length > 0 ? route : '-'}`);
      hilog.info(DOMAIN, 'EntryAbility', '接续保存 tab=%{public}s route=%{public}s', tab, route);
    } catch (e) {
      LogStore.log('流转', '接续保存', '异常降级AGREE', LogStore.errorOf(e as Object));
      try {
        wantParam['continueTab'] = '0';
        wantParam['continueRoute'] = '';
      } catch (e2) {
        // ignore
      }
    }
    return AbilityConstant.OnContinueResult.AGREE;
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const open: string = (want.parameters?.['open'] as string) ?? '';
    if (open.length > 0) {
      AppState.requestOpenPage(open);
    }
  }

  /** Ability 销毁回调 */
  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
    // 防抖队列立即落盘，避免销毁时丢缓存
    DataStore.flushNow();
    // 清理南医新闻图片缓存
    NewsApi.clearCache();
    // 删除空闲教室导出 Excel 临时文件（含解压目录）
    try {
      const cacheDir: string = this.context.cacheDir;
      const files: string[] = [
        `${cacheDir}/kxcdlb_export.xlsx`,
        `${cacheDir}/kxcdlb_xlsx`
      ];
      for (let i = 0; i < files.length; i++) {
        try {
          if (fileIo.accessSync(files[i])) {
            if (fileIo.statSync(files[i]).isDirectory()) {
              fileIo.rmdirSync(files[i]);
            } else {
              fileIo.unlinkSync(files[i]);
            }
          }
        } catch (e) {
          // 单文件清理失败可忽略
        }
      }
    } catch (e) {
      // ignore
    }
  }

  /** 窗口创建：加载主页面并设置沉浸式状态栏 */
  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 沉浸式：内容延伸到状态栏，并把状态栏/导航条高度存入 AppStorage 供页面避让
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      mainWindow.setWindowLayoutFullScreen(true);
      const topArea: window.AvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      AppStorage.setOrCreate('topInsetPx', topArea.topRect.height);
      const bottomArea: window.AvoidArea =
        mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      AppStorage.setOrCreate('bottomInsetPx', bottomArea.bottomRect.height);
      mainWindow.on('avoidAreaChange', (data) => {
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
          AppStorage.setOrCreate('topInsetPx', data.area.topRect.height);
        } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          AppStorage.setOrCreate('bottomInsetPx', data.area.bottomRect.height);
        }
      });
      // 是否"窗口化"（PC 上拖动缩放的浮动窗口，非全屏/最大化）：
      // 浮动窗口底部没有系统安全区，悬浮底栏固定贴底会显得过低 → 需要额外留白
      EntryAbility.publishFloating(mainWindow);
      mainWindow.on('windowStatusChange', () => {
        EntryAbility.publishFloating(mainWindow);
      });
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set full screen. Cause: %{public}s', JSON.stringify(err));
    }

    windowStage.loadContent('pages/Splash', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });

    try {
      // 应用当前深色模式设置
      this.context.getApplicationContext()
        .setColorMode(DataStore.isDarkOn() ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
          : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  /** 窗口销毁回调 */
  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  /** 应用进入后台回调 */
  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    // 切后台时立即落盘，避免防抖队列中的数据因进程挂起而丢失
    DataStore.flushNow();
    // 通知与提醒：进入后台收敛一次（实况窗该建就建），并停止前台心跳
    NotifyScheduler.markForeground(false);
    // 防窥：进入后台开启窗口隐私模式，多任务卡片/最近任务预览不再泄露成绩等敏感内容
    this.setPrivacyMode(true);
  }

  /** 设置窗口隐私模式（失败静默：部分设备/窗口类型不支持） */
  private setPrivacyMode(on: boolean): void {
    try {
      window.getLastWindow(this.context).then((w: window.Window) => {
        w.setWindowPrivacyMode(on).catch((_e: Object) => {
          // 不支持时忽略
        });
      }).catch((_e: Object) => {
        // 忽略
      });
    } catch (e) {
      // 忽略
    }
  }
}