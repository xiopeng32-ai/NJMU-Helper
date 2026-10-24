/**
 * 语言与地区（界面语言切换）
 *
 * 支持：跟随系统 / 简体中文 / 繁體中文 / English
 *  - 切换立即生效，无需重启：I18n.setPref() 写入偏好 + 广播 langRev，订阅方重建。
 *  - 同时把语言同步给系统（i18n.System.setAppPreferredLanguage），
 *    应用名、权限说明、桌面卡片名称等「资源文件」文案随之切换。
 *  - 繁体由简繁映射表即时转换，不需要逐条维护译文；英文查词典，未收录回落中文原文。
 *
 * 页面自带一个"实时预览"卡片：用当前语言渲染一段课程表 / 考试摘录，
 * 让用户在选择前就能看到排版效果（也顺便验证长英文不挤压布局）。
 */
import { AppState } from '../common/AppState';
import { PageHeader } from './common/UiKit';
import { WallpaperFill } from './common/WallpaperFill';
import { Theme } from '../common/ThemeUtil';
import { I18n, LangOption, T } from '../common/I18n';
import { NotifyScheduler } from '../common/NotifyScheduler';

/** 语言单选行（@Component 而非 @Builder：选中态要随状态即时刷新） */
@Component
struct LangRow {
  @Prop title: string = '';
  @Prop desc: string = '';
  @Prop selected: boolean = false;
  @Prop isLast: boolean = false;
  @StorageProp('themeColor') themeColor: string = 'green';
  onPick: () => void = () => {
  };

  build() {
    Row() {
      Column() {
        Text(this.title)
          .fontSize(15)
          .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Normal)
          .fontColor($r('app.color.text_primary'))
        if (this.desc.length > 0) {
          Text(this.desc)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 选中标记：主题色圆底 + 勾
      if (this.selected) {
        Stack() {
          Circle()
            .width(20)
            .height(20)
            .fill(Theme.colorOf(this.themeColor))
          Image($r('app.media.checkmark_sel'))
            .width(12)
            .height(12)
            .fillColor(Color.White)
        }
        .width(20)
        .height(20)
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 13, bottom: 13 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(12)
    .margin({ bottom: this.isLast ? 0 : 8 })
    .onClick(() => {
      this.onPick();
    })
  }
}

@Component
export struct LanguagePage {
  @StorageProp('topInsetPx') topInsetPx: number = 0;
  @StorageProp('bottomInsetPx') bottomInsetPx: number = 0;
  @StorageProp('themeColor') themeColor: string = 'green';
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /** 语言版本号：切换后自增 → 本页与所有订阅方一起重建 */
  @StorageProp('langRev') langRev: number = 0;
  /** 当前偏好（'system' / 'zh-Hans' / 'zh-Hant' / 'en-US'） */
  @State pref: string = I18n.getPref();
  /** 常用语言（跟随系统 / 简体 / 繁體 / English） */
  @State primaryOptions: LangOption[] = I18n.options(true);
  /** 其他语言（日 / 韩 / 法 / 德 / 西 / 俄 / 葡 / 意） */
  @State moreOptions: LangOption[] = I18n.options(false);

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        WallpaperFill()

        Scroll() {
          Column() {
            Column()
              .width('100%')
              .height(this.getUIContext().px2vp(this.topInsetPx) + 60)

            // ── 实时预览：用当前语言渲染一段课表 + 考试，直观看到排版效果 ──
            this.previewCard()

            this.sectionTitle(T('界面语言'))
            Text(T('选择应用界面使用的语言'))
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .margin({ bottom: 8, left: 4 })

            ForEach(this.primaryOptions, (opt: LangOption, idx: number) => {
              this.langRow(opt, idx, this.primaryOptions.length)
            }, (opt: LangOption, idx: number) => `p_${opt.id}_${this.pref === opt.id ? 1 : 0}_${this.langRev}_${idx}`)

            // ── 其他语言 ──
            Column()
              .height(18)
            this.sectionTitle(T('更多语言'))
            ForEach(this.moreOptions, (opt: LangOption, idx: number) => {
              this.langRow(opt, idx, this.moreOptions.length)
            }, (opt: LangOption, idx: number) => `m_${opt.id}_${this.pref === opt.id ? 1 : 0}_${this.langRev}_${idx}`)

            // ── 说明 ──
            Column() {
              Text(T('语言切换立即生效，无需重启应用。'))
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
              Text(T('学位课程、教务公告等校内数据由学校系统提供，保持原文语言。'))
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .margin({ top: 6 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 4, right: 4, top: 14 })

            Text('')
              .height(30 + this.getUIContext().px2vp(this.bottomInsetPx))
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)

        PageHeader({
          title: T('语言与地区'),
          onBack: () => {
            AppState.stack.pop();
          }
        })
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .onShown(() => {
      // 语言在别处被改动（含跟随系统解析结果变化）时同步选中态与副标题
      this.pref = I18n.getPref();
      this.primaryOptions = I18n.options(true);
      this.moreOptions = I18n.options(false);
    })
  }

  /** 一行语言选项（抽成 @Builder 便于两组共用；选中态来自 this.pref，能正常刷新） */
  @Builder
  langRow(opt: LangOption, idx: number, total: number) {
    LangRow({
      title: opt.native,
      desc: opt.id === 'system' ? T('跟随系统语言') : opt.desc,
      selected: this.pref === opt.id,
      isLast: idx === total - 1,
      onPick: () => {
        if (this.pref === opt.id) {
          return;
        }
        this.pref = opt.id;
        const changed: boolean = I18n.setPref(opt.id);
        // 已排入系统的课前提醒、成绩通知里的文案是「排程时」的字符串，
        // 不重建就会一直是旧语言 —— 这里强制重建一次（force 原因 'settings'）。
        if (changed) {
          NotifyScheduler.rescheduleAll('settings').catch(() => {
          });
        }
      }
    })
  }

  /** 分区标题 */
  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_tertiary'))
      .width('100%')
      .margin({ top: 4, bottom: 6, left: 4 })
  }

  /**
   * 预览卡片。
   * 用当前语言渲染，英文较长时用 maxLines + ellipsis 保证不撑破排版。
   */
  @Builder
  previewCard() {
    Column() {
      Text(T('预览'))
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')

      // 课程行
      Row() {
        Column()
          .width(4)
          .height(38)
          .backgroundColor(Theme.colorOf(this.themeColor))
          .borderRadius(2)
          .margin({ right: 10 })
        Column() {
          Text(T('高等数学'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${T('课程表')} · ${T('第{0}周', 8)} · ${T('周一')}`)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ top: 3 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(T('博学楼 A207 · 第 1-2 节'))
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ top: 2 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 12, bottom: 12 })

      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(0.5)

      // 考试行
      Row() {
        Column() {
          Text(T('考试安排'))
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('2026-10-28 09:00')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ top: 3 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(T('待考'))
          .fontSize(11)
          .fontColor(Theme.colorOf(this.themeColor))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(Theme.rgba(Theme.colorOf(this.themeColor), 0.12))
          .borderRadius(9)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 12, bottom: 4 })
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(14)
    .margin({ bottom: 14 })
  }
}
