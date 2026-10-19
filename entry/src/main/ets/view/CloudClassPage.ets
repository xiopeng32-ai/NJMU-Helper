/**
 * CloudClassPage — 云课堂（智教云）页面
 *
 * 展示：我的课程 / 课堂实录 / 通知（分段切换）。
 * 数据来源 CloudClassApi（纯 API 直连，复用统一身份认证 CAS）。
 *
 * 首次进入：若未登录云课堂，尝试用持久化 CASTGC 静默续期；
 * 失败则提示去登录（复用教务登录成功后自动建立云课堂会话）。
 */
import { CloudClassApi } from '../api/CloudClassApi';
import { Const } from '../common/Constants';
import { AppState } from '../common/AppState';
import { GlassMaterial } from '../common/GlassMaterial';
import { WallpaperTone } from '../common/WallpaperTone';
import { Immersive } from './common/Immersive';
import { MaterialCard } from './common/MaterialCard';
import { MaterialButton } from './common/MaterialButton';
import { BarTitle, EmptyTip, LoadingTip } from './common/UiKit';
import { AntiPeepOverlay } from './common/AntiPeepOverlay';
import { WallpaperFill } from './common/WallpaperFill';
import { CloudCourse, CloudNotice, RecordCourse } from '../model/CloudModels';

@Component
export struct CloudClassPage {
  @StorageProp('topInsetPx') topInsetPx: number = 0;
  @StorageProp('bottomInsetPx') bottomInsetPx: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageProp('wallpaperTone') wallpaperTone: number = -1;
  @StorageProp('immersiveEffect') immersiveEffect: boolean = false;
  @StorageProp('barStyle') barStyle: string = 'new';
  @StorageProp('fontWeightMode') fwMode: string = 'follow';
  @StorageProp('grayTick') grayTick: number = 0;

  /** 分段：course=课程 / record=课堂实录 / notice=通知 */
  @State seg: string = 'course';
  @State loading: boolean = false;
  @State loggedIn: boolean = false;
  @State userName: string = '';
  @State courses: CloudCourse[] = [];
  @State recordCourses: RecordCourse[] = [];
  @State notices: CloudNotice[] = [];
  @State error: string = '';

  aboutToAppear(): void {
    this.load();
  }

  /** 加载：先静默续期，再拉课程/实录/通知 */
  private async load(): Promise<void> {
    this.loading = true;
    this.error = '';
    try {
      // 确保会话（已登录则复用，否则静默续期，再失败提示）
      if (!CloudClassApi.isLoggedIn()) {
        await CloudClassApi.silentRelogin();
      }
      const s = CloudClassApi.getSession();
      if (s !== null) {
        this.loggedIn = true;
        this.userName = s.userName;
      }
      // 拉取当前学期 + 数据
      const term = await CloudClassApi.getCurrentTerm();
      if (term === null) {
        this.error = '未获取到当前学期';
        return;
      }
      const sy: string = term.schoolYear;
      const tm: string = term.term;
      const courses = await CloudClassApi.getMyCourses(sy, tm);
      const records = await CloudClassApi.getRecordCourses(sy, tm);
      const notices = await CloudClassApi.getNotifications(sy, tm);
      this.courses = courses;
      this.recordCourses = records;
      this.notices = notices;
    } catch (e) {
      this.error = (e as Error).message ?? '加载失败';
      this.loggedIn = CloudClassApi.isLoggedIn();
    } finally {
      this.loading = false;
    }
  }

  /** 重新加载（下拉/按钮） */
  private async refresh(): Promise<void> {
    await this.load();
  }

  @Builder
  segBar() {
    Row({ space: 8 }) {
      this.segChip('course', '我的课程')
      this.segChip('record', '课堂实录')
      this.segChip('notice', '通知')
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  segChip(key: string, label: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.seg === key ? '#FFFFFF' : (this.isDarkMode ? '#CCCCCC' : '#555555'))
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .backgroundColor(this.seg === key ? '#1B3A63' : Color.Transparent)
      .borderRadius(16)
      .onClick(() => {
        this.seg = key;
      })
  }

  @Builder
  courseList() {
    if (this.courses.length === 0) {
      EmptyTip({ text: '暂无课程' })
    } else {
      Column() {
        ForEach(this.courses, (c: CloudCourse) => {
          MaterialCard({
            cardRadius: 14,
            cardMargin: { top: 10 },
            cardBg: GlassMaterial.homeCardBg($r('app.color.bg_card')),
            cardBlur: GlassMaterial.cardBlur(),
            cardBorderW: GlassMaterial.cardBorderWidth(),
            cardBorderC: GlassMaterial.borderColor(),
            cardShadow: GlassMaterial.cardShadowStyle()
          }) {
            Column() {
              Text(c.courseName)
                .fontSize(15)
                .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${c.collegeName}${c.teacherName.length > 0 ? ` · ${c.teacherName}` : ''}`)
                .fontSize(12)
                .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary')))
                .margin({ top: 4 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }, (c: CloudCourse) => c.courseId)
      }
      .width('100%')
    }
  }

  @Builder
  recordList() {
    if (this.recordCourses.length === 0) {
      EmptyTip({ text: '暂无课堂实录' })
    } else {
      Column() {
        ForEach(this.recordCourses, (c: RecordCourse) => {
          MaterialCard({
            cardRadius: 14,
            cardMargin: { top: 10 },
            cardBg: GlassMaterial.homeCardBg($r('app.color.bg_card')),
            cardBlur: GlassMaterial.cardBlur(),
            cardBorderW: GlassMaterial.cardBorderWidth(),
            cardBorderC: GlassMaterial.borderColor(),
            cardShadow: GlassMaterial.cardShadowStyle()
          }) {
            Row() {
              if (c.coverUrl.length > 0) {
                Image(c.coverUrl)
                  .width(56)
                  .height(40)
                  .borderRadius(6)
                  .objectFit(ImageFit.Cover)
              }
              Column() {
                Text(c.courseName)
                  .fontSize(15)
                  .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${c.weeks.length} 周次录播${c.teacherNames.length > 0 ? ` · ${c.teacherNames}` : ''}`)
                  .fontSize(12)
                  .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary')))
                  .margin({ top: 4 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: c.coverUrl.length > 0 ? 12 : 0 })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
        }, (c: RecordCourse) => c.courseId)
      }
      .width('100%')
    }
  }

  @Builder
  noticeList() {
    if (this.notices.length === 0) {
      EmptyTip({ text: '暂无通知' })
    } else {
      Column() {
        ForEach(this.notices, (n: CloudNotice, idx: number) => {
          MaterialCard({
            cardRadius: 14,
            cardMargin: { top: 10 },
            cardBg: GlassMaterial.homeCardBg($r('app.color.bg_card')),
            cardBlur: GlassMaterial.cardBlur(),
            cardBorderW: GlassMaterial.cardBorderWidth(),
            cardBorderC: GlassMaterial.borderColor(),
            cardShadow: GlassMaterial.cardShadowStyle()
          }) {
            Column() {
              Text(n.content)
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .lineHeight(20)
                .width('100%')
              Text(n.notificationDate)
                .fontSize(11)
                .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary')))
                .margin({ top: 6 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }, (n: CloudNotice, idx: number) => `${idx}_${n.notificationDate}`)
      }
      .width('100%')
    }
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        WallpaperFill()
        Column() {
          // 顶栏占位
          Column()
            .width('100%')
            .height(this.getUIContext().px2vp(this.topInsetPx) + 60)

          if (this.loading) {
            LoadingTip()
          } else if (this.error.length > 0) {
            Column() {
              Text(this.error)
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .textAlign(TextAlign.Center)
              MaterialButton({
                btnRadius: 18,
                btnBg: '#1B3A63',
                btnBlur: this.immersiveEffect ? BlurStyle.Thin : BlurStyle.NONE,
                btnBorderW: 1,
                btnBorderC: 'rgba(255,255,255,0.28)',
                btnMargin: { top: 16 },
                btnOnClick: () => { this.refresh(); }
              }) {
                Text('重试')
                  .fontSize(14)
                  .fontColor('#FFFFFF')
                  .width(100)
                  .height(36)
                  .textAlign(TextAlign.Center)
              }
            }
            .width('100%')
            .margin({ top: 60 })
            .alignItems(HorizontalAlign.Center)
          } else {
            Scroll() {
              Column() {
                // 登录状态行
                if (this.loggedIn) {
                  Text(this.userName.length > 0 ? `已登录云课堂 · ${this.userName}` : '已登录云课堂')
                    .fontSize(12)
                    .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary')))
                    .width('100%')
                }
                this.segBar()
                if (this.seg === 'course') {
                  this.courseList()
                } else if (this.seg === 'record') {
                  this.recordList()
                } else {
                  this.noticeList()
                }
                Column().height(this.getUIContext().px2vp(this.bottomInsetPx) + 24)
              }
              .width('100%')
              .padding({ left: 16, right: 16 })
            }
            .scrollBar(BarState.Off)
            .layoutWeight(1)
            .align(Alignment.Top)
            .edgeEffect(EdgeEffect.Spring)
          }
        }
        .width('100%')
        .height('100%')

        // 顶栏
        Stack({ alignContent: Alignment.TopStart }) {
          Column()
            .width('100%')
            .height(this.getUIContext().px2vp(this.topInsetPx) + 60)
            .backgroundColor('#1B3A63')
            .backgroundBlurStyle(Immersive.blur(BlurStyle.Thin, this.barStyle === 'legacy'))
          Row() {
            BarTitle({ title: '云课堂' })
            Blank()
          }
          .width('100%')
          .height(this.getUIContext().px2vp(this.topInsetPx) + 60)
          .alignItems(VerticalAlign.Top)
          .padding({ left: 16, right: 16, top: this.getUIContext().px2vp(this.topInsetPx) + 12, bottom: 12 })
        }
        .width('100%')
        .position({ x: 0, y: 0 })
        .zIndex(2)

        AntiPeepOverlay({ isPeeped: false })
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
