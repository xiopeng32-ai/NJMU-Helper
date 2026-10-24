/**
 * 主框架：Navigation（承载二级页面）+ HdsTabs 底栏（首页 / 课程表 / 成绩 / 南医新闻 / 我的）
 * 悬浮底栏移植自 HarmonyOS Spatialization 示例
 * （https://gitcode.com/HarmonyOS_Samples/Spatialization）：
 *   - HdsTabs.barFloatingStyle：胶囊悬浮栏（两侧留白 + 底部留白 + 左右手自适应）
 *   - barWidth 与内容卡片宽度对齐（340/420/500），5 个选项间距适中
 *   - systemMaterialEffect: IMMERSIVE/ADAPTIVE 沉浸毛玻璃光感，自动按深浅色反色
 *   - 内容区底部已加 padding，避免悬浮栏遮挡最后一项内容
 *
 * 页面底色：由 `AppearanceStore.pageBackground()` 派生（内置主题色染色；
 * 自定义 hex 需开启「高权限自定义主题色」）——移植自参考项目 miha_hm 的页面底色染色。
 * 新增页面路由：BackgroundCropPage（背景裁剪）/ FontManagePage（字体管理）。
 */
import { DataStore } from '../common/DataStore';
import { LogStore } from '../common/LogStore';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { AppState } from '../common/AppState';
import { AppearanceStore } from '../common/AppearanceStore';
import { Const } from '../common/Constants';
import { I18n } from '../common/I18n';
import { GlassMaterial } from '../common/GlassMaterial';
import { Theme } from '../common/ThemeUtil';
import { Wallpaper } from '../common/Wallpaper';
import { WallpaperTone } from '../common/WallpaperTone';
import { AboutPage } from './AboutPage';
import { AcademicPage } from './AcademicPage';
import { ExamPage } from './ExamPage';
import { HomeView } from './HomeView';
import { KxjsPage } from './KxjsPage';
import { MineView } from './MineView';
import { NewsDetailPage } from './NewsDetailPage';
import { NewsFavPage } from './NewsFavPage';
import { CollegeNoticePage } from './CollegeNoticePage';
import { NewsPage } from './NewsPage';
import { LogPage } from './LogPage';
import { SearchResultPage } from './SearchResultPage';
import { WebViewPage } from './WebViewPage';
import { WallpaperPage } from './WallpaperPage';
import { BackgroundCropPage } from './BackgroundCropPage';
import { FontManagePage } from './FontManagePage';
import { WechatOAPage } from './WechatOAPage';
import { NoticeDetailPage, NoticePage } from './NoticePage';
import { PrivacyPage } from './PrivacyPage';
import { TermsPage } from './TermsPage';
import { ScheduleView } from './ScheduleView';
import { ScorePage } from './ScorePage';
import { CloudClassPage } from './CloudClassPage';
import { TodaySchedulePage } from './TodaySchedulePage';
import { ChangelogPage } from './ChangelogPage';
import { NotifySettingsPage } from './NotifySettingsPage';
import { LanguagePage } from './LanguagePage';
import { CourseRawPage } from './CourseRawPage';
import { QuickSelectPage } from './QuickSelectPage';
import { ResponsiveUtil } from '../common/ResponsiveUtil';
import { T } from '../common/I18n';

@Component
export struct MainView {
  /** 界面语言版本号：切换语言后自增，订阅它即可重建本组件 */
  @StorageProp('langRev') langRev: number = 0;
  @StorageProp('bottomInsetPx') bottomInsetPx: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /** 壁纸蒙版开关（关闭时不叠加可读性遮罩） */
  @StorageProp('wallpaperMask') wallpaperMask: boolean = true;
  @StorageProp('themeColor') themeColor: string = 'green';
  /** 高权限自定义主题色开关（登记依赖：切换后页面底色即时刷新） */
  @StorageProp('customAccentFull') customAccentFull: boolean = false;
  /** 页面背景色（广播键）：沾色/主题/深色/高权限开关变化时由 AppearanceStore.broadcastDerived() 重写 */
  @StorageProp('pageBackground') pageBgBc: string = '';
  @StorageProp('immersiveEffect') immersiveEffect: boolean = false;
  /** 全局壁纸 id（'b1'..'b6' 预置 / 'c:<path>' 自定义 / 'none'=未启用） */
  @StorageProp('wallpaperId') wallpaperId: string = 'none';
  /** 壁纸亮度（自动对比度适配用） */
  @StorageProp('wallpaperTone') wallpaperTone: number = -1;
  /** 是否 PC 窗口化（非全屏/最大化）：窗口底部无系统安全区，底栏需额外留白 */
  @StorageProp('winFloating') winFloating: boolean = false;
  /** 二级页面请求切换底部 Tab（如今日课表页的「查看完整课表」）：-1 表示无请求 */
  @Watch('onSwitchTabRequest') @StorageProp('switchTabRequest') switchTabReq: number = -1;
  @State currentIndex: number = 0;
  /** 接续恢复中的目标 Tab（-1 = 无恢复任务）：仅用于日志确认切换是否真正生效 */
  private restoringTab: number = -1;
  /** 沉浸浏览：首页内容下滑时隐藏悬浮底栏（HomeView 滚动广播），上滑/切页恢复 */
  @StorageProp('homeBarsHidden') homeBarHidden: boolean = false;
  /** 全局字重响应式订阅：表达式读 this.fwMode 才登记依赖，fwValue 声明即订阅 */
  @StorageProp('fontWeightMode') fwMode: string = 'follow';
  @StorageProp('fontWeightValue') fwValue: number = 400;
  /**
   * 底栏高亮专用状态（与页面解耦）：点击 tab 时立即更新（图标/文字即时变色），
   * 页面切换只交给 changeIndex(index) 带动画执行；currentIndex 在 onChange
   * （动画完成）才同步。此前点击直接赋值 currentIndex → HdsTabs 的 index 参数瞬跳，
   * 外观设置的「页面平滑切换」动画被完全绕过（开关无效的根因）。
   */
  @State activeIndex: number = 0;
  /** 主页页面平滑切换（外观设置）：开启后页签切换带页面滑动过渡 */
  @StorageProp('smoothPageSwitch') smoothPageSwitch: boolean = true;
  private tabsController: HdsTabsController = new HdsTabsController();
  onLogout: () => void = () => {
  };
  /** 前往登录页（不退出登录）：由 MineView 退出弹窗触发，向上传给 Index */
  onGotoLogin: () => void = () => {
  };

  /**
   * 悬浮底栏距窗口底部的距离（vp）。
   * - 常规（手机 / 平板 / PC 全屏、最大化）：仅让出系统导航条安全区，尽量贴底；
   * - PC 窗口化（浮动窗口）：窗口底部没有系统安全区，沿用"贴底"会显得过低，
   *   故保底留出 16vp，与全屏观感一致。
   */
  private barBottomMargin(): number {
    const inset: number = this.getUIContext().px2vp(this.bottomInsetPx);
    const base: number = 4 + inset;
    if (ResponsiveUtil.isDesktop() && this.winFloating) {
      return Math.max(base, 16);
    }
    return base;
  }

  /** Tab 序号 → 灰字活动页 key（每页/角色单独灰字色的生效上下文） */
  static tabPageKey(index: number): string {
    if (index === 1) {
      return 'schedule';
    }
    if (index === 2) {
      return 'score';
    }
    if (index === 3) {
      return 'news';
    }
    if (index === 4) {
      return 'mine';
    }
    return 'home';
  }

  /** 页面出现：处理桌面卡片点击跳转（AppState.openPageRequest）+ 多端流转恢复 */
  /**
   * 应用接续恢复：读 DataStore 快照 → 延迟切 Tab → 延迟打开二级页 → 清标记。
   * 延迟是必要的：aboutToAppear 阶段 TabsController 尚未绑定组件，changeIndex 会无效。
   */
  private restoreContinueState(): void {
    const pending: string = DataStore.get(AppState.KEY_CONTINUE_PENDING);
    if (pending !== '1') {
      return;
    }
    LogStore.log('流转', '接续恢复', '开始', `pending=1 tab=${DataStore.get(AppState.KEY_CONTINUE_TAB)}`);
    const tabRaw: number = Number.parseInt(DataStore.get(AppState.KEY_CONTINUE_TAB), 10);
    const route: string = DataStore.get(AppState.KEY_CONTINUE_ROUTE);
    // 先清标记，保证即使后续失败也不会反复跳转
    DataStore.put(AppState.KEY_CONTINUE_PENDING, '0');
    const tab: number = Number.isNaN(tabRaw) ? 0 : Math.max(0, Math.min(4, tabRaw));
    // ⚠ 这里不能先写 currentIndex：HdsTabs 以 index 作为"初始页"，接续时若把初始 index 设成非 0，
    // 内容区在 controller 绑定前会渲染成空白（表现为"蓝屏/无内容"）。改为保持默认 0 启动，
    // 等 controller 就绪后统一 changeIndex，让 HdsTabs 自己带动内容切换。
    AppState.currentTabIndex = tab;
    this.restoringTab = tab;
    // 双保险：① 改受控属性 currentIndex（index 参数驱动切页）② changeIndex（controller 驱动）
    // 只调 changeIndex 在部分机型/首帧布局期间会被吞掉，导致停在首页或不渲染；
    // 只改 currentIndex 在 HdsTabs 未就绪时可能空白。两者都做，谁先生效都能到目标页。
    setTimeout(() => {
      this.activeIndex = tab;
      try {
        this.currentIndex = tab;
        this.tabsController.changeIndex(tab);
        GlassMaterial.setTabPage(MainView.tabPageKey(tab));
        LogStore.log('流转', '接续恢复', '已切页', `tab=${tab} index=${this.currentIndex}`);
      } catch (e) {
        LogStore.log('流转', '接续恢复', '切页异常', LogStore.errorOf(e as Object));
      }
      // 校验：1.2s 后仍不在目标页则再试一次，并把结果写进日志（便于定位是否被布局吞掉）
      setTimeout(() => {
        if (this.currentIndex !== tab) {
          try {
            this.currentIndex = tab;
            this.activeIndex = tab;
            this.tabsController.changeIndex(tab);
            LogStore.log('流转', '接续恢复', '重试切页', `tab=${tab}`);
          } catch (e2) {
            LogStore.log('流转', '接续恢复', '重试失败', LogStore.errorOf(e2 as Object));
          }
        } else {
          LogStore.log('流转', '接续恢复', '确认到位', `tab=${tab}`);
        }
        // 最后一层校验：仍失败就明确告知用户（避免对着空白页猜），并留在首页保证可用
        setTimeout(() => {
          if (this.currentIndex !== tab) {
            LogStore.log('流转', '接续恢复', '失败', `目标tab=${tab} 实际tab=${this.currentIndex}`);
            try {
              this.getUIContext().getPromptAction().showToast({
                message: '接续恢复未完成，已回到首页', duration: 2400
              });
            } catch (e3) {
              // ignore
            }
          }
        }, 900);
      }, 1200);
    }, 700);
    // 二级页面再晚一点，等 Tab 内容渲染完成
    if (route.length > 0) {
      setTimeout(() => {
        try {
          AppState.stack.pushPath({ name: route });
          LogStore.log('流转', '接续恢复', '完成', `tab=${tab} route=${route}`);
        } catch (e) {
          LogStore.log('流转', '接续恢复', '路由失败', `${route} ${LogStore.errorOf(e as Object)}`);
        }
      }, 1400);
    } else {
      LogStore.log('流转', '接续恢复', '完成', `tab=${tab}（无二级页）`);
    }
  }

  /** 处理外部跳转请求（冷启动 aboutToAppear 与热启动订阅共用） */
  private handleOpen(req: string): void {
    if (req.length === 0) {
      return;
    }
    // 先切到首页 Tab（无论哪种 open，都以此为入口）
    if (this.currentIndex !== 0) {
      this.currentIndex = 0;
      this.activeIndex = 0;
      this.tabsController.changeIndex(0);
    }
    if (req === 'exam-pick') {
      // 跳转到「考试安排」页，ExamPage 内部通过 AppState.pickExam 触发选择弹窗
      AppState.openPageRequest = '';
      AppState.stack.pushPath({ name: Const.ROUTE_EXAM });
    } else if (req === 'exam') {
      // 通知点击：直达考试安排页
      AppState.openPageRequest = '';
      AppState.stack.pushPath({ name: Const.ROUTE_EXAM });
    } else if (req === 'score') {
      // 通知点击：直达成绩页
      AppState.openPageRequest = '';
      AppState.stack.pushPath({ name: Const.ROUTE_SCORE });
    } else if (req === 'notice') {
      // 通知点击：直达通知页
      AppState.openPageRequest = '';
      AppState.stack.pushPath({ name: Const.ROUTE_NOTICE });
    } else if (req === 'schedule') {
      // 通知/实况窗点击：切到课表 Tab
      AppState.openPageRequest = '';
      if (this.currentIndex !== 1) {
        this.activeIndex = 1;
        this.currentIndex = 1;
        this.tabsController.changeIndex(1);
      }
    } else if (req === 'academic') {
      // 桌面「学业成绩」卡片点击：直接打开学业情况页
      AppState.openPageRequest = '';
      AppState.stack.pushPath({ name: Const.ROUTE_ACADEMIC });
    } else {
      // 'home' 或其它：仅回到首页
      AppState.openPageRequest = '';
    }
  }

  aboutToDisappear(): void {
    AppState.clearOpenPageListener();
  }

  aboutToAppear(): void {
    // 多端流转（应用接续）：从 DataStore 读取快照并延迟应用。
    // 关键点（修复接续后空白 / 二次接续失败）：
    //  1) 状态来自持久化，不依赖 AppStorage 在 Ability.onCreate 阶段的写入时序；
    //  2) 必须等 TabsController 与 Navigation 栈就绪后再切换，否则 index 改了但页面不渲染（空白）；
    //  3) 消费后立刻清 pending，避免下次普通启动又跳到接续页。
    this.restoreContinueState();
    // 灰字高级调整：初始活动页 = 当前 Tab（默认首页）；同时记录 Tab key 供路由页退出后恢复
    GlassMaterial.setTabPage(MainView.tabPageKey(this.currentIndex));
    AppState.setOpenPageListener((p: string) => {
      this.handleOpen(p);
    });
    this.handleOpen(AppState.openPageRequest);
  }


  /** Tab 按钮：图标 + 文字，选中品牌色、未选中灰（高亮读 activeIndex：点击即时变色，与页面动画解耦） */
  @Builder
  tabItem(title: string, icon: Resource, index: number) {
    Column() {
      Image(icon)
        .width(ResponsiveUtil.tabIconSize())
        .height(ResponsiveUtil.tabIconSize())
        .fillColor(this.activeIndex === index ? Theme.colorOf(this.themeColor) : WallpaperTone.onWallpaper(this.wallpaperTone, this.isDarkMode))
      Text(title)
        .fontSize(ResponsiveUtil.tabFontSize())
        // 德语/俄语等长语言在 1/5 屏宽里也要单行不折行（宁可省略号，也不要堆成两行把图标顶歪）
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontWeight(this.fwMode === 'follow' ? (this.activeIndex === index ? FontWeight.Medium : FontWeight.Normal) : AppearanceStore.fontWeight(this.activeIndex === index ? FontWeight.Medium : FontWeight.Normal))
        .fontColor(this.activeIndex === index ? Theme.colorOf(this.themeColor) : (this.isDarkMode ? '#FFFFFF' : '#000000'))
        .margin({ top: 3 })
    }
    .width('100%')
    .height(ResponsiveUtil.tabItemHeight())
    .justifyContent(FlexAlign.Center)
    // 智慧屏/PC：遥控器与键盘可通过焦点进入底栏（触摸设备上无副作用）
    .focusable(true)
    .focusOnTouch(false)
    .onClick(() => {
      // 高亮即时更新（activeIndex），页面切换只走 changeIndex(index) 带动画：
      // 直接赋值 currentIndex 会让 HdsTabs 的 index 参数瞬跳、绕过平滑切换动画（勿回退）。
      // 关闭平滑开关时 animationDuration(0)，changeIndex 瞬跳、行为不变。
      if (this.activeIndex !== index) {
        this.activeIndex = index;
        this.tabsController.changeIndex(index);
      }
    })
  }

  @Builder
  pageMap(name: string) {
    if (name === Const.ROUTE_EXAM) {
      ExamPage()
    } else if (name === Const.ROUTE_NOTICE) {
      NoticePage()
    } else if (name === Const.ROUTE_NOTICE_DETAIL) {
      NoticeDetailPage()
    } else if (name === Const.ROUTE_ACADEMIC) {
      AcademicPage()
    } else if (name === Const.ROUTE_SCORE) {
      ScorePage()
    } else if (name === Const.ROUTE_PRIVACY) {
      PrivacyPage()
    } else if (name === Const.ROUTE_TERMS) {
      TermsPage()
    } else if (name === Const.ROUTE_ABOUT) {
      AboutPage()
    } else if (name === Const.ROUTE_CHANGELOG) {
      ChangelogPage()
    } else if (name === Const.ROUTE_NOTIFY_SETTINGS) {
      NotifySettingsPage()
    } else if (name === Const.ROUTE_LANGUAGE) {
      LanguagePage()
    } else if (name === Const.ROUTE_COURSE_RAW) {
      CourseRawPage()
    } else if (name === Const.ROUTE_QUICK_SELECT) {
      QuickSelectPage()
    } else if (name === Const.ROUTE_EMPTY_ROOM) {
      KxjsPage()
    } else if (name === Const.ROUTE_NEWS_DETAIL) {
      NewsDetailPage()
    } else if (name === Const.ROUTE_NEWS_FAV) {
      NewsFavPage()
    } else if (name === Const.ROUTE_LOG) {
      LogPage()
    } else if (name === Const.ROUTE_SEARCH) {
      SearchResultPage()
    } else if (name === Const.ROUTE_WEB_PAGE) {
      WebViewPage()
    } else if (name === Const.ROUTE_WALLPAPER) {
      WallpaperPage()
    } else if (name === Const.ROUTE_BG_CROP) {
      BackgroundCropPage()
    } else if (name === Const.ROUTE_FONT_MANAGE) {
      FontManagePage()
    } else if (name === Const.ROUTE_WECHAT_OA) {
      WechatOAPage()
    } else if (name === Const.ROUTE_COLLEGE_NOTICE) {
      CollegeNoticePage()
    } else if (name === Const.ROUTE_CLOUD_CLASS) {
      CloudClassPage()
    } else if (name === Const.ROUTE_TODAY_SCHEDULE) {
      TodaySchedulePage()
    }
  }

  /** 二级页面请求切换 Tab（如今日课表页「查看完整课表」）：消费后复位标记 */
  private onSwitchTabRequest(): void {
    const idx: number = this.switchTabReq;
    if (idx < 0 || idx > 4) {
      return;
    }
    AppStorage.setOrCreate<number>('switchTabRequest', -1);
    // 等二级页 pop 动画结束再切，避免动画叠加
    setTimeout(() => {
      this.activeIndex = idx;
      this.tabsController.changeIndex(idx);
      AppState.currentTabIndex = idx;
    }, 220);
  }

  /** HDS 材质类型（容错：部分 ROM/HDS 版本可能不提供该枚举） */
  private safeMaterialType(): hdsMaterial.MaterialType {
    try {
      return hdsMaterial.MaterialType.IMMERSIVE;
    } catch (e) {
      return 0 as hdsMaterial.MaterialType;
    }
  }

  /** HDS 材质档位（容错） */
  private safeMaterialLevel(): hdsMaterial.MaterialLevel {
    try {
      return hdsMaterial.MaterialLevel.ADAPTIVE;
    } catch (e) {
      return 0 as hdsMaterial.MaterialLevel;
    }
  }

  build() {
    Stack() {
      // 页面底色：无壁纸时的默认底色（五个 Tab 页根背景已透明，由本层兜底）。
      // 底色经 AppearanceStore 派生：内置主题色始终染色；自定义 hex 需开启「高权限自定义主题色」。
      // 走广播键订阅：开关/主题/深色变化时即时刷新（广播未写入前回落静态派生兜底）。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.pageBgBc.length > 0
          ? this.pageBgBc
          : AppearanceStore.pageBackground(this.isDarkMode, this.themeColor))
        .hitTestBehavior(HitTestMode.None)
      // 全局壁纸（'none'=未启用不渲染）。壁纸始终清晰显示；
      // 可读性遮罩仅壁纸启用时叠加，避免默认观感变化。
      if (this.wallpaperId.startsWith('c:')) {
        Image(Wallpaper.src(this.wallpaperId))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .hitTestBehavior(HitTestMode.None)
        if (this.wallpaperMask) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.wallpaperTone >= 0
              ? WallpaperTone.overlay(this.wallpaperTone, this.isDarkMode)
              : (this.isDarkMode ? 'rgba(8,10,10,0.38)' : 'rgba(255,255,255,0.18)'))
            .hitTestBehavior(HitTestMode.None)
        }
      }
      Navigation(AppState.stack) {
        // scrollable=false 见下方属性链：禁止左右滑动切换页面——课程表页的横向滑动用于切换周次，二者冲突
        HdsTabs({ barPosition: BarPosition.End, index: this.currentIndex, controller: this.tabsController }) {
          TabContent() {
            HomeView({
              onSwitchTab: (index: number) => {
                // 同 tabItem 点击：高亮即时更新，切换走 changeIndex(index) 带动画
                // （直接赋值 currentIndex 会瞬跳、绕过平滑切换动画）
                if (this.activeIndex !== index) {
                  this.activeIndex = index;
                  this.tabsController.changeIndex(index);
                }
              }
            })
          }
          .tabBar(this.tabItem(I18n.tabLabels()[0], $r('app.media.house'), 0))

          TabContent() {
            ScheduleView()
          }
          .tabBar(this.tabItem(I18n.tabLabels()[1], $r('app.media.calendar'), 1))

          TabContent() {
            AcademicPage({ isTab: true })
          }
          .tabBar(this.tabItem(I18n.tabLabels()[2], $r('app.media.data_icon'), 2))

          // 南医新闻（占位页）：位于"成绩"和"我的"之间
          TabContent() {
            NewsPage()
          }
          .tabBar(this.tabItem(I18n.tabLabels()[3], $r('app.media.list_square_bill'), 3))

          TabContent() {
            MineView({
              onLogout: () => {
                this.onLogout();
              },
              onGotoLogin: () => {
                this.onGotoLogin();
              }
            })
          }
          .tabBar(this.tabItem(I18n.tabLabels()[4], $r('app.media.person'), 4))
        }
        // 手势左右滑动固定禁用（scrollable 不在 HdsTabsOptions 中，只能走属性链）；
        // smoothPageSwitch 仅控制点击切页的滑动动画时长，不再控制手势
        .scrollable(false)
        .animationDuration(this.smoothPageSwitch ? 240 : 0) // 平滑切换：开启时页面滑动过渡（移植自参考项目）
        .barMode(BarMode.Fixed)
        // 悬浮底栏（自适应长度 + 紧凑高度 + 沉浸光感）
        //  - barWidth 与上方内容卡片宽度对齐（手机约 300vp），5 个选项间距适中
        //  - systemMaterialEffect: IMMERSIVE + ADAPTIVE 沉浸毛玻璃，按系统算力/光感强弱分档适配
        //  - lightColor 为材质光效着色（深色下用浅色高光，浅色下用品牌色低饱和光效），增强光感层次
        //  - barBottomMargin 贴近底部，内容区底部已加 padding 防止遮挡
        .barOverlap(true) // 内容与底栏重叠，由 barFloatingStyle 控制悬浮外观
        .barFloatingStyle({
          // 智慧屏/PC 大屏上底栏加宽，避免 5 个入口挤在中间一小条
          barWidth: ResponsiveUtil.isLargeScreen()
            ? { smallWidth: 520, mediumWidth: 620, largeWidth: 760 }
            : { smallWidth: 340, mediumWidth: 420, largeWidth: 500 },
          barSideMargin: 12, // 悬浮栏距屏幕左右边缘
          barBottomMargin: this.homeBarHidden ? -160 : this.barBottomMargin(), // 沉浸浏览：隐藏时推出屏幕外；距屏幕底部（PC 窗口化时自动多留白，见方法注释）
          adaptToHandedness: true, // 左右手自适应
          // 光效颜色跟随主题色（点光源与主题色一致）
          lightColor: Theme.rgba(Theme.colorOf(this.themeColor), this.isDarkMode ? 0.40 : 0.28),
          systemMaterialEffect: {
            // 底栏沉浸光感固定开启（不受外观设置开关影响）
            materialType: this.safeMaterialType(),
            materialLevel: this.safeMaterialLevel() // 随系统沉浸光感强弱自适应
          }
        })
        .width('100%')
        .height('100%')
        .onChange((index: number) => {
          if (index === this.currentIndex) {
            return;
          }
          // 瞬时切换（无淡入淡出）：避免整页透明度 0→1 造成切换闪烁。
          // onChange 在切换（含滑动）完成后触发：currentIndex 同步给 HdsTabs 的 index 参数，
          // activeIndex 同步让底栏高亮跟上手势滑动（点击路径已在 onClick 里先行更新）。
          this.currentIndex = index;
          this.activeIndex = index;
          // 多端流转：同步当前 Tab（接续到另一台设备时按此恢复）
          AppState.currentTabIndex = index;
          // 切页恢复底栏与标题栏（沉浸隐藏状态只在首页滚动中生效）
          AppStorage.setOrCreate<boolean>('homeBarsHidden', false);
          // 灰字高级调整：同步活动页面 key（常驻 Tab 页的每页单独灰字色随切换生效）
          GlassMaterial.setTabPage(MainView.tabPageKey(index));
        })
      }
      .hideTitleBar(true)
      .backgroundColor(Color.Transparent)
      .mode(NavigationMode.Stack)
      .navDestination(this.pageMap)
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
