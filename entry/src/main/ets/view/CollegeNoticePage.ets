/**
 * 学院公告订阅页（Navigation 二级页）
 * - 列出南医大各二级学院，勾选订阅（本地持久化）；
 * - 点击学院行 → WebView 打开该学院官网（公告以官网为准）；
 * - 顶部「已订阅」分组置顶，方便查看已订阅学院。
 */
import { NewsApi, CollegeEntry } from '../api/NewsApi';
import { AppState } from '../common/AppState';
import { Const } from '../common/Constants';
import { DataStore } from '../common/DataStore';
import { Theme } from '../common/ThemeUtil';
import { WallpaperTone } from '../common/WallpaperTone';
import { Immersive } from './common/Immersive';
import { BackButton } from './common/BackButton';
import { WallpaperFill } from './common/WallpaperFill';
import { AppearanceStore } from '../common/AppearanceStore';
import { GlassMaterial } from '../common/GlassMaterial';
import { T } from '../common/I18n';

@Component
export struct CollegeNoticePage {
  /** 界面语言版本号：切换语言后自增，订阅它即可重建本组件 */
  @StorageProp('langRev') langRev: number = 0;
  @StorageProp('topInsetPx') topInsetPx: number = 0;
  @StorageProp('grayTick') grayTick: number = 0;
  @StorageProp('fontWeightMode') fwMode: string = 'follow';
  @StorageProp('fontWeightValue') fwValue: number = 400;
  @StorageProp('glassStrength') glassStrength: number = 70;
  @StorageProp('cardMaterial') cardMaterial: boolean = false;
  @StorageProp('grayTextMode') grayTextMode: string = 'default';
  @StorageProp('grayTextColor') grayTextColor: string = '';
  @StorageProp('themeColor') themeColor: string = 'green';
  @StorageProp('barStyle') barStyle: string = 'new';
  @StorageProp('immersiveEffect') immersiveEffect: boolean = false;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageProp('wallpaperTone') wallpaperTone: number = -1;
  /** 订阅信号：切换订阅时自增，驱动列表重渲染订阅态 */
  @State subTick: number = 0;
  /** 已订阅学院域名列表（快照） */
  private subscribed: string[] = [];

  aboutToAppear(): void {
    this.refreshSubs();
  }

  private refreshSubs(): void {
    this.subscribed = DataStore.loadCollegeSubs();
  }

  /** 判断某学院是否已订阅 */
  private isSub(domain: string): boolean {
    return this.subscribed.indexOf(domain) >= 0;
  }

  /** 切换订阅 */
  private toggle(domain: string): void {
    DataStore.toggleCollegeSub(domain);
    this.refreshSubs();
    this.subTick++;
    const added: boolean = this.isSub(domain);
    this.getUIContext().getPromptAction().showToast({ message: added ? '已订阅，官网公告更新可随时查看' : '已取消订阅' });
  }

  /** 打开学院官网（WebView） */
  private openCollege(c: CollegeEntry): void {
    AppState.webUrl = NewsApi.collegeHome(c.domain);
    AppState.webTitle = `${c.name} · 公告`;
    AppState.stack.pushPath({ name: Const.ROUTE_WEB_PAGE });
  }

  /** 学院行（统一布局，订阅按钮在右） */
  @Builder
  collegeRow(c: CollegeEntry, index: number, showDivider: boolean) {
    Column() {
      Row() {
        Column() {
          Text(c.name)
            .fontSize(15)
            .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(c.domain)
            .fontSize(11)
            .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .margin({ top: 4 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 订阅按钮：已订阅=主题色实底「已订阅」，未订阅=描边「订阅」
        Text(this.isSub(c.domain) ? T('已订阅') : '订阅')
          .fontSize(12)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
          .fontColor(this.isSub(c.domain) ? Color.White : Theme.colorOf(this.themeColor))
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .backgroundColor(this.isSub(c.domain) ? Theme.colorOf(this.themeColor) : Color.Transparent)
          .border({ width: 1, color: Theme.colorOf(this.themeColor) })
          .borderRadius(15)
          .onClick(() => { this.toggle(c.domain); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .onClick(() => { this.openCollege(c); })

      if (showDivider) {
        Divider().color($r('app.color.divider')).margin({ left: 16, right: 16 })
      }
    }
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        WallpaperFill()
      Column() {
        // 顶栏
        Stack({ alignContent: Alignment.TopStart }) {
          Column()
            .width('100%')
            .height(this.getUIContext().px2vp(this.topInsetPx) + 60)
            .linearGradient({ angle: 180, colors: Theme.barGradient(this.themeColor, this.barStyle) })
            .backgroundBlurStyle(Immersive.blur(BlurStyle.Thin, this.barStyle === 'legacy'))
        Row() {
          BackButton({ onBack: () => { AppState.stack.pop(); } })
          Text(T('学院公告订阅'))
            .fontSize(18).fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
            .fontColor(WallpaperTone.onWallpaper(this.wallpaperTone, this.isDarkMode))
            .margin({ left: 6 })
            .layoutWeight(1)
        }
        .width('100%').alignItems(VerticalAlign.Center)
        .height(this.getUIContext().px2vp(this.topInsetPx) + 60)
        .padding({ left: 16, right: 16, bottom: 12, top: this.getUIContext().px2vp(this.topInsetPx) + 12 })
        }
        .width('100%')

        List({ space: 0 }) {
          // 说明卡片
          ListItem() {
            Column() {
              Text(T('订阅说明'))
                .fontSize(14)
                .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
                .fontColor($r('app.color.text_primary'))
                .width('100%')
              Text(T('勾选订阅你所在/关注的学院后，可在「已订阅」分组快速进入学院官网查看最新公告。学院公告内容以各学院官网发布为准。'))
                .fontSize(12)
                .lineHeight(19)
                .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                .width('100%')
                .margin({ top: 6 })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 14, bottom: 14 })
            .backgroundColor($r('app.color.bg_card'))
          }

          // 已订阅分组标题
          ListItem() {
            Row() {
              Text(T('已订阅'))
                .fontSize(13)
                .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
                .fontColor($r('app.color.text_primary'))
              Blank()
              Text(`${this.subscribed.length} 个`)
                .fontSize(11)
                .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 6 })
          }

          // 已订阅学院列表（置顶）
          ForEach(NewsApi.COLLEGES.filter((c: CollegeEntry) => this.isSub(c.domain)), (c: CollegeEntry, idx: number) => {
            ListItem() {
              this.collegeRow(c, idx, idx < this.subscribed.length - 1)
            }
          }, (c: CollegeEntry) => `sub-${c.domain}`)

          // 全部学院分组标题
          ListItem() {
            Row() {
              Text(T('全部学院'))
                .fontSize(13)
                .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
                .fontColor($r('app.color.text_primary'))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 6 })
          }

          // 全部学院列表
          ForEach(NewsApi.COLLEGES, (c: CollegeEntry, idx: number) => {
            ListItem() {
              this.collegeRow(c, idx, idx < NewsApi.COLLEGES.length - 1)
            }
          // key 带订阅态：ForEach 对 key 未变的项不重跑 itemGenerator，订阅按钮会停在旧文字
          }, (c: CollegeEntry) => `all-${c.domain}-${this.isSub(c.domain) ? 1 : 0}`)

          // 底部空隙
          ListItem() {
            Column().height(24)
          }
        }
        .width('100%').layoutWeight(1)
        .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      }
      .width('100%').height('100%')
      .backgroundColor(Color.Transparent)
      }
      .width('100%')
      .height('100%')
    }
    .backgroundColor($r('app.color.bg_page'))
    .hideTitleBar(true)
    .systemTransition(NavigationSystemTransitionType.SLIDE_RIGHT)
    .width('100%').height('100%')
  }
}
