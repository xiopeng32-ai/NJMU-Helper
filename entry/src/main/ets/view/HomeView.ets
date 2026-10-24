/**
 * 首页：学期概览 + 今日课程 + 快捷入口 + 近期考试
 * 头部：简约白卡头像（真实证件照）+ 学号/学院/班级
 *
 * 卡片外观接入（移植自参考项目 miha_hm `components/MaterialCard.ets` + `pages/AppearanceSettingsPage.ets`）：
 *  - 卡片统一用 `MaterialCard` 承载，层级照抄参考：材质承载层在卡片内部、位于内容之下，
 *    材质生效时卡片自身的底色/磨砂/边框/阴影一并让出，因此每张卡片只有一层视觉
 *    （就是沉浸光感材质本身），不会出现「材质盖住卡片」或两层卡片；
 *  - 卡片间距：卡片与卡片之间的间距走 `MaterialCard` 的 `cardMargin`（迁移前挂在卡片自身的 margin），
 *    区块与区块之间的间距仍由外层 Column 的 margin 承载（原样保留）；
 *  - 卡片沾色：材质生效时由 `MaterialCard` 内部在材质**之上**铺一层沾色（材质不采样同 Stack 兄弟节点，
 *    所以沾色必须独立成层），非材质场景由 `cardSurface()` 直接返回沾色底；
 *  - 主题色流光 / 卡片流光触感：由 MaterialCard **内置流光**承担（跟手光斑 + 溢出光晕，
 *    与参考项目 miha_hm 完全同源）；首页曾用页面级流光层（128vp 光斑画在页面根 Stack，
 *    不受卡片圆角裁切导致「范围错误」），已删除统一走卡内流光；
 *  - 卡片内的小卡片 / 小胶囊按钮同样接入材质（对应参考 README「按钮的沉浸光感」）：
 *    成排的快捷入口小卡用 `MaterialCard` + `cardMaterialShadow: false`（挨得近，投影会在卡间叠成暗带）；
 *    胶囊小按钮用公共组件 `MaterialButton`（Toggle 承载层 + 内容，普通 Button 直接挂材质真机不渲染）；
 *    半模态弹窗内容用 `MaterialSheetPanel`，且 `bindSheet` 必须显式 `backgroundColor: Color.Transparent`。
 */
import { KeyCode } from '@kit.InputKit';
import { SheetUtil } from '../common/SheetUtil';
import { mediaquery } from '@kit.ArkUI';
import { JwApi } from '../api/JwApi';
import { HttpClient } from '../api/HttpClient';
import { AppState } from '../common/AppState';
import { Const } from '../common/Constants';
import { DataStore } from '../common/DataStore';
import { DateUtil } from '../common/DateUtil';
import { SectionUtil } from '../common/SectionUtil';
import { LogStore } from '../common/LogStore';
import { Theme } from '../common/ThemeUtil';
import { WallpaperTone } from '../common/WallpaperTone';
import { Immersive } from './common/Immersive';
// 玻璃质感（GlassMaterial）：按钮=玻璃胶囊 GlassCapsule / 卡片=玻璃卡片 GlassCard
// 卡片容器统一走 MaterialCard（材质承载层在卡片内容之下，见 view/common/MaterialCard.ets）
import { MaterialCard, MaterialSheetPanel } from './common/MaterialCard';
import { materialActive, sheetBlurStyle } from '../common/SystemMaterial';
import { MaterialCardLayer } from './common/MaterialCarrier';
import { MaterialButton } from './common/MaterialButton';
import { AppearanceStore } from '../common/AppearanceStore';
import { GlassMaterial } from '../common/GlassMaterial';
import { CourseItem, ExamItem, NoticeItem, QuickEntry, TermInfo, TodayCourse } from '../model/Models';
import { TeachingCalendar } from '../model/TeachingCalendar';
import { BarTitle, EmptyTip, LoadingTip, SectionHeader, TagChip } from './common/UiKit';
import { WebSurface } from './WebSurface';
import { CHANGELOG_ALL, ChangelogItem } from '../common/Changelog';
import { ResponsiveUtil } from '../common/ResponsiveUtil';
import { T } from '../common/I18n';

/** 下一次非今日课的预告（首页课程无课时展示） */
interface NextFutureCourse {
  course: CourseItem;
  weekdayLabel: string;
  weekTag: string;
  timeRange: string;
  /** 月日（如 "8月12日"），用于卡片显示具体日期 */
  dateLabel: string;
}

/**
 * 版本更新内容弹窗：正文**左对齐**（系统 showDialog 的消息居中，不满足需求，改自绘）。
 * 数据经 @Link 由宿主注入，open() 前赋值即可。
 */
@CustomDialog
struct UpdateContentDialog {
  /** 界面语言版本号：切换语言后重建，避免对话框文案滞后 */
  @StorageProp('langRev') langRev: number = 0;
  controller?: CustomDialogController;
  @Link titleText: string;
  @Link lines: string[];
  build() {
    Column({ space: 10 }) {
      Text(this.titleText)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Column({ space: 5 }) {
        ForEach(this.lines, (line: string) => {
          Text(`· ${line}`)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Start)
        }, (line: string) => line)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      Button(T('知道了'))
        .fontSize(14)
        .fontColor(Color.White)
        .backgroundColor('#005BAC')
        .width('100%')
        .height(38)
        .borderRadius(10)
        .onClick(() => {
          this.controller?.close();
        })
    }
    .padding(20)
    .borderRadius(16)
    .backgroundColor($r('app.color.bg_card'))
    .width('82%')
  }
}

@Component
export struct HomeView {
  /** 界面语言版本号：切换语言后自增，订阅它即可重建本组件 */
  @StorageProp('langRev') langRev: number = 0;
  @StorageProp('topInsetPx') topInsetPx: number = 0;
  @StorageProp('bottomInsetPx') bottomInsetPx: number = 0;
  @StorageProp('themeColor') themeColor: string = 'green';
  @StorageProp('barStyle') barStyle: string = 'new';
  @StorageProp('immersiveEffect') immersiveEffect: boolean = false;
  /** 灰字覆盖响应（grayTextMode/grayTextColor 变化时触发本页重渲染，取值经 GlassMaterial 读取） */
  @StorageProp('grayTextMode') grayTextMode: string = 'default';
  @StorageProp('grayTextColor') grayTextColor: string = '';
  /** 灰字广播依赖登记：声明不进表达式=假订阅（实证），根容器 opacity 恒真表达式才真正登记 */
  @StorageProp('grayTick') grayTick: number = 0;
  /** 玻璃档位（weak/mid/strong）：仅用于档位切换时触发本页重渲染（取值经 GlassMaterial 静态方法） */
  @StorageProp('glassLevel') glassLevel: string = 'strong';
  /** 通透程度（0~100 滑条）：材质风格/磨砂与底色透明度联动（实时切换） */
  @StorageProp('glassStrength') glassStrength: number = 70;
  @StorageProp('subtitleColor') subtitleColor: string = '';
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /** 壁纸亮度（顶栏文字自适应用） */
  @StorageProp('wallpaperTone') wallpaperTone: number = -1;
  @StorageLink('showAvatar') showAvatar: boolean = false;
  // ── 移植自参考项目的卡片外观开关（@StorageProp：开关变化即时触发本页重渲染）──
  /** 卡片沾色：卡片底色混入 10% 主题色 */
  @StorageProp('cardTint') cardTint: boolean = false;
  /** 主题色流光 / 卡片流光触感：由 MaterialCard 内部订阅（cardGlowTouch / immersivePressGlow），本页不再跟踪 */
  @State todayCourses: TodayCourse[] = [];
  @State nextClass: TodayCourse | null = null;
  @State exams: ExamItem[] = [];
  @State notices: NoticeItem[] = [];
  @State currentWeek: number = 0;
  @State loading: boolean = true;
  @State photo: string = '';
  @State isLandscape: boolean = false;
  @State teachingCal: TeachingCalendar | null = null;
  /** 沉浸浏览：下滑隐藏顶部标题栏与底部 tab 栏，上滑恢复（广播给 MainView 控制底栏） */
  @State barHidden: boolean = false;
  /** 滚动累计偏移（onScroll 增量求和），用于下滑阈值判断 */
  private scrollOffset: number = 0;
  /** 日历月份 Swiper 当前页（自绘页码指示器用） */
  @State calPageIndex: number = 0;
  @State jwcNotices: NoticeItem[] = [];
  @State showNoticeSheet: boolean = false;
  @State sheetNotice: NoticeItem | null = null;
  @State showWebSheet: boolean = false;
  // 学期选择（首页顶栏 + 全局设置）
  @State terms: TermInfo[] = [];
  @State selectedTermIndex: number = 0;
  @State showTermSheet: boolean = false;
  // 日历：Swiper 左右滑动查看月份
  @State calDefaultMonth: number = 0;
  // 日历自定义：开学日（按学期存，与课程表共用同一份数据）/ 结束日 / 学期标题（空 = 用校历解析值）
  @State customTermStart: string = '';
  @State customTermEnd: string = '';
  @State customSemesterLabel: string = '';
  @State labelInput: string = '';
  @State showCalEditor: boolean = false;
  /** 全局字重响应式订阅：表达式读 this.fwMode 才登记依赖（静态函数内读 AppStorage 不登记），
   *  fwValue 声明即订阅（custom 模式调数值时触发本页重渲染） */
  @StorageProp('fontWeightMode') fwMode: string = 'follow';
  @StorageProp('fontWeightValue') fwValue: number = 400;
  // 课程无课时：随机鼓励文案 + 下次课预告
  @State randomRestText: string = '';
  @State nextFutureCourse: NextFutureCourse | null = null;
  /** 订阅 refreshAll 广播：登录后 refreshAll 完成会 setOrCreate 此值，触发本页从缓存重载数据
   *  （修复「首页不显示」：refreshAll 成功但 HomeView 的 loadData 已在缓存为空时跑完，数据没回填） */
  @Watch('onRefreshStatusChanged') @StorageProp('dataRefreshStatus') refreshStatus: Record<string, Object> = {};
  /** 会话过期标记（HttpClient 检测到登录页响应时置真）：驱动顶栏「登录已过期 · 重登」提示 */
  @StorageProp('sessionExpired') sessionExpiredFlag: boolean = false;
  /** 在线保活定时器（前台每 8 分钟轻量请求一次，维持教务会话活跃） */
  private keepAliveTimer: number = -1;
  @State refreshing: boolean = false;
  onSwitchTab: (index: number) => void = () => {
  };
  private landscapeListener: mediaquery.MediaQueryListener | null = null;
  /** 窗口宽度断点监听（PC 窗口缩放时切换布局） */
  private wideListener: mediaquery.MediaQueryListener | null = null;
  /** 当前窗口是否横向 / 是否宽 ≥ 600vp（两者组合出布局判定） */
  private landscapeMq: boolean = false;
  private wideMq: boolean = false;

  /**
   * 卡片底色（作为 MaterialCard 的 cardBg 传入）：
   * - 沉浸光感材质生效 → **透明**（让卡片内部承载层的材质来渲染，材质优先级高于原有底色/模糊/边框）；
   * - 卡片沾色开启 → 混入 10% 主题色的卡片底（移植自参考项目「卡片沾色」）；
   * - 光感开启但材质不可用 → 半透明玻璃底（配 cardBlur 出毛玻璃）；
   * - 光感关闭 → 原纯色卡片（可读性优先）。
   *
   * 注：材质生效时 MaterialCard 会把该底色与磨砂一并让出（行内再判一次），
   * 这里返回透明只是保证「非材质分支」与承载层的取值一致。
   */
  private cardSurface(): ResourceColor {
    if (materialActive()) {
      // 材质生效：底色让出；沾色由 MaterialCard 承载层内部的「沾色层」压在材质之上呈现
      return Color.Transparent;
    }
    if (this.cardTint) {
      return AppearanceStore.cardBackground(this.isDarkMode, this.themeColor);
    }
    if (!this.immersiveEffect) {
      return $r('app.color.bg_card');
    }
    return GlassMaterial.cardSurface(this.isDarkMode);
  }

  /** 页面级触摸跟踪已删除：流光统一由 MaterialCard 内置实现（对齐参考项目） */

  /**
   * 卡片底色（作为 MaterialCard 的 cardBg 传入）。
   * 卡片阴影不再单独下发：MaterialCard 的 cardShadow 默认即「无阴影」（与原 cardShadow() 一致）。
   */
  private cardBgColor(): ResourceColor {
    return this.cardSurface();
  }

  /** 卡片内子层（子卡片/子块）底色：光感开启时同步半透明，避免不透明子块挡住毛玻璃 */
  private subBg(orig: ResourceColor): ResourceColor {
    if (!this.immersiveEffect) {
      return orig;
    }
    return GlassMaterial.surface(this.isDarkMode);
  }

  /** 页面出现：加载数据并监听横竖屏 */
  /** 版本更新弹窗数据（@Link 注入自绘弹窗） */
  @State updateTitle: string = '';
  @State updateLines: string[] = [];
  updateDialog: CustomDialogController = new CustomDialogController({
    builder: UpdateContentDialog({ titleText: $updateTitle, lines: $updateLines }),
    autoCancel: false,
    customStyle: true
  });

  aboutToAppear(): void {
    // 版本更新提示：每个版本在更新后**首次进首页**弹一次，内容直接引用更新日志最新一条
    // （无需随版本手动改弹窗文案）；弹过即记录版本号，之后不再打扰。
    // 自绘弹窗（正文左对齐，绿色按钮），替代消息居中的系统 showDialog。
    const latest: ChangelogItem = CHANGELOG_ALL[0];
    if (DataStore.getLastSeenVersion() !== latest.version) {
      DataStore.setLastSeenVersion(latest.version);
      this.updateTitle = `已更新到 v${latest.version}`;
      this.updateLines = latest.items;
      this.updateDialog.open();
    }
    // 功能浏览模式优先用 AppState.mockCurrentWeek > 0 指定的周次，确保所有功能有数据
    if (AppState.mockCurrentWeek > 0) {
      this.currentWeek = AppState.mockCurrentWeek;
    } else {
      this.currentWeek = DateUtil.weekOfTerm(AppState.term, new Date());
      // 兜底：学期边界（开学前/期末后）weekOfTerm 可能返回 0，周次 0 匹配不到任何课
      // → 首页误显"当前没课了"，故夹到 [1, 30]
      if (this.currentWeek < 1) {
        this.currentWeek = 1;
      } else if (this.currentWeek > 30) {
        this.currentWeek = 30;
      }
    }
    this.calDefaultMonth = this.computeCurrentMonth();
    this.calPageIndex = this.calInitialIndex();
    this.loadTermCustom();
    this.randomRestText = this.pickRestText();
    this.listenLandscape();
    this.startKeepAlive();
    this.loadData();
  }

  /** 页面消失：注销监听 */
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
    this.stopKeepAlive();
  }

  /**
   * 启动在线保活：前台每 8 分钟轻量请求一次通知接口，维持教务/云课堂会话活跃，
   * 避免长时间停留首页后会话静默过期导致"点开就要求重登"。
   * 已过期时改为触发一次自动恢复（CASTGC → 账号密码），无感续期。
   */
  private startKeepAlive(): void {
    this.stopKeepAlive();
    this.keepAliveTimer = setInterval(() => {
      if (JwApi.USE_MOCK) {
        return;
      }
      if (AppState.sessionExpired) {
        HttpClient.resetNetworkCache();
        JwApi.autoRecoverIfNeeded();
        return;
      }
      // 轻量保活：只碰通知接口（缓存命中/单飞去重，开销小），失败静默
      HttpClient.resetNetworkCache();
      JwApi.getNotices().catch((_e: Object) => {
        // ignore
      });
    }, 8 * 60 * 1000);
  }

  private stopKeepAlive(): void {
    if (this.keepAliveTimer >= 0) {
      clearInterval(this.keepAliveTimer);
      this.keepAliveTimer = -1;
    }
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

  /** 等待冷启动会话恢复完成（AppState.sessionReady；服务大厅登录时 Index 先桥接新教务系统再置 true）
   *  上限 8s：缓存/内置校历已在前置块秒开，网络数据晚到可后台覆盖，不必让用户等 15s */
  private waitSessionReady(): Promise<void> {
    return new Promise<void>((resolve) => {
      if (AppState.sessionReady) {
        resolve();
        return;
      }
      let waited: number = 0;
      const check: () => void = () => {
        waited += 200;
        if (AppState.sessionReady || waited > 8000) {
          resolve();
          return;
        }
        setTimeout(() => {
          check();
        }, 200);
      };
      check();
    });
  }

  private async loadData(waitSession: boolean = true): Promise<void> {
    // ★ 缓存秒开块放最前（不依赖任何异步等待）：课表/考试/消息/内置校历立即渲染，
    //   即使 waitSessionReady 卡 15s、getTerms 失败、任一接口挂起，首页也绝不白屏空转
    const cachedCourses: CourseItem[] = JwApi.loadCachedCourses();
    if (cachedCourses.length > 0) {
      this.todayCourses = this.pickToday(cachedCourses);
      this.nextClass = this.firstUnfinished(this.todayCourses);
      this.nextFutureCourse = this.findNextFutureCourse(cachedCourses, AppState.term);
      this.randomRestText = this.pickRestText();
      const cachedExams: ExamItem[] = JwApi.loadCachedExams();
      this.exams = this.pickComingExams(cachedExams);
      this.notices = JwApi.loadCachedNotices().slice(0, 3);
    }
    if (this.teachingCal === null) {
      this.teachingCal = JwApi.builtinCal();
    }
    if (cachedCourses.length > 0 || this.teachingCal !== null) {
      this.loading = false;
    }
    // 头像：先读缓存，再独立拉取（不依赖课表/考试成功，避免被前面接口失败跳过）
    const cachedPhoto: string = JwApi.loadCachedPhoto();
    if (cachedPhoto.length > 0) {
      this.photo = cachedPhoto;
    }
    // 日志：记录缓存秒开结果（含下一节课是否命中，便于定位「下一节课不显示」）
    LogStore.log('首页', '缓存秒开', cachedCourses.length > 0 ? '命中' : '无缓存',
      `课表${cachedCourses.length}节 今日课${this.todayCourses.length}节 下一节=${this.nextClass !== null ? this.nextClass.course.name : '无'} 当前周=${this.currentWeek}`);
    // 冷启动会话恢复中（服务大厅登录：Index 正在用 CASTGC 重新桥接"新教务系统"）：
    // 等待就绪后再取数，避免用旧教务会话导致数据拉取失败（最多等 15s 兜底）。
    // 下拉刷新（waitSession=false）时跳过等待：会话早已就绪，再等 15s 只会让刷新圈空转。
    if (waitSession) {
      await this.waitSessionReady();
    }
    // 学期列表（顶栏选择用）：容错化，失败不再阻塞后续刷新链路
    try {
      this.terms = await JwApi.getTerms();
      for (let i: number = 0; i < this.terms.length; i++) {
        if (this.terms[i].id === AppState.term.id) {
          this.selectedTermIndex = i;
          break;
        }
      }
    } catch (e) {
      LogStore.log('首页', '学期列表', '加载失败', LogStore.errorOf(e as Object));
    }
    // 日志调试：记录本地操作（先用缓存秒开）与实际反馈（网络刷新结果）
    LogStore.log('首页', '消息加载', '开始',
      `缓存课表${cachedCourses.length}节 考试${this.exams.length}门 通知${this.notices.length}条`);
    // ★ 课表/考试/消息三接口并行 + 各自容错：任一失败不阻断其余，且总耗时≈最慢一个（性能优化）
    const taskCourses: Promise<CourseItem[]> = JwApi.getCoursesSmart(AppState.term.id, false)
      .catch((_e: Object): CourseItem[] => []);
    const taskExams: Promise<ExamItem[]> = JwApi.getExams(AppState.term.id)
      .catch((_e: Object): ExamItem[] => []);
    const taskNotices: Promise<NoticeItem[]> = JwApi.getNotices()
      .catch((_e: Object): NoticeItem[] => []);

    const courses: CourseItem[] = await taskCourses;
    // ★ 网络返回空时回退缓存兜底：首次真实登录时 refreshAll（登录回调）与 loadData（挂载）并发，
    //   getCoursesSmart 可能因 coursesFetchedToday 短路或时序竞态返回空，此时再读一次缓存确保首页有数据
    let finalCourses: CourseItem[] = courses;
    if (finalCourses.length === 0) {
      finalCourses = JwApi.loadCachedCourses();
    }
    if (finalCourses.length > 0) {
      this.todayCourses = this.pickToday(finalCourses);
      this.nextClass = this.firstUnfinished(this.todayCourses);
      this.nextFutureCourse = this.findNextFutureCourse(finalCourses, AppState.term);
      this.randomRestText = this.pickRestText();
      LogStore.log('首页', '课表', '刷新成功',
        `${finalCourses.length}节 今日课${this.todayCourses.length}节 下一节=${this.nextClass !== null ? this.nextClass.course.name : '无'}`);
    } else {
      LogStore.log('首页', '课表', '刷新失败', '返回空且无缓存');
    }
    const exams: ExamItem[] = await taskExams;
    if (exams.length > 0) {
      this.exams = this.pickComingExams(exams);
    } else {
      // 考试空 → 回退缓存（refreshAll 并发写入场景）
      const cachedExams2: ExamItem[] = JwApi.loadCachedExams();
      if (cachedExams2.length > 0) {
        this.exams = this.pickComingExams(cachedExams2);
      }
    }
    const notices: NoticeItem[] = await taskNotices;
    if (notices.length > 0) {
      this.notices = notices.slice(0, 3);
      LogStore.log('首页', '消息', '刷新成功', `${notices.length}条`);
    } else {
      // 消息空 → 回退缓存（refreshAll 并发写入场景）
      const cachedNotices2: NoticeItem[] = JwApi.loadCachedNotices();
      if (cachedNotices2.length > 0) {
        this.notices = cachedNotices2.slice(0, 3);
        LogStore.log('首页', '消息', '回退缓存', `${cachedNotices2.length}条`);
      }
    }
    // 获取状态提示：若课表仍为空（缓存无 + 网络失败），提示用户可稍后重试
    if (this.todayCourses.length === 0 && this.nextClass === null && cachedCourses.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: T('数据获取失败，请稍后下拉刷新重试'), duration: 2000 });
    }
    // ★ 校历 + 官网通知并行（原为串行两次 await，总耗时翻倍）；各自独立容错，互不阻塞
    const pCal: Promise<TeachingCalendar | null> = JwApi.getTeachingCalendar()
      .catch((_e: Object): TeachingCalendar | null => null);
    const pJwc: Promise<NoticeItem[]> = JwApi.getJwcNotices()
      .catch((_e: Object): NoticeItem[] => []);
    const cal: TeachingCalendar | null = await pCal;
    if (cal !== null) {
      this.teachingCal = cal;
    }
    const jn: NoticeItem[] = await pJwc;
    if (jn.length > 0) {
      this.jwcNotices = jn;
    }
    // 头像：不阻塞主链路（getPhoto 读超时 60s），后台静默拉取
    if (!JwApi.USE_MOCK) {
      JwApi.getPhoto().then((p: string) => {
        if (p.length > 0) {
          this.photo = p;
        }
      }).catch((_e: Object) => {
        // ignore
      });
    }
    // 解除首屏 loading（无缓存场景也依赖此行；有缓存时已在前置块提前解除）
    this.loading = false;
  }

  /** refreshAll 完成后广播回调：从缓存重载课表/考试/消息回填 UI（修复「首页不显示」） */
  private onRefreshStatusChanged(): void {
    // ★ 异常隔离：此回调由 AppStorage.setOrCreate 同步触发，抛出的异常会反向冒泡到
    //   refreshAll 的 catch（曾因节次越界导致每次刷新都被记为失败、首页永远填不上数据），
    //   故整体兜底，任何渲染期异常都不得影响数据层。
    try {
      this.refillFromCache();
    } catch (e) {
      LogStore.log('首页', '刷新广播', '回填异常', LogStore.errorOf(e as Object));
    }
  }

  /** 从缓存回填首页数据（课表/考试/消息/周次） */
  private refillFromCache(): void {
    // 周次兜底：异常场景下 currentWeek 可能为 0（周次 0 匹配不到任何课 → 误显"当前没课了"）
    if (this.currentWeek < 1) {
      this.currentWeek = DateUtil.weekOfTerm(AppState.term, new Date());
      if (this.currentWeek < 1) {
        this.currentWeek = 1;
      }
    }
    // 仅在当前无数据时才从缓存回填（避免覆盖用户正在进行的操作/最新网络结果）
    const cachedCourses: CourseItem[] = JwApi.loadCachedCourses();
    if (cachedCourses.length > 0) {
      this.todayCourses = this.pickToday(cachedCourses);
      this.nextClass = this.firstUnfinished(this.todayCourses);
      this.nextFutureCourse = this.findNextFutureCourse(cachedCourses, AppState.term);
      this.randomRestText = this.pickRestText();
    }
    const cachedExams: ExamItem[] = JwApi.loadCachedExams();
    if (cachedExams.length > 0) {
      this.exams = this.pickComingExams(cachedExams);
    }
    const cachedNotices: NoticeItem[] = JwApi.loadCachedNotices();
    if (cachedNotices.length > 0) {
      this.notices = cachedNotices.slice(0, 3);
    }
    this.loading = false;
    LogStore.log('首页', '刷新广播', '回填缓存',
      `课表${cachedCourses.length}节 今日课${this.todayCourses.length}节 消息${this.notices.length}条`);
  }

  /** 下拉刷新：重新加载首页全部数据 */
  private async onRefresh(): Promise<void> {
    // 下拉刷新会回滚到顶部：恢复顶栏/底栏显示
    this.restoreBars();
    // 用户主动刷新 → 重新探测网络（此前可能判定无网，恢复后应重新走网络）
    HttpClient.resetNetworkCache();
    try {
      await this.loadData(false);
    } catch (e) {
      LogStore.log('首页', '下拉刷新', '异常', LogStore.errorOf(e as Object));
    } finally {
      // 兜底：无论成功失败、是否卡在会话等待，都确保刷新圈停止（修复下拉刷新一直转圈）
      this.refreshing = false;
    }
  }

  /** 今日所在自然月（yyyymm，用于日历默认展示） */
  private computeCurrentMonth(): number {
    const d: Date = new Date();
    return d.getFullYear() * 100 + (d.getMonth() + 1);
  }

  /** 课程无课时随机鼓励文案（三选一） */
  private pickRestText(): string {
    const opts: string[] = [T('好好休息吧~'), T('放松一下吧~'), T('做自己想做的事吧！')];
    return opts[Math.floor(Math.random() * opts.length)];
  }

  /**
   * 寻找今天之后最近的一节课（用于"无课时下次课预告"）。
   * 1) 当前周 weekday > 今天 weekday（今天的课已全部结束，视为"今天没课了"，从明天起找）
   * 2) 否则后续周 weekday 升序
   */
  private findNextFutureCourse(courses: CourseItem[], term: TermInfo): NextFutureCourse | null {
    const todayW: number = DateUtil.weekdayOf(new Date());
    // 周次兜底：学期边界 weekOfTerm 可能返回 0，此前会因 weeks.includes(0) 全 false 而永远查不到下次课
    const cwRaw: number = DateUtil.weekOfTerm(term, new Date());
    const cw: number = cwRaw < 1 ? (this.currentWeek > 0 ? this.currentWeek : 1) : cwRaw;
    const nowMin: number = DateUtil.minutesOfNow();
    // 1) 当前周，今天及之后
    for (let w: number = todayW; w <= 7; w++) {
      for (const c of courses) {
        if (c.weekday === w && c.weeks.includes(cw)) {
          // 今天的课必须还没结束；明天及之后的课直接命中
          if (w === todayW) {
            const endMin: number = SectionUtil.endMinCurrent(c.endSection);
            if (nowMin > endMin) {
              continue;
            }
          }
          const dt: Date = DateUtil.dateOfWeekDay(term, cw, w);
          return {
            course: c,
            weekdayLabel: Const.WEEK_SHORT[w - 1],
            weekTag: T('本周'),
            timeRange: SectionUtil.rangeTextCurrent(c.startSection, c.endSection),
            dateLabel: DateUtil.formatCn(dt)
          };
        }
      }
    }
    for (let wk: number = cw + 1; wk <= term.totalWeeks; wk++) {
      for (let w: number = 1; w <= 7; w++) {
        for (const c of courses) {
          if (c.weekday === w && c.weeks.includes(wk)) {
            const dt: Date = DateUtil.dateOfWeekDay(term, wk, w);
            return {
              course: c,
              weekdayLabel: Const.WEEK_SHORT[w - 1],
              weekTag: `第 ${wk} 周`,
              timeRange: SectionUtil.rangeTextCurrent(c.startSection, c.endSection),
              dateLabel: DateUtil.formatCn(dt)
            };
          }
        }
      }
    }
    return null;
  }

  /**
   * 切换学期（全局设置）。调用 JwApi.setTerm 同步 JwApi.term + AppState.term + 持久化，
   * 重新拉首页数据（currentWeek/今日/下次课/通知/校历）。其他页（课表/成绩/考试）下次进页时自动按新 term 加载。
   */
  private async selectTerm(index: number): Promise<void> {
    if (index < 0 || index >= this.terms.length || index === this.selectedTermIndex) {
      this.showTermSheet = false;
      return;
    }
    const term: TermInfo = this.terms[index];
    this.selectedTermIndex = index;
    this.showTermSheet = false;
    JwApi.setTerm(term);
    // 全局广播：课程表/成绩页等立即同步切换学期（不依赖下次进页/组件 @Watch）
    AppState.notifyTermSwitched();
    // 刷新增强：完成选择后自动临时切到另一学期再切回（不显示给用户），
    // 强制所有依赖学期缓存的页面完成两轮刷新，确保全局切到与首页一致。
    const tmpIdx: number = index === 0 ? 1 : index - 1;
    if (tmpIdx >= 0 && tmpIdx < this.terms.length && tmpIdx !== index) {
      JwApi.setTerm(this.terms[tmpIdx]);
      AppState.notifyTermSwitched();
      JwApi.setTerm(term);
      AppState.notifyTermSwitched();
    }
    this.currentWeek = DateUtil.weekOfTerm(term, new Date());
    // 学期变更：重新读取该学期的自定义开学日等设置
    this.loadTermCustom();
    // 学期变更：清空旧数据并重新拉取
    this.todayCourses = [];
    this.nextClass = null;
    this.nextFutureCourse = null;
    this.exams = [];
    this.notices = [];
    this.jwcNotices = [];
    this.teachingCal = null;
    this.loading = true;
    await this.loadData();
  }

  /** 从课表中筛选今日课程并按节次排序 */
  private pickToday(courses: CourseItem[]): TodayCourse[] {
    const weekday: number = DateUtil.weekdayOf(new Date());
    const nowMin: number = DateUtil.minutesOfNow();
    const list: TodayCourse[] = [];
    for (const c of courses) {
      if (c.weekday === weekday && c.weeks.includes(this.currentWeek)) {
        // 节次取分钟统一走 DateUtil 夹取版本：课表存在第 16-17 节等超出作息表的课程，
        // 直接 Const.SECTIONS[c.startSection-1] 会取到 undefined 并在 @Watch 回填里抛异常，
        // 导致每次刷新都失败、首页数据永远填不上（日志实测 Cannot read property start of undefined）
        const startMin: number = SectionUtil.startMinCurrent(c.startSection);
        const endMin: number = SectionUtil.endMinCurrent(c.endSection);
        list.push({
          course: c,
          timeRange: SectionUtil.rangeTextCurrent(c.startSection, c.endSection),
          finished: nowMin > endMin,
          ongoing: nowMin >= startMin && nowMin <= endMin
        });
      }
    }
    list.sort((a: TodayCourse, b: TodayCourse) => a.course.startSection - b.course.startSection);
    return list;
  }

  /** 今日最早一节未结束的课程（进行中或尚未开始） */
  private firstUnfinished(list: TodayCourse[]): TodayCourse | null {
    for (const c of list) {
      if (!c.finished) {
        return c;
      }
    }
    return null;
  }

  /** 距离下一节课开始的倒计时文案 */
  private countdownText(item: TodayCourse): string {
    if (item.ongoing) {
      return T('进行中');
    }
    const startMin: number = SectionUtil.startMinCurrent(item.course.startSection);
    const diff: number = startMin - DateUtil.minutesOfNow();
    if (diff <= 0) {
      return T('即将开始');
    }
    const h: number = Math.floor(diff / 60);
    const m: number = diff % 60;
    if (h <= 0) {
      return `${m} 分钟后`;
    }
    return `${h} 小时${m > 0 ? ` ${m} 分` : ''}后`;
  }

  /** 从考试列表中筛选近期（未来）考试 */
  private pickComingExams(exams: ExamItem[]): ExamItem[] {
    const today: Date = new Date();
    const list: ExamItem[] = [];
    for (const e of exams) {
      if (DateUtil.diffDays(today, DateUtil.parse(e.date)) >= 0) {
        list.push(e);
      }
    }
    list.sort((a: ExamItem, b: ExamItem) => DateUtil.parse(a.date).getTime() - DateUtil.parse(b.date).getTime());
    return list.slice(0, 2);
  }

  /** 根据当前时段返回问候语（早上好/下午好等） */
  private greeting(): string {
    const h: number = new Date().getHours();
    if (h < 6) {
      return T('夜深了');
    }
    if (h < 12) {
      return T('早上好');
    }
    if (h < 14) {
      return T('中午好');
    }
    if (h < 19) {
      return T('下午好');
    }
    return T('晚上好');
  }

  /** 快捷入口图标（按 key 分配，单色 SVG 随主题色渲染） */
  private quickEntryIcon(key: string): Resource {
    if (key === 'today') {
      return $r('app.media.calendar');
    }
    if (key === 'exam') {
      return $r('app.media.exam_arrange');
    }
    if (key === 'score') {
      return $r('app.media.doc_text_badge_magnifyingglass');
    }
    if (key === 'room') {
      return $r('app.media.map_badge_local');
    }
    if (key === 'cloud') {
      return $r('app.media.cloud_class');
    }
    return $r('app.media.data_icon');
  }

  /** 首页功能入口点击分发（跳转对应页面） */
  private onEntryTap(key: string): void {
    if (key === 'today') {
      AppState.stack.pushPath({ name: Const.ROUTE_TODAY_SCHEDULE });
    } else if (key === 'schedule') {
      this.onSwitchTab(1);
    } else if (key === 'score') {
      // 成绩查询：学业情况页内的二级页面，直接推入
      AppState.stack.pushPath({ name: Const.ROUTE_SCORE });
    } else if (key === 'exam') {
      AppState.stack.pushPath({ name: Const.ROUTE_EXAM });
    } else if (key === 'room') {
      // 教室查询（空教室/空闲教室）
      AppState.stack.pushPath({ name: Const.ROUTE_EMPTY_ROOM });
    } else if (key === 'jw') {
      // 教务系统：应用内 WebView 打开（复用全局会话 Cookie）
      AppState.webUrl = Const.WEB_PORTAL_URL;
      AppState.webTitle = T('教务系统');
      AppState.stack.pushPath({ name: Const.ROUTE_WEB_PAGE });
    } else if (key === 'cloud') {
      // 云课堂（智教云：我的课程 / 课堂实录 / 通知）
      AppState.stack.pushPath({ name: Const.ROUTE_CLOUD_CLASS });
    } else if (key === 'academic') {
      AppState.stack.pushPath({ name: Const.ROUTE_ACADEMIC });
    } else {
      this.getUIContext().getPromptAction().showToast({ message: T('该功能将在接入教务接口后开放') });
    }
  }

  /** 标题栏整体高度（含状态栏 inset），也是滑动隐藏时的位移量 */
  private titleBarHeight(): number {
    return this.getUIContext().px2vp(this.topInsetPx) + 60;
  }

  /** 首页滚动方向检测：下滑且越过阈值 → 隐藏顶栏/底栏（沉浸浏览），上滑 → 恢复 */
  private handleHomeScroll(deltaY: number): void {
    this.scrollOffset += deltaY;
    // 累计偏移夹在 [0, 阈值*1.5]，避免长时间滚动后数值膨胀导致方向判断迟钝
    if (this.scrollOffset < 0) {
      this.scrollOffset = 0;
    }
    const threshold: number = 90;
    if (this.scrollOffset > threshold * 1.5) {
      this.scrollOffset = threshold * 1.5;
    }
    if (deltaY > 0 && this.scrollOffset > threshold) {
      if (!this.barHidden) {
        this.barHidden = true;
        // animateTo 包裹广播：底栏 barBottomMargin 变化平滑过渡，标题栏 translate 也随动画
        this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut }, () => {
          AppStorage.setOrCreate<boolean>('homeBarsHidden', true);
        });
      }
    } else if (deltaY < 0) {
      if (this.barHidden) {
        this.barHidden = false;
        this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut }, () => {
          AppStorage.setOrCreate<boolean>('homeBarsHidden', false);
        });
      }
      if (this.scrollOffset < 0) {
        this.scrollOffset = 0;
      }
    }
  }

  /** 退出首页/刷新时恢复顶栏底栏显示 */
  private restoreBars(): void {
    this.scrollOffset = 0;
    if (this.barHidden) {
      this.barHidden = false;
      AppStorage.setOrCreate<boolean>('homeBarsHidden', false);
    }
  }

  @Builder
  titleBar() {
    // 顶部固定标题栏（三层）：最下内容 → 中全透明模糊层 → 顶主题色渐变
    Stack({ alignContent: Alignment.TopStart }) {
      // 顶：主题色渐变
      Column()
        .width('100%')
        .height(this.getUIContext().px2vp(this.topInsetPx) + 60)
        .linearGradient({
          angle: 180,
          colors: Theme.barGradient(this.themeColor, this.barStyle)
        })
        .backgroundBlurStyle(Immersive.blur(BlurStyle.Thin, this.barStyle === 'legacy'))
    Row() {
      BarTitle({ title: T('首页') })
      // 会话过期 / 手动重登模式：标题右侧显示胶囊（点击执行重新登录）
      if (this.shouldShowRelogin()) {
        Text(AppState.sessionExpired ? T('登录已过期 · 重登') : T('重登'))
          .fontSize(11)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
          .fontColor('#FFFFFF')
          .backgroundColor('#FF9800')
          .height(22)
          .padding({ left: 8, right: 8 })
          .borderRadius(11)
          // 形态与其它顶栏按钮统一（细亮边 + 微阴影），保留橙色警示语义
          .border({ width: 1, color: 'rgba(255,255,255,0.35)' })
          .shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 })
          .margin({ left: 8 })
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.onReloginClick();
          })
      }
      Blank()
      // 右侧：当前教学周（未开学显示"未开学"）—— 沉浸光感常驻
      MaterialButton({
        btnRadius: 12,
        btnPersistent: true,
        btnBg: '#33FFFFFF',
        btnBlur: BlurStyle.Thin,
        btnMargin: { right: 8 }
      }) {
        Text(this.isTermStarted() ? `第 ${this.todayTeachingWeek()} 周` : '未开学')
          .fontSize(12)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
          .fontColor(WallpaperTone.onWallpaper(this.wallpaperTone, this.isDarkMode))
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      }
      // 右侧：当前学年学期（完整格式，点击展开学期选择，全局设置）—— 沉浸光感常驻
      MaterialButton({
        btnRadius: 14,
        btnPersistent: true,
        btnOnClick: (): void => {
          this.showTermSheet = true;
        }
      }) {
        Row() {
          Text(this.terms.length > 0 && this.selectedTermIndex < this.terms.length
            ? this.terms[this.selectedTermIndex].label
            : AppState.term.label)
            .fontSize(11)
            .fontColor(this.subtitleColor.length > 0 ? this.subtitleColor : WallpaperTone.onWallpaper(this.wallpaperTone, this.isDarkMode))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Image($r('app.media.list_bullet'))
            .width(14)
            .height(14)
            .fillColor(this.subtitleColor.length > 0 ? this.subtitleColor : WallpaperTone.onWallpaper(this.wallpaperTone, this.isDarkMode))
            .margin({ left: 4 })
        }
        .padding({ left: 10, right: 6, top: 4, bottom: 4 })
      }
    }
    .width('100%')
    .height(this.getUIContext().px2vp(this.topInsetPx) + 60)
    // 左标题与右侧按钮组垂直居中对齐（原 Top 对齐导致两者高低不一）
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: this.getUIContext().px2vp(this.topInsetPx) + 12, bottom: 12 })
    }
    .width('100%')
    // 内容穿透：整个三层标题栏悬浮最上层、不占布局空间，内容可滚入其下层
    .position({ x: 0, y: 0 })
    .zIndex(2)
    // 沉浸浏览：下滑隐藏（上移滑出屏幕），上滑恢复；带平滑过渡动画
    .translate({ y: this.barHidden ? -this.titleBarHeight() : 0 })
    .opacity(this.barHidden ? 0 : 1)
    .animation({ duration: 260, curve: Curve.EaseInOut })
  }

  /** 学期选择弹层（全局设置）—— 与课程表页 termPickerSheet 完全同构 */
  @Builder
  termPickerSheet() {
    // 弹窗内容套 MaterialSheetPanel：材质由 Toggle 承载层渲染，bindSheet 必须显式透明底（见外层选项）。
    // SheetSize.FIT_CONTENT（高度随内容）→ panelFillHeight: false；内层 20/8/24vp 内边距原样保留。
    MaterialSheetPanel({ panelRadius: 20, panelPadding: 0, panelFillHeight: false, panelTitle: T('选择学年-学期'), panelShowClose: true, panelOnClose: (): void => { this.showTermSheet = false; } }) {
      Column() {
        if (this.terms.length === 0) {
          Text(T('暂无可选学期'))
            .fontSize(13)
            .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 12 })
        } else {
          ForEach(this.terms, (term: TermInfo, index: number) => {
            Row() {
              Text(term.label)
                .fontSize(14)
                .fontColor(this.selectedTermIndex === index ? $r('app.color.brand_on') : $r('app.color.text_primary'))
                .layoutWeight(1)
              if (this.selectedTermIndex === index) {
                Image($r('app.media.checkmark_circle'))
                  .width(16)
                  .height(16)
                  .fillColor($r('app.color.brand_on'))
              }
            }
            .width('100%')
            .height(46)
            .padding({ left: 16, right: 16 })
            .backgroundColor(this.selectedTermIndex === index ? Theme.colorOf(this.themeColor) : $r('app.color.bg_chip'))
            .borderRadius(10)
            .margin({ bottom: 8 })
            .onClick(() => {
              this.selectTerm(index);
            })
          }, (term: TermInfo) => term.id)
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 24 })
    }
  }

  /** 会话过期提示条：一行小胶囊，不遮挡内容、不强制用户重登（可继续浏览离线数据） */
  @Builder
  sessionBanner() {
    Row({ space: 8 }) {
      Text(T('离线'))
        .fontSize(10)
        .fontColor('#FFFFFF')
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .backgroundColor('rgba(255,255,255,0.26)')
        .borderRadius(8)
      Text(T('登录已过期，显示上次同步数据'))
        .fontSize(11)
        .fontColor('rgba(255,255,255,0.92)')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(T('重登'))
        .fontSize(11)
        .fontColor('#FFFFFF')
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .backgroundColor('rgba(255,255,255,0.24)')
        .borderRadius(10)
        .onClick(() => {
          this.onReloginClick();
        })
    }
    .width('100%')
    .padding({ left: 10, right: 8, top: 7, bottom: 7 })
    .backgroundColor('rgba(224,138,0,0.92)')
    .borderRadius(10)
    .margin({ top: 8 })
  }

  @Builder
  avatarCard() {
    // 头像卡片（MaterialCard 承载：材质层是卡片内部底层，材质生效时卡片底色让出）：
    // showAvatar 仅控制圆形头像的显示/隐藏，姓名等其余信息始终显示
    MaterialCard({
      cardRadius: 16,
      cardBg: this.cardBgColor(),
      cardBlur: GlassMaterial.bgBlur(this.immersiveEffect),
      cardBorderW: GlassMaterial.borderWidth(),
      cardBorderC: GlassMaterial.borderColor()
    }) {
      Row() {
        if (this.showAvatar) {
        if (this.photo.length > 0) {
          Image(AppState.photoDataUrl(this.photo))
            .width(52)
            .height(52)
            .borderRadius(26)
            .objectFit(ImageFit.Cover)
            .backgroundColor(this.subBg($r('app.color.bg_chip'))).backgroundBlurStyle((AppStorage.get<boolean>('immersiveEffect') ?? false) ? BlurStyle.Thin : BlurStyle.NONE).border({ width: 1, color: 'rgba(255,255,255,0.28)' }).shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 }).clip(true)
        } else if (JwApi.USE_MOCK) {
          // 功能浏览模式：使用内置的演示头像（南小医）
          Image($r('app.media.mock_avatar'))
            .width(52)
            .height(52)
            .borderRadius(26)
            .objectFit(ImageFit.Cover)
            .backgroundColor(this.subBg($r('app.color.bg_chip'))).backgroundBlurStyle((AppStorage.get<boolean>('immersiveEffect') ?? false) ? BlurStyle.Thin : BlurStyle.NONE).border({ width: 1, color: 'rgba(255,255,255,0.28)' }).shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 }).clip(true)
        } else {
          Text(AppState.avatarText())
            .fontSize(17)
            .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
            .fontColor(Theme.colorOf(this.themeColor))
            .width(52)
            .height(52)
            .borderRadius(26)
            .backgroundColor(this.subBg($r('app.color.bg_chip'))).backgroundBlurStyle((AppStorage.get<boolean>('immersiveEffect') ?? false) ? BlurStyle.Thin : BlurStyle.NONE).border({ width: 1, color: 'rgba(255,255,255,0.28)' }).shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 }).clip(true)
            .textAlign(TextAlign.Center)
        }
      }

      Column() {
        Text(`${AppState.displayName()}，${this.greeting()}`)
          .fontSize(17)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.subtitleText())
          .fontSize(12)
          .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          .margin({ top: 4 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ left: this.showAvatar ? 12 : 0 })
      .layoutWeight(1)

      Blank()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(16)
    }
  }

  /** 学生名字下方的副标题：学号 · 学院 · 班级（仅展示存在的字段） */
  private subtitleText(): string {
    const sid: string = AppState.studentId();
    const college: string = AppState.profile !== null ? AppState.profile.college : '';
    const cls: string = AppState.profile !== null ? AppState.profile.className : '';
    const parts: string[] = [];
    if (sid.length > 0) {
      parts.push(sid);
    }
    if (college.length > 0) {
      parts.push(college);
    }
    if (cls.length > 0) {
      parts.push(cls);
    }
    return parts.join(' · ');
  }

  @Builder
  todayCard() {
    Column() {
      Row() {
        Divider()
          .vertical(true)
          .strokeWidth(3)
          .color(Theme.colorOf(this.themeColor))
          .height(14)
          .margin({ right: 8 })
        Text(T('下一节课'))
          .fontSize(16)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
          .fontColor($r('app.color.text_primary'))
        Blank()
        if (this.todayCourses.length > 0) {
          Text(this.nextClass === null ? '今日课程已结束' : `今日 ${this.todayCourses.length} 节`)
            .fontSize(12)
            .fontColor(WallpaperTone.onWallpaper(this.wallpaperTone, this.isDarkMode))
        }
      }
      .width('100%')

      // 卡片主体（"下一节课"标题单独在卡片外显示）
      // MaterialCard 承载：材质层是卡片内部底层、与卡片同尺寸同圆角，材质生效时卡片底色让出
      MaterialCard({
        cardRadius: 18,
        cardBg: this.cardBgColor(),
        cardBlur: GlassMaterial.bgBlur(this.immersiveEffect),
        cardBorderW: GlassMaterial.borderWidth(),
        cardBorderC: GlassMaterial.borderColor(),
        // 标题行与卡片之间原有 12vp（迁移前挂在标题行上的 margin）→ 改由卡片的外边距承载
        cardMargin: { top: 12 }
      }) {
      Column() {
      if (this.todayCourses.length === 0) {
        // 无今日课时：当前没课了哦！ + 随机鼓励文案 + 下次课预告（点击跳课程表打开详情）
        Column() {
          Text(`当前没课了哦！${this.randomRestText.length > 0 ? this.randomRestText : '好好休息吧~'}`)
            .fontSize(13)
            .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .textAlign(TextAlign.Center)
            .width('100%')
          if (this.nextFutureCourse !== null) {
            // 下次课子卡（卡片内部的子卡）：同样接入材质承载（Toggle 承载层 + 内容）。
            // 关掉材质自带投影——小卡挨得近时投影会在卡间缝隙里叠成暗带（参考 README「卡片迁移约定」）
            MaterialCard({
              cardRadius: 16,
              cardDirection: FlexDirection.Row,
              cardMaterialShadow: false,
              cardBg: this.subBg($r('app.color.bg_chip')),
              cardBlur: GlassMaterial.bgBlur(this.immersiveEffect),
              cardBorderW: GlassMaterial.borderWidth(),
              cardBorderC: GlassMaterial.borderColor(),
              cardShadow: GlassMaterial.capsuleShadow(),
              // 标题内容与子卡之间原有 12vp 上边距 → 改由卡片外边距承载
              cardMargin: { top: 12 }
            }) {
            Row() {
              // 左侧竖条：下次课 三个字竖排
              Column() {
                Text('下').fontSize(13).fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium)).fontColor(Theme.colorOf(this.themeColor))
                Text('次').fontSize(13).fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium)).fontColor(Theme.colorOf(this.themeColor))
                Text('课').fontSize(13).fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium)).fontColor(Theme.colorOf(this.themeColor))
              }
              .padding(10)
              .backgroundColor(this.subBg(Theme.rgba(Theme.colorOf(this.themeColor), 0.12))).backgroundBlurStyle((AppStorage.get<boolean>('immersiveEffect') ?? false) ? BlurStyle.Thin : BlurStyle.NONE).border({ width: 1, color: 'rgba(255,255,255,0.28)' }).shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 }).clip(true)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .borderRadius({ topLeft: 16, bottomLeft: 16 })

              // 右侧主体：课程名+地点 居中
              Column() {
                Text(this.nextFutureCourse.course.name)
                  .fontSize(18)
                  .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .textAlign(TextAlign.Center)
                  .width('100%')
                Text(this.nextFutureCourse.course.location)
                  .fontSize(11)
                  .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                  .textAlign(TextAlign.Center)
                  .width('100%')
                  .margin({ top: 6 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)
              .padding({ left: 8, right: 8, top: 12, bottom: 12 })
              .border({ width: { right: 1 }, color: $r('app.color.divider') })

              // 最右侧：日期 + 时间（与桌面卡片"X月X日"对齐）
              Column() {
                Text(this.nextFutureCourse.dateLabel)
                  .fontSize(11)
                  .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                  .fontColor(Theme.colorOf(this.themeColor))
                  .textAlign(TextAlign.Center)
                Text(this.nextFutureCourse.timeRange)
                  .fontSize(11)
                  .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                  .fontColor($r('app.color.text_primary'))
                  .textAlign(TextAlign.Center)
                  .margin({ top: 3 })
              }
              .padding({ left: 10, right: 12 })
              .justifyContent(FlexAlign.Center)
            }
            .width('100%')
            // 点击「下次课」子卡：跳转课程表并自动打开该课的课程详情
            // （ScheduleView aboutToAppear 消费 AppState.pendingCourse）
            .onClick(() => {
              if (this.nextFutureCourse !== null) {
                AppState.pendingCourse = this.nextFutureCourse.course;
                // 广播 tick：课程表页已被 Tabs 保活（aboutToAppear 不再触发），靠 @Watch 消费
                AppStorage.setOrCreate<number>('pendingCourseTick',
                  (AppStorage.get<number>('pendingCourseTick') ?? 0) + 1);
              }
              this.onSwitchTab(1);
            })
            }
          }
        }
        .width('100%')
      } else if (this.nextClass === null) {
        Column() {
          Row() {
            Text('🎉')
              .fontSize(26)
              .margin({ right: 12 })
            Column() {
              Text(T('今日课程已全部结束'))
                .fontSize(16)
                .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                .fontColor($r('app.color.text_primary'))
              Text(`今天共 ${this.todayCourses.length} 节课，辛苦啦`)
                .fontSize(12)
                .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ top: 8, bottom: 8 })
          if (this.nextFutureCourse !== null) {
            // 下次课子卡（与上一分支同款）：材质承载 + 关掉材质自带投影
            MaterialCard({
              cardRadius: 16,
              cardDirection: FlexDirection.Row,
              cardMaterialShadow: false,
              cardBg: this.subBg($r('app.color.bg_chip')),
              cardBlur: GlassMaterial.bgBlur(this.immersiveEffect),
              cardBorderW: GlassMaterial.borderWidth(),
              cardBorderC: GlassMaterial.borderColor(),
              cardShadow: GlassMaterial.capsuleShadow(),
              cardMargin: { top: 12 }
            }) {
            Row() {
              Column() {
                Text('下').fontSize(13).fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium)).fontColor(Theme.colorOf(this.themeColor))
                Text('次').fontSize(13).fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium)).fontColor(Theme.colorOf(this.themeColor))
                Text('课').fontSize(13).fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium)).fontColor(Theme.colorOf(this.themeColor))
              }
              .padding(10)
              .backgroundColor(this.subBg(Theme.rgba(Theme.colorOf(this.themeColor), 0.12))).backgroundBlurStyle((AppStorage.get<boolean>('immersiveEffect') ?? false) ? BlurStyle.Thin : BlurStyle.NONE).border({ width: 1, color: 'rgba(255,255,255,0.28)' }).shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 }).clip(true)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .borderRadius({ topLeft: 16, bottomLeft: 16 })

              Column() {
                Text(this.nextFutureCourse.course.name)
                  .fontSize(18)
                  .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .textAlign(TextAlign.Center)
                  .width('100%')
                Text(this.nextFutureCourse.course.location)
                  .fontSize(11)
                  .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                  .textAlign(TextAlign.Center)
                  .width('100%')
                  .margin({ top: 6 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)
              .padding({ left: 8, right: 8, top: 12, bottom: 12 })
              .border({ width: { right: 1 }, color: $r('app.color.divider') })

              Column() {
                Text(this.nextFutureCourse.dateLabel)
                  .fontSize(11)
                  .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                  .fontColor(Theme.colorOf(this.themeColor))
                  .textAlign(TextAlign.Center)
                Text(this.nextFutureCourse.timeRange)
                  .fontSize(11)
                  .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                  .fontColor($r('app.color.text_primary'))
                  .textAlign(TextAlign.Center)
                  .margin({ top: 3 })
              }
              .padding({ left: 10, right: 12 })
              .justifyContent(FlexAlign.Center)
            }
            .width('100%')
            // 点击「下次课」子卡：跳转课程表并自动打开该课的课程详情（同上一分支）
            .onClick(() => {
              if (this.nextFutureCourse !== null) {
                AppState.pendingCourse = this.nextFutureCourse.course;
                // 广播 tick：课程表页已被 Tabs 保活（aboutToAppear 不再触发），靠 @Watch 消费
                AppStorage.setOrCreate<number>('pendingCourseTick',
                  (AppStorage.get<number>('pendingCourseTick') ?? 0) + 1);
              }
              this.onSwitchTab(1);
            })
            }
          }
        }
        .width('100%')
      } else {
        Row() {
          Column() {
            Text(this.nextClass!.timeRange.split('-')[0])
              .fontSize(14)
              .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
              .fontColor($r('app.color.text_primary'))
            Text(this.nextClass!.timeRange.split('-')[1])
              .fontSize(11)
              .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
              .margin({ top: 2 })
          }
          .width(48)
          .alignItems(HorizontalAlign.Start)

          Column() {
            Circle()
              .width(8)
              .height(8)
              .fill(this.nextClass!.ongoing ? Theme.colorOf(this.themeColor) : Const.COURSE_FG[this.nextClass!.course.colorIndex])
          }
          .width(20)
          .margin({ top: 6 })

          Column() {
            Row() {
              Text(this.nextClass!.course.name)
                .fontSize(18)
                .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (this.nextClass!.ongoing) {
                TagChip({ text: T('进行中'), color: $r('app.color.brand_on'), bg: Theme.colorOf(this.themeColor) })
              } else {
                TagChip({
                  text: this.countdownText(this.nextClass!),
                  color: $r('app.color.accent_orange'),
                  bg: $r('app.color.bg_chip')
                })
              }
            }
            .width('100%')

            Row() {
              // 上课地点：地图定位图标（南医蓝）
              Image($r('app.media.map_badge_local'))
                .width(13)
                .height(13)
              Text(this.nextClass!.course.location)
                .fontSize(12)
                .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                .margin({ left: 4 })
              // 授课教师：人像图标（南医蓝）
              Image($r('app.media.portrait'))
                .width(13)
                .height(13)
                .margin({ left: 12 })
              Text(this.nextClass!.course.teacher)
                .fontSize(12)
                .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                .margin({ left: 4 })
              Blank()
              Text(`第 ${this.nextClass!.course.startSection}-${this.nextClass!.course.endSection} 节`)
                .fontSize(11)
                .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            }
            .width('100%')
            .margin({ top: 6 })
          }
          .layoutWeight(1)
          .padding({ left: 6 })
        }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          // 点击「下一节课」主体：跳课程表并打开对应课程详情（与下方「下次课」子卡同语义）；
          // 今日课程已结束（nextClass 为空）时仅切 tab
          .onClick(() => {
            if (this.nextClass !== null) {
              AppState.pendingCourse = this.nextClass.course;
              // 广播 tick：课程表页已被 Tabs 保活（aboutToAppear 不再触发），靠 @Watch 消费
              AppStorage.setOrCreate<number>('pendingCourseTick',
                (AppStorage.get<number>('pendingCourseTick') ?? 0) + 1);
            }
            this.onSwitchTab(1);
          })
        }
      }
      .width('100%')
      .padding(16)
      }
    }
    .width('100%')
  }

  @Builder
  quickEntries() {
    Column() {
      SectionHeader({ title: T('快捷入口'), action: '', onAction: () => {} })
      // 快捷入口卡（实色底）
      // MaterialCard 承载：材质层是卡片内部底层、与卡片同尺寸同圆角，材质生效时卡片底色让出
      MaterialCard({
        cardRadius: 18,
        cardBg: this.cardBgColor(),
        cardBlur: GlassMaterial.bgBlur(this.immersiveEffect),
        cardBorderW: GlassMaterial.borderWidth(),
        cardBorderC: GlassMaterial.borderColor()
      }) {
      Column() {
      Grid() {
        ForEach(Const.QUICK_ENTRIES, (item: QuickEntry) => {
          GridItem() {
            Column() {
              // 快捷入口小卡（成排）：材质承载 + 内容，与首页大卡同源。
              // 挨得近的小卡必须关掉材质自带投影（cardMaterialShadow: false），
              // 否则投影会在卡间缝隙里叠成一条暗带（参考 README「卡片迁移约定」）。
              MaterialCard({
                cardWidth: '94%',
                cardRadius: 14,
                cardDirection: FlexDirection.Row,
                cardMaterialShadow: false,
                cardBg: this.subBg($r('app.color.bg_chip')),
                cardBlur: GlassMaterial.bgBlur(this.immersiveEffect),
                cardBorderW: GlassMaterial.borderWidth(),
                cardBorderC: GlassMaterial.borderColor(),
                cardOnClick: () => {
                  this.onEntryTap(item.key);
                }
              }) {
                Row() {
                  // 快捷入口图标（单色 SVG，随主题色渲染）：按 key 分配
                  Image(this.quickEntryIcon(item.key))
                    .width(22)
                    .height(22)
                    .objectFit(ImageFit.Contain)
                    .fillColor(Theme.colorOf(this.themeColor))
                  Text(item.title)
                    .fontSize(14)
                    .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                    .fontColor($r('app.color.text_primary'))
                    .margin({ left: 8 })
                }
                .width('100%')
                .height(48)
                .justifyContent(FlexAlign.Center)
              }
            }
          }
          // 智慧屏/键盘：快捷入口可获焦，遥控器「确定」直接打开
          .focusable(true)
          .focusOnTouch(false)
          .onKeyEvent((event: KeyEvent) => {
            if (event.type === KeyType.Down &&
              (event.keyCode === KeyCode.KEYCODE_ENTER || event.keyCode === KeyCode.KEYCODE_DPAD_CENTER)) {
              this.onEntryTap(item.key);
              return true;
            }
            return false;
          })
        }, (item: QuickEntry) => item.key)
      }
        .columnsTemplate('1fr 1fr')
        .rowsTemplate('1fr 1fr 1fr')
        .width('100%')
        .padding({ top: 6, bottom: 6 })
      }
      .width('100%')
      .height(176) // 三行入口卡高（4 项 2×2 时 118；5 项 2×3 后加高）
      .padding({ left: 16, right: 16 })
      }
    }
    .width('100%')
  }

  @Builder
  examSection() {
    Column() {
      SectionHeader({
        title: T('近期考试'), action: T('全部'), onAction: () => {
          AppState.stack.pushPath({ name: Const.ROUTE_EXAM });
        }
      })
      if (this.exams.length === 0) {
        // MaterialCard 承载：材质层是卡片内部底层，材质生效时卡片底色让出
        MaterialCard({
          cardRadius: 18,
          cardBg: this.cardBgColor(),
          cardBlur: GlassMaterial.bgBlur(this.immersiveEffect),
          cardBorderW: GlassMaterial.borderWidth(),
          cardBorderC: GlassMaterial.borderColor()
        }) {
          EmptyTip({ text: T('近期没有考试安排') })
        }
      } else {
        ForEach(this.exams, (item: ExamItem) => {
          // 成排卡片：卡片之间的 10vp 由 MaterialCard 的 cardMargin 承载
          // （迁移前是挂在卡片自身的 .margin({ bottom: 10 })；尾随闭包之后不能再链式加属性）
          MaterialCard({
            cardRadius: 16,
            cardBg: this.cardBgColor(),
            cardBlur: GlassMaterial.bgBlur(this.immersiveEffect),
            cardBorderW: GlassMaterial.borderWidth(),
            cardBorderC: GlassMaterial.borderColor(),
            cardMargin: { bottom: 10 },
            cardOnClick: () => {
              AppState.stack.pushPath({ name: Const.ROUTE_EXAM });
            }
          }) {
            Row() {
              Column() {
                Text(`${DateUtil.parse(item.date).getMonth() + 1}/${DateUtil.parse(item.date).getDate()}`)
                  .fontSize(15)
                  .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
                  .fontColor($r('app.color.accent_orange'))
                Text(DateUtil.relativeDay(DateUtil.parse(item.date)))
                  .fontSize(10)
                  .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                  .margin({ top: 2 })
              }
              .width(54)
              .padding({ top: 8, bottom: 8 })
              .backgroundColor(this.subBg($r('app.color.bg_chip'))).backgroundBlurStyle((AppStorage.get<boolean>('immersiveEffect') ?? false) ? BlurStyle.Thin : BlurStyle.NONE).border({ width: 1, color: 'rgba(255,255,255,0.28)' }).shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 }).clip(true)
              .borderRadius(10)

              Column() {
                Text(item.courseName)
                  .fontSize(15)
                  .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${item.timeRange} · ${item.location} · ${item.seat} 号座`)
                  .fontSize(12)
                  .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                  .margin({ top: 5 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: 12 })

              TagChip({
                text: item.examType,
                color: $r('app.color.accent_orange'),
                bg: $r('app.color.bg_chip')
              })
            }
            .width('100%')
            .padding(14)
          }
        }, (item: ExamItem) => item.id)
      }
    }
    .width('100%')
    .margin({ top: 18 })
  }

  /** 首页消息卡（v1.0.0 原样恢复）：教务消息汇总，查看更多进消息页，点击进消息详情页 */
  @Builder
  messageSection() {
    Column() {
      SectionHeader({
        title: T('消息'), action: T('查看更多'), onAction: () => {
          AppState.stack.pushPath({ name: Const.ROUTE_NOTICE });
        }
      })
      if (this.notices.length === 0) {
        // MaterialCard 承载：材质层是卡片内部底层，材质生效时卡片底色让出
        MaterialCard({
          cardRadius: 18,
          cardBg: this.cardBgColor(),
          cardBlur: GlassMaterial.bgBlur(this.immersiveEffect),
          cardBorderW: GlassMaterial.borderWidth(),
          cardBorderC: GlassMaterial.borderColor()
        }) {
          EmptyTip({ text: T('暂无消息') })
        }
      } else {
        MaterialCard({
          cardRadius: 18,
          cardBg: this.cardBgColor(),
          cardBlur: GlassMaterial.bgBlur(this.immersiveEffect),
          cardBorderW: GlassMaterial.borderWidth(),
          cardBorderC: GlassMaterial.borderColor()
        }) {
        Column() {
          ForEach(this.notices.slice(0, 3), (item: NoticeItem, index: number) => {
            Column() {
              Row() {
                if (!item.read) {
                  Circle()
                    .width(7)
                    .height(7)
                    .fill($r('app.color.state_danger'))
                    .margin({ right: 8 })
                }
                Text(item.title)
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')

              Row() {
                Text(item.source)
                  .fontSize(11)
                  .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                Text(' · ')
                  .fontSize(11)
                  .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                Text(item.date)
                  .fontSize(11)
                  .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                Blank()
                Text(T('详情 ›'))
                  .fontSize(11)
                  .fontColor(Theme.colorOf(this.themeColor))
              }
              .width('100%')
              .margin({ top: 6 })

              if (index < Math.min(this.notices.length, 3) - 1) {
                Divider()
                  .color($r('app.color.divider'))
                  .margin({ top: 12, bottom: 12 })
              }
            }
            .width('100%')
            .onClick(() => {
              AppState.currentNotice = item;
              AppState.stack.pushPath({ name: Const.ROUTE_NOTICE_DETAIL });
            })
          }, (item: NoticeItem) => item.id)
        }
        .width('100%')
        .padding(16)
        }
      }
    }
    .width('100%')
    .margin({ top: 18 })
  }

  /** 首页通知卡（独立功能卡片）：数据源为教务处官网「学期校历」最新两条，每条带【通知】标志 + 文章链接，点击打开文章页 */
  @Builder
  noticeSection() {
    Column() {
      SectionHeader({ title: T('官网公告'), action: T('查看更多'), onAction: () => {
        // 打开南医大官网「通知公告」栏目（外部链接页）
        AppState.webUrl = Const.JWC_LIST_URL;
        AppState.webTitle = T('官网公告');
        AppState.stack.pushPath({ name: Const.ROUTE_WEB_PAGE });
      } })
      if (this.jwcNotices.length === 0) {
        // MaterialCard 承载：材质层是卡片内部底层，材质生效时卡片底色让出
        MaterialCard({
          cardRadius: 18,
          cardBg: this.cardBgColor(),
          cardBlur: GlassMaterial.bgBlur(this.immersiveEffect),
          cardBorderW: GlassMaterial.borderWidth(),
          cardBorderC: GlassMaterial.borderColor()
        }) {
          EmptyTip({ text: T('暂无通知') })
        }
      } else {
        MaterialCard({
          cardRadius: 18,
          cardBg: this.cardBgColor(),
          cardBlur: GlassMaterial.bgBlur(this.immersiveEffect),
          cardBorderW: GlassMaterial.borderWidth(),
          cardBorderC: GlassMaterial.borderColor()
        }) {
        Column() {
          ForEach(this.jwcNotices, (item: NoticeItem, index: number) => {
            Column() {
              Row() {
                Text(item.title)
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')

              Row() {
                Text(item.source)
                  .fontSize(11)
                  .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                Text(' · ')
                  .fontSize(11)
                  .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                Text(item.date)
                  .fontSize(11)
                  .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                Blank()
                Text(T('阅读 ›'))
                  .fontSize(11)
                  .fontColor(Theme.colorOf(this.themeColor))
              }
              .width('100%')
              .margin({ top: 6 })

              if (index < this.jwcNotices.length - 1) {
                Divider()
                  .color($r('app.color.divider'))
                  .margin({ top: 12, bottom: 12 })
              }
            }
            .width('100%')
            .onClick(() => {
              if (item.url.length > 0) {
                // 功能浏览模式默认禁止打开网页；调试模式开启后允许
                if (JwApi.USE_MOCK && !AppState.debugNetwork) {
                  this.getUIContext().getPromptAction().showToast({ message: T('当前模式禁止使用') });
                  return;
                }
                // 有文章链接：在"外部链接"页面打开南医大官网文章页
                AppState.webUrl = item.url;
                AppState.webTitle = T('官网公告');
                AppState.stack.pushPath({ name: Const.ROUTE_WEB_PAGE });
              } else {
                this.sheetNotice = item;
                this.showNoticeSheet = true;
              }
            })
          }, (item: NoticeItem) => item.id)
        }
        .width('100%')
        .padding(16)
        }
      }
    }
    .width('100%')
    .margin({ top: 18 })
  }

  /** 通知详情底部弹层（原地展开，不跳页） */
  @Builder
  noticeSheet() {
    // 面板材质与卡片同源：bindSheet 自身的 systemMaterial 挂在面板上、内容区不生效，
    // 所以由 MaterialSheetPanel 的 Toggle 承载层铺满整块面板来渲染材质。
    // 配套硬要求：bindSheet 必须显式 backgroundColor: Color.Transparent，
    // 否则默认白底会把材质整块盖住（表现为「弹窗一点光感都没有」）。
    MaterialSheetPanel({ panelRadius: 24, panelPadding: 16, panelShowClose: true, panelOnClose: (): void => { this.showNoticeSheet = false; } }) {
    Column() {
      if (this.sheetNotice !== null) {
        Text(this.sheetNotice.title)
          .fontSize(17)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Row() {
          TagChip({ text: '【通知】', color: $r('app.color.accent_purple'), bg: $r('app.color.bg_chip') })
            .margin({ right: 8 })
          if (this.sheetNotice.isTop) {
            TagChip({ text: '置顶', color: $r('app.color.state_danger'), bg: $r('app.color.bg_chip') })
              .margin({ right: 8 })
          }
          Text(this.sheetNotice.source)
            .fontSize(12)
            .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          Text(' · ')
            .fontSize(12)
            .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          Text(this.sheetNotice.date)
            .fontSize(12)
            .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          Blank()
        }
        .width('100%')
        .margin({ top: 12, bottom: 14 })
        Divider()
          .color($r('app.color.divider'))
        Scroll() {
          Text(this.sheetNotice.content.length > 0 ? this.sheetNotice.content : T('暂无详细内容，可在消息页查看完整公告。'))
            .fontSize(14)
            .lineHeight(24)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .margin({ top: 14 })
      }
    }
    .width('100%')
    .height('100%')
    }
  }

  /** 设备当前日期（yyyy-MM-dd），优先于校历内置 todayDate，避免缓存/预置数据过期 */
  private effectiveToday(): string {
    return DateUtil.format(new Date());
  }

  /** 今日所属教学周次（开学后返回对应周次；未开学返回 0）。自定义开学日时按自定义日推算 */
  private todayTeachingWeek(): number {
    const cal: TeachingCalendar | null = this.teachingCal;
    if (cal === null) {
      return 0;
    }
    const today: string = this.effectiveToday();
    if (this.customTermStart.length > 0) {
      const d: number = DateUtil.diffDays(DateUtil.parse(this.customTermStart), DateUtil.parse(today));
      if (d < 0) {
        return 0;
      }
      return Math.floor(d / 7) + 1;
    }
    for (let r: number = 0; r < cal.rows.length; r++) {
      const dates: string[] = cal.rows[r].dates;
      for (let c: number = 0; c < dates.length; c++) {
        if (dates[c] === today) {
          return cal.weekNumbers[c] !== undefined ? cal.weekNumbers[c] : 0;
        }
      }
    }
    return 0;
  }

  /** 是否已开学（今日 >= 有效开学日，支持自定义） */
  private isTermStarted(): boolean {
    const start: string = this.effStart();
    if (start.length === 0) {
      return false;
    }
    return DateUtil.parse(start).getTime() <= new Date().getTime();
  }

  /**
   * 是否在顶栏显示"重登"胶囊。
   * 条件：会话已过期（任意登录方式，最高优先级）或（手动重登模式 + 校历为空）；
   *      须已加载完 + 真实登录（非功能浏览）。
   */
  private shouldShowRelogin(): boolean {
    if (JwApi.USE_MOCK) {
      return false;
    }
    // 会话过期（接口被重定向到统一身份认证登录页）：任何登录方式都提示重登
    if (AppState.sessionExpired) {
      return true;
    }
    if (this.loading) {
      return false;
    }
    if (DataStore.getLoginMode() !== 'legacy') {
      return false;
    }
    return this.teachingCal === null;
  }

  /** 点击"重登"胶囊：调用 Index 注册的回调（弹"真正重新登录"确认 + 全局遮罩重登） */
  private onReloginClick(): void {
    if (AppState.onForceRelogin !== null) {
      AppState.onForceRelogin();
    } else {
      this.getUIContext().getPromptAction().showToast({ message: T('重登功能暂不可用') });
    }
  }

  /** 校历覆盖的自然月列表：[年份*100+月份, ...]（如 202608 ~ 202702），采用有效起止（自定义优先） */
  private calMonthList(): number[] {
    const s: string = this.effStart();
    const e: string = this.effEnd();
    if (s.length === 0 || e.length === 0) {
      return [];
    }
    const sy: number = Number(s.slice(0, 4));
    const sm: number = Number(s.slice(5, 7));
    const ey: number = Number(e.slice(0, 4));
    const em: number = Number(e.slice(5, 7));
    if (sy === 0 || sm === 0 || ey === 0 || em === 0) {
      return [];
    }
    if (sy > ey || (sy === ey && sm > em)) {
      return [];
    }
    const out: number[] = [];
    let y: number = sy;
    let m: number = sm;
    while (y < ey || (y === ey && m <= em)) {
      out.push(y * 100 + m);
      m++;
      if (m > 12) {
        m = 1;
        y++;
      }
    }
    return out;
  }

  /** 某自然月的月历格子：每行 7 格（周一~周日），值为 yyyy-MM-dd 或 ''（空位补齐） */
  private monthGrid(year: number, month: number): string[][] {
    const rows: string[][] = [];
    const first: Date = new Date(year, month - 1, 1);
    const daysInMonth: number = new Date(year, month, 0).getDate();
    const lead: number = (first.getDay() + 6) % 7; // 周一=0
    let cur: string[] = [];
    for (let i = 0; i < lead; i++) {
      cur.push('');
    }
    for (let d = 1; d <= daysInMonth; d++) {
      cur.push(DateUtil.format(new Date(year, month - 1, d)));
      if (cur.length === 7) {
        rows.push(cur);
        cur = [];
      }
    }
    if (cur.length > 0) {
      while (cur.length < 7) {
        cur.push('');
      }
      rows.push(cur);
    }
    // 固定补足到 6 行（31 天大小），保证各月份高度一致，滑动时不会上下抽动
    while (rows.length < 6) {
      rows.push(['', '', '', '', '', '', '']);
    }
    return rows;
  }

  /** 日期类型：用于日历格子的工作日/节假日/调休标注 */
  private dayType(day: string): string {
    // 调休补班（周末上班）——蓝/棕标注"班"
    if (HomeView.WORKDAYS.indexOf(day) >= 0) {
      return 'workday';
    }
    // 法定节假日（放假）——橙红标注"休"
    if (HomeView.HOLIDAYS.indexOf(day) >= 0) {
      return 'holiday';
    }
    // 周末（自然休息日）
    const d: Date = DateUtil.parse(day);
    const wd: number = d.getDay();
    if (wd === 0 || wd === 6) {
      return 'weekend';
    }
    return 'normal';
  }

  /** 日期是否属于校历中的节假日（法定放假日，非周末） */
  private isCalHoliday(date: string): boolean {
    return HomeView.HOLIDAYS.indexOf(date) >= 0;
  }

  /** 日期是否为调休补班（周末上班日） */
  private isMakeupWorkday(date: string): boolean {
    return HomeView.WORKDAYS.indexOf(date) >= 0;
  }

  /** 法定节假日（放假，不含周末）——2026 国办通知，覆盖 2026 秋季学期 + 2027 春季学期常见假期 */
  private static readonly HOLIDAYS: string[] = [
    // 中秋节 2026（9.25-9.27）
    '2026-09-25', '2026-09-26', '2026-09-27',
    // 国庆节 2026（10.1-10.7）
    '2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04', '2026-10-05', '2026-10-06', '2026-10-07',
    // 元旦 2027（1.1-1.3）
    '2027-01-01', '2027-01-02', '2027-01-03',
    // 春节 2027（2.15-2.23，落在寒假）
    '2027-02-15', '2027-02-16', '2027-02-17', '2027-02-18', '2027-02-19', '2027-02-20', '2027-02-21', '2027-02-22', '2027-02-23'
  ];

  /** 调休补班（周末上班日）——2026 国办通知 */
  private static readonly WORKDAYS: string[] = [
    '2026-09-20', // 国庆调休：周日上班
    '2026-10-10', // 国庆调休：周六上班
    '2027-01-04'  // 元旦调休：周日上班
  ];

  /** 某日期所属教学周（1 起；不在学期内返回 0，按有效开学日推算） */
  private weekIndex(day: string): number {
    const start: string = this.effStart();
    if (start.length === 0 || day.length === 0) {
      return 0;
    }
    const d: number = DateUtil.diffDays(DateUtil.parse(start), DateUtil.parse(day));
    if (d < 0) {
      return 0;
    }
    return Math.floor(d / 7) + 1;
  }

  /** 周次配色（同周同色，8 色循环；低透明度以保持文字可读） */
  private weekColor(idx: number): string {
    if (idx <= 0) {
      return '#00000000';
    }
    const palette: string[] = [
      '#332E7AFF', '#3322A06B', '#33E8833A', '#339B59C9',
      '#33D94F70', '#3300A6B8', '#33C9A227', '#33546E7A'
    ];
    return palette[(idx - 1) % palette.length];
  }

  /** 载入日历自定义设置（开学日按学期存，结束日与标题为全局） */
  private loadTermCustom(): void {
    this.customTermStart = DataStore.getCustomTermStart(AppState.term.id);
    this.customTermEnd = DataStore.get(DataStore.KEY_CUSTOM_TERM_END);
    this.customSemesterLabel = DataStore.get(DataStore.KEY_SEMESTER_LABEL);
    this.labelInput = this.customSemesterLabel;
  }

  /** 有效开学日（自定义优先，回落校历解析值） */
  private effStart(): string {
    if (this.customTermStart.length > 0) {
      return this.customTermStart;
    }
    if (this.teachingCal === null) {
      return '';
    }
    return this.teachingCal!.startDate;
  }

  /** 有效结束日（自定义优先，回落校历解析值） */
  private effEnd(): string {
    if (this.customTermEnd.length > 0) {
      return this.customTermEnd;
    }
    if (this.teachingCal === null) {
      return '';
    }
    return this.teachingCal!.endDate;
  }

  /** 有效学期标题（自定义优先，回落校历解析值） */
  private effLabel(): string {
    if (this.customSemesterLabel.length > 0) {
      return this.customSemesterLabel;
    }
    if (this.teachingCal === null) {
      return '';
    }
    return this.teachingCal!.semesterLabel;
  }

  /** 自定义起止变化后重算当前月与页码（避免停留在已被排除的空白月份） */
  private refreshCalendarState(): void {
    this.calDefaultMonth = this.computeCurrentMonth();
    this.calPageIndex = this.calInitialIndex();
  }

  /** 打开「开学日」选择器（立即生效；与课程表共用同一份数据，周次同步变化） */
  private openStartPicker(): void {
    const base: string = this.effStart();
    const sel: Date = base.length > 0 ? DateUtil.parse(base) : new Date();
    DatePickerDialog.show({
      start: new Date(2000, 0, 1),
      end: new Date(2035, 11, 31),
      selected: sel,
      onAccept: (value: DatePickerResult) => {
        const y: number = value.year ?? 2000;
        const m: number = value.month ?? 0;
        const d: number = value.day ?? 1;
        const date: string = DateUtil.format(new Date(y, m, d));
        this.customTermStart = date;
        DataStore.setCustomTermStart(AppState.term.id, date);
        this.refreshCalendarState();
      }
    });
  }

  /** 打开「结束日」选择器 */
  private openEndPicker(): void {
    const base: string = this.effEnd();
    const sel: Date = base.length > 0 ? DateUtil.parse(base) : new Date();
    DatePickerDialog.show({
      start: new Date(2000, 0, 1),
      end: new Date(2035, 11, 31),
      selected: sel,
      onAccept: (value: DatePickerResult) => {
        const y: number = value.year ?? 2000;
        const m: number = value.month ?? 0;
        const d: number = value.day ?? 1;
        const date: string = DateUtil.format(new Date(y, m, d));
        this.customTermEnd = date;
        DataStore.put(DataStore.KEY_CUSTOM_TERM_END, date);
        this.refreshCalendarState();
      }
    });
  }

  /** 保存自定义学期标题（留空 = 恢复校历原标题） */
  private saveCalLabel(): void {
    this.customSemesterLabel = this.labelInput.trim();
    DataStore.put(DataStore.KEY_SEMESTER_LABEL, this.customSemesterLabel);
    this.getUIContext().getPromptAction().showToast({
      message: this.customSemesterLabel.length > 0 ? T('已保存') : T('已恢复默认标题')
    });
  }

  /** 恢复默认日期（清除自定义开学 / 结束日） */
  private restoreCalDates(): void {
    this.customTermStart = '';
    this.customTermEnd = '';
    DataStore.setCustomTermStart(AppState.term.id, '');
    DataStore.put(DataStore.KEY_CUSTOM_TERM_END, '');
    this.refreshCalendarState();
    this.getUIContext().getPromptAction().showToast({ message: T('已恢复校历日期') });
  }

  /** 日历设置面板：学期标题 + 开学日 / 结束日自定义 */
  @Builder
  calEditorSheet() {
    // 补上沉浸光感：面板内自绘「日历设置」标题 + 关闭按钮（此前是系统 title 的普通弹层）
    MaterialSheetPanel({ panelRadius: 20, panelPadding: 0, panelFillHeight: false, panelTitle: T('日历设置'), panelShowClose: true, panelOnClose: (): void => { this.showCalEditor = false; } }) {
    Column() {
      Text(T('学期标题'))
        .fontSize(13)
        .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      // 学期标题输入框：TextInput 属表单控件，不能走 Toggle 承载层 → Stack 兄弟结构：
      // MaterialCardLayer 纯视觉承载层画沉浸光感（受全局开关控制），输入框自身透明底；
      // 材质关闭时回落原 comp_background_tertiary 实色底。原 top:6 间距由外壳 margin 承担。
      Stack() {
        if (materialActive()) {
          MaterialCardLayer({ layerRadius: $r('sys.float.corner_radius_level12'), layerShadow: false })
        }
        TextInput({ placeholder: T('留空则显示校历原标题'), text: this.labelInput })
          .height(48)
          .enterKeyType(EnterKeyType.Done)
          .borderRadius($r('sys.float.corner_radius_level12'))
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Regular : AppearanceStore.fontWeight(FontWeight.Regular))
          .backgroundColor(materialActive() ? Color.Transparent : $r('sys.color.comp_background_tertiary'))
          .caretStyle({ color: $r('sys.color.font_emphasize') })
          .type(InputType.Normal)
          .fontColor(Theme.colorOf(this.themeColor))
          .placeholderFont({ size: $r('sys.float.Body_L'), weight: FontWeight.Regular })
          .onChange((v: string) => {
            this.labelInput = v;
          })
      }
      .width('100%')
      .margin({ top: 6 })
      .borderRadius($r('sys.float.corner_radius_level12'))
      Row() {
        Text(T('保存标题'))
          .fontSize(13)
          .fontColor(Color.White)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor(Theme.colorOf(this.themeColor))
          .borderRadius(10)
          .onClick(() => {
            this.saveCalLabel();
          })
        Text(T('恢复默认标题'))
          .fontSize(13)
          .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor(this.subBg($r('app.color.bg_chip'))).backgroundBlurStyle((AppStorage.get<boolean>('immersiveEffect') ?? false) ? BlurStyle.Thin : BlurStyle.NONE).border({ width: 1, color: 'rgba(255,255,255,0.28)' }).shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 }).clip(true)
          .borderRadius(10)
          .margin({ left: 10 })
          .onClick(() => {
            this.labelInput = '';
            this.saveCalLabel();
          })
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Text(T('开学日期'))
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text(this.effStart().length > 0 ? this.effStart() : T('未设置'))
          .fontSize(13)
          .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          .margin({ right: 10 })
        Text(T('修改'))
          .fontSize(12)
          .fontColor(Theme.colorOf(this.themeColor))
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(this.subBg($r('app.color.bg_chip'))).backgroundBlurStyle((AppStorage.get<boolean>('immersiveEffect') ?? false) ? BlurStyle.Thin : BlurStyle.NONE).border({ width: 1, color: 'rgba(255,255,255,0.28)' }).shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 }).clip(true)
          .borderRadius(10)
      }
      .width('100%')
      .height(46)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.openStartPicker();
      })

      Row() {
        Text(T('结束日期'))
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text(this.effEnd().length > 0 ? this.effEnd() : T('未设置'))
          .fontSize(13)
          .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          .margin({ right: 10 })
        Text(T('修改'))
          .fontSize(12)
          .fontColor(Theme.colorOf(this.themeColor))
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(this.subBg($r('app.color.bg_chip'))).backgroundBlurStyle((AppStorage.get<boolean>('immersiveEffect') ?? false) ? BlurStyle.Thin : BlurStyle.NONE).border({ width: 1, color: 'rgba(255,255,255,0.28)' }).shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 }).clip(true)
          .borderRadius(10)
      }
      .width('100%')
      .height(46)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.openEndPicker();
      })

      Text(T('恢复默认日期'))
        .fontSize(13)
        .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.subBg($r('app.color.bg_chip'))).backgroundBlurStyle((AppStorage.get<boolean>('immersiveEffect') ?? false) ? BlurStyle.Thin : BlurStyle.NONE).border({ width: 1, color: 'rgba(255,255,255,0.28)' }).shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 }).clip(true)
        .borderRadius(10)
        .margin({ top: 10 })
        .onClick(() => {
          this.restoreCalDates();
        })

      Text(T('提示：修改开学时间会同时影响课程表的周次推算；学期标题留空即恢复校历原标题。'))
        .fontSize(11)
        .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
        .width('100%')
        .margin({ top: 12 })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 14, bottom: 26 })
    }
  }

  /** 学期日历信息小标签（胶囊小按钮：材质走 MaterialButton 的 Toggle 承载层） */
  @Builder
  infoChip(text: string, color: ResourceColor) {
    MaterialButton({
      btnRadius: 10,
      btnMargin: { right: 8 },
      btnBg: this.subBg($r('app.color.bg_chip')),
      btnBlur: GlassMaterial.bgBlur(this.immersiveEffect),
      btnBorderW: GlassMaterial.borderWidth(),
      btnBorderC: GlassMaterial.borderColor()
    }) {
      Text(text)
        .fontSize(11)
        .fontColor(color)
        .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
    }
  }

  /** 日期是否在有效学期范围内（有效开学日 ~ 有效结束日），范围外灰色显示 */
  private isInTerm(day: string): boolean {
    const s: string = this.effStart();
    const e: string = this.effEnd();
    if (s.length === 0 || e.length === 0) {
      return true;
    }
    return day >= s && day <= e;
  }

  /** Swiper 初始页索引（默认当月，不在校历覆盖月份则第一月） */
  private calInitialIndex(): number {
    const all: number[] = this.calMonthList();
    const idx: number = all.indexOf(this.calDefaultMonth);
    return idx >= 0 ? idx : 0;
  }

  /** 日历（正常日历样式）：Swiper 左右滑动查看月份；按自然月分块的月历（周一~周日），今日/节假日高亮，学期范围外灰色；底部附校历说明。数据运行时解析，不写死 */
  @Builder
  calendar() {
    Column() {
      SectionHeader({ title: T('日历'), action: T('设置'), onAction: () => {
        this.labelInput = this.customSemesterLabel;
        this.showCalEditor = true;
      } })

      // 卡片主体（标题"日历"单独在卡片外，样式对齐"近期考试"）
      // MaterialCard 承载：材质层是卡片内部底层、与卡片同尺寸同圆角，材质生效时卡片底色让出
      MaterialCard({
        cardRadius: 18,
        cardBg: this.cardBgColor(),
        cardBlur: GlassMaterial.bgBlur(this.immersiveEffect),
        cardBorderW: GlassMaterial.borderWidth(),
        cardBorderC: GlassMaterial.borderColor()
      }) {
      if (this.teachingCal === null) {
        // "加载日历"占位卡：固定高度（不再套 padding，避免卡片被撑高）
        Column() {
          LoadingTip({ text: T('加载日历…') })
        }
          .width('100%')
          .height(140)
          .justifyContent(FlexAlign.Center)
      } else {
        // else 分支内容自带 padding（padding 必须挂在卡片内部的内容容器上，承载层才能铺满整张卡片）
        Column() {
        // 学期标题：点击可自定义（留空恢复校历原标题）
        Text(this.effLabel())
          .fontSize(13)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .margin({ bottom: 8 })
          .onClick(() => {
            this.labelInput = this.customSemesterLabel;
            this.showCalEditor = true;
          })

        Row() {
          // 未开学不显示周次，显示"未开学"
          if (this.isTermStarted()) {
            this.infoChip(`第 ${this.todayTeachingWeek()} 周`, Theme.colorOf(this.themeColor))
          } else {
            this.infoChip(T('未开学'), $r('app.color.accent_orange'))
          }
          if (this.effStart().length > 0) {
            // 开生日胶囊小按钮（点击改期）：材质走 MaterialButton 的 Toggle 承载层
            MaterialButton({
              btnRadius: 10,
              btnMargin: { right: 8 },
              btnBg: this.subBg($r('app.color.bg_chip')),
              btnBlur: GlassMaterial.bgBlur(this.immersiveEffect),
              btnBorderW: GlassMaterial.borderWidth(),
              btnBorderC: GlassMaterial.borderColor(),
              btnOnClick: () => {
                this.openStartPicker();
              }
            }) {
              Text(`开学 ${this.effStart().slice(5)}`)
                .fontSize(11)
                .fontColor($r('app.color.accent_blue'))
                .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            }
          }
          if (this.effEnd().length > 0) {
            // 结束日胶囊小按钮（点击改期）：同上，材质走 MaterialButton 的 Toggle 承载层
            MaterialButton({
              btnRadius: 10,
              btnMargin: { right: 8 },
              btnBg: this.subBg($r('app.color.bg_chip')),
              btnBlur: GlassMaterial.bgBlur(this.immersiveEffect),
              btnBorderW: GlassMaterial.borderWidth(),
              btnBorderC: GlassMaterial.borderColor(),
              btnOnClick: () => {
                this.openEndPicker();
              }
            }) {
              Text(`结束 ${this.effEnd().slice(5)}`)
                .fontSize(11)
                .fontColor($r('app.color.accent_orange'))
                .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            }
          }
        }
        .width('100%')
        .margin({ bottom: 10 })

        // 月份 Swiper：左右滑动查看其他月份
        Swiper() {
          ForEach(this.calMonthList(), (ym: number) => {
            Column() {
              Text(`${ym % 100}月 ${Math.floor(ym / 100)}`)
                .fontSize(13)
                .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .margin({ top: 6, bottom: 6 })

              Row() {
                ForEach(Const.WEEK_SHORT, (d: string) => {
                  Text(d)
                    .fontSize(10)
                    .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                    .textAlign(TextAlign.Center)
                    .layoutWeight(1)
                }, (d: string) => d)
              }
              .width('100%')
              .padding({ bottom: 4 })

              ForEach(this.monthGrid(Math.floor(ym / 100), ym % 100), (row: string[]) => {
                Row() {
                  ForEach(row, (day: string, di: number) => {
                    Column() {
                      if (day.length > 0) {
                        // 日期数字：今日白字高亮；节假日橙红；调休补班蓝；周末灰；普通按学期内/过去判断
                        Text(day.slice(-2))
                          .fontSize(11)
                          .fontColor(
                            day === this.effectiveToday()
                              ? Color.White
                              : (this.dayType(day) === 'holiday'
                                ? $r('app.color.accent_orange')
                                : (this.dayType(day) === 'workday'
                                  ? $r('app.color.accent_blue')
                                  : (this.dayType(day) === 'weekend'
                                    ? GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))
                                    : (this.isInTerm(day)
                                      ? (day < this.effectiveToday()
                                        ? GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))
                                        : $r('app.color.text_primary'))
                                      : GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))))))
                          )
                          .fontWeight(this.fwMode === 'follow' ? (day === this.effectiveToday() ? FontWeight.Bold : FontWeight.Normal) : AppearanceStore.fontWeight(day === this.effectiveToday() ? FontWeight.Bold : FontWeight.Normal))
                          .width('100%')
                          .height(20)
                          .textAlign(TextAlign.Center)
                        // 节假日/调休角标：休=橙红小字，班=蓝小字，普通日期留空
                        if (this.dayType(day) === 'holiday' || this.dayType(day) === 'workday') {
                          Text(this.dayType(day) === 'holiday' ? '休' : '班')
                            .fontSize(7)
                            .fontColor(this.dayType(day) === 'holiday' ? $r('app.color.accent_orange') : $r('app.color.accent_blue'))
                            .width('100%')
                            .height(8)
                            .textAlign(TextAlign.Center)
                        }
                      }
                    }
                    .layoutWeight(1)
                    .height(28)
                    .justifyContent(FlexAlign.Center)
                    // 色带两端圆角（周一到周日为一条，两头收角）
                    .borderRadius({
                      topLeft: di === 0 ? 10 : 0,
                      bottomLeft: di === 0 ? 10 : 0,
                      topRight: di === row.length - 1 ? 10 : 0,
                      bottomRight: di === row.length - 1 ? 10 : 0
                    })
                    // 背景铺满整格 → 同一周（行内 7 天）连成一条色带；已过去的日期/周次显示为灰色
                    .backgroundColor(
                      day.length === 0
                        ? Color.Transparent
                        : (day === this.effectiveToday()
                          ? Theme.colorOf(this.themeColor)
                          : (day < this.effectiveToday()
                            ? 'rgba(128,138,136,0.22)'
                            : (this.isInTerm(day) ? this.weekColor(this.weekIndex(day)) : Color.Transparent)))
                    )
                  }, (day: string, di: number) => `${di}-${day}`)
                }
                .width('100%')
                .height(32)
                .margin({ bottom: 2 })
              }, (row: string[], ri: number) => `${ri}-${row.length}`)
            }
            .width('100%')
            .padding({ top: 6, bottom: 8 })
          }, (ym: number) => `${ym}`)
        }
        .index(this.calInitialIndex())
        .loop(false)
        .indicator(false)
        .onChange((index: number) => {
          this.calPageIndex = index;
        })
        .width('100%')

        // 页码指示器（自绘）：位于月份内容下方，位置可精确控制，不遮挡日期
        // 彩色指示条加沉浸光感：材质承载层常驻，色条改半透明叠在材质上（彩色玻璃观感）
        Row({ space: 6 }) {
          ForEach(this.calMonthList(), (ym: number, i: number) => {
            Stack() {
              if (GlassMaterial.immSupported()) {
                MaterialCardLayer({ layerRadius: 3, layerShadow: false, layerForce: true })
              }
              Column()
                .width(i === this.calPageIndex ? 14 : 6)
                .height(6)
                .borderRadius(3)
                .backgroundColor(i === this.calPageIndex
                  ? Theme.rgba(Theme.colorOf(this.themeColor), 0.62)
                  : '#33000000')
            }
          }, (ym: number, i: number) => `caldot${i}`)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 2, bottom: 2 })

        // 校历说明（来自校历 PDF 说明区）
        Column() {
          Text(T('校历说明'))
            .fontSize(11)
            .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
            .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .width('100%')
          Text(T('第一学期 2026年9月7日至2027年1月15日，共19周，寒假5周。2026年9月5日报到注册，9月7日上课，新生另定。'))
            .fontSize(11)
            .lineHeight(18)
            .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .width('100%')
            .margin({ top: 6 })
          Text(T('节假日：中秋 9.25-9.27、国庆 10.1-10.7（9.20/10.10 补班）、元旦 1.1-1.3（1.4 补班）。日历中「休」为放假日，「班」为调休上班日。'))
            .fontSize(11)
            .lineHeight(18)
            .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .width('100%')
            .margin({ top: 4 })
        }
        .width('100%')
        .padding(12)
          .backgroundColor(this.subBg($r('app.color.bg_chip'))).backgroundBlurStyle((AppStorage.get<boolean>('immersiveEffect') ?? false) ? BlurStyle.Thin : BlurStyle.NONE).border({ width: 1, color: 'rgba(255,255,255,0.28)' }).shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 }).clip(true)
          .borderRadius(12)
          .margin({ top: 6 })
        }
        .width('100%')
        .padding(16)
      }
      }
    }
    .width('100%')
    .margin({ top: 18 })
    // 日历设置面板（挂日历卡片外框；与根 Column / Scroll 上的其它弹层分属不同组件，避免冲突）
    .bindSheet($$this.showCalEditor, this.calEditorSheet(), {
      // 宽度对齐其他半模态面板（用户要求：平板/横屏下不再默认超宽）
      width: SheetUtil.sheetWidth(),
      height: SheetSize.FIT_CONTENT,
      // 关闭按钮/标题改由面板内 MaterialSheetPanel 自绘；显式透明底 + 材质模糊补上沉浸光感
      showClose: false,
      preferType: SheetType.BOTTOM,
      backgroundColor: Color.Transparent,
      blurStyle: sheetBlurStyle()
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
    Column() {
    this.titleBar()
    if (this.isLandscape) {
      this.homeLandscape()
    } else {
    // 中间内容：可滚动；横屏/平板下内容限宽 720vp 并居中（一多适配）
    Row() {
      Refresh({ refreshing: $$this.refreshing }) {
        Scroll() {
          Column() {
            // 顶栏占位（随内容滚走）：固定高度，位于悬浮渐变标题栏下方
            Column()
              .width('100%')
              .height(this.getUIContext().px2vp(this.topInsetPx) + 60)
            // 头像卡片（始终显示；圆形头像由 showAvatar 开关控制）
            if (this.sessionExpiredFlag) {
              this.sessionBanner()
            }
            this.avatarCard()

            Column() {
              this.todayCard()
            }
            .margin({ top: 12 })

            Column() {
              this.quickEntries()
            }
            .margin({ top: 18 })

            this.calendar()
            this.examSection()
            this.messageSection()
            this.noticeSection()
            Column() {
              Text(T('数据来源: 南京医科大学教务系统')).fontSize(11)
                .fontColor(WallpaperTone.onWallpaperSecondary(this.wallpaperTone, this.isDarkMode))
              Text(T('南京医科大学教务处')).fontSize(11)
                .fontColor(WallpaperTone.onWallpaperSecondary(this.wallpaperTone, this.isDarkMode))
                .margin({ top: 3 })
              Text(T('"功能浏览"模式为本地模拟数据')).fontSize(11)
                .fontColor(WallpaperTone.onWallpaperSecondary(this.wallpaperTone, this.isDarkMode))
                .margin({ top: 3 })
            }
            .width('100%')
            .margin({ top: 20, bottom: 24 })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 100 }) // 底部预留悬浮底栏高度，避免内容被遮挡
          // 学期选择弹层（与根 Column 的通知弹层/Scroll 的网页弹层分置不同组件，避免同组件多 bindSheet 冲突）
          .bindSheet($$this.showTermSheet, this.termPickerSheet(), {
            width: SheetUtil.sheetWidth(),
            preferType: SheetType.BOTTOM,
            height: SheetSize.FIT_CONTENT,
            // 关闭按钮由 MaterialSheetPanel 自绘（沉浸光感），系统 showClose 必须关掉避免双按钮
            showClose: false,
            dragBar: true,
            // 必须显式透明：不透明底（默认白/bg_card）会把 MaterialSheetPanel 的材质整块盖住
            backgroundColor: Color.Transparent,
            blurStyle: sheetBlurStyle()
          })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)
        // 沉浸浏览：滚动方向检测 → 隐藏/恢复顶栏与底栏
        .onScroll((_x: number, y: number) => {
          this.handleHomeScroll(y);
        })
        // 通知文章页（教务处官网）挂在内层 Scroll，与根组件的通知弹层分离（同组件多 bindSheet 仅最后一个生效）
        .bindSheet($$this.showWebSheet, this.webSheet(), {
          width: SheetUtil.sheetWidth(),
          preferType: SheetType.BOTTOM,
          height: SheetSize.LARGE,
          dragBar: false,
          backgroundColor: Color.Transparent,
          blurStyle: sheetBlurStyle()
        })
      }
      .onRefreshing(() => { this.onRefresh(); })
      }
      .width(720)
      .constraintSize({ maxWidth: '100%' })
      .height('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center) // 横屏/平板下 Scroll 水平居中
    }
    }
    .width('100%')
    .height('100%')
    // 壁纸功能：页面根背景透明，让主框架底层的全局壁纸透出（无壁纸时由 MainView 底层 bg_page 兜底）
    .backgroundColor(Color.Transparent)
    .bindSheet($$this.showNoticeSheet, this.noticeSheet(), {
      width: SheetUtil.sheetWidth(),
      preferType: SheetType.BOTTOM,
      height: SheetSize.LARGE,
      // 关闭按钮由 MaterialSheetPanel 自绘（沉浸光感），系统 showClose 必须关掉避免双按钮
      showClose: false,
      dragBar: true,
      // 必须显式透明：BindOptions.backgroundColor 默认是 Color.White，
      // 而沉浸光感的视觉层级位于 backgroundColor 之下，白底会把面板材质整块盖住
      backgroundColor: Color.Transparent,
      blurStyle: sheetBlurStyle()
    })
    }
    .width('100%')
    .height('100%')
    // 灰字广播依赖登记：grayTick 变化触发整页重算 graySecondary/grayTertiary 文本色（恒真不改变视觉）
    .opacity(this.grayTick >= 0 ? 1 : 1)
  }

  @Builder
  homeLandscape() {
    Row() {
      // 左列：头像 / 今日课程 / 校历 / 快捷入口
      Refresh({ refreshing: $$this.refreshing }) {
        Scroll() {
          Column() {
            // 顶栏占位（随内容滚走）：固定高度，与左/右列保持一致
            Column()
              .width('100%')
              .height(this.getUIContext().px2vp(this.topInsetPx) + 60)
            if (this.sessionExpiredFlag) {
              this.sessionBanner()
            }
            this.avatarCard()
            Column() {
              this.todayCard()
            }
            .margin({ top: 12 })
            Column() {
              this.quickEntries()
            }
            .margin({ top: 12 })
            this.calendar()
          }
          .width('100%')
          .padding({ left: 16, right: 8, top: 12, bottom: 100 })
        }
        .layoutWeight(1)
        .height('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)
        .bindSheet($$this.showTermSheet, this.termPickerSheet(), {
          width: SheetUtil.sheetWidth(),
          preferType: SheetType.BOTTOM,
          height: SheetSize.FIT_CONTENT,
          // 关闭按钮由 MaterialSheetPanel 自绘（沉浸光感），系统 showClose 必须关掉避免双按钮
          showClose: false,
          dragBar: true,
          backgroundColor: Color.Transparent,
          blurStyle: sheetBlurStyle()
        })
      }
      .layoutWeight(1)
      .height('100%')
      .onRefreshing(() => { this.onRefresh(); })

      // 右列：考试 / 消息 / 通知
      Refresh({ refreshing: $$this.refreshing }) {
        Scroll() {
          Column() {
            // 顶栏占位（随内容滚走）
            Column()
              .width('100%')
              .height(this.getUIContext().px2vp(this.topInsetPx) + 60)
            this.examSection()
            this.messageSection()
            this.noticeSection()
            Column() {
              Text(T('数据来源: 南京医科大学教务系统')).fontSize(11)
                .fontColor(WallpaperTone.onWallpaperSecondary(this.wallpaperTone, this.isDarkMode))
              Text(T('南京医科大学教务处')).fontSize(11)
                .fontColor(WallpaperTone.onWallpaperSecondary(this.wallpaperTone, this.isDarkMode))
                .margin({ top: 3 })
              Text(T('"功能浏览"模式为本地模拟数据')).fontSize(11)
                .fontColor(WallpaperTone.onWallpaperSecondary(this.wallpaperTone, this.isDarkMode))
                .margin({ top: 3 })
            }
            .width('100%')
            .margin({ top: 20, bottom: 24 })
          }
          .width('100%')
          .padding({ left: 8, right: 16, top: 12, bottom: 100 })
        }
        .layoutWeight(1)
        .height('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)
        .bindSheet($$this.showWebSheet, this.webSheet(), {
          width: SheetUtil.sheetWidth(),
          preferType: SheetType.BOTTOM,
          height: SheetSize.LARGE,
          dragBar: false,
          backgroundColor: Color.Transparent,
          blurStyle: sheetBlurStyle()
        })
      }
      .layoutWeight(1)
      .height('100%')
      .onRefreshing(() => { this.onRefresh(); })
    }
    .width('100%')
    .layoutWeight(1)
    .align(Alignment.Top)
  }

  @Builder
  webSheet() {
    // 网页弹层也走沉浸光感面板：标题进面板（AppState.webTitle 动态传入）
    MaterialSheetPanel({ panelRadius: 20, panelPadding: 0, panelTitle: AppState.webTitle, panelShowClose: true, panelOnClose: (): void => { this.showWebSheet = false; } }) {
      WebSurface()
    }
  }
}