/**
 * 学业情况：
 *  - 平均学分绩点 GPA（大字号）
 *  - 4 个统计卡：已修 / 在读 / 未修 / 未通过
 *  - 课程分类与修读情况（点击分类查看：已完成 / 在读 / 未修 / 未通过 课程）
 *  - 未通过课程列表
 *  - 学业提醒
 *
 * 数据来源：JwApi.getAcademic() 解析完正方学业页纯文本得到总体统计；
 * 课程分类与详情从成绩（ScoreItem.kclbmc）+ 课表数据组合产生。
 *
 * 卡片外观接入（照首页 HomeView / 关于页 AboutPage 的写法推广）：
 *  - 7 张页面级卡片（GPA / 总体成绩 / 成绩分布 / 已修在读未修未通过 / 课程分类 / 课程明细 / 学业提醒）
 *    统一用 `MaterialCard` 承载（材质层在卡片内部、位于内容之下），材质生效时卡片自身的
 *    底色/磨砂/亮边/阴影一并让出，每张卡只有一层视觉；关闭光感回落为原来的纯色/毛玻璃卡片；
 *  - 原卡片上的 `.padding(...)` / `.borderRadius(...)` / `.margin(...)` / `.alignItems(...)`
 *    一律改走 `cardPadding` / `cardRadius` / `cardMargin` / `cardAlignItems`
 *    （尾随闭包初始化的自定义组件之后不能再链式加属性）；不对称 padding（{ top: 18, bottom: 18 }）
 *    挂到内部内容容器上，间距与原值逐张对齐；
 *  - 「展开全部 / 收起」是纯文字链（无胶囊底），保持原写法不改为材质按钮；
 *    卡片内部的子块（进度条、序号圆圈）同样保持原自绘玻璃写法（材质卡内部不再叠第二层材质）。
 */
import { JwApi } from '../api/JwApi';
import { AppState } from '../common/AppState';
import { Const } from '../common/Constants';
import { DataStore } from '../common/DataStore';
import { LogStore } from '../common/LogStore';
import { AntiPeepManager } from '../common/AntiPeepManager';
import { CourseItem, AcademicReport, CreditCategory, OverallGradeStats, OverallGrades, ScoreItem, TermInfo, TermScore, LevelExamSummary, LevelExamItem, PlanProgress } from '../model/Models';
import { EMPTY_REPORT } from '../model/Empty';
import { LoadingTip, PageHeader, StatCell } from './common/UiKit';
import { ChevronRight } from './common/ChevronRight';
import { AntiPeepOverlay } from './common/AntiPeepOverlay';
import { WallpaperFill } from './common/WallpaperFill';
import { Theme } from '../common/ThemeUtil';
import { AppearanceStore } from '../common/AppearanceStore';
import { GlassMaterial } from '../common/GlassMaterial';
import { WallpaperTone } from '../common/WallpaperTone';
// 沉浸光感：卡片统一走 MaterialCard（材质承载层在卡片内容之下，材质生效时卡片底色/磨砂/亮边/阴影
// 一并让出，每张卡只剩一层视觉）
import { MaterialCard, MaterialSheetPanel } from './common/MaterialCard';
import { MaterialButton } from './common/MaterialButton';
import { SheetUtil } from '../common/SheetUtil';
import { sheetBlurStyle } from '../common/SystemMaterial';
import { ImageExport, ExportResult } from '../common/ScoreImageExport';
import { common } from '@kit.AbilityKit';

/** 成绩明细统计结果（基于成绩接口，非未开放的学业情况页） */
interface GradeStats {
  passed: number;
  failed: number;
  totalCredit: number;
}

/** 课程明细示例数据：教务未开放「课程修读」数据时（overallCourses 为空）填充展示，
 *  全部为中性假数据（示例教师/通用课程名），不含任何真实个人信息 */
const MOCK_DETAIL_COURSES: ScoreItem[] = [
  { id: 'mock01', courseName: '高等数学（上）', credit: 4, score: 91, scoreText: '91', gradePoint: 4.0, courseType: '必修', examType: '正常考试', teacher: '示例教师A', termId: '2023-2024-1', kclbmc: '必修课', isCore: false },
  { id: 'mock02', courseName: '大学外语（一）', credit: 3, score: 86, scoreText: '86', gradePoint: 3.7, courseType: '必修', examType: '正常考试', teacher: '示例教师B', termId: '2023-2024-1', kclbmc: '必修课', isCore: false },
  { id: 'mock03', courseName: '思想道德与法治', credit: 3, score: -1, scoreText: '良好', gradePoint: 3.3, courseType: '必修', examType: '正常考试', teacher: '示例教师C', termId: '2023-2024-1', kclbmc: '必修课', isCore: false },
  { id: 'mock04', courseName: '大学计算机基础', credit: 2, score: 94, scoreText: '94', gradePoint: 4.0, courseType: '必修', examType: '正常考试', teacher: '示例教师D', termId: '2023-2024-2', kclbmc: '必修课', isCore: false },
  { id: 'mock05', courseName: '高等数学（下）', credit: 4, score: 88, scoreText: '88', gradePoint: 3.8, courseType: '必修', examType: '正常考试', teacher: '示例教师A', termId: '2023-2024-2', kclbmc: '必修课', isCore: false },
  { id: 'mock06', courseName: '大学体育（二）', credit: 1, score: -1, scoreText: '优秀', gradePoint: 4.0, courseType: '必修', examType: '正常考试', teacher: '示例教师E', termId: '2023-2024-2', kclbmc: '必修课', isCore: false },
  { id: 'mock07', courseName: '有机化学', credit: 4, score: 82, scoreText: '82', gradePoint: 3.2, courseType: '必修', examType: '正常考试', teacher: '示例教师F', termId: '2024-2025-1', kclbmc: '必修课', isCore: false },
  { id: 'mock08', courseName: '中华优秀传统文化', credit: 2, score: -1, scoreText: '良好', gradePoint: 3.3, courseType: '选修', examType: '正常考试', teacher: '示例教师G', termId: '2024-2025-1', kclbmc: '选修课', isCore: false },
  { id: 'mock09', courseName: '概率论与数理统计', credit: 3, score: 90, scoreText: '90', gradePoint: 3.9, courseType: '必修', examType: '正常考试', teacher: '示例教师H', termId: '2024-2025-2', kclbmc: '必修课', isCore: false },
  { id: 'mock10', courseName: '大学生创新创业基础', credit: 2, score: -1, scoreText: '中等', gradePoint: 2.7, courseType: '选修', examType: '正常考试', teacher: '示例教师I', termId: '2024-2025-2', kclbmc: '选修课', isCore: false }
];

/** 总体成绩示例统计：教务未开放「学业情况-总体」时（overallStats 为空）填充展示，
 *  数值与 MOCK_DETAIL_COURSES 一致（10 门：优 4 / 良 5 / 中 1），中性假数据 */
const MOCK_STATS: OverallGradeStats = {
  gpa: '3.62',
  credits: '28.5',
  courseCount: 10,
  excellent: 4,
  good: 5,
  medium: 1,
  pass: 0,
  coreAvg: -1,
  ncAvg: -1,
  overallScore: -1,
  coreGpa: -1,
  requiredGpa: -1,
  officialOverall: '',
  cet4: -1,
  electiveCredit: -1,
  failedCount: -1
};

@Component
export struct AcademicPage {
  /** 会话级拉取节流：5 分钟内重复进入不再全量拉取（缓存照常展示，下拉刷新强制拉取） */
  private static lastFetchMs: number = 0;
  private static readonly FETCH_TTL_MS: number = 5 * 60 * 1000;
  @StorageProp('topInsetPx') topInsetPx: number = 0;
  /** 灰字广播订阅：颜色表达式需传 this.grayTick 才登记响应式依赖（否则改色不实时刷新） */
  @StorageProp('grayTick') grayTick: number = 0;
  /** 响应式依赖：玻璃/灰字设置变化时即时刷新本页（取值经 GlassMaterial 静态方法读取） */
  @StorageProp('glassStrength') glassStrength: number = 70;
  @StorageProp('cardMaterial') cardMaterial: boolean = false;
  @StorageProp('grayTextMode') grayTextMode: string = 'default';
  @StorageProp('grayTextColor') grayTextColor: string = '';
  @StorageProp('bottomInsetPx') bottomInsetPx: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /** 全局字重响应式订阅：表达式读 this.fwMode 才登记依赖，fwValue 声明即订阅 */
  @StorageProp('fontWeightMode') fwMode: string = 'follow';
  @StorageProp('fontWeightValue') fwValue: number = 400;
  /** 壁纸亮度（文字自适应用） */
  @StorageProp('wallpaperTone') wallpaperTone: number = -1;
  @StorageProp('themeColor') themeColor: string = 'green';
  @StorageProp('barStyle') barStyle: string = 'new';
  /** 沉浸光感：卡片玻璃化 */
  @StorageProp('glassEnabled') glassEnabled: boolean = false;
  @StorageProp('glassBlur') glassBlur: number = 16;
  @StorageProp('glassRefract') glassRefract: number = 40;
  @State report: AcademicReport = EMPTY_REPORT;
  @State courses: CourseItem[] = [];
  @State termScores: TermScore[] = [];
  /** 总体成绩统计（移植自参考项目「成绩-总体」：累计绩点/已修学分/总课程 + 成绩分布） */
  @State overallStats: OverallGradeStats | null = null;
  /** 总体成绩 - 课程明细（含成绩/学分/绩点） */
  @State overallCourses: ScoreItem[] = [];
  /** 课程明细是否展开（默认只显示前 8 条） */
  @State detailExpanded: boolean = false;
  /** 学业总评成绩展示开关（南医大 2023 级起重要指标，可自定义显隐） */
  @State showOverallScore: boolean = true;
  /** 顶部 GPA 卡片显示内容：'gpa'=平均学分绩点 / 'overall'=学业总评成绩（持久化，可切换） */
  @State gpaCardMode: string = 'gpa';
  /** tab 内嵌模式：true=作为底部 tab 页渲染（无 NavDestination/返回键），false=二级推送页 */
  @Prop isTab: boolean = false;
  /** 等级考试汇总（四六级 CET4/CET6 + 计算机等级，来自考级项目报名接口） */
  @State levelExams: LevelExamSummary | null = null;
  /** 培养方案完成情况（教学执行计划 N153540 计算：在读/未修/应修学分） */
  @State planProgress: PlanProgress | null = null;
  /** 学期名称缓存（termId → label，避免重复构建） */
  private termLabels: TermInfo[] = [];
  @State loading: boolean = true;
  @State refreshing: boolean = false;
  @State isPeeped: boolean = false;
  private peepMgr: AntiPeepManager = new AntiPeepManager();
  /** 统计卡点击弹窗：当前展开的统计类型（''=关闭；passed/failed/studying/unearned/band/category） */
  @State showStatSheet: boolean = false;
  @State statSheetTitle: string = '';
  @State statSheetKind: string = '';
  /** 弹窗直接展示的课程列表（新 kind 用预置列表，避免 @Builder 内动态查询受限） */
  @State statSheetList: ScoreItem[] = [];
  /** 弹窗空态说明文案（在读/未修等无数据源时） */
  @State statSheetHint: string = '';
  /** 在读/未修课程名列表（来自培养方案计算，纯课程名展示） */
  @State statSheetNames: string[] = [];
  /** 手动已修白名单（课程名列表，响应式，标记/取消后即时刷新统计） */
  @State planWhitelist: string[] = [];
  /** 导出图片：是否显示选择面板 / 是否导出中 */
  @State showExportSheet: boolean = false;
  @State exportingImage: boolean = false;
  /** 导出模块选择：'overview'=学业概览 / 'detail'=课程明细 / 'warning'=学业提醒（可多选，空=全部） */
  @State exportModules: string[] = ['overview', 'detail', 'warning'];

  /** 页面出现：触发学业数据加载 */
  aboutToAppear(): void {
    // 读取学业总评成绩展示开关（默认开启）
    this.showOverallScore = DataStore.get(DataStore.KEY_SHOW_OVERALL_SCORE) !== '0';
    this.gpaCardMode = DataStore.get(DataStore.KEY_GPA_CARD_MODE) === 'overall' ? 'overall' : 'gpa';
    this.load();
    // 启动防窥保护监听
    this.peepMgr.start((hidden: boolean) => { this.isPeeped = hidden; });
  }

  aboutToDisappear(): void {
    this.peepMgr.stop();
  }

  private async load(force: boolean = false): Promise<void> {
    this.loading = true;
    const cached: AcademicReport = JwApi.loadCachedAcademic();
    if (cached.gpa > 0 || cached.totalRequired > 0) {
      this.report = cached;
    }
    const cachedCourses: CourseItem[] = JwApi.loadCachedCourses();
    if (cachedCourses.length > 0) {
      this.courses = cachedCourses;
    }
    this.termScores = JwApi.loadCachedTermScores();
    // 总体成绩：先展示缓存
    const cachedOverall: OverallGrades | null = JwApi.loadCachedOverallGrades();
    if (cachedOverall !== null) {
      this.overallStats = cachedOverall.stats;
      this.overallCourses = cachedOverall.courses;
    }
    // 等级考试：先展示缓存
    const cachedLevelExams: LevelExamSummary | null = JwApi.loadCachedLevelExams();
    if (cachedLevelExams !== null) {
      this.levelExams = cachedLevelExams;
    }
    // 培养方案完成情况：先展示缓存
    const cachedPlan: PlanProgress | null = JwApi.loadCachedPlanProgress();
    if (cachedPlan !== null) {
      this.planProgress = cachedPlan;
    }
    // 手动已修白名单
    this.planWhitelist = DataStore.planPassWhitelist();
    // 日志调试：记录本地操作（先展示缓存）+ 实际反馈
    LogStore.log('学业', '页面加载', '开始',
      `先展示缓存 GPA=${cached.gpa} 课程${cachedCourses.length}节 成绩${this.termScores.length}学期`);
    // 缓存节流：5 分钟内重复进入不再全量拉取（下拉刷新强制拉取）
    if (!force && Date.now() - AcademicPage.lastFetchMs < AcademicPage.FETCH_TTL_MS) {
      this.loading = false;
      LogStore.log('学业', '页面加载', '缓存有效', '5 分钟内已拉取过，跳过网络更新');
      return;
    }
    try {
      // 四路**并行**拉取：谁先完成谁先上屏（此前串行 await，后面的数据要干等前面的）
      const p1: Promise<void> = JwApi.getAcademic()
        .then((r: AcademicReport): void => {
          this.report = r;
        })
        .catch((): void => {
        });
      const p2: Promise<void> = JwApi.getCoursesSmart(AppState.term.id, false)
        .then((c: CourseItem[]): void => {
          this.courses = c;
        })
        .catch((): void => {
        });
      const p3: Promise<void> = JwApi.getTermScores()
        .then((s: TermScore[]): void => {
          this.termScores = s;
        })
        .catch((): void => {
        });
      const p4: Promise<void> = JwApi.getOverallGrades()
        .then((o: OverallGrades): void => {
          this.overallStats = o.stats;
          this.overallCourses = o.courses;
        })
        .catch((): void => {
        });
      const p5: Promise<void> = JwApi.getLevelExams()
        .then((le: LevelExamSummary): void => {
          this.levelExams = le;
        })
        .catch((): void => {
        });
      const p6: Promise<void> = JwApi.getPlanProgress()
        .then((pp: PlanProgress): void => {
          this.planProgress = pp;
        })
        .catch((): void => {
        });
      await Promise.all([p1, p2, p3, p4, p5, p6]);
      AcademicPage.lastFetchMs = Date.now();
      LogStore.log('学业', '页面加载', '完成', '六路并行拉取结束（各数据完成即上屏）');
    } catch (e) {
      // 网络异常时保持缓存
      LogStore.log('学业', '页面加载', '网络异常', LogStore.errorOf(e as Object));
    }
    this.loading = false;
  }

  /** 下拉刷新：重新加载学业情况 */
  private async buttonRefresh(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    await this.load(true);
    this.refreshing = false;
  }

  private async onRefresh(): Promise<void> {
    await this.load(true);
    this.refreshing = false;
  }

  /** 打开导出选择面板 */
  private openExportSheet(): void {
    this.showExportSheet = true;
  }

  /** 切换导出模块勾选 */
  private toggleExportModule(m: string): void {
    const idx: number = this.exportModules.indexOf(m);
    if (idx >= 0) {
      this.exportModules.splice(idx, 1);
    } else {
      this.exportModules.push(m);
    }
    this.exportModules = this.exportModules.slice(0);
  }

  /** 导出模块是否勾选 */
  private isExportModule(m: string): boolean {
    return this.exportModules.indexOf(m) >= 0;
  }

  /** 导出学业情况图片 */
  private async exportAcademicImage(): Promise<void> {
    if (this.exportingImage) {
      return;
    }
    this.showExportSheet = false;
    if (this.exportModules.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请至少选择一个导出模块' });
      return;
    }
    this.exportingImage = true;
    this.getUIContext().getPromptAction().showToast({ message: '正在生成学业情况图片…' });
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      // 文件名不能含 / 等特殊字符，日期用紧凑格式（如 20261018）
      const now: Date = new Date();
      const dateStr: string = `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, '0')}${String(now.getDate()).padStart(2, '0')}`;
      // 用离屏 Builder 完整渲染：课程多时卡片高度可超屏幕，组件快照会截断
      const result: ExportResult = await ImageExport.exportBuilder(
        ctx, this.getUIContext(), (): void => { this.academicExportCard(); }, 'academic',
        `学业情况_${dateStr}`);
      this.getUIContext().getPromptAction().showToast({ message: result.message });
    } finally {
      this.exportingImage = false;
    }
  }
  private currentGpa(): number {
    // report.gpa 来自 xsxyqk 学业情况接口（南医大未部署，常为 0）；
    // 为 0 时回退到总体成绩统计的累计绩点（成绩明细加权计算，真实可靠）。
    if (this.report.gpa > 0) {
      return this.report.gpa;
    }
    if (this.overallStats !== null) {
      const g: number = Number(this.overallStats.gpa);
      if (!Number.isNaN(g) && g > 0) {
        return g;
      }
    }
    return 0;
  }

  /** 学业总评成绩数值：官方体检单直出优先（officialOverall），其次计算值 overallScore，无则 -1 */
  private currentOverallScore(): number {
    if (this.overallStats === null) {
      return -1;
    }
    if (this.overallStats.officialOverall.length > 0) {
      const v: number = Number(this.overallStats.officialOverall);
      if (!Number.isNaN(v)) {
        return v;
      }
    }
    return this.overallStats.overallScore;
  }

  /** 基于成绩明细（overallCourses，覆盖全部学期）统计真实修读情况。
   *  学业情况页（xsxyqk）南医大未开放，report 里的门数恒为 0，
   *  因此「已修/未通过」改用成绩明细统计，「未修/在读」无可靠数据源时回退 report。 */
  private gradeStats(): GradeStats {
    let passed: number = 0;
    let failed: number = 0;
    let totalCredit: number = 0;
    const scores: ScoreItem[] = this.overallCourses.length > 0 ? this.overallCourses : [];
    for (const s of scores) {
      const digits: string = JwApi.scoreDigitsText(s.scoreText);
      const num: number = digits.length > 0 ? Number(digits) : -1;
      const gradeText: string = s.scoreText.replace(/\s/g, '');
      const isFailed: boolean = gradeText.indexOf('不及格') >= 0 || gradeText.indexOf('不合格') >= 0;
      const isPass: boolean = gradeText.length > 0 && digits.length === 0 &&
        (gradeText.indexOf('优') >= 0 || gradeText.indexOf('良') >= 0 || gradeText.indexOf('中') >= 0 ||
          gradeText.indexOf('及格') >= 0 || gradeText.indexOf('合格') >= 0 || gradeText.indexOf('通过') >= 0 ||
          gradeText.indexOf('免修') >= 0 || gradeText.indexOf('缓考') >= 0);
      if (gradeText.length === 0) {
        continue; // 无成绩记录（在读/未出分），不计
      }
      if (digits.length > 0 && num >= 0 && num < 60) {
        failed++;
      } else if (isFailed) {
        failed++;
      } else {
        passed++;
        totalCredit += s.credit;
      }
    }
    return { passed: passed, failed: failed, totalCredit: totalCredit };
  }

  /** 未通过门数：优先用官方体检单「不及格课程 N 门」（权威直出），
   *  其次成绩明细统计（真实），最后回退 report.failedCount。 */
  private failedCountOf(): number {
    if (this.overallStats !== null && this.overallStats.failedCount >= 0) {
      return this.overallStats.failedCount;
    }
    const g: GradeStats = this.gradeStats();
    if (this.overallCourses.length > 0) {
      return g.failed;
    }
    return this.report.failedCount;
  }

  /** 已修（通过）门数：优先用成绩明细统计，无明细时回退 report.totalEarned */
  private passedCountOf(): number {
    const g: GradeStats = this.gradeStats();
    if (this.overallCourses.length > 0) {
      return g.passed;
    }
    return this.report.totalEarned;
  }

  /** 在读门数：优先用培养方案（教学执行计划）计算的真实值，回退 report */
  private studyingCountOf(): number {
    if (this.planProgress !== null && this.planProgress.available) {
      return this.planProgress.studyingCount;
    }
    return this.report.studyingCount;
  }

  /** 未修门数：优先用培养方案计算的真实值，回退 report */
  private unearnedCountOf(): number {
    if (this.planProgress !== null && this.planProgress.available) {
      return this.planProgress.unearnedCount;
    }
    return this.report.unearnedCount;
  }

  /** 判断某条成绩是否为「未通过」（百分制<60 或等级制不及格/不合格） */
  private isScoreFailed(s: ScoreItem): boolean {
    const digits: string = JwApi.scoreDigitsText(s.scoreText);
    const num: number = digits.length > 0 ? Number(digits) : -1;
    const gradeText: string = s.scoreText.replace(/\s/g, '');
    if (digits.length > 0 && num >= 0 && num < 60) {
      return true;
    }
    return gradeText.indexOf('不及格') >= 0 || gradeText.indexOf('不合格') >= 0;
  }

  /** 判断某条成绩是否为「已通过」（有成绩且非未通过、非无成绩） */
  private isScorePassed(s: ScoreItem): boolean {
    const digits: string = JwApi.scoreDigitsText(s.scoreText);
    const gradeText: string = s.scoreText.replace(/\s/g, '');
    if (gradeText.length === 0) {
      return false; // 无成绩记录（在读/未出分）
    }
    return !this.isScoreFailed(s);
  }

  /** 已通过课程列表（供点击弹窗展示） */
  private passedCourses(): ScoreItem[] {
    const out: ScoreItem[] = [];
    for (const s of this.overallCourses) {
      if (this.isScorePassed(s)) {
        out.push(s);
      }
    }
    return out;
  }

  /** 未通过课程列表（供点击弹窗展示） */
  private failedCourses(): ScoreItem[] {
    const out: ScoreItem[] = [];
    for (const s of this.overallCourses) {
      if (this.isScoreFailed(s)) {
        out.push(s);
      }
    }
    return out;
  }

  /** 取某条成绩的百分制数值（等级制/无数字返回 -1） */
  private scoreNumber(s: ScoreItem): number {
    const digits: string = JwApi.scoreDigitsText(s.scoreText);
    return digits.length > 0 ? Number(digits) : -1;
  }

  /** 成绩分布档位：0=优(≥90) 1=良(≥80) 2=中(≥70) 3=及(≥60) 4=不及格(<60) -1=无法判定 */
  private scoreBand(s: ScoreItem): number {
    const n: number = this.scoreNumber(s);
    if (n < 0) {
      return -1;
    }
    if (n >= 90) {
      return 0;
    }
    if (n >= 80) {
      return 1;
    }
    if (n >= 70) {
      return 2;
    }
    if (n >= 60) {
      return 3;
    }
    return 4;
  }

  /** 按成绩档位返回课程列表（供成绩分布点击弹窗） */
  private bandCourses(band: number): ScoreItem[] {
    const out: ScoreItem[] = [];
    for (const s of this.overallCourses) {
      if (this.scoreBand(s) === band) {
        out.push(s);
      }
    }
    return out;
  }

  /** 按课程类别（kclbmc/courseType）返回课程列表（供课程分类点击弹窗） */
  private categoryCourses(name: string): ScoreItem[] {
    const out: ScoreItem[] = [];
    for (const s of this.overallCourses) {
      const cat: string = s.kclbmc.length > 0 ? s.kclbmc : s.courseType;
      if (cat === name) {
        out.push(s);
      }
    }
    return out;
  }

  /** 按南医大 2023 版学籍管理规定生成学业提醒（结合学业页统计 + 成绩明细 + 官方体检单）：
   *  1) 必修课程累计 ≥20 学分未取得 → 留降级预警；
   *  2) 累计 ≥8 门必修不及格/无成绩 → 留降级预警；
   *  3) 核心课程平均学分绩点 < 2.0 → 学位授予预警；
   *  4) CET4 未过 425 分 → 提醒；
   *  5) 计算机等级/计算机课程未过 → 提醒；
   *  否则给出正向提示。 */
  private buildWarnings(): string[] {
    const out: string[] = [];
    // 从成绩明细统计必修课程不及格门数与未取得学分（含所有学期成绩）
    let requiredFailedCount: number = 0;
    let requiredFailCredit: number = 0;
    const scores: ScoreItem[] = this.overallCourses.length > 0 ? this.overallCourses : [];
    for (const s of scores) {
      const isRequired: boolean = s.courseType === '必修' || s.kclbmc.indexOf('必修') >= 0;
      if (!isRequired) {
        continue;
      }
      const digits: string = JwApi.scoreDigitsText(s.scoreText);
      const num: number = digits.length > 0 ? Number(digits) : -1;
      // 等级制：只有明确"不及格/不合格"才算未通过；优/良/中/及格/合格/通过均视为通过
      const gradeText: string = s.scoreText.replace(/\s/g, '');
      const isGradeFailed: boolean = gradeText.indexOf('不及格') >= 0 || gradeText.indexOf('不合格') >= 0;
      const isGradePass: boolean = gradeText.length > 0 && digits.length === 0 &&
        (gradeText.indexOf('优') >= 0 || gradeText.indexOf('良') >= 0 || gradeText.indexOf('中') >= 0 ||
          gradeText.indexOf('及格') >= 0 || gradeText.indexOf('合格') >= 0 || gradeText.indexOf('通过') >= 0 ||
          gradeText.indexOf('免修') >= 0 || gradeText.indexOf('缓考') >= 0);
      // 无任何成绩记录（成绩未出/在读课程）不计入未通过
      if (gradeText.length === 0) {
        continue;
      }
      // 不及格：百分制 <60，或等级制明确不及格
      if (digits.length > 0 && num >= 0 && num < 60) {
        requiredFailedCount++;
        requiredFailCredit += s.credit;
      } else if (isGradeFailed) {
        requiredFailedCount++;
        requiredFailCredit += s.credit;
      } else if (isGradePass) {
        // 通过，不计
      }
    }

    // 规则 1：必修累计 20 学分未取得
    if (requiredFailCredit >= 20) {
      out.push(`必修课程累计未取得 ${requiredFailCredit.toFixed(1)} 学分（≥20），按学校规定不能修读下一学年课程，请尽快补考/重修。`);
    } else if (requiredFailCredit > 0) {
      out.push(`必修课程累计未取得 ${requiredFailCredit.toFixed(1)} 学分，请注意距 20 学分的留降级红线。`);
    }

    // 规则 2：累计 8 门必修不及格
    if (requiredFailedCount >= 8) {
      out.push(`累计 ${requiredFailedCount} 门必修课程不及格/无成绩（≥8），按学校规定不能修读下一学年课程，请尽快补考/重修。`);
    } else if (requiredFailedCount > 0) {
      out.push(`累计 ${requiredFailedCount} 门必修课程不及格/无成绩，请注意距 8 门的留降级红线。`);
    }

    // 规则 3：核心课程平均学分绩点 < 2.0 → 学位预警（优先用官方体检单 coreGpa）
    if (this.overallStats !== null) {
      const coreGpa: number = this.overallStats.coreGpa >= 0
        ? this.overallStats.coreGpa
        : Number(this.overallStats.gpa);
      if (!isNaN(coreGpa) && coreGpa > 0 && coreGpa < 2.0) {
        out.push(`核心课程平均学分绩点 ${coreGpa.toFixed(2)} 低于 2.0，可能影响学士学位授予，请重点关注核心课程成绩。`);
      }
    }

    // 规则 4：CET4（等级考试接口优先，其次官方体检单 cet4；≥425 通过）
    const cet4Score: number = this.levelCET4();
    if (cet4Score >= 0) {
      if (cet4Score < 425) {
        out.push(`CET4 成绩 ${cet4Score.toFixed(0)} 分未达 425 分，未满足学位授予外语要求，请尽早重考。`);
      } else {
        out.push(`CET4 已通过（${cet4Score.toFixed(0)} 分，≥425），满足学位授予外语要求。`);
      }
    } else {
      out.push('CET4 成绩暂未录入（可能尚未参加考试），请留意学校报名通知，尽早通过（≥425 分）。');
    }

    // 规则 5：CET6（等级考试接口专属，体检单不含 CET6；≥425 通过，非学位硬要求但鼓励）
    const cet6Score: number = this.levelCET6();
    if (cet6Score >= 0) {
      if (cet6Score < 425) {
        out.push(`CET6 已考 ${cet6Score.toFixed(0)} 分（未达 425），如需报考研究生或求职加分建议重考。`);
      } else {
        out.push(`CET6 已通过（${cet6Score.toFixed(0)} 分，≥425）。`);
      }
    }

    // 规则 6：计算机等级考试（NCRE，等级考试接口；"合格"档即通过）
    if (this.levelExams !== null && this.levelExams.hasData) {
      if (this.levelExams.computerPassed) {
        out.push(`计算机等级考试已通过（${this.levelExams.computerName}），满足计算机能力要求。`);
      } else {
        out.push('计算机等级考试（NCRE）尚未通过，部分专业为学位授予/毕业要求，请留意报名并尽早通过。');
      }
    } else {
      out.push('计算机等级考试（NCRE）暂无成绩记录，部分专业为学位授予/毕业要求，请留意报名通知。');
    }

    // 计划内未通过：优先用官方体检单「不及格课程 N 门」直出值（权威），
    // 缺失时用成绩明细统计的全部未通过门数（含非必修）。不再依赖未开放的学业页 report.failedCount。
    const officialFailed: number = this.failedCountOf();
    if (officialFailed > 0 && requiredFailedCount === 0) {
      out.push(`计划内未通过课程 ${officialFailed} 门（教务处体检单统计），建议尽快补考/重修。`);
    }

    // 培养方案修读进度（教学执行计划计算）：未修/在读门数真实值
    if (this.planProgress !== null && this.planProgress.available) {
      const pp: PlanProgress = this.planProgress;
      if (pp.unearnedCount > 0) {
        out.push(`培养方案内还有 ${pp.unearnedCount} 门课程未修（计划共 ${pp.totalRequired} 门，已通过 ${pp.totalEarned} 门、在读 ${pp.studyingCount} 门）。`);
      } else if (pp.studyingCount > 0) {
        out.push(`培养方案课程已全部修读，当前 ${pp.studyingCount} 门在读中，按计划推进即可。`);
      }
    }

    // 无任何风险时给正向提示（此时仅可能剩正向的 CET4/计算机提示）
    if (out.length === 0) {
      out.push('当前学业状态良好，必修课程与平均学分绩点均达标，请继续保持。');
    }
    return out;
  }

  /** CET4 最优成绩：等级考试接口优先，其次官方体检单 cet4，无则 -1 */
  private levelCET4(): number {
    if (this.levelExams !== null && this.levelExams.cet4 >= 0) {
      return this.levelExams.cet4;
    }
    if (this.overallStats !== null && this.overallStats.cet4 >= 0) {
      return this.overallStats.cet4;
    }
    return -1;
  }

  /** CET6 最优成绩（仅等级考试接口有，体检单不含 CET6），无则 -1 */
  private levelCET6(): number {
    if (this.levelExams !== null && this.levelExams.cet6 >= 0) {
      return this.levelExams.cet6;
    }
    return -1;
  }

  /** 等级考试单条成绩展示文本：CET 显示分数（去掉 .00），计算机显示"合格/良好"等原值，空显示"--" */
  private levelExamScoreText(it: LevelExamItem): string {
    if (it.score.length === 0) {
      return '--';
    }
    if (it.categoryCode === '05') {
      // CET：数字字符串"368.00"→ 去掉小数尾
      const num: number = Number(it.score);
      if (!isNaN(num)) {
        return `${num.toFixed(0)}`;
      }
    }
    return it.score;
  }

  /** 等级考试单条成绩颜色：通过→品牌色，未通过→警示色，无成绩→灰 */
  private levelExamPassedColor(it: LevelExamItem): ResourceColor {
    if (it.score.length === 0) {
      return $r('app.color.text_tertiary');
    }
    if (it.categoryCode === '05') {
      // CET ≥425 通过
      const num: number = Number(it.score);
      if (!isNaN(num)) {
        return num >= 425 ? $r('app.color.brand') : $r('app.color.state_danger');
      }
      return $r('app.color.text_primary');
    }
    if (it.categoryCode === '08') {
      // 计算机"合格"档即通过：合格/良好/优秀/中等/及格/通过 等非"不及格/不合格"
      const t: string = it.score.replace(/\s/g, '');
      const isFailed: boolean = t.indexOf('不及格') >= 0 || t.indexOf('不合格') >= 0;
      const isPass: boolean = t.length > 0 && !isFailed;
      return isPass ? $r('app.color.brand') : $r('app.color.state_danger');
    }
    return $r('app.color.text_primary');
  }

  /** 其他成绩列表：仅保留 四六级（CET）/ 计算机等级 / 普通话水平测试 结果 */
  private otherExamItems(): LevelExamItem[] {
    if (this.levelExams === null || !this.levelExams.hasData) {
      return [];
    }
    const out: LevelExamItem[] = [];
    for (const it of this.levelExams.items) {
      const key: string = `${it.categoryName}${it.name}`;
      if (key.indexOf('CET') >= 0 || key.indexOf('四') >= 0 || key.indexOf('六') >= 0 ||
          key.indexOf('计算机') >= 0 || key.indexOf('普通话') >= 0) {
        out.push(it);
      }
    }
    return out;
  }

  /** 各课程分类：优先基于成绩明细（overallCourses）的 kclbmc/courseType 统计
   *  （学业情况页 xsxyqk 南医大未开放，report.categories 恒为空，不可用）。
   *  返回分类名 + 已修学分（required 表示该分类总学分，此处无培养方案数据，用已修学分回填）。 */
  private categories(): CreditCategory[] {
    // 按成绩明细（overallCourses）的 kclbmc/courseType 归并统计：
    // 分类名来自教务成绩的「课程类别」（含 通识选修课A/B/C/D类 等真实类别），
    // 点击分类时用同名 kclbmc 过滤成绩明细，保证弹窗有数据。
    // 应修学分：用培养方案（教学执行计划 N153540 xdyq 页）的类别应修学分（jdkcxf）
    // 按名称匹配回填；匹配不上的分类 required=0（UI 只显示已修学分，不虚标应修）。
    if (this.overallCourses.length > 0) {
      const names: string[] = [];
      const credits: number[] = [];
      for (const s of this.overallCourses) {
        if (!this.isScorePassed(s)) {
          continue; // 只统计已通过课程学分
        }
        const cat: string = s.kclbmc.length > 0 ? s.kclbmc : s.courseType;
        const key: string = cat.length > 0 ? cat : '其他';
        let idx: number = names.indexOf(key);
        if (idx < 0) {
          names.push(key);
          credits.push(0);
          idx = names.length - 1;
        }
        credits[idx] += s.credit;
      }
      const out: CreditCategory[] = [];
      for (let i: number = 0; i < names.length; i++) {
        out.push({ name: names[i], required: 0, earned: credits[i] });
      }
      // 应修学分：培养方案类别（jdkcxf）按名称匹配（精确 / 归一化去空格 / 互相包含）
      if (this.planProgress !== null && this.planProgress.available) {
        for (const cat of out) {
          for (const pc of this.planProgress.categories) {
            if (pc.required <= 0) {
              continue;
            }
            const a: string = cat.name.replace(/\s/g, '');
            const b: string = pc.name.replace(/\s/g, '');
            if (a === b || (a.length > 1 && b.length > 1 && (a.indexOf(b) >= 0 || b.indexOf(a) >= 0))) {
              cat.required = pc.required;
              break;
            }
          }
        }
      }
      return out;
    }
    return this.report.categories;
  }

  @Builder
  gpaCard() {
    // MaterialCard 承载：材质层是卡片内部底层、与卡片同尺寸同圆角，材质生效时卡片底色/磨砂/亮边/阴影让出；
    // 原 20vp 内边距走 cardPadding、18vp 圆角走 cardRadius、左对齐走 cardAlignItems。
    MaterialCard({
      cardRadius: 18,
      cardPadding: 20,
      cardAlignItems: ItemAlign.Start,
      cardBg: GlassMaterial.homeCardBg($r('app.color.bg_card')),
      cardBlur: GlassMaterial.cardBlur(),
      cardBorderW: GlassMaterial.cardBorderWidth(),
      cardBorderC: GlassMaterial.borderColor(),
      cardShadow: GlassMaterial.cardShadowStyle()
    }) {
    Column() {
      Row() {
        Text(this.gpaCardMode === 'overall' ? '学业总评成绩' : '平均学分绩点（GPA）')
          .fontSize(13)
          .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
        Blank()
        // 导出学业情况图片（选择模块）
        Text('导出')
          .fontSize(11)
          .fontColor($r('app.color.brand'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .border({ width: 1, color: $r('app.color.brand') })
          .borderRadius(10)
          .margin({ right: 8 })
          .onClick(() => {
            this.openExportSheet();
          })
        // 显示内容切换：绩点 ⇄ 总评（持久化，下次进入保持所选）
        Text(this.gpaCardMode === 'overall' ? '切换为绩点' : '切换为总评')
          .fontSize(11)
          .fontColor($r('app.color.brand'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .border({ width: 1, color: $r('app.color.brand') })
          .borderRadius(10)
          .onClick(() => {
            this.gpaCardMode = this.gpaCardMode === 'overall' ? 'gpa' : 'overall';
            DataStore.put(DataStore.KEY_GPA_CARD_MODE, this.gpaCardMode);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.gpaCardMode === 'overall' && this.currentOverallScore() >= 0) {
        Row() {
          Text(this.currentOverallScore().toFixed(2))
            .fontSize(48)
            .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
            .fontColor($r('app.color.brand'))
          Text('分')
            .fontSize(16)
            .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .margin({ left: 6, bottom: 8 })
        }
        .alignItems(VerticalAlign.Bottom)
        .margin({ top: 4 })
      } else {
        Row() {
          Text(this.currentGpa().toFixed(2))
            .fontSize(48)
            .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
            .fontColor($r('app.color.brand'))
          Text('/ 5.0')
            .fontSize(16)
            .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .margin({ left: 6, bottom: 8 })
        }
        .alignItems(VerticalAlign.Bottom)
        .margin({ top: 4 })
      }

      Text(this.gpaCardMode === 'overall'
        ? 'CC×70% + NC×30%（2023级起，教务处官方体检单直出）'
        : `数据来源: 教务系统学业页（统计时间 ${new Date().toLocaleDateString('zh-CN')}）`)
        .fontSize(11)
        .fontColor(WallpaperTone.onWallpaperSecondary(this.wallpaperTone, this.isDarkMode))
        .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    }
  }

  /** 成绩查询二级入口卡：学业总评/等级考试上移后，各学期成绩明细从这里进入 */
  @Builder
  scoreEntry() {
    MaterialCard({
      cardRadius: 18,
      cardPadding: 14,
      cardBg: GlassMaterial.homeCardBg($r('app.color.bg_card')),
      cardBlur: GlassMaterial.cardBlur(),
      cardBorderW: GlassMaterial.cardBorderWidth(),
      cardBorderC: GlassMaterial.borderColor(),
      cardShadow: GlassMaterial.cardShadowStyle(),
      cardMargin: { top: 14 },
      cardOnClick: (): void => {
        AppState.stack.pushPath({ name: Const.ROUTE_SCORE });
      }
    }) {
    Row() {
      Column() {
        Text('成绩查询')
          .fontSize(15)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
          .fontColor($r('app.color.text_primary'))
        Text('各学期成绩明细 · 绩点 · 排序与统计')
          .fontSize(11)
          .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      ChevronRight({ iconSize: 13 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  overviewRow() {
    // MaterialCard 承载：原卡片上下 18vp 内边距（不对称）挂内部内容容器，18vp 圆角走 cardRadius、
    // 14vp 上间距走 cardMargin。
    MaterialCard({
      cardRadius: 18,
      cardBg: GlassMaterial.homeCardBg($r('app.color.bg_card')),
      cardBlur: GlassMaterial.cardBlur(),
      cardBorderW: GlassMaterial.cardBorderWidth(),
      cardBorderC: GlassMaterial.borderColor(),
      cardShadow: GlassMaterial.cardShadowStyle(),
      cardMargin: { top: 14 }
    }) {
    Row() {
      StatCell({
        value: `${this.passedCountOf()}`,
        label: '已修',
        color: $r('app.color.brand'),
        onTap: (): void => { this.openStatSheet('passed', '已修课程（通过）'); }
      })
      Divider()
        .vertical(true)
        .height(28)
        .color($r('app.color.divider'))
      StatCell({
        value: `${this.studyingCountOf()}`,
        label: '在读',
        color: $r('app.color.accent_blue'),
        onTap: (): void => { this.openStatSheet('studying', '在读课程'); }
      })
      Divider()
        .vertical(true)
        .height(28)
        .color($r('app.color.divider'))
      StatCell({
        value: `${this.unearnedCountOf()}`,
        label: '未修',
        color: $r('app.color.accent_orange'),
        onTap: (): void => { this.openStatSheet('unearned', '未修课程'); }
      })
      Divider()
        .vertical(true)
        .height(28)
        .color($r('app.color.divider'))
      StatCell({
        value: `${this.failedCountOf()}`,
        label: '未通过',
        color: this.failedCountOf() > 0 ? $r('app.color.state_danger') : $r('app.color.text_primary'),
        onTap: (): void => { this.openStatSheet('failed', '未通过课程'); }
      })
    }
    .width('100%')
    .padding({ top: 18, bottom: 18 })
    }
  }

  /** 打开统计明细弹窗（按 kind 动态查询课程） */
  private openStatSheet(kind: string, title: string): void {
    this.statSheetKind = kind;
    this.statSheetTitle = title;
    this.statSheetHint = '';
    this.statSheetNames = [];
    // 在读/未修：优先用培养方案计算的真实课程名列表
    if (kind === 'studying' && this.planProgress !== null && this.planProgress.available) {
      this.statSheetNames = this.planProgress.studyingNames;
    } else if (kind === 'unearned' && this.planProgress !== null && this.planProgress.available) {
      this.statSheetNames = this.planProgress.unearnedNames;
    }
    this.statSheetList = this.statSheetCourses();
    this.showStatSheet = true;
  }

  /** 打开预置课程列表的弹窗（成绩分布档位 / 课程分类等，列表已预先计算） */
  private openListSheet(title: string, list: ScoreItem[], hint: string): void {
    this.statSheetKind = 'list';
    this.statSheetTitle = title;
    this.statSheetHint = hint;
    this.statSheetList = list;
    this.showStatSheet = true;
  }

  /** 课程是否已在手动已修白名单 */
  private isWhitelisted(name: string): boolean {
    return this.planWhitelist.indexOf(name) >= 0;
  }

  /** 标记课程为已修（加入白名单），并重新拉取培养方案统计刷新数字 */
  private markPassed(name: string): void {
    if (this.isWhitelisted(name)) {
      return;
    }
    this.planWhitelist = DataStore.addPlanPassCourse(name);
    this.getUIContext().getPromptAction().showToast({ message: `已标记「${name}」为已修` });
    // 重新计算培养方案统计（白名单变化会影响未修/已通过数字）
    this.reloadPlanProgress();
  }

  /** 取消课程已修标记（移出白名单） */
  private unmarkPassed(name: string): void {
    this.planWhitelist = DataStore.removePlanPassCourse(name);
    this.getUIContext().getPromptAction().showToast({ message: `已取消「${name}」的已修标记` });
    this.reloadPlanProgress();
  }

  /** 白名单变化后重新拉取培养方案统计（缓存会被新白名单覆盖） */
  private reloadPlanProgress(): void {
    // 清除缓存，强制重新计算（白名单变化会影响结果）
    DataStore.remove(DataStore.KEY_PLAN_PROGRESS);
    JwApi.getPlanProgress().then((pp: PlanProgress): void => {
      this.planProgress = pp;
    }).catch((): void => {
    });
  }

  /** 统计明细弹窗对应的课程列表 */
  private statSheetCourses(): ScoreItem[] {
    if (this.statSheetKind === 'failed') {
      return this.failedCourses();
    }
    if (this.statSheetKind === 'passed') {
      return this.passedCourses();
    }
    // 在读/未修：成绩明细无直接数据源，返回空（弹窗内展示说明）
    return [];
  }

  /** 统计明细半模态弹窗（已修/未通过的具体课程清单；在读/未修暂无数据源时给说明） */
  @Builder
  statSheet() {
    MaterialSheetPanel({ panelRadius: 20, panelPadding: 0, panelFillHeight: false, panelTitle: this.statSheetTitle, panelShowClose: true, panelOnClose: (): void => { this.showStatSheet = false; } }) {
    Column() {
      if (this.statSheetKind === 'studying' || this.statSheetKind === 'unearned') {
        if (this.statSheetNames.length > 0) {
          // 有培养方案计算的真实课程名列表：展示课程清单，支持手动标记已修（写入本地白名单）
          Text(this.statSheetKind === 'unearned'
            ? '以下为培养方案内尚未修读的课程。可点右侧「标记已修」手动记为已修（本地白名单，随时可取消）。'
            : '以下为培养方案内正在修读的课程。可点右侧「标记已修」手动记为已修（本地白名单，随时可取消）。')
            .fontSize(12)
            .lineHeight(18)
            .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .width('100%')
            .padding({ left: 20, right: 20, top: 4, bottom: 8 })
          List() {
            ForEach(this.statSheetNames, (nm: string, idx: number) => {
              ListItem() {
                Row() {
                  Column()
                    .width(4)
                    .height(20)
                    .borderRadius(2)
                    .backgroundColor(this.statSheetKind === 'studying' ? $r('app.color.accent_blue') : $r('app.color.accent_orange'))
                  Text(nm)
                    .fontSize(14)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ left: 12 })
                    .layoutWeight(1)
                  // 「标记已修 / 取消」：用户自定义课程为已修（写入本地白名单，持久化）
                  Text(this.isWhitelisted(nm) ? '已标记' : '标记已修')
                    .fontSize(12)
                    .fontColor(this.isWhitelisted(nm) ? $r('app.color.brand') : $r('app.color.text_secondary'))
                    .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                    .borderRadius(12)
                    .backgroundColor(this.isWhitelisted(nm) ? $r('app.color.brand_light') : $r('app.color.bg_chip'))
                    .margin({ left: 8 })
                    .onClick(() => {
                      if (this.isWhitelisted(nm)) {
                        this.unmarkPassed(nm);
                      } else {
                        this.markPassed(nm);
                      }
                    })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                .padding({ top: 9, bottom: 9 })
              }
            }, (nm: string, idx: number) => `${idx}_${nm}`)
          }
          .width('100%')
          .height(320)
          .scrollBar(BarState.Off)
          .divider({ strokeWidth: 0.5, color: $r('app.color.divider') })
          .padding({ left: 20, right: 20, bottom: 8 })
        } else {
          // 无数据源（培养方案未下发）：给说明
          Text(this.statSheetKind === 'studying'
            ? '在读课程指本学期已选但尚未出成绩的课程；由于培养方案未下发，当前无法精确获取，请在教务系统课程表/选课界面查看。'
            : '未修课程指培养方案内尚未修读的课程；由于培养方案未下发，当前无法精确获取，请在教务系统培养方案查看。')
            .fontSize(13)
            .lineHeight(21)
            .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .width('100%')
            .padding({ left: 20, right: 20, top: 4, bottom: 20 })
        }
      } else if (this.statSheetList.length === 0) {
        Text(this.statSheetHint.length > 0 ? this.statSheetHint : '暂无相关课程记录')
          .fontSize(13)
          .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          .width('100%')
          .padding({ left: 20, right: 20, top: 4, bottom: 20 })
      } else {
        List() {
          ForEach(this.statSheetList, (s: ScoreItem) => {
            ListItem() {
              Row() {
                Column()
                  .width(4)
                  .height(20)
                  .borderRadius(2)
                  .backgroundColor(this.statSheetKind === 'failed' ? $r('app.color.state_danger') : $r('app.color.brand'))
                Column() {
                  Text(s.courseName)
                    .fontSize(14)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Row() {
                    Text(`${s.credit.toFixed(1)}学分`)
                      .fontSize(11)
                      .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                    Text(s.courseType.length > 0 ? ` · ${s.courseType}` : '')
                      .fontSize(11)
                      .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                  }
                  .margin({ top: 2 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Text(s.scoreText)
                  .fontSize(14)
                  .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                  .fontColor(this.statSheetKind === 'failed' ? $r('app.color.state_danger') : $r('app.color.text_primary'))
                  .margin({ left: 10 })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ top: 9, bottom: 9 })
            }
          }, (s: ScoreItem) => s.id)
        }
        .width('100%')
        .height(320)
        .scrollBar(BarState.Off)
        .divider({ strokeWidth: 0.5, color: $r('app.color.divider') })
        .padding({ left: 20, right: 20, bottom: 8 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  categorySection() {
    // MaterialCard 承载：原 18vp 内边距走 cardPadding、18vp 圆角走 cardRadius、14vp 上间距走 cardMargin
    MaterialCard({
      cardRadius: 18,
      cardPadding: 18,
      cardBg: GlassMaterial.homeCardBg($r('app.color.bg_card')),
      cardBlur: GlassMaterial.cardBlur(),
      cardBorderW: GlassMaterial.cardBorderWidth(),
      cardBorderC: GlassMaterial.borderColor(),
      cardShadow: GlassMaterial.cardShadowStyle(),
      cardMargin: { top: 14 }
    }) {
    Column() {
      Row() {
        Text('课程分类与修读情况')
          .fontSize(16)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')
      .margin({ bottom: 14 })

      ForEach(this.categories(), (item: CreditCategory, index: number) => {
        Column() {
          Row() {
            Text(item.name)
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
            Blank()
            Text(item.required > 0 ? `已修 ${item.earned.toFixed(1)} / 应修 ${item.required.toFixed(1)} 学分` : `${item.earned.toFixed(1)} 学分`)
              .fontSize(12)
              .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            Text('  ›')
              .fontSize(13)
              .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          }
          .width('100%')

          // 学分完成进度条（应修 > 0 时展示）
          if (item.required > 0) {
            Row() {
              Stack({ alignContent: Alignment.Start }) {
                Row()
                  .width('100%')
                  .height(6)
                  .borderRadius(3)
                  .backgroundColor($r('app.color.divider'))
                Row()
                  .width(`${Math.min(100, item.required > 0 ? item.earned / item.required * 100 : 0)}%`)
                  .height(6)
                  .borderRadius(3)
                  .backgroundColor($r('app.color.brand'))
              }
              .width('100%')
              .height(6)
            }
            .width('100%')
            .margin({ top: 8 })
          }
        }
        .width('100%')
        .padding({ top: 10, bottom: 10 })
        .margin({ bottom: 2 })
        .onClick((): void => {
          const list: ScoreItem[] = this.categoryCourses(item.name);
          this.openListSheet(`「${item.name}」课程（${list.length} 门）`, list,
            this.overallCourses.length === 0 ? '教务未开放课程修读数据，当前为示例数据，无法展示真实课程清单。' : '');
        })
      }, (item: CreditCategory) => item.name)
    }
    .width('100%')
    }
  }

  @Builder
  warningSection() {
    // MaterialCard 承载：原 18vp 内边距走 cardPadding、18vp 圆角走 cardRadius、14vp 上间距走 cardMargin；
    // 提醒条目里的序号圆圈（实色浅底）保留原写法（材质卡内部不再叠第二层材质）。
    MaterialCard({
      cardRadius: 18,
      cardPadding: 18,
      cardBg: GlassMaterial.homeCardBg($r('app.color.bg_card')),
      cardBlur: GlassMaterial.cardBlur(),
      cardBorderW: GlassMaterial.cardBorderWidth(),
      cardBorderC: GlassMaterial.borderColor(),
      cardShadow: GlassMaterial.cardShadowStyle(),
      cardMargin: { top: 14 }
    }) {
    Column() {
      Row() {
        Text('学业提醒')
          .fontSize(16)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')
      .margin({ bottom: 10 })

      ForEach(this.buildWarnings(), (text: string, index: number) => {
        Stack({ alignContent: Alignment.Start }) {
          // 序号圆圈：固定在左上（Stack 定位，不受文本行数影响）
          Row() {
            Text(`${index + 1}`)
              .fontSize(11)
              .fontColor($r('app.color.state_warn'))
              .width(18)
              .height(18)
              .lineHeight(18)
              .textAlign(TextAlign.Center)
              .backgroundColor($r('app.color.bg_chip')).backgroundBlurStyle(GlassMaterial.cardBlur()).border({ width: GlassMaterial.cardBorderWidth(), color: GlassMaterial.borderColor() }).shadow(GlassMaterial.cardShadowStyle()).clip(true)
              .borderRadius(9)
          }
          .width(18)
          .height(18)
          .position({ x: 0, y: 0 })

          // 文字：左侧预留 28vp 给序号圆圈，width 100% 自然换行
          Text(text)
            .fontSize(13)
            .lineHeight(21)
            .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .margin({ left: 28 })
            .width('100%')
        }
        .width('100%')
        .margin({ bottom: 10 })
      }, (text: string) => text)
    }
    .width('100%')
    }
  }

  /** 导出模块选择面板：勾选要导出的模块（学业概览 / 课程明细 / 学业提醒） */
  @Builder
  exportSheet() {
    MaterialSheetPanel({ panelRadius: 20, panelPadding: 0, panelFillHeight: false,
      panelTitle: '选择要导出的内容', panelShowClose: true, panelOnClose: (): void => { this.showExportSheet = false; } }) {
    Column() {
      Text('勾选要导出到图片中的模块（可多选）')
        .fontSize(12)
        .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
        .width('100%')
        .padding({ left: 20, right: 20, top: 4, bottom: 8 })

      Column() {
        this.exportModuleRow('overview', '学业概览', 'GPA · 学业总评 · 已修/在读/未修/未通过 · 成绩分布')
        this.exportModuleRow('detail', '课程明细', '各学期课程成绩 · 学分 · 绩点')
        this.exportModuleRow('warning', '学业提醒', '留降级/学位/CET 等预警提示')
      }
      .width('100%')
      .padding({ left: 20, right: 20 })

      MaterialButton({
        btnRadius: 12,
        btnBg: '#1B3A63',
        btnBlur: this.glassEnabled ? BlurStyle.Thin : BlurStyle.NONE,
        btnBorderW: 1,
        btnBorderC: 'rgba(255,255,255,0.28)',
        btnMargin: { top: 16, left: 20, right: 20, bottom: 24 },
        btnOnClick: () => { this.exportAcademicImage(); }
      }) {
        Text(this.exportingImage ? '生成中…' : '导出图片')
          .fontSize(15)
          .fontColor('#FFFFFF')
          .width('100%')
          .height(44)
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    }
  }

  /** 导出模块勾选行 */
  @Builder
  exportModuleRow(key: string, title: string, desc: string) {
    Row() {
      Column() {
        Text(title)
          .fontSize(15)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
          .fontColor($r('app.color.text_primary'))
        Text(desc)
          .fontSize(11)
          .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Row()
        .width(20)
        .height(20)
        .borderRadius(10)
        .border({ width: 1.5, color: this.isExportModule(key) ? $r('app.color.brand') : $r('app.color.divider') })
        .backgroundColor(this.isExportModule(key) ? $r('app.color.brand') : Color.Transparent)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .margin({ left: 12 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 12, bottom: 12 })
    .onClick(() => { this.toggleExportModule(key); })
  }

  /** 计算学分完成百分比（0-100，超 100 截断） */
  /** 总体（累计）成绩卡片：累计绩点 / 已修学分 / 总课程 */
  @Builder
  overallCard() {
    // MaterialCard 承载：原 18vp 内边距走 cardPadding、18vp 圆角走 cardRadius、14vp 上间距走 cardMargin
    MaterialCard({
      cardRadius: 18,
      cardPadding: 18,
      cardBg: GlassMaterial.homeCardBg($r('app.color.bg_card')),
      cardBlur: GlassMaterial.cardBlur(),
      cardBorderW: GlassMaterial.cardBorderWidth(),
      cardBorderC: GlassMaterial.borderColor(),
      cardShadow: GlassMaterial.cardShadowStyle(),
      cardMargin: { top: 14 }
    }) {
    Column() {
      Row() {
        Text('总体成绩')
          .fontSize(16)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
          .fontColor($r('app.color.text_primary'))
        Blank()
        // 学业总评成绩被隐藏时的常驻恢复入口（卡片隐藏后唯一的找回途径）
        if (!this.showOverallScore) {
          Text('其他成绩已隐藏 · 恢复')
            .fontSize(11)
            .fontColor($r('app.color.brand'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .border({ width: 1, color: $r('app.color.brand') })
            .borderRadius(10)
            .margin({ right: 8 })
            .onClick(() => {
              this.showOverallScore = true;
              DataStore.put(DataStore.KEY_SHOW_OVERALL_SCORE, '1');
            })
        }
        // 教务未开放总体统计时回落示例数据，加角标防误解
        if (this.overallStats === null) {
          Text('示例数据')
            .fontSize(10)
            .fontColor(Theme.colorOf(this.themeColor))
            .border({ width: 1, color: Theme.colorOf(this.themeColor) })
            .borderRadius(8)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ right: 6 })
        }
        Text(`共 ${this.displayStats().courseCount} 门`)
          .fontSize(11)
          .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
      }
      .width('100%')
      .margin({ bottom: 12 })

      Row() {
        StatCell({
          value: this.displayStats().gpa,
          label: '累计绩点'
        })
        StatCell({
          value: this.displayStats().credits,
          label: '已修学分'
        })
        StatCell({
          value: `${this.displayStats().courseCount}`,
          label: '总课程'
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    }
  }

  /** 其他成绩卡片：四六级 / 计算机等级 / 普通话水平测试（原「学业总评成绩」卡，
   *  总评数值已上移至顶部 GPA 卡可切换展示，此卡只保留等级考试类结果） */
  @Builder
  overallScoreCard() {
    // MaterialCard 承载：原 18vp 内边距走 cardPadding、18vp 圆角走 cardRadius、14vp 上间距走 cardMargin
    MaterialCard({
      cardRadius: 18,
      cardPadding: 18,
      cardBg: GlassMaterial.homeCardBg($r('app.color.bg_card')),
      cardBlur: GlassMaterial.cardBlur(),
      cardBorderW: GlassMaterial.cardBorderWidth(),
      cardBorderC: GlassMaterial.borderColor(),
      cardShadow: GlassMaterial.cardShadowStyle(),
      cardMargin: { top: 14 }
    }) {
    Column() {
      Row() {
        Text('其他成绩')
          .fontSize(16)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
          .fontColor($r('app.color.text_primary'))
        Blank()
        // 隐藏按钮：点击后卡片整体隐藏，改由上方「总体成绩」卡内的常驻恢复入口重新显示
        Text('隐藏')
          .fontSize(12)
          .fontColor($r('app.color.brand'))
          .onClick(() => {
            this.showOverallScore = false;
            DataStore.put(DataStore.KEY_SHOW_OVERALL_SCORE, '0');
          })
      }
      .width('100%')
      .margin({ bottom: 12 })

      if (this.otherExamItems().length > 0) {
          Row() {
            Text('等级考试')
              .fontSize(11)
              .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
              .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          }
          .width('100%')
          .margin({ top: 14, bottom: 4 })

          ForEach(this.otherExamItems(), (it: LevelExamItem) => {
            Row() {
              Column() {
                Text(it.name.length > 0 ? it.name : '等级考试')
                  .fontSize(13)
                  .fontColor($r('app.color.text_primary'))
                if (it.examTime.length > 0) {
                  Text(it.examTime.length >= 10 ? it.examTime.substring(0, 10) : it.examTime)
                    .fontSize(10)
                    .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                    .margin({ top: 2 })
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Text(this.levelExamScoreText(it))
                .fontSize(14)
                .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                .fontColor(this.levelExamPassedColor(it))
                .margin({ left: 10 })
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
          }, (it: LevelExamItem) => it.id.length > 0 ? it.id : `${it.name}-${it.examTime}`)

        Text('数据来源：教务系统「等级考试」报名成绩（四六级 / 计算机等级 / 普通话水平测试）')
          .fontSize(10)
          .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          .width('100%')
          .margin({ top: 12 })
      } else {
        // 无数据：提示
        Text('暂无四六级 / 计算机等级 / 普通话水平测试成绩记录')
          .fontSize(12)
          .lineHeight(20)
          .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          .width('100%')
      }
    }
    .width('100%')
    }
  }

  /** 成绩分布（优 ≥90 / 良 ≥80 / 中 ≥70 / 及 ≥60），移植自参考项目「成绩分布」 */
  @Builder
  distributionSection() {
    // MaterialCard 承载：原 18vp 内边距走 cardPadding、18vp 圆角走 cardRadius、14vp 上间距走 cardMargin
    MaterialCard({
      cardRadius: 18,
      cardPadding: 18,
      cardBg: GlassMaterial.homeCardBg($r('app.color.bg_card')),
      cardBlur: GlassMaterial.cardBlur(),
      cardBorderW: GlassMaterial.cardBorderWidth(),
      cardBorderC: GlassMaterial.borderColor(),
      cardShadow: GlassMaterial.cardShadowStyle(),
      cardMargin: { top: 14 }
    }) {
    Column() {
      Row() {
        Text('成绩分布')
          .fontSize(16)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
          .fontColor($r('app.color.text_primary'))
        Blank()
        // 教务未开放总体统计时回落示例数据，加角标防误解
        if (this.overallStats === null) {
          Text('示例数据')
            .fontSize(10)
            .fontColor(Theme.colorOf(this.themeColor))
            .border({ width: 1, color: Theme.colorOf(this.themeColor) })
            .borderRadius(8)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ right: 6 })
        }
        Text('按已统计课程划分')
          .fontSize(11)
          .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
      }
      .width('100%')
      .margin({ bottom: 12 })

      // 分段条：按门数占比
      Row() {
        if (this.distTotal() > 0) {
          Row()
            .layoutWeight(this.distCount(0) > 0 ? this.distCount(0) : 0.0001)
            .height(8)
            .backgroundColor($r('app.color.brand'))
          Row()
            .layoutWeight(this.distCount(1) > 0 ? this.distCount(1) : 0.0001)
            .height(8)
            .backgroundColor($r('app.color.accent_blue'))
          Row()
            .layoutWeight(this.distCount(2) > 0 ? this.distCount(2) : 0.0001)
            .height(8)
            .backgroundColor($r('app.color.accent_orange'))
          Row()
            .layoutWeight(this.distCount(3) > 0 ? this.distCount(3) : 0.0001)
            .height(8)
            .backgroundColor($r('app.color.accent_purple'))
        } else {
          Row()
            .layoutWeight(1)
            .height(8)
            .backgroundColor($r('app.color.bg_chip')).backgroundBlurStyle(GlassMaterial.cardBlur()).border({ width: GlassMaterial.cardBorderWidth(), color: GlassMaterial.borderColor() }).shadow(GlassMaterial.cardShadowStyle()).clip(true)
        }
      }
      .width('100%')
      .borderRadius(4)
      .clip(true)
      .margin({ bottom: 12 })

      Row() {
        this.distItem('优', this.distCount(0), $r('app.color.brand'), 0)
        this.distItem('良', this.distCount(1), $r('app.color.accent_blue'), 1)
        this.distItem('中', this.distCount(2), $r('app.color.accent_orange'), 2)
        this.distItem('及', this.distCount(3), $r('app.color.accent_purple'), 3)
      }
      .width('100%')
    }
    .width('100%')
    }
  }

  /** 分布图例单项 */
  @Builder
  distItem(label: string, count: number, color: ResourceColor, band: number) {
    Column() {
      Row() {
        Row()
          .width(8)
          .height(8)
          .backgroundColor(color)
          .borderRadius(4)
        Text(label)
          .fontSize(12)
          .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          .margin({ left: 5 })
      }
      .alignItems(VerticalAlign.Center)
      Text(`${count} 门`)
        .fontSize(13)
        .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 4 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .onClick((): void => {
      this.openListSheet(`${label}等课程（${count} 门）`, this.bandCourses(band),
        this.overallCourses.length === 0 ? '教务未开放课程修读数据，当前为示例数据，无法展示真实课程清单。' : '');
    })
  }

  /** 课程明细（成绩/学分/绩点），默认显示前 8 条 */
  @Builder
  courseDetailSection() {
    // MaterialCard 承载：原 18vp 内边距走 cardPadding、18vp 圆角走 cardRadius、14vp 上间距走 cardMargin
    MaterialCard({
      cardRadius: 18,
      cardPadding: 18,
      cardBg: GlassMaterial.homeCardBg($r('app.color.bg_card')),
      cardBlur: GlassMaterial.cardBlur(),
      cardBorderW: GlassMaterial.cardBorderWidth(),
      cardBorderC: GlassMaterial.borderColor(),
      cardShadow: GlassMaterial.cardShadowStyle(),
      cardMargin: { top: 14 }
    }) {
    Column() {
      Row() {
        Text('课程明细')
          .fontSize(16)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
          .fontColor($r('app.color.text_primary'))
        Blank()
        // 教务未开放课程修读数据时回落示例数据，加角标防误解
        if (this.overallCourses.length === 0) {
          Text('示例数据')
            .fontSize(10)
            .fontColor(Theme.colorOf(this.themeColor))
            .border({ width: 1, color: Theme.colorOf(this.themeColor) })
            .borderRadius(8)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ right: 6 })
        }
        Text(`共 ${this.displayCourses().length} 门 · ${this.detailTermCount()} 个学期`)
          .fontSize(11)
          .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
      }
      .width('100%')
      .margin({ bottom: 10 })

      ForEach(this.detailList(), (item: ScoreItem) => {
          Row() {
            Column() {
              Text(item.courseName)
                .fontSize(13)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
              Text(`${this.termLabelOf(item.termId)}${item.kclbmc.length > 0 ? ` · ${item.kclbmc}` : (item.courseType.length > 0 ? ` · ${item.courseType}` : '')}`)
                .fontSize(11)
                .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                .width('100%')
                .margin({ top: 2 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Text(item.credit > 0 ? `${item.credit} 学分` : '')
              .fontSize(11)
              .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
              .margin({ right: 10 })
            Text(item.gradePoint > 0 ? `绩点 ${item.gradePoint}` : '')
              .fontSize(11)
              .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
              .margin({ right: 10 })
            Text(item.scoreText)
              .fontSize(14)
              .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
              .fontColor(this.scoreTone(item.scoreText))
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: 7, bottom: 7 })
          // 展开/收起：新增行淡入下移、移除行淡出上收（配合点击处 animateTo）
          .transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 6 }))
            .animation({ duration: 260, curve: Curve.Friction }))
        }, (item: ScoreItem) => `${item.courseName}-${item.termId}`)

        if (this.displayCourses().length > 8) {
          // 展开/收起是纯文字链（原本就没有胶囊底），保持原写法不改为材质按钮
          Text(this.detailExpanded ? '收起' : `展开全部 ${this.displayCourses().length} 门`)
            .fontSize(12)
            .fontColor(Theme.colorOf(this.themeColor))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 10 })
            .onClick(() => {
              // 显式动画包裹状态切换：新增/收起的课程行按 .transition 播放淡入淡出，
              // 卡片高度变化也随动画平滑过渡（参照 WallpaperPage 数据增删同款模式）
              this.getUIContext().animateTo({ duration: 260, curve: Curve.Friction }, () => {
                this.detailExpanded = !this.detailExpanded;
              });
            })
        }
    }
    .width('100%')
    }
  }

  /** 明细数据源：教务未开放课程修读数据（真实数据为空）时回落示例数据 */
  private displayCourses(): ScoreItem[] {
    return this.overallCourses.length > 0 ? this.overallCourses : MOCK_DETAIL_COURSES;
  }

  /** 总体成绩数据源：教务未开放总体统计（overallStats 为空）时回落示例数据 */
  private displayStats(): OverallGradeStats {
    return this.overallStats !== null ? this.overallStats : MOCK_STATS;
  }

  /** 明细展示列表（默认前 8 条） */
  private detailList(): ScoreItem[] {
    const src: ScoreItem[] = this.displayCourses();
    return this.detailExpanded ? src : src.slice(0, 8);
  }

  /** 明细覆盖的学期数（证明"全部学期"） */
  private detailTermCount(): number {
    const ids: string[] = [];
    const src: ScoreItem[] = this.displayCourses();
    for (const c of src) {
      if (c.termId.length > 0 && ids.indexOf(c.termId) < 0) {
        ids.push(c.termId);
      }
    }
    return ids.length;
  }

  /** 学期 id → 学期名称（如 2024-2025-1 → 2024-2025学年 第一学期） */
  private termLabelOf(termId: string): string {
    if (termId.length === 0) {
      return '学期未知';
    }
    if (this.termLabels.length === 0) {
      const terms: TermInfo[] = JwApi.buildLocalTerms();
      for (const t of terms) {
        this.termLabels.push(t);
      }
    }
    for (const t of this.termLabels) {
      if (t.id === termId) {
        return t.label;
      }
    }
    return termId;
  }

  /** 分布门数（0=优 1=良 2=中 3=及）；无真实统计时走示例数据 */
  private distCount(index: number): number {
    const s: OverallGradeStats = this.displayStats();
    if (index === 0) {
      return s.excellent;
    }
    if (index === 1) {
      return s.good;
    }
    if (index === 2) {
      return s.medium;
    }
    return s.pass;
  }

  /** 分布总门数 */
  private distTotal(): number {
    return this.distCount(0) + this.distCount(1) + this.distCount(2) + this.distCount(3);
  }

  /** 成绩文本 → 颜色（≥90 品牌色 / ≥80 蓝 / ≥70 橙 / 其它 紫） */
  private scoreTone(text: string): ResourceColor {
    let digits: string = '';
    for (let i: number = 0; i < text.length; i++) {
      const ch: string = text.charAt(i);
      if (ch >= '0' && ch <= '9') {
        digits += ch;
      }
    }
    const n: number = digits.length > 0 ? Number(digits) : -1;
    if (n >= 90) {
      return $r('app.color.brand');
    }
    if (n >= 80) {
      return $r('app.color.accent_blue');
    }
    if (n >= 70) {
      return $r('app.color.accent_orange');
    }
    if (n >= 60) {
      return $r('app.color.accent_purple');
    }
    return GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'));
  }

  private percent(earned: number, required: number): number {
    if (required <= 0) {
      return 0;
    }
    const p: number = Math.round(earned / required * 100);
    return p > 100 ? 100 : p;
  }

  /** 进度条颜色按完成度分档（静态语义，不随主题）：<40 橙 / 40-70 琥珀 / 70-95 南医蓝 / ≥95 深绿 */
  private pctColor(p: number): ResourceColor {
    if (p < 40) {
      return $r('app.color.accent_orange');
    }
    if (p < 70) {
      return '#D98E04';
    }
    if (p < 95) {
      return '#005BAC';
    }
    return '#0B6E3B';
  }

  /** 学业情况导出卡片（挂载但离屏，供 getComponentSnapshot 快照生成图片）
   *  按导出面板勾选的模块渲染。 */
  @Builder
  academicExportCard() {
    Column() {
      // 标题
      Row() {
        Text('学业情况')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Blank()
        Text(new Date().toLocaleDateString('zh-CN'))
          .fontSize(11)
          .fontColor('#AFC6E4')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (AppState.profile !== null) {
        Text(`${AppState.profile.name} · ${AppState.profile.studentId} · ${AppState.profile.major}`)
          .fontSize(12)
          .fontColor('#E8F0F8')
          .margin({ top: 4 })
      }

      Divider()
        .color('#3A5B8C')
        .margin({ top: 12, bottom: 10 })

      // 学业概览模块
      if (this.isExportModule('overview')) {
        Text('学业概览')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#BBD8FF')
          .margin({ bottom: 8 })
        Row() {
          this.academicExportMetric('平均绩点', this.currentGpa().toFixed(2))
          this.academicExportMetric('学业总评', this.currentOverallScore() >= 0 ? this.currentOverallScore().toFixed(2) : '--')
          this.academicExportMetric('已修', `${this.passedCountOf()}`)
          this.academicExportMetric('未通过', `${this.failedCountOf()}`)
        }
        .width('100%')
        Divider().color('#3A5B8C').margin({ top: 12, bottom: 12 })
      }

      // 课程明细模块
      if (this.isExportModule('detail')) {
        Text('课程明细')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#BBD8FF')
          .margin({ bottom: 8 })
        Column() {
          ForEach(this.displayCourses().slice(0, 30), (it: ScoreItem, idx: number) => {
            Row() {
              Text(it.courseName)
                .fontSize(12)
                .fontColor('#FFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(`${it.credit.toFixed(1)}学分`)
                .fontSize(10)
                .fontColor('#AFC6E4')
                .margin({ left: 8, right: 8 })
              Text(it.scoreText)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#8FF0C0')
            }
            .width('100%')
            .padding({ top: 4, bottom: 4 })
          }, (it: ScoreItem, idx: number) => `ae${idx}_${it.id}`)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        Divider().color('#3A5B8C').margin({ top: 12, bottom: 12 })
      }

      // 学业提醒模块
      if (this.isExportModule('warning')) {
        Text('学业提醒')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#BBD8FF')
          .margin({ bottom: 8 })
        Column() {
          ForEach(this.buildWarnings(), (w: string, idx: number) => {
            Row() {
              Text(`${idx + 1}`)
                .fontSize(10)
                .fontColor('#1B3A63')
                .width(16)
                .height(16)
                .lineHeight(16)
                .textAlign(TextAlign.Center)
                .backgroundColor('#BBD8FF')
                .borderRadius(8)
              Text(w)
                .fontSize(11)
                .lineHeight(17)
                .fontColor('#E8F0F8')
                .margin({ left: 8 })
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .padding({ top: 4, bottom: 4 })
          }, (w: string, idx: number) => `aw${idx}`)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      Text('南医助手 · 学业情况')
        .fontSize(10)
        .fontColor('#7F9BC4')
        .margin({ top: 14 })
    }
    .width(360)
    .padding(20)
    .backgroundColor('#1B3A63')
    .borderRadius(16)
  }

  /** 学业概览导出指标（卡片内小格） */
  @Builder
  academicExportMetric(label: string, value: string) {
    Column() {
      Text(value)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
      Text(label)
        .fontSize(10)
        .fontColor('#AFC6E4')
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  /** 页面主体内容（NavDestination 与 tab 内嵌两种模式共用） */
  @Builder
  pageInner() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 二级页壁纸底层（无壁纸回 bg_page，不透下层）
      WallpaperFill()
      Column() {
        if (this.loading) {
          // 悬浮顶栏下垂直居中
          Column() {
            LoadingTip()
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          Refresh({ refreshing: $$this.refreshing }) {
          Scroll() {
            Column() {
              // 顶栏让位 spacer（与成绩页同款：下拉刷新指示位置统一）
              Column()
                .width('100%')
                .height(this.getUIContext().px2vp(this.topInsetPx) + 60 + (this.barStyle === 'legacy' ? 14 : 0))
              this.gpaCard()
              this.scoreEntry()
              this.overallCard()
              if (this.showOverallScore) {
                this.overallScoreCard()
              }
              this.distributionSection()
              this.overviewRow()
              this.categorySection()
              this.courseDetailSection()
              this.warningSection()
              Column()
                .height(this.getUIContext().px2vp(this.bottomInsetPx) + 24)
            }
            .width('100%')
            .padding({ left: 16, right: 16 })
          }
          .scrollBar(BarState.Off)
          .layoutWeight(1)
          .align(Alignment.Top)
          .edgeEffect(EdgeEffect.Spring)
          }
          .layoutWeight(1)
          .height('100%')
          .pullToRefresh(false)
          .onRefreshing(() => { this.onRefresh(); })
        }
      }
      .width('100%')
      .height('100%')
        // 顶栏悬浮（最上层）：正文 Scroll 顶部已让位，上滑可滚入其渐变下层透出
        PageHeader({
          title: '学业情况',
          subtitle: AppState.profile !== null ? `${AppState.profile.major} · ${AppState.profile.grade}` : '',
          actionText: '刷新',
          actionTone: 'glass',
          showBack: !this.isTab,
          onAction: () => {
            this.buttonRefresh();
          },
          onBack: () => {
            AppState.stack.pop();
          }
        })

        AntiPeepOverlay({ isPeeped: this.isPeeped })

        // 导出选择面板锚点：ArkUI 同一组件多次 bindSheet 只有最后一个生效，
        // 故导出面板挂到独立零尺寸锚点上，避免挤掉统计面板。
        Column()
          .width(0)
          .height(0)
          .bindSheet($$this.showExportSheet, this.exportSheet(), {
            width: SheetUtil.sheetWidth(),
            preferType: SheetType.BOTTOM,
            height: SheetSize.FIT_CONTENT,
            dragBar: true,
            showClose: false,
            backgroundColor: Color.Transparent,
            blurStyle: sheetBlurStyle()
          })
      }
      .width('100%')
      .height('100%')
      // 全局壁纸：二级页根背景透明，透出主框架底层壁纸（无壁纸时由 MainView 底层纯色兜底）
      .backgroundColor(Color.Transparent)
  }

  build() {
    if (this.isTab) {
      // tab 内嵌模式：无 NavDestination 包裹，返回键隐藏，bindSheet 挂在容器上
      Column() {
        this.pageInner()
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))
      .bindSheet($$this.showStatSheet, this.statSheet(), {
        width: SheetUtil.sheetWidth(),
        preferType: SheetType.BOTTOM,
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        showClose: false,
        backgroundColor: Color.Transparent,
        blurStyle: sheetBlurStyle()
      })
    } else {
      NavDestination() {
        this.pageInner()
      }
      .backgroundColor($r('app.color.bg_page'))
      .hideTitleBar(true)
      .systemTransition(NavigationSystemTransitionType.SLIDE_RIGHT)
      .bindSheet($$this.showStatSheet, this.statSheet(), {
        width: SheetUtil.sheetWidth(),
        preferType: SheetType.BOTTOM,
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        showClose: false,
        backgroundColor: Color.Transparent,
        blurStyle: sheetBlurStyle()
      })
    }
  }
}