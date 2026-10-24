/**
 * TodaySchedulePage —— 今日课表
 *
 * 设计目标：一屏看完今天所有课，信息密度优先。
 *  - 顶部概览条：节数 / 起止时间 / 总学时（三格，一行）
 *  - 时间轴：左列起止时间 + 节次，右列紧凑课程卡
 *  - 课程卡三行：课程名+状态 / 节次·教室 / 类型·教师·学分·周次
 *  - 进行中：绿色描边 + 底部进度条 + 剩余分钟
 *  - 课与课之间若空档 ≥ 30 分钟，插一条虚线提示「空档 X」
 */
import { AppState } from '../common/AppState';
import { AppearanceStore } from '../common/AppearanceStore';
import { Const } from '../common/Constants';
import { DateUtil } from '../common/DateUtil';
import { SectionUtil } from '../common/SectionUtil';
import { LogStore } from '../common/LogStore';
import { Theme } from '../common/ThemeUtil';
import { WallpaperTone } from '../common/WallpaperTone';
import { JwApi } from '../api/JwApi';
import { CourseItem, TermInfo } from '../model/Models';
import { BackButton } from './common/BackButton';
import { Immersive } from './common/Immersive';
import { EmptyTip } from './common/UiKit';
import { WallpaperFill } from './common/WallpaperFill';
import { T } from '../common/I18n';

interface TodayRow {
  course: CourseItem;
  startMin: number;
  endMin: number;
  startText: string;
  endText: string;
  timeText: string;
  /** 0=已结束 1=进行中 2=待开始 */
  state: number;
}

@Component
export struct TodaySchedulePage {
  /** 界面语言版本号：切换语言后自增，订阅它即可重建本组件 */
  @StorageProp('langRev') langRev: number = 0;
  @StorageProp('topInsetPx') topInsetPx: number = 0;
  @StorageProp('bottomInsetPx') bottomInsetPx: number = 0;
  @StorageProp('themeColor') themeColor: string = 'green';
  @StorageProp('barStyle') barStyle: string = 'new';
  @StorageProp('wallpaperTone') wallpaperTone: number = -1;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageProp('fwMode') fwMode: string = 'follow';

  @State rows: TodayRow[] = [];
  @State currentWeek: number = 1;
  @State refreshing: boolean = false;
  @State loading: boolean = true;
  /** 概览条缓存：rebuild 时一次算好，避免 build 内重复遍历 rows */
  @State sumCount: string = '0';
  @State sumRange: string = '--:--';
  @State sumHours: string = '0';
  private tickTimer: number = -1;

  aboutToAppear(): void {
    this.refreshToday();
    // 30 秒重算一次状态与进度（足够跟手且省电）
    this.tickTimer = setInterval(() => {
      this.rebuild();
    }, 30000);
  }

  aboutToDisappear(): void {
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
  }

  private term(): TermInfo {
    return AppState.term;
  }

  private computeWeek(): number {
    if (AppState.mockCurrentWeek > 0) {
      return AppState.mockCurrentWeek;
    }
    const w: number = DateUtil.weekOfTerm(this.term(), new Date());
    return w < 1 ? 1 : w;
  }

  private async refreshToday(): Promise<void> {
    this.currentWeek = this.computeWeek();
    const cached: CourseItem[] = JwApi.loadCachedCourses();
    if (cached.length > 0) {
      this.rebuild(cached);
      this.loading = false;
    }
    try {
      const fresh: CourseItem[] = await JwApi.getCoursesSmart(this.term().id, false);
      if (fresh.length > 0) {
        this.rebuild(fresh);
      }
    } catch (e) {
      LogStore.log('今日课表', '刷新', '失败回退缓存', LogStore.errorOf(e as Object));
    } finally {
      this.loading = false;
      this.refreshing = false;
    }
  }

  private rebuild(courses?: CourseItem[]): void {
    this.currentWeek = this.computeWeek();
    this.rows = this.pick(courses !== undefined ? courses : JwApi.loadCachedCourses());
    this.recalcSummary();
  }

  /** 重算概览（节数 / 起止 / 学时），仅在数据或状态变化时执行 */
  private recalcSummary(): void {
    this.sumCount = `${this.rows.length}`;
    this.sumRange = `${this.firstStart()}-${this.lastEnd()}`;
    this.sumHours = this.totalHours();
  }

  private pick(courses: CourseItem[]): TodayRow[] {
    const weekday: number = DateUtil.weekdayOf(new Date());
    const nowMin: number = DateUtil.minutesOfNow();
    const raw: CourseItem[] = [];
    for (const c of courses) {
      if (c.noSchedule || c.weekday !== weekday) {
        continue;
      }
      if (c.weeks.includes(this.currentWeek)) {
        raw.push(c);
      }
    }
    raw.sort((a: CourseItem, b: CourseItem) => a.startSection - b.startSection);
    const out: TodayRow[] = [];
    for (const c of raw) {
      const s: number = SectionUtil.startMinCurrent(c.startSection);
      const e: number = SectionUtil.endMinCurrent(c.endSection);
      let state: number = 2;
      if (nowMin > e) {
        state = 0;
      } else if (nowMin >= s) {
        state = 1;
      }
      const row: TodayRow = {
        course: c,
        startMin: s,
        endMin: e,
        startText: this.secText(c.startSection, false),
        endText: this.secText(c.endSection, true),
        timeText: SectionUtil.rangeTextCurrent(c.startSection, c.endSection),
        state: state
      };
      out.push(row);
    }
    return out;
  }

  /** 单节起止时刻：按当前生效作息（尊重用户的课表设置），不再读硬编码 Const.SECTIONS */
  private secText(section: number, end: boolean): string {
    const min: number = end
      ? SectionUtil.endMinCurrent(section)
      : SectionUtil.startMinCurrent(section);
    const h: number = Math.floor(min / 60);
    const m: number = min % 60;
    return `${h < 10 ? '0' : ''}${h}:${m < 10 ? '0' : ''}${m}`;
  }

  private nowMin(): number {
    return DateUtil.minutesOfNow();
  }

  private finishedCount(): number {
    let n: number = 0;
    for (const r of this.rows) {
      if (r.state === 0) {
        n++;
      }
    }
    return n;
  }

  private firstStart(): string {
    return this.rows.length === 0 ? '--:--' : this.rows[0].startText;
  }

  private lastEnd(): string {
    if (this.rows.length === 0) {
      return '--:--';
    }
    let m: number = 0;
    let text: string = '--:--';
    for (const r of this.rows) {
      if (r.endMin > m) {
        m = r.endMin;
        text = r.endText;
      }
    }
    return text;
  }

  /** 今日总学时（按 45 分钟 / 学时折算） */
  private totalHours(): string {
    let min: number = 0;
    for (const r of this.rows) {
      min += r.endMin - r.startMin;
    }
    const h: number = Math.round(min / 45 * 10) / 10;
    return `${h}`;
  }

  private stateText(row: TodayRow): string {
    const n: number = this.nowMin();
    if (row.state === 0) {
      return T('已结束');
    }
    if (row.state === 1) {
      const left: number = row.endMin - n;
      return left <= 0 ? '即将下课' : `剩 ${left} 分`;
    }
    const diff: number = row.startMin - n;
    if (diff <= 0) {
      return T('即将开始');
    }
    if (diff < 60) {
      return `${diff} 分钟后`;
    }
    return `${Math.floor(diff / 60)} 时 ${diff % 60} 分后`;
  }

  private stateColor(row: TodayRow): string {
    if (row.state === 0) {
      return '#9AA0A6';
    }
    if (row.state === 1) {
      return '#1E9E5A';
    }
    return Theme.colorOf(this.themeColor);
  }

  /** 进行中进度（0-100） */
  private progressOf(row: TodayRow): number {
    const span: number = row.endMin - row.startMin;
    if (span <= 0) {
      return 0;
    }
    const done: number = this.nowMin() - row.startMin;
    return Math.max(0, Math.min(100, Math.round(done / span * 100)));
  }

  private typeColor(type: string): string {
    if (type.indexOf('核心') >= 0) {
      return '#2F6FDE';
    }
    if (type.indexOf('实践') >= 0) {
      return '#E08A00';
    }
    if (type.indexOf('通识') >= 0) {
      return '#8B5CF6';
    }
    return '#5B6470';
  }

  /** 第二行：节次 · 教室 */
  private secondLine(row: TodayRow): string {
    const sec: string = `第${row.course.startSection}-${row.course.endSection}节`;
    return row.course.location.length > 0 ? `${sec} · ${row.course.location}` : sec;
  }

  /** 第三行元信息：教师 · 类型 · 学分 · 周次（单行拼接，减少节点数） */
  private metaText(row: TodayRow): string {
    const parts: string[] = [];
    if (row.course.courseType.length > 0) {
      parts.push(row.course.courseType);
    }
    if (row.course.teacher.length > 0) {
      parts.push(row.course.teacher);
    }
    if (row.course.credit > 0) {
      parts.push(`${row.course.credit} 学分`);
    }
    if (row.course.weeksText.length > 0) {
      parts.push(row.course.weeksText);
    }
    return parts.join(' · ');
  }

  private todayLabel(): string {
    const d: Date = new Date();
    const w: string = Const.WEEK_LABELS[DateUtil.weekdayOf(d) - 1];
    return `${d.getMonth() + 1} 月 ${d.getDate()} 日 · ${w}`;
  }

  private topVp(): number {
    return this.getUIContext().px2vp(this.topInsetPx);
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
              .height(this.topVp() + 56)
              .linearGradient({ angle: 180, colors: Theme.barGradient(this.themeColor, this.barStyle) })
              .backgroundBlurStyle(Immersive.blur(BlurStyle.Thin, this.barStyle === 'legacy'))
            Row() {
              BackButton({ onBack: () => { AppState.stack.pop(); } })
              Column() {
                Text(T('今日课表'))
                  .fontSize(19)
                  .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
                  .fontColor(WallpaperTone.onWallpaper(this.wallpaperTone, this.isDarkMode))
                  .height(26)
                  .lineHeight(26)
                Text(`${this.todayLabel()} · 第 ${this.currentWeek} 周`)
                  .fontSize(10)
                  .fontColor(WallpaperTone.onWallpaper(this.wallpaperTone, this.isDarkMode))
                  .height(14)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Text(this.rows.length > 0
                ? `${this.rows.length - this.finishedCount()}/${this.rows.length} 待上`
                : '无课')
                .fontSize(10)
                .fontColor(WallpaperTone.onWallpaper(this.wallpaperTone, this.isDarkMode))
            }
            .width('100%')
            .height(this.topVp() + 56)
            .alignItems(VerticalAlign.Top)
            .padding({ left: 10, right: 16, top: this.topVp() + 8, bottom: 8 })
          }
          .width('100%')
          .height(this.topVp() + 56)

          // 概览条：节数 / 起止 / 学时
          if (this.rows.length > 0) {
            Row() {
              this.overviewCell(this.sumCount, '节课')
              Divider().vertical(true).height(18).color('rgba(128,128,128,0.22)')
              this.overviewCell(this.sumRange, T('时间'))
              Divider().vertical(true).height(18).color('rgba(128,128,128,0.22)')
              this.overviewCell(this.sumHours, '学时')
            }
            .width('100%')
            .height(40)
            .backgroundColor($r('app.color.bg_card'))
            .padding({ left: 4, right: 4 })
          }

          Refresh({ refreshing: $$this.refreshing }) {
            Scroll() {
              Column() {
                if (this.rows.length === 0) {
                  EmptyTip({ text: this.loading ? '正在读取课表…' : '今天没有课程' })
                  Text(T('查看完整课表'))
                    .fontSize(13)
                    .fontColor('#FFFFFF')
                    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                    .backgroundColor(Theme.colorOf(this.themeColor))
                    .borderRadius(16)
                    .margin({ top: 16 })
                    .onClick(() => {
                      AppState.stack.pop();
                      AppStorage.setOrCreate<number>('switchTabRequest', 1);
                    })
                } else {
                  ForEach(this.rows, (row: TodayRow) => {
                    this.courseRow(row)
                  }, (row: TodayRow) => row.course.id)
                  Text(T('查看完整课表'))
                    .fontSize(12)
                    .fontColor(Theme.colorOf(this.themeColor))
                    .width('100%')
                    .textAlign(TextAlign.Center)
                    .padding({ top: 8, bottom: 8 })
                    .onClick(() => {
                      AppState.stack.pop();
                      AppStorage.setOrCreate<number>('switchTabRequest', 1);
                    })
                }
                Column().height(this.getUIContext().px2vp(this.bottomInsetPx) + 20)
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 10 })
            }
            .scrollBar(BarState.Off)
          }
          .onRefreshing(() => {
            this.refreshToday();
          })
          .layoutWeight(1)
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

  @Builder
  overviewCell(value: string, label: string) {
    Column() {
      Text(value)
        .fontSize(value.length > 10 ? 10 : 13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
      Text(label)
        .fontSize(9)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ top: 1 })
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  courseRow(row: TodayRow) {
    Column() {
      Row() {
        Text(`${row.startText}-${row.endText}`)
          .fontSize(11)
          .fontWeight(row.state === 1 ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(row.state === 0 ? '#9AA0A6' : this.stateColor(row))
          .margin({ right: 8 })
        Text(row.course.name)
          .fontSize(14)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
          .fontColor(row.state === 0 ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.stateText(row))
          .fontSize(9)
          .fontColor('#FFFFFF')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor(this.stateColor(row))
          .borderRadius(7)
          .margin({ left: 6 })
      }
      .width('100%')

      Text(this.secondLine(row))
        .fontSize(10)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 3 })

      Text(this.metaText(row))
        .fontSize(9)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 2 })

      if (row.state === 1) {
        Row() {
          Row()
            .width(`${this.progressOf(row)}%`)
            .height(2)
            .backgroundColor(this.stateColor(row))
            .borderRadius(1)
        }
        .width('100%')
        .height(2)
        .backgroundColor('rgba(30,158,90,0.18)')
        .borderRadius(1)
        .margin({ top: 6 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor(row.state === 1
      ? (this.isDarkMode ? 'rgba(30,158,90,0.18)' : 'rgba(30,158,90,0.07)')
      : $r('app.color.bg_card'))
    .borderRadius(12)
    .border({
      width: row.state === 1 ? 1.2 : 1,
      color: row.state === 1 ? this.stateColor(row) : 'rgba(128,128,128,0.14)'
    })
    .margin({ bottom: 6 })
  }
}
