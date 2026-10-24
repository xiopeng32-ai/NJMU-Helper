/**
 * 考试安排（二级页）：学年/学期选择 + 考试列表 + 点开查看详情 + 导入日历
 *
 * 卡片外观接入（照首页 HomeView / 关于页 AboutPage 的写法推广）：
 *  - 页面级卡片（顶部提示卡 / 考试卡）统一用 `MaterialCard` 承载（材质层在卡片内部、位于内容之下），
 *    材质生效时卡片自身的底色/磨砂/亮边/阴影一并让出，每张卡只有一层视觉；
 *    关闭光感回落为原来的纯色/毛玻璃卡片；
 *  - 原卡片上的 `.padding(...)` / `.borderRadius(...)` / `.margin(...)` / `.opacity(...)` / `.onClick(...)`
 *    一律改走 `cardPadding` / `cardRadius` / `cardMargin` / `cardOpacity` / `cardOnClick`
 *    （尾随闭包初始化的自定义组件之后不能再链式加属性）；
 *  - 弹窗内容套 `MaterialSheetPanel`，`bindSheet` 显式 `backgroundColor: Color.Transparent` +
 *    `blurStyle: sheetBlurStyle()`；弹窗**内部**的列表行保持原 Row 写法（面板本身已是材质，
 *    再包 MaterialCard 会在同一区域叠第二层材质）。
 */
import { componentSnapshot } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { SheetUtil } from '../common/SheetUtil';
import { common, Want, wantConstant } from '@kit.AbilityKit';
import { JwApi } from '../api/JwApi';
import { AppState } from '../common/AppState';
import { CalendarUtil } from '../common/CalendarUtil';
import { CalendarExport } from '../common/CalendarExport';
import { Const } from '../common/Constants';
import { DataStore } from '../common/DataStore';
import { LogStore } from '../common/LogStore';
import { DateUtil } from '../common/DateUtil';
import { Theme } from '../common/ThemeUtil';
import { AppearanceStore } from '../common/AppearanceStore';
import { GlassMaterial } from '../common/GlassMaterial';
import { WallpaperTone } from '../common/WallpaperTone';
import { Immersive } from './common/Immersive';
import { ExamItem, TermInfo } from '../model/Models';
import { EmptyTip, LoadingTip, TagChip } from './common/UiKit';
import { BackButton } from './common/BackButton';
import { WallpaperFill } from './common/WallpaperFill';
// 沉浸光感：页面级卡片统一走 MaterialCard（材质承载层在卡片内容之下，材质生效时卡片底色/磨砂/亮边/阴影
// 一并让出，每张卡只剩一层视觉），胶囊小按钮走 MaterialButton，半模态弹窗内容走 MaterialSheetPanel
import { MaterialCard, MaterialSheetPanel } from './common/MaterialCard';
import { MaterialButton } from './common/MaterialButton';
import { sheetBlurStyle } from '../common/SystemMaterial';
import { ImageExport, ExportResult } from '../common/ScoreImageExport';
import { T } from '../common/I18n';

/** 考试提醒时长选择弹窗（自定义，支持多档） */
@CustomDialog
struct ExamReminderDialog {
  /** 界面语言版本号：切换语言后重建，避免对话框文案滞后 */
  @StorageProp('langRev') langRev: number = 0;
  controller?: CustomDialogController;
  /** 当前选中（分钟字符串，'0' = 不提醒） */
  @State picked: string = '1440';
  /** 确认回调 */
  onConfirm: (minutes: string) => void = () => {
  };

  private readonly options: string[] = ['0', '30', '60', '1440', '2880'];
  private readonly labels: string[] = [T('不提醒'), '提前30分', T('提前1小时'), T('提前1天'), T('提前2天')];

  aboutToAppear(): void {
    // 默认选中上次使用的提醒时长
    const last: string = DataStore.get('exam_reminder_min');
    if (last.length > 0) {
      this.picked = last;
    }
  }

  build() {
    Column() {
      Text(T('设置考试提醒'))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      Text(T('提醒会写入系统日历，按所选时间提前通知'))
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ top: 4 })

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.options, (v: string, idx: number) => {
          Text(this.labels[idx])
            .fontSize(13)
            .fontColor(this.picked === v ? '#FFFFFF' : $r('app.color.text_secondary'))
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .backgroundColor(this.picked === v ? $r('app.color.brand') : $r('app.color.bg_chip'))
            .borderRadius(16)
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.picked = v;
            })
        }, (v: string) => v)
      }
      .width('100%')
      .margin({ top: 14 })

      Row({ space: 10 }) {
        Text(T('取消'))
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .layoutWeight(1)
          .height(38)
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.bg_chip'))
          .borderRadius(19)
          .onClick(() => {
            this.controller?.close();
          })
        Text(T('确定'))
          .fontSize(14)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
          .height(38)
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.brand'))
          .borderRadius(19)
          .onClick(() => {
            this.onConfirm(this.picked);
            this.controller?.close();
          })
      }
      .width('100%')
      .margin({ top: 18 })
    }
    .width('86%')
    .padding(20)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(18)
  }
}

@Component
export struct ExamPage {
  /** 界面语言版本号：切换语言后自增，订阅它即可重建本组件 */
  @StorageProp('langRev') langRev: number = 0;
  @StorageProp('topInsetPx') topInsetPx: number = 0;
  /** 灰字广播订阅：颜色表达式需传 this.grayTick 才登记响应式依赖（否则改色不实时刷新） */
  @StorageProp('grayTick') grayTick: number = 0;
  @StorageProp('bottomInsetPx') bottomInsetPx: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /** 壁纸亮度（顶栏文字自适应用） */
  @StorageProp('wallpaperTone') wallpaperTone: number = -1;
  /** 全局字重响应式订阅：表达式读 this.fwMode 才登记依赖，fwValue 声明即订阅（custom 调值触发重渲染） */
  @StorageProp('fontWeightMode') fwMode: string = 'follow';
  @StorageProp('fontWeightValue') fwValue: number = 400;
  @StorageProp('themeColor') themeColor: string = 'green';
  @StorageProp('barStyle') barStyle: string = 'new';
  @StorageProp('immersiveEffect') immersiveEffect: boolean = false;
  /** 响应式依赖：玻璃/灰字设置变化时即时刷新本页（取值经 GlassMaterial 静态方法读取） */
  @StorageProp('glassStrength') glassStrength: number = 70;
  @StorageProp('cardMaterial') cardMaterial: boolean = false;
  /** 卡片沾色底色（广播键）：沾色开关变化时由 AppearanceStore.broadcastDerived() 重写 */
  @StorageProp('cardTintBg') tintBg: string = '';
  @StorageProp('grayTextMode') grayTextMode: string = 'default';
  @StorageProp('grayTextColor') grayTextColor: string = '';
  @StorageProp('subtitleColor') subtitleColor: string = '';
  @State terms: TermInfo[] = [];
  @State selectedTermIndex: number = 0;
  @State exams: ExamItem[] = [];
  @State loading: boolean = true;
  @State showTermSheet: boolean = false;
  @State showDetail: boolean = false;
  @State selectedExam: ExamItem | null = null;
  /** 桌面卡片挑考试弹窗 */
  @State showPickExam: boolean = false;
  /** 当前用作桌面卡片倒计时的考试 id（空=用最近一场） */
  @State pickedExamId: string = '';
  @State refreshing: boolean = false;
  /** 正在生成导出图片 */
  @State exportingImage: boolean = false;
  /** 正在写入日历 */
  @State addingCalendar: boolean = false;
  /** 待写入日历的考试（null = 全部） */
  private calendarTarget: ExamItem | null = null;
  /** 提醒选择弹窗控制器 */
  private reminderDialog: CustomDialogController = new CustomDialogController({
    builder: ExamReminderDialog({
      onConfirm: (minutes: string) => {
        this.applyCalendarReminder(minutes);
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true
  });
  /** 进入方式：是否由桌面卡片点过来 */
  private enterFromCard: boolean = false;

  /** 页面出现：加载考试数据 */
  aboutToAppear(): void {
    // 灰字高级调整：本页成为活动页（每页单独灰字色生效）
    GlassMaterial.setPageActive('exam');
    this.pickedExamId = DataStore.getPickedExamId();
    // 桌面卡片跳转 → 进入 picker 模式，加载完后自动弹
    this.enterFromCard = AppState.openPageRequest === 'exam-pick';
    if (this.enterFromCard) {
      // 清空意图避免下次进入时反复触发
      AppState.openPageRequest = '';
    }
    this.load();
  }

  /** 页面消失：恢复活动页上下文为当前 Tab 页（避免回落后 Tab 的单独灰字色失效） */
  aboutToDisappear(): void {
    GlassMaterial.restoreTabPage();
  }

  /** 加载完成回调（用于桌面卡片模式自动弹 picker） */
  private afterLoaded(): void {
    this.loading = false;
    if (this.enterFromCard) {
      this.enterFromCard = false;
      // 始终弹出选考试弹窗，让用户主动确认
      this.showPickExam = true;
    }
  }

  /** 选中要倒计时的考试 */
  private pickExamForCard(item: ExamItem | null): void {
    const id: string = item === null ? '' : item.id;
    DataStore.setPickedExamId(id);
    this.pickedExamId = id;
    if (item !== null) {
      this.getUIContext().getPromptAction().showToast({ message: `已设置《${item.courseName}》为桌面卡片倒计时` });
    } else {
      this.getUIContext().getPromptAction().showToast({ message: T('已恢复为最近一场考试自动倒计时') });
    }
  }

  /** 根据 pickedExamId 查找课程名称（展示用） */
  private pickedExamName(): string {
    for (const ex of this.exams) {
      if (ex.id === this.pickedExamId) {
        return ex.courseName;
      }
    }
    return this.pickedExamId;
  }

  /** 当前选中的学期 id（未选时回退全局当前学期） */
  private currentTermId(): string {
    if (this.selectedTermIndex >= 0 && this.selectedTermIndex < this.terms.length) {
      return this.terms[this.selectedTermIndex].id;
    }
    return AppState.term.id;
  }

  /**
   * 导出考试安排为图片（与学业情况页同一套框架：离屏渲染 → 系统相册确认框）。
   *
   * 用 ImageExport.exportBuilder 而不是组件快照：考试多时列表会超出屏幕高度，
   * 直接快照会被截断；离屏 Builder 按内容完整渲染，导出的是整份清单。
   */
  /**
   * 一键把考试写入系统日历（提前 1 天 + 提前 1 小时各提醒一次）。
   * 与课程表导出共用 CalendarExport 的权限申请逻辑。
   */
  private async addExamsToCalendar(onlyItem: ExamItem | null = null): Promise<void> {
    if (this.addingCalendar) {
      return;
    }
    const list: ExamItem[] = onlyItem !== null ? [onlyItem] : this.exams;
    if (list.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: T('暂无考试可添加') });
      return;
    }
    // 先让用户选提醒方式（记住上次选择作为默认）
    this.calendarTarget = onlyItem;
    this.reminderDialog.open();
  }

  /** 提醒时长文案 */
  private reminderLabel(minutes: string): string {
    if (minutes === '30') {
      return T('提前 30 分钟');
    }
    if (minutes === '60') {
      return T('提前 1 小时');
    }
    if (minutes === '1440') {
      return T('提前 1 天');
    }
    if (minutes === '2880') {
      return T('提前 2 天');
    }
    return '不';
  }

  /** 用户选好提醒时长后真正写入日历 */
  private async applyCalendarReminder(minutes: string): Promise<void> {
    DataStore.put('exam_reminder_min', minutes);
    const n: number = Number.parseInt(minutes, 10);
    const reminder: number[] = isNaN(n) || n <= 0 ? [] : [n];
    const list: ExamItem[] = this.calendarTarget !== null ? [this.calendarTarget] : this.exams;
    this.addingCalendar = true;
    this.getUIContext().getPromptAction().showToast({ message: T('正在写入系统日历…') });
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const count: number = await CalendarExport.exportExams(ctx, list, reminder);
      const tip: string = reminder.length === 0
        ? `已添加 ${count} 场考试到日历（不提醒）`
        : `已添加 ${count} 场考试到日历（${this.reminderLabel(minutes)}提醒）`;
      this.getUIContext().getPromptAction().showToast({ message: tip, duration: 2600 });
    } catch (e) {
      LogStore.log('考试', '加入日历', '失败', LogStore.errorOf(e as Object));
      this.getUIContext().getPromptAction().showToast({ message: T('添加失败，请确认已授予日历权限') });
    } finally {
      this.addingCalendar = false;
    }
  }

  private async exportExamsAsImage(): Promise<void> {
    if (this.exportingImage) {
      return;
    }
    if (this.exams.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: T('暂无考试安排可导出') });
      return;
    }
    this.exportingImage = true;
    this.getUIContext().getPromptAction().showToast({ message: T('正在生成考试安排图片…') });
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const now: Date = new Date();
      const dateStr: string = `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, '0')}${String(now.getDate()).padStart(2, '0')}`;
      const result: ExportResult = await ImageExport.exportBuilder(
        ctx, this.getUIContext(), (): void => { this.examExportCard(); }, 'exam',
        `考试安排_${dateStr}`);
      this.getUIContext().getPromptAction().showToast({ message: result.message });
    } catch (e) {
      LogStore.log('考试', '导出图片', '失败', LogStore.errorOf(e as Object));
      this.getUIContext().getPromptAction().showToast({ message: T('导出失败，请重试') });
    } finally {
      this.exportingImage = false;
    }
  }

  /** 长按单张考试卡：只导出这一场（同样走离屏渲染，尺寸稳定） */
  private async exportOneExam(item: ExamItem): Promise<void> {
    if (this.exportingImage) {
      return;
    }
    this.exportingImage = true;
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const result: ExportResult = await ImageExport.exportBuilder(
        ctx, this.getUIContext(), (): void => { this.examExportSingleCard(item); }, 'exam_one',
        `考试_${item.courseName}`);
      this.getUIContext().getPromptAction().showToast({ message: result.message });
    } catch (e) {
      LogStore.log('考试', '导出单场', '失败', LogStore.errorOf(e as Object));
      this.getUIContext().getPromptAction().showToast({ message: T('导出失败，请重试') });
    } finally {
      this.exportingImage = false;
    }
  }

  /** 导出卡顶部日期 */
  private exportDateLabel(): string {
    const d: Date = new Date();
    return `${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()}`;
  }

  /** 导出卡：待考场次 */
  private upcomingCount(): number {
    let n: number = 0;
    for (const e of this.exams) {
      if (this.daysLeft(e) >= 0) {
        n++;
      }
    }
    return n;
  }

  /** 导出卡：最近一场剩余天数（无则 -1） */
  private nearestDays(): number {
    let best: number = -1;
    for (const e of this.exams) {
      const d: number = this.daysLeft(e);
      if (d >= 0 && (best < 0 || d < best)) {
        best = d;
      }
    }
    return best;
  }

  /** 离屏导出卡：整份考试清单（深蓝渐变头 + 白色主体） */
  @Builder
  examExportCard() {
    Column() {
      Column() {
        Row() {
          Column() {
            Text(T('考试安排'))
              .fontSize(21)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Text(this.currentTermLabel())
              .fontSize(11)
              .fontColor('#A9C4E4')
              .margin({ top: 3 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text(this.exportDateLabel())
            .fontSize(10)
            .fontColor('#D6E6F8')
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor('rgba(255,255,255,0.16)')
            .borderRadius(9)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        if (AppState.profile !== null) {
          Text(`${AppState.profile.name} · ${AppState.profile.className} · ${AppState.profile.major}`)
            .fontSize(11)
            .fontColor('#C7DBF1')
            .margin({ top: 8 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        Row() {
          this.exportStat(`${this.exams.length}`, '总场次')
          Column().width(1).height(22).backgroundColor('rgba(255,255,255,0.18)')
          this.exportStat(this.nearestDays() >= 0 ? `${this.nearestDays()}` : '--', '最近一场(天)')
          Column().width(1).height(22).backgroundColor('rgba(255,255,255,0.18)')
          this.exportStat(`${this.upcomingCount()}`, '待考')
        }
        .width('100%')
        .margin({ top: 14 })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 20, bottom: 18 })
      .linearGradient({ angle: 135, colors: [['#12304F', 0.0], ['#1B3A63', 0.55], ['#2A5580', 1.0]] })

      Column() {
        ForEach(this.exams, (item: ExamItem) => {
          this.examExportRow(item)
        }, (item: ExamItem) => item.id)

        Row() {
          Text('南医助手')
            .fontSize(9)
            .fontColor('#9AA6B4')
          Blank()
          Text(`共 ${this.exams.length} 场 · ${this.exportDateLabel()}`)
            .fontSize(9)
            .fontColor('#9AA6B4')
        }
        .width('100%')
        .margin({ top: 14, bottom: 2 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 14 })
      .backgroundColor('#FFFFFF')
    }
    .width(360)
    .borderRadius(16)
    .clip(true)
  }

  /** 导出卡统计格 */
  @Builder
  exportStat(value: string, label: string) {
    Column() {
      Text(value)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
      Text(label)
        .fontSize(9)
        .fontColor('#A9C4E4')
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  /** 导出卡一行考试：日期徽章 + 课程 + 时间地点 + 状态 */
  @Builder
  examExportRow(item: ExamItem) {
    Row() {
      Column() {
        Text(`${DateUtil.parse(item.date).getMonth() + 1}月`)
          .fontSize(8)
          .fontColor(this.daysLeft(item) >= 0 ? '#2F6FDE' : '#9AA6B4')
        Text(`${DateUtil.parse(item.date).getDate()}`)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.daysLeft(item) >= 0 ? '#12304F' : '#9AA6B4')
      }
      .width(38)
      .padding({ top: 4, bottom: 4 })
      .backgroundColor(this.daysLeft(item) >= 0 ? '#EAF1FC' : '#F2F4F7')
      .borderRadius(8)
      .alignItems(HorizontalAlign.Center)

      Column() {
        Row() {
          Text(item.courseName)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.daysLeft(item) >= 0 ? '#1A1D1C' : '#8A939E')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.daysLeft(item) >= 0 ? `${this.daysLeft(item)} 天后` : '已结束')
            .fontSize(9)
            .fontColor(this.daysLeft(item) >= 0 ? '#E07B00' : '#9AA6B4')
        }
        .width('100%')

        Text(`${item.timeRange} · ${item.location}`)
          .fontSize(9)
          .fontColor('#6B7684')
          .width('100%')
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Row({ space: 6 }) {
          Text(item.examType)
            .fontSize(8)
            .fontColor('#2F6FDE')
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .backgroundColor('#EAF1FC')
            .borderRadius(4)
          Text(`座位 ${item.seat}`)
            .fontSize(8)
            .fontColor('#9AA6B4')
        }
        .width('100%')
        .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 10 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 9, bottom: 9 })
    .border({ width: { bottom: 1 }, color: '#EFF2F6' })
  }

  /** 离屏导出卡：单场考试（长按卡片时用） */
  @Builder
  examExportSingleCard(item: ExamItem) {
    Column() {
      Column() {
        Text(T('考试安排'))
          .fontSize(11)
          .fontColor('#A9C4E4')
          .width('100%')
        Text(item.courseName)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .width('100%')
          .margin({ top: 6 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          Text(this.daysLeft(item) >= 0 ? `还有 ${this.daysLeft(item)} 天` : '已结束')
            .fontSize(10)
            .fontColor('#FFFFFF')
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .backgroundColor(this.daysLeft(item) >= 0 ? 'rgba(255,197,107,0.28)' : 'rgba(255,255,255,0.16)')
            .borderRadius(8)
          Blank()
          Text(item.examType)
            .fontSize(10)
            .fontColor('#C7DBF1')
        }
        .width('100%')
        .margin({ top: 10 })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 16 })
      .linearGradient({ angle: 135, colors: [['#12304F', 0.0], ['#1B3A63', 0.6], ['#2A5580', 1.0]] })

      Column() {
        this.exportDetailRow('日期', `${item.date}（${Const.WEEK_LABELS[DateUtil.weekdayOf(DateUtil.parse(item.date)) - 1]}）`)
        this.exportDetailRow(T('时间'), item.timeRange)
        this.exportDetailRow(T('考场'), item.location)
        this.exportDetailRow(T('座位'), item.seat)
        if (item.teacher.length > 0) {
          this.exportDetailRow(T('教师'), item.teacher)
        }
        Row() {
          Text('南医助手')
            .fontSize(9)
            .fontColor('#9AA6B4')
          Blank()
          Text(this.exportDateLabel())
            .fontSize(9)
            .fontColor('#9AA6B4')
        }
        .width('100%')
        .margin({ top: 12 })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 14, bottom: 16 })
      .backgroundColor('#FFFFFF')
    }
    .width(320)
    .borderRadius(16)
    .clip(true)
  }

  /** 单场导出卡的明细行 */
  @Builder
  exportDetailRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(10)
        .fontColor('#8A939E')
        .width(42)
      Text(value)
        .fontSize(12)
        .fontColor('#1A1D1C')
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .border({ width: { bottom: 1 }, color: '#F2F4F7' })
  }

  private async load(): Promise<void> {
    this.loading = true;
    // 本地生成年学期列表（保证选择可用）
    this.terms = await JwApi.getTerms();
    for (let i = 0; i < this.terms.length; i++) {
      if (this.terms[i].id === AppState.term.id) {
        this.selectedTermIndex = i;
        break;
      }
    }
    // 先用缓存秒开（按学期隔离：避免显示成别的学期的考试）
    const cached: ExamItem[] = JwApi.loadCachedExams(this.currentTermId());
    if (cached.length > 0) {
      this.exams = cached.slice(0);
      this.loading = false;
    }
    try {
      await this.fetchSelectedTerm();
    } catch (e) {
      // 网络异常保持缓存
    }
    this.afterLoaded();
  }

  /** 下拉刷新：重新加载考试安排 */
  private async onRefresh(): Promise<void> {
    await this.load();
    this.refreshing = false;
  }

  private async fetchSelectedTerm(): Promise<void> {
    if (this.selectedTermIndex < 0 || this.selectedTermIndex >= this.terms.length) {
      return;
    }
    const term: TermInfo = this.terms[this.selectedTermIndex];
    const list: ExamItem[] = await JwApi.getExams(term.id);
    list.sort((a: ExamItem, b: ExamItem) => DateUtil.parse(a.date).getTime() - DateUtil.parse(b.date).getTime());
    this.exams = list;
  }

  private async selectTerm(index: number): Promise<void> {
    this.selectedTermIndex = index;
    this.showTermSheet = false;
    this.loading = true;
    try {
      await this.fetchSelectedTerm();
    } catch (e) {
      // ignore
    } finally {
      this.loading = false;
    }
  }

  /** 当前学期展示文案 */
  private currentTermLabel(): string {
    if (this.terms.length === 0 || this.selectedTermIndex >= this.terms.length) {
      return AppState.term.label;
    }
    return this.terms[this.selectedTermIndex].label;
  }

  /** 考试距今天数（正数=还有几天，0=今天，负数=已过去） */
  private daysLeft(item: ExamItem): number {
    return DateUtil.diffDays(new Date(), DateUtil.parse(item.date));
  }

  /** 倒计时 TagChip 文字颜色（按剩余天数分级：≤3天红紧急、≤7天黄中等、>7天绿充足；已结束灰） */
  private daysTagColor(d: number): ResourceColor {
    if (d < 0) {
      return GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'));
    }
    if (d <= 3) {
      return $r('app.color.state_danger');
    }
    if (d <= 7) {
      return $r('app.color.state_warn');
    }
    return $r('app.color.state_success');
  }

  /** 待考场次数（未开始的考试数量） */
  private comingCount(): number {
    let n: number = 0;
    for (const e of this.exams) {
      if (this.daysLeft(e) >= 0) {
        n++;
      }
    }
    return n;
  }

  /** 最近一场考试的倒计时/时间文案 */
  private nextExamText(): string {
    for (const e of this.exams) {
      const d: number = this.daysLeft(e);
      if (d >= 0) {
        return d === 0 ? `今天有《${e.courseName}》考试，加油！` : `距离《${e.courseName}》还有 ${d} 天`;
      }
    }
    return T('本学期考试已全部结束');
  }

  @Builder
  examCard(item: ExamItem) {
    // MaterialCard 承载：材质层是卡片内部底层、与卡片同尺寸同圆角，材质生效时卡片底色/磨砂/亮边/阴影让出；
    // 原 14vp 内边距走 cardPadding、16vp 圆角走 cardRadius、12vp 下间距走 cardMargin、
    // 已结束考试的 0.6 透明度走 cardOpacity、整卡点击走 cardOnClick
    // （尾随闭包初始化的自定义组件之后不能再链式加属性）。
    MaterialCard({
      cardRadius: 16,
      cardPadding: 14,
      cardBg: GlassMaterial.homeCardBg($r('app.color.bg_card')),
      cardBlur: GlassMaterial.cardBlur(),
      cardBorderW: GlassMaterial.cardBorderWidth(),
      cardBorderC: GlassMaterial.borderColor(),
      cardShadow: GlassMaterial.cardShadowStyle(),
      cardMargin: { bottom: 12 },
      cardOpacity: this.daysLeft(item) < 0 ? 0.6 : 1,
      cardOnClick: () => {
        this.selectedExam = item;
        this.showDetail = true;
      }
    }) {
    Row() {
      Column() {
        Text(`${DateUtil.parse(item.date).getMonth() + 1}`)
          .fontSize(11)
          .fontColor(this.daysLeft(item) < 0 ? GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary')) : $r('app.color.accent_orange'))
        Text(`${DateUtil.parse(item.date).getDate()}`)
          .fontSize(22)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
          .fontColor(this.daysLeft(item) < 0 ? GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary')) : $r('app.color.accent_orange'))
        Text(Const.WEEK_LABELS[DateUtil.weekdayOf(DateUtil.parse(item.date)) - 1])
          .fontSize(10)
          .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          .margin({ top: 2 })
      }
      .width(60)
      .padding({ top: 10, bottom: 10 })
      .backgroundColor($r('app.color.bg_chip')).backgroundBlurStyle((AppStorage.get<boolean>('immersiveEffect') ?? false) ? BlurStyle.Thin : BlurStyle.NONE).border({ width: 1, color: 'rgba(255,255,255,0.28)' }).shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 }).clip(true)
      .borderRadius(12)

      Column() {
        Row() {
          Text(item.courseName)
            .fontSize(16)
            .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
            .fontColor(this.daysLeft(item) < 0 ? GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary')) : $r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.daysLeft(item) < 0) {
            TagChip({ text: T('已结束'), color: GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary')), bg: $r('app.color.bg_chip') })
          } else if (this.daysLeft(item) === 0) {
            TagChip({ text: T('今天'), color: $r('app.color.brand_on'), bg: $r('app.color.state_danger') })
          } else {
            // 倒计时按远近分级配色：≤3天红(紧急)、≤7天黄(中等)、>7天绿(充足)
            TagChip({
              text: `${this.daysLeft(item)} 天后`,
              color: this.daysTagColor(this.daysLeft(item)),
              bg: $r('app.color.bg_chip')
            })
          }
        }
        .width('100%')

        Row() {
          Column()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor(this.examTypeColor(item.examType))
            .margin({ right: 5 })
          Text(item.timeRange)
            .fontSize(12)
            .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .margin({ left: 4 })
          Column()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor(this.examTypeColor(item.examType))
            .margin({ left: 12, right: 5 })
          Text(item.location)
            .fontSize(12)
            .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .margin({ left: 4 })
        }
        .width('100%')
        .margin({ top: 8 })

        Row() {
          TagChip({ text: item.examType, color: Theme.colorOf(this.themeColor), bg: Theme.rgba(Theme.colorOf(this.themeColor), 0.12) })
          Text(`座位号 ${item.seat}`)
            .fontSize(11)
            .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .margin({ left: 8 })
          Blank()
        }
        .width('100%')
        .margin({ top: 8 })
      }
      .layoutWeight(1)
      .margin({ left: 12 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    // 手势分享：长按单张卡片生成图片并分享（id 供 componentSnapshot 精确截图）
    .id(`examCard_${item.id}`)
    .gesture(LongPressGesture({ repeat: false, duration: 450 })
      .onAction(() => {
        this.exportOneExam(item);
      }))
    }
  }

  @Builder
  detailSheet() {
    // 弹窗内容套 MaterialSheetPanel：bindSheet 自身的 systemMaterial 挂在面板上、内容区不生效，
    // 由 MaterialSheetPanel 的 Toggle 承载层渲染材质；配套硬要求（见 build 的 bindSheet 选项）
    // 是显式 backgroundColor: Color.Transparent（默认白底会把材质整块盖住）。
    // 高度随内容（SheetSize.FIT_CONTENT）→ panelFillHeight: false；内层 20/8/24vp 内边距原样保留。
    MaterialSheetPanel({ panelRadius: 20, panelPadding: 0, panelFillHeight: false, panelTitle: T('考试详情'), panelShowClose: true, panelOnClose: (): void => { this.showDetail = false; } }) {
    Column() {
      if (this.selectedExam !== null) {
        Row() {
          Column()
            .width(4)
            .height(20)
            .borderRadius(2)
            .backgroundColor($r('app.color.accent_orange'))
          Text(this.selectedExam.courseName)
            .fontSize(19)
            .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
            .fontColor($r('app.color.text_primary'))
            .margin({ left: 8 })
            .layoutWeight(1)
        }
        .width('100%')
        .margin({ bottom: 16 })

        this.sheetRow('考试日期', `${this.selectedExam.date}（${Const.WEEK_LABELS[DateUtil.weekdayOf(DateUtil.parse(this.selectedExam.date)) - 1]}）`, this.examTypeColor(this.selectedExam.examType))
        this.sheetRow(T('考试时间'), this.selectedExam.timeRange, this.examTypeColor(this.selectedExam.examType))
        this.sheetRow(T('考试地点'), this.selectedExam.location, this.examTypeColor(this.selectedExam.examType))
        this.sheetRow(T('座位号'), this.selectedExam.seat, this.examTypeColor(this.selectedExam.examType))
        this.sheetRow(T('考试性质'), this.selectedExam.examType, this.examTypeColor(this.selectedExam.examType))

        Row() {
          // 导入日历：材质走 MaterialButton 的 Toggle 承载层（普通 Button 直接挂材质真机不渲染）；
          // MaterialButton 的 Stack 内部 layoutWeight 不生效 → 把 layoutWeight 移到外层 Column，
          // 内容自己写 width('100%') / height(44) 把点击区撑满（与我的页备份弹窗同一写法）。
          Column() {
            MaterialButton({
              btnRadius: 12,
              btnBg: Theme.rgba(Theme.colorOf(this.themeColor), 0.12),
              btnBlur: BlurStyle.NONE,
              btnOnClick: () => {
                if (this.selectedExam !== null) {
                  const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
                  CalendarUtil.addExamToCalendar(this.selectedExam, ctx);
                }
              }
            }) {
              Text(T('导入日历'))
                .fontSize(15)
                .fontColor(Theme.colorOf(this.themeColor))
                .width('100%')
                .height(44)
                .textAlign(TextAlign.Center)
            }
          }
          .layoutWeight(1)
          Column() {
            // 红底语义按钮（同 pickExamSheet 红关闭先例）：immersive 开时加磨砂，关时纯实底
            MaterialButton({
              btnRadius: 12,
              btnBg: '#DB5252',
              btnBlur: (AppStorage.get<boolean>('immersiveEffect') ?? false) ? BlurStyle.Thin : BlurStyle.NONE,
              btnBorderW: 1,
              btnBorderC: 'rgba(255,255,255,0.28)',
              btnOnClick: () => {
                this.showDetail = false;
              }
            }) {
              Text(T('关闭'))
                .fontSize(15)
                // 红底上的文字黑白自适应
                .fontColor($r('sys.color.font_primary'))
                .width('100%')
                .height(44)
                .textAlign(TextAlign.Center)
            }
          }
          .layoutWeight(1)
          .margin({ left: 12 })
        }
        .width('100%')
        .margin({ top: 18 })
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 24 })
    }
  }

  @Builder
  termPickerSheet() {
    // 弹窗内容套 MaterialSheetPanel（同考试详情弹窗）：材质由 Toggle 承载层渲染，bindSheet 必须显式透明底；
    // 高度随内容（FIT_CONTENT）→ panelFillHeight: false；内层 20/8/24vp 内边距原样保留。
    MaterialSheetPanel({ panelRadius: 20, panelPadding: 0, panelFillHeight: false, panelTitle: T('选择学年-学期'), panelShowClose: true, panelOnClose: (): void => { this.showTermSheet = false; } }) {
    Column() {
      if (this.terms.length === 0) {
        Text(T('暂无可查询的学期'))
          .fontSize(13)
          .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          .width('100%')
          .textAlign(TextAlign.Center)
      } else {
        Scroll() {
          Column() {
            ForEach(this.terms, (term: TermInfo, index: number) => {
              // 学期行保留实色底：选中态靠实色背景（选中=主题色 / 未选中=浅灰）表达，
              // 沉浸光感材质会让出底色、把选中态吃掉，故不改为材质按钮。
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
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .constraintSize({ maxHeight: 360 })
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 24 })
    }
  }

  @Builder
  sheetRow(label: string, value: string, dotColor: string) {
    Row() {
      Column()
        .width(6)
        .height(6)
        .borderRadius(3)
        .backgroundColor(dotColor)
        .margin({ right: 10 })
      Text(label)
        .fontSize(13)
        .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
        .width(72)
      Text(value)
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 7, bottom: 7 })
  }

  /** 考试性质配色（互不冲突）：正考=南医蓝 / 补考重修=橙 / 缓考=蓝 / 其他=灰 */
  private examTypeColor(examType: string): string {
    if (examType === '正考' || examType === '正常考试') {
      return '#005BAC';
    }
    if (examType === '补考' || examType === '重修') {
      return '#FF9800';
    }
    if (examType === '缓考') {
      return '#3B82F6';
    }
    return '#9E9E9E';
  }

  /**
   * 桌面卡片"选择倒计时考试"弹窗：列出未来未开始的考试，让用户主动选一场
   * 作为桌面卡片显示；点击即生效。
   */
  @Builder
  pickExamSheet() {
    // 弹窗内容套 MaterialSheetPanel（同详情/学期弹窗）：材质由 Toggle 承载层渲染，bindSheet 必须显式透明底；
    // 高度随内容（SheetSize.LARGE 固定高）→ 保持 panelFillHeight 默认 true，让材质裹住整块面板。
    MaterialSheetPanel({ panelRadius: 20, panelPadding: 0, panelFillHeight: false, panelTitle: T('选择桌面卡片倒计时'), panelShowClose: true, panelOnClose: (): void => { this.showPickExam = false; } }) {
    Column() {
      // 顶部说明（去掉重复标题"桌面卡片倒计时"，sheet 自身 title 已显示）
      Text(T('选一场考试作为桌面卡片的倒计时对象'))
        .fontSize(12)
        .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
        .width('100%')
        .margin({ bottom: 4 })
      Text(T('不选则自动显示最近一场未开始的考试'))
        .fontSize(11)
        .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
        .width('100%')
        .margin({ bottom: 14 })

      // 当前选择状态
      Row() {
        Text(this.pickedExamId.length === 0 ? '当前: 最近一场考试自动倒计时' : `当前: ${this.pickedExamName()}`)
          .fontSize(12)
          .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.pickedExamId.length > 0) {
          // 清除选择：胶囊小按钮，材质走 MaterialButton 的 Toggle 承载层（btnBg 保留原蓝色浅底；
          // 原按钮无边框、无磨砂 → 光感关闭时按原样回落）
          MaterialButton({
            btnRadius: 4,
            btnBg: 'rgba(44,95,168,0.10)',
            btnBlur: BlurStyle.NONE,
            btnOnClick: () => {
              this.pickExamForCard(null);
              this.showPickExam = false;
            }
          }) {
            Text(T('清除选择'))
              .fontSize(11)
              .fontColor('#2C5FA8')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          }
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor($r('app.color.bg_chip')).backgroundBlurStyle((AppStorage.get<boolean>('immersiveEffect') ?? false) ? BlurStyle.Thin : BlurStyle.NONE).border({ width: 1, color: 'rgba(255,255,255,0.28)' }).shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 }).clip(true)
      .borderRadius(10)
      .margin({ bottom: 12 })

      // 未来未开始的考试列表
      Scroll() {
        Column() {
          if (this.exams.length === 0) {
            Text(T('本学期暂无考试安排，刷新后重试'))
              .fontSize(12)
              .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding(20)
          } else {
            ForEach(this.exams, (item: ExamItem) => {
              if (this.daysLeft(item) >= 0) {
                Row() {
                  Column() {
                    Text(item.courseName)
                      .fontSize(14)
                      .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`${item.date} ${item.timeRange} · ${item.location}`)
                      .fontSize(11)
                      .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                      .margin({ top: 4 })
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  .margin({ right: 8 })

                  if (this.pickedExamId === item.id) {
                    // 「当前使用」是选中态标签（无点击）：保留实色底——选中态靠实色背景表达，
                    // 材质会让出底色、把选中态吃掉，故不改为材质按钮。
                    Text(T('当前使用'))
                      .fontSize(11)
                      .fontColor($r('app.color.brand_on'))
                      .backgroundColor(Theme.colorOf(this.themeColor)).backgroundBlurStyle((AppStorage.get<boolean>('immersiveEffect') ?? false) ? BlurStyle.Thin : BlurStyle.NONE).border({ width: 1, color: 'rgba(255,255,255,0.28)' }).shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 }).clip(true)
                      .height(24)
                      .padding({ left: 8, right: 8 })
                      .borderRadius(12)
                      .textAlign(TextAlign.Center)
                  } else {
                    // 用作倒计时：胶囊小按钮，材质走 MaterialButton 的 Toggle 承载层
                    MaterialButton({
                      btnRadius: 12,
                      btnBg: Theme.rgba(Theme.colorOf(this.themeColor), 0.12),
                      btnBlur: GlassMaterial.cardBlur(),
                      btnBorderW: GlassMaterial.cardBorderWidth(),
                      btnBorderC: GlassMaterial.borderColor(),
                      btnOnClick: () => {
                        this.pickExamForCard(item);
                        this.showPickExam = false;
                      }
                    }) {
                      Text(T('用作倒计时'))
                        .fontSize(11)
                        .fontColor(Theme.colorOf(this.themeColor))
                        .height(24)
                        .padding({ left: 8, right: 8 })
                        .textAlign(TextAlign.Center)
                    }
                  }
                }
                .width('100%')
                .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                .backgroundColor(this.pickedExamId === item.id ? Theme.rgba(Theme.colorOf(this.themeColor), 0.12) : (this.tintBg.length > 0 ? this.tintBg : GlassMaterial.homeCardBg($r('app.color.bg_card')))).backgroundBlurStyle(GlassMaterial.cardBlur()).border({ width: GlassMaterial.cardBorderWidth(), color: GlassMaterial.borderColor() }).shadow(GlassMaterial.cardShadowStyle()).clip(true)
                .borderRadius(10)
                .margin({ bottom: 6 })
              }
              // key 带选中态：否则换了倒计时考试后，列表仍显示旧的「当前使用」
            }, (item: ExamItem) => `${item.id}_${this.pickedExamId === item.id ? 1 : 0}`)
          }
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .constraintSize({ maxHeight: 380 })
      .edgeEffect(EdgeEffect.Spring)

      // 底部关闭按钮
      Row() {
        // 关闭：材质走 MaterialButton；原 Button 的 layoutWeight 移到外层 Column
        // （MaterialButton 的 Stack 内部 layoutWeight 不生效），内容自己撑满点击区。
        Column() {
          MaterialButton({
            btnRadius: 10,
            // 底部矩形关闭按钮改红色（用户澄清：是这里，不是右上角 ✕）
            btnBg: '#DB5252',
            btnBlur: (AppStorage.get<boolean>('immersiveEffect') ?? false) ? BlurStyle.Thin : BlurStyle.NONE,
            btnBorderW: 1,
            btnBorderC: 'rgba(255,255,255,0.28)',
            btnOnClick: () => {
              this.showPickExam = false;
            }
          }) {
            Text(T('关闭'))
              .fontSize(14)
              // 红底上的文字黑白自适应
              .fontColor($r('sys.color.font_primary'))
              .width('100%')
              .height(40)
              .textAlign(TextAlign.Center)
          }
        }
        .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 14 })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 24 })
    }
  }

  build() {
    NavDestination() {
      // Stack 包裹：让"桌面卡片选考试"弹窗单独挂载在独立组件上，
      // 与外层 showTermSheet / 内层 showDetail 三种弹窗互不冲突
      Stack() {
        // 二级页壁纸底层（无壁纸回 bg_page，不透下层）
        WallpaperFill()
      Column() {
        // 顶栏（两层）：内容(底)/主题渐变(顶)；模糊层已取消
        Stack({ alignContent: Alignment.TopStart }) {
          Column()
            .width('100%')
            .height(this.getUIContext().px2vp(this.topInsetPx) + 60)
            .linearGradient({
              angle: 180,
              colors: Theme.barGradient(this.themeColor, this.barStyle)
            })
            .backgroundBlurStyle(Immersive.blur(BlurStyle.Thin, this.barStyle === 'legacy'))
        Row() {
          BackButton({ onBack: () => { AppState.stack.pop(); } })

          Column() {
            Text(T('考试查询'))
              .fontSize(20)
              .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
              .fontColor(WallpaperTone.onWallpaper(this.wallpaperTone, this.isDarkMode))
              .height(28)
              .lineHeight(28)
Row() {
              Text(`${this.currentTermLabel()} · 待考 ${this.comingCount()} 场`)
                .fontSize(11)
                .fontColor(WallpaperTone.onWallpaper(this.wallpaperTone, this.isDarkMode))
              Image($r('app.media.list_bullet'))
                .width(14)
                .height(14)
                .fillColor(this.subtitleColor.length > 0 ? this.subtitleColor : (this.barStyle === 'legacy' ? 'rgba(255,255,255,0.92)' : (this.isDarkMode ? GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary')) : '#CCFFFFFF')))
                .margin({ left: 3 })
            }
            .height(15)
            .margin({ top: 2 })
            .onClick(() => {
              this.showTermSheet = true;
            })
          }
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 6 })
          .layoutWeight(1)

          // 右上："桌面卡片"快捷按钮（触发选考试弹窗）→ MaterialButton（Toggle 承载层，btnPersistent 常驻：
          // 不随全局沉浸光感开关关闭而消失；光感关闭回落原白玻璃胶囊）。原 34 高胶囊由内容 Text height(34) 撑出，
          // 视觉与左侧返回按钮统一；微阴影随材质统一让出。
          // 保存为图片：SaveButton 安全控件 —— 点击即授权并直接落相册，
          // 不再弹「选择打开方式」选择器（用户反馈那条路径很难用）。
          // 导出：与学业情况页同一套（离屏渲染整份清单 → 系统相册确认框）
          MaterialButton({
            btnRadius: 17,
            btnPersistent: true,
            btnBg: this.isDarkMode ? 'rgba(255,255,255,0.16)' : 'rgba(255,255,255,0.24)',
            btnBlur: Immersive.blur(BlurStyle.Thin, this.immersiveEffect),
            btnBorderW: 1,
            btnBorderC: 'rgba(255,255,255,0.28)',
            btnMargin: { right: 8 },
            btnOnClick: () => {
              this.exportExamsAsImage();
            }
          }) {
            Text(this.exportingImage ? T('生成中…') : T('导出'))
              .fontSize(13)
              .fontColor(WallpaperTone.onWallpaper(this.wallpaperTone, this.isDarkMode))
              .height(34)
              .padding({ left: 14, right: 14 })
              .textAlign(TextAlign.Center)
          }
          MaterialButton({
            btnRadius: 17,
            btnPersistent: true,
            btnBg: this.isDarkMode ? 'rgba(255,255,255,0.16)' : 'rgba(255,255,255,0.24)',
            btnBlur: Immersive.blur(BlurStyle.Thin, this.immersiveEffect),
            btnBorderW: 1,
            btnBorderC: 'rgba(255,255,255,0.28)',
            btnOnClick: () => {
              this.showPickExam = true;
            }
          }) {
            Text(T('桌面卡片'))
              .fontSize(13)
              .fontColor(WallpaperTone.onWallpaper(this.wallpaperTone, this.isDarkMode))
              .height(34)
              .padding({ left: 14, right: 14 })
              .textAlign(TextAlign.Center)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .padding({ left: 10, right: 16, bottom: 12, top: this.getUIContext().px2vp(this.topInsetPx) + 12 })
        .height(this.getUIContext().px2vp(this.topInsetPx) + 60)
        }
        .width('100%')
        // 顶栏悬浮：正文可滚入其渐变下层透出
        .position({ x: 0, y: 0 })
        .zIndex(2)

        // 考试详情弹层挂在内层容器，与外层"选择学期"弹层分离
        Column() {
          if (this.loading) {
            LoadingTip()
          } else {
            Refresh({ refreshing: $$this.refreshing }) {
            Scroll() {
              Column() {
                // 顶栏悬浮让位（正文默认从顶栏下方开始，上滑才滚入渐变下层）
                Column().width('100%').height(this.getUIContext().px2vp(this.topInsetPx) + 60)
                // MaterialCard 承载：材质层是卡片内部底层，材质生效时卡片底色让出；
                // 原 14vp 内边距走 cardPadding、16vp 圆角走 cardRadius、14vp 下间距走 cardMargin；
                // 卡片底色是主题色淡底（材质不可用时回落它，观感与原卡片一致）
                MaterialCard({
                  cardRadius: 16,
                  cardPadding: 14,
                  cardBg: Theme.rgba(Theme.colorOf(this.themeColor), 0.12),
                  cardBlur: GlassMaterial.cardBlur(),
                  cardBorderW: GlassMaterial.cardBorderWidth(),
                  cardBorderC: GlassMaterial.borderColor(),
                  cardShadow: GlassMaterial.cardShadowStyle(),
                  cardMargin: { bottom: 14 }
                }) {
                Row() {
                  Column() {
                    Text(this.nextExamText())
                      .fontSize(14)
                      .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                      .fontColor($r('app.color.text_primary'))
                    Text(T('考试须携带学生证与身份证，提前 15 分钟入场'))
                      .fontSize(11)
                      .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                      .margin({ top: 4 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                }
                .width('100%')
                }

                if (this.exams.length === 0) {
                  EmptyTip({ text: T('本学期暂无考试安排') })
                } else {
                  ForEach(this.exams, (item: ExamItem) => {
                    this.examCard(item)
                  }, (item: ExamItem) => item.id)

                  // 一键加入日历（含提前 1 天 / 1 小时提醒）
                  Row({ space: 6 }) {
                    Image($r('app.media.calendar'))
                      .width(15)
                      .height(15)
                      .fillColor(Theme.colorOf(this.themeColor))
                    Text(this.addingCalendar ? T('正在写入日历…') : T('全部加入系统日历（自动提醒）'))
                      .fontSize(13)
                      .fontColor(Theme.colorOf(this.themeColor))
                  }
                  .width('100%')
                  .height(42)
                  .justifyContent(FlexAlign.Center)
                  .backgroundColor(Theme.rgba(Theme.colorOf(this.themeColor), 0.10))
                  .borderRadius(12)
                  .margin({ top: 4, bottom: 4 })
                  .onClick(() => {
                    this.addExamsToCalendar(null);
                  })
                }

                Column()
                  .height(this.getUIContext().px2vp(this.bottomInsetPx) + 16)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14 })
              .id('examShareArea')
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
        .layoutWeight(1)
        .bindSheet($$this.showDetail, this.detailSheet(), {
          width: SheetUtil.sheetWidth(),
          preferType: SheetType.BOTTOM,
          height: SheetSize.FIT_CONTENT,
          dragBar: true,
          // 关闭按钮由 MaterialSheetPanel 自绘（沉浸光感），系统 showClose 必须关掉避免双按钮
          showClose: false,
          // 必须显式透明：BindOptions.backgroundColor 默认是 Color.White，
          // 而沉浸光感的视觉层级位于 backgroundColor **之下**，白底会把 MaterialSheetPanel 的材质整块盖住。
          backgroundColor: Color.Transparent,
          blurStyle: sheetBlurStyle()
        })
      }
      .width('100%')
      .height('100%')
      // 全局壁纸：二级页根背景透明，透出主框架底层壁纸（无壁纸时由 MainView 底层纯色兜底）
      .backgroundColor(Color.Transparent)
      .bindSheet($$this.showTermSheet, this.termPickerSheet(), {
        width: SheetUtil.sheetWidth(),
        preferType: SheetType.BOTTOM,
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        // 关闭按钮由 MaterialSheetPanel 自绘（沉浸光感），系统 showClose 必须关掉避免双按钮
        showClose: false,
        // 同考试详情弹窗：显式透明底 + 材质模糊（否则默认白底盖住 MaterialSheetPanel 的材质）
        backgroundColor: Color.Transparent,
        blurStyle: sheetBlurStyle()
      })
      }
      // pickSheet 挂在最外 Stack 上，独立组件避免与 showTermSheet/showDetail 互相覆盖
      .width('100%')
      .height('100%')
      .bindSheet($$this.showPickExam, this.pickExamSheet(), {
        width: SheetUtil.sheetWidth(),
        preferType: SheetType.BOTTOM,
        // 高度自适应内容（此前 LARGE 固定高，内容少时面板下半截空一大块）
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        // 关闭按钮由 MaterialSheetPanel 自绘（沉浸光感），系统 showClose 必须关掉避免双按钮
        showClose: false,
        // 同考试详情弹窗：显式透明底 + 材质模糊（否则默认白底盖住 MaterialSheetPanel 的材质）
        backgroundColor: Color.Transparent,
        blurStyle: sheetBlurStyle()
      })
    }
    .backgroundColor($r('app.color.bg_page'))
    .hideTitleBar(true)
    .systemTransition(NavigationSystemTransitionType.SLIDE_RIGHT)
  }
}