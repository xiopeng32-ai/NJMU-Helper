/**
 * 校公众号页（我的 → 校园服务 → 校公众号）：
 *  - 展示学校各官方微信公众号（名称 / 微信号 / 简介），点击「去关注」：
 *    - 已知主页直达链接的公众号（homeUrl 非空，__biz 取自公众号文章源码 var biz）：
 *      弹出「扫码关注」面板，内置 QRCode 渲染 mp.weixin.qq.com/mp/profile_ext 主页链接，
 *      微信「扫一扫」扫码直达公众号主页（可点关注）；面板内保留「复制链接并打开微信」兜底
 *      （profile_ext 链接仅微信内可开，外部浏览器提示"请在微信客户端打开"）。
 *    - 无直达链接的公众号：复制名称并拉起微信，在微信搜索框粘贴搜索关注。
 *  - 拉起微信：先试鸿蒙版包名 com.tencent.wechat，回落 com.tencent.mm，均失败提示手动操作。
 */
import { common, Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppState } from '../common/AppState';
import { AppearanceStore } from '../common/AppearanceStore';
import { GlassMaterial } from '../common/GlassMaterial';
import { Theme } from '../common/ThemeUtil';
import { materialAvailable, sheetBlurStyle } from '../common/SystemMaterial';
import { SheetUtil } from '../common/SheetUtil';
import { MaterialButton } from './common/MaterialButton';
import { MaterialCard, MaterialSheetPanel } from './common/MaterialCard';
import { PageHeader } from './common/UiKit';
import { WallpaperFill } from './common/WallpaperFill';
import { mediaquery } from '@kit.ArkUI';
import { ResponsiveUtil } from '../common/ResponsiveUtil';

/** 公众号条目（homeUrl 非空 = 点「去关注」弹出二维码面板：码内容为该链接 + 复制链接兜底；
 *  homeUrl 空 = 复制名称 → 弹窗确认后拉起微信搜索） */
interface OAItem {
  name: string;
  homeUrl: string;
  /** 分组：'通用'（校级/公共服务/学生组织）| '学院'（各学院官方号） */
  group: string;
}

/** 由 __biz 拼公众号主页链接（微信内打开/扫码直达关注页） */
function homeUrlOf(biz: string): string {
  return biz.length > 0
    ? `https://mp.weixin.qq.com/mp/profile_ext?action=home&__biz=${biz}#wechat_redirect`
    : '';
}

/** 学校官方公众号清单（名称/biz 抓取自公众号文章页 var biz 与 nickname）；
 *  group 为自动分类：校级部门/公共服务/学生组织归「通用」，各学院官方号归「学院」。
 *  注：南医大官方公众号 biz 编码待接入（需从南医大公众号文章页抓取），当前 homeUrl 置空，
 *  点击「去关注」走「复制名称 → 微信搜索」兜底路径。 */
const OA_LIST: OAItem[] = [
  // ── 通用 ──
  { name: '南京医科大学', homeUrl: '', group: '通用' },
  { name: '南京医科大学研究生院', homeUrl: '', group: '通用' },
  { name: '南京医科大学教务处', homeUrl: '', group: '通用' },
  { name: '南京医科大学图书馆', homeUrl: '', group: '通用' },
  { name: '南京医科大学学生会', homeUrl: '', group: '通用' },
  // ── 学院（南医大各学院官方号 biz 待接入，暂列名称）──
  { name: '南京医科大学基础医学院', homeUrl: '', group: '学院' },
  { name: '南京医科大学第一临床医学院', homeUrl: '', group: '学院' },
  { name: '南京医科大学第二临床医学院', homeUrl: '', group: '学院' },
  { name: '南京医科大学公共卫生学院', homeUrl: '', group: '学院' },
  { name: '南京医科大学护理学院', homeUrl: '', group: '学院' },
  { name: '南京医科大学药学院', homeUrl: '', group: '学院' }
];

@Component
export struct WechatOAPage {
  @StorageProp('topInsetPx') topInsetPx: number = 0;
  @StorageProp('bottomInsetPx') bottomInsetPx: number = 0;
  /** 灰字广播订阅：颜色表达式需传 this.grayTick 才登记响应式依赖 */
  @StorageProp('grayTick') grayTick: number = 0;
  @StorageProp('themeColor') themeColor: string = 'green';
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageProp('barStyle') barStyle: string = 'new';
  /** 沉浸光感订阅：公众号卡片材质判定（订阅与使用点须在同一 struct） */
  @StorageProp('immersiveEffect') immersiveEffect: boolean = false;
  @StorageProp('fontWeightMode') fwMode: string = 'follow';
  @StorageProp('fontWeightValue') fwValue: number = 400;

  /** 扫码关注面板：showQrSheet 控制显隐，qrItem 记录当前公众号（仅 homeUrl 非空时弹出） */
  @State showQrSheet: boolean = false;
  @State qrItem: OAItem | null = null;

  /** 平板/大屏横屏标记：两张分组卡并排两列（用户要求适配），判定规则同 NewsPage */
  @State isLandscape: boolean = false;
  private landscapeListener: mediaquery.MediaQueryListener | null = null;
  private wideListener: mediaquery.MediaQueryListener | null = null;
  private landscapeMq: boolean = false;
  private wideMq: boolean = false;

  aboutToAppear(): void {
    this.listenLayout();
  }

  /** 页面消失：注销监听 */
  aboutToDisappear(): void {
    this.landscapeListener = null;
    this.wideListener = null;
  }

  /** 监听窗口尺寸/方向变化：宽 ≥600vp 且横向 → 两列布局（见 ResponsiveUtil.isWideLayout） */
  private listenLayout(): void {
    const mq = this.getUIContext().getMediaQuery();
    this.landscapeMq = mq.matchMediaSync(ResponsiveUtil.QUERY_LANDSCAPE).matches;
    this.wideMq = mq.matchMediaSync(ResponsiveUtil.QUERY_WIDE).matches;
    this.isLandscape = ResponsiveUtil.isWideLayout(this.wideMq, this.landscapeMq);
    this.landscapeListener = mq.matchMediaSync(ResponsiveUtil.QUERY_LANDSCAPE);
    this.landscapeListener.on('change', (res: mediaquery.MediaQueryResult) => {
      this.landscapeMq = res.matches;
      this.isLandscape = ResponsiveUtil.isWideLayout(this.wideMq, this.landscapeMq);
    });
    this.wideListener = mq.matchMediaSync(ResponsiveUtil.QUERY_WIDE);
    this.wideListener.on('change', (res: mediaquery.MediaQueryResult) => {
      this.wideMq = res.matches;
      this.isLandscape = ResponsiveUtil.isWideLayout(this.wideMq, this.landscapeMq);
    });
  }

  /** 去关注入口：有主页直达链接 → 弹二维码面板（微信扫一扫直达）；无 → 复制名称拉起微信搜索 */
  private follow(item: OAItem): void {
    if (item.homeUrl.length > 0) {
      this.qrItem = item;
      this.showQrSheet = true;
      return;
    }
    this.copyTextAndLaunch(item.name, false);
  }

  /** 复制文本 → 弹窗确认 → 拉起微信（用户要求：打开微信必须弹窗确认，不可直接跳转）。
   *  二维码面板的兜底按钮与无链接公众号共用 */
  private copyTextAndLaunch(copyText: string, isHomeLink: boolean): void {
    const pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, copyText);
    pasteboard.getSystemPasteboard().setData(pasteData).then(() => {
      this.confirmLaunchWechat(copyText, isHomeLink);
    }).catch(() => {
      // 剪贴板失败不阻断：仍弹确认（用户可回 App 手动复制后再试）
      this.confirmLaunchWechat(copyText, isHomeLink);
    });
  }

  /** 打开微信确认弹窗（系统 showDialog，AboutPage 退出调试同款写法） */
  private confirmLaunchWechat(copyText: string, isHomeLink: boolean): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '打开微信',
      message: isHomeLink
        ? '已复制链接。是否打开微信？在微信任意聊天窗口粘贴并打开该链接'
        : `已复制「${copyText}」。是否打开微信？在微信搜索粘贴即可关注`,
      buttons: [
        { text: '取消', color: '#888888' },
        { text: '打开微信', color: '#005BAC', primary: true }
      ]
    }).then((res) => {
      if (res.index === 1) {
        this.launchWechat(copyText, isHomeLink);
      }
    });
  }

  /** 拉起微信（三级回落）：
   *  ① 显式 Want：bundleName + abilityName（鸿蒙微信入口 UIAbility 为 EntryAbility——
   *     只写 bundleName 时部分设备/版本解析不到入口，实测拉不起，必须补 abilityName）
   *  ② 回落 Android 包名 com.tencent.mm
   *  ③ weixin:// scheme 隐式拉起（系统路由到微信） */
  private launchWechat(copied: string, isHomeLink: boolean): void {
    const okMsg: string = isHomeLink
      ? '已复制链接，在微信任意聊天窗口粘贴并打开'
      : `已复制「${copied}」，在微信搜索粘贴即可关注`;
    const failMsg: string = isHomeLink
      ? '已复制链接，未检测到微信，请手动打开微信粘贴打开'
      : `已复制「${copied}」，未检测到微信，请手动打开微信搜索关注`;
    const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const wantHm: Want = { deviceId: '', bundleName: 'com.tencent.wechat', abilityName: 'EntryAbility' };
    ctx.startAbility(wantHm).then((): void => {
      this.getUIContext().getPromptAction().showToast({ message: okMsg });
    }).catch((): void => {
      const wantApk: Want = { deviceId: '', bundleName: 'com.tencent.mm' };
      ctx.startAbility(wantApk).then((): void => {
        this.getUIContext().getPromptAction().showToast({ message: okMsg });
      }).catch((): void => {
        const wantScheme: Want = { deviceId: '', uri: 'weixin://' };
        ctx.startAbility(wantScheme).then((): void => {
          this.getUIContext().getPromptAction().showToast({ message: okMsg });
        }).catch((): void => {
          this.getUIContext().getPromptAction().showToast({ message: failMsg });
        });
      });
    });
  }

  /** 公众号材质是否生效（与其它页 matOn 同判定链） */
  private matOn(): boolean {
    return this.immersiveEffect && materialAvailable();
  }

  /** 扫码关注面板：白色码区 + QRCode（黑点白底确保微信扫一扫可识别）+ 复制链接兜底按钮 */
  @Builder
  qrSheet() {
    MaterialSheetPanel({ panelRadius: 20, panelPadding: 0, panelFillHeight: false, panelTitle: '扫码关注', panelShowClose: true, panelOnClose: (): void => { this.showQrSheet = false; } }) {
      Column() {
        if (this.qrItem !== null) {
          Text(this.qrItem.name)
            .fontSize(16)
            .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .textAlign(TextAlign.Center)
          // 白底码区：QRCode 黑点在白底上对比度最高，深色模式下也保证扫码可识别
          Column() {
            QRCode(this.qrItem.homeUrl)
              .width(200)
              .height(200)
              .color('#000000')
          }
          .backgroundColor(Color.White)
          .borderRadius(12)
          .padding(10)
          .margin({ top: 12 })

          // 微信无公开「携带 URL 拉起」scheme，链接仅微信内可打开 → 扫码是最直接路径
          Text('微信限制无法从外部直接打开链接，请用微信「扫一扫」扫描上方二维码')
            .fontSize(12)
            .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 12 })

          // 兜底：复制链接 → 弹窗确认 → 拉起微信（扫一扫不便时在微信聊天窗口粘贴打开）
          // margin 必须走 btnMargin 参数——MaterialButton 尾随闭包后不能再链式属性
          MaterialButton({
            btnRadius: 21,
            btnMargin: { top: 14 },
            btnBg: '#005BAC',
            btnBlur: GlassMaterial.bgBlur(this.immersiveEffect),
            btnBorderW: GlassMaterial.borderWidth(),
            btnBorderC: GlassMaterial.borderColor(),
            btnOnClick: (): void => {
              if (this.qrItem !== null) {
                this.showQrSheet = false;
                this.copyTextAndLaunch(this.qrItem.homeUrl, true);
              }
            }
          }) {
            Text('复制链接并打开微信')
              .fontSize(14)
              .fontColor($r('sys.color.font_primary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .height(42)
          }
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ left: 20, right: 20, top: 8, bottom: 24 })
    }
  }

  /** 分组内的公众号数量 */
  private groupCount(groupName: string): number {
    let n: number = 0;
    for (const it of OA_LIST) {
      if (it.group === groupName) {
        n++;
      }
    }
    return n;
  }

  /** 分组列表卡：按 group 过滤渲染；行内不放头像徽标与描述文本（用户要求），仅名称+去关注按钮 */
  @Builder
  oaGroupCard(groupName: string) {
    MaterialCard({
      cardRadius: 18,
      cardPadding: 6,
      cardBg: GlassMaterial.homeCardBg($r('app.color.bg_card')),
      cardBlur: GlassMaterial.cardBlur(),
      cardBorderW: GlassMaterial.cardBorderWidth(),
      cardBorderC: GlassMaterial.borderColor(),
      cardShadow: GlassMaterial.cardShadowStyle(),
      cardMargin: { top: 14 }
    }) {
      Column() {
        Row() {
          Text(groupName)
            .fontSize(13)
            .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
            .fontColor(Theme.colorOf(this.themeColor))
          Blank()
          Text(`${this.groupCount(groupName)} 个`)
            .fontSize(11)
            .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
        }
        .width('100%')
        .padding({ top: 10, bottom: 4, left: 10, right: 10 })

        ForEach(OA_LIST.filter((it: OAItem): boolean => it.group === groupName), (item: OAItem, index: number) => {
          Column() {
            Row() {
              Text(item.name)
                .fontSize(15)
                .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)

              // 右：去关注（绿色实底，文字黑白自动对比度）
              MaterialButton({
                btnRadius: 15,
                btnBg: '#005BAC',
                btnBlur: GlassMaterial.bgBlur(this.immersiveEffect),
                btnBorderW: GlassMaterial.borderWidth(),
                btnBorderC: GlassMaterial.borderColor(),
                btnMargin: { left: 10 },
                btnOnClick: (): void => {
                  this.follow(item);
                }
              }) {
                Text('去关注')
                  .fontSize(12)
                  .fontColor(Color.White)
                  .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding({ top: 12, bottom: 12, left: 10, right: 10 })

            if (index < this.groupCount(groupName) - 1) {
              Divider().color($r('app.color.divider'))
            }
          }
          .width('100%')
        }, (item: OAItem) => item.name)
      }
      .width('100%')
    }
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 二级页壁纸底层（无壁纸回 bg_page，不透下层）
        WallpaperFill()
        Scroll() {
          Column() {
            // 顶栏让位 spacer（与学业页同款）
            Column()
              .width('100%')
              .height(this.getUIContext().px2vp(this.topInsetPx) + 60 + (this.barStyle === 'legacy' ? 14 : 0))

            // 说明卡
            MaterialCard({
              cardRadius: 18,
              cardPadding: 16,
              cardBg: GlassMaterial.homeCardBg($r('app.color.bg_card')),
              cardBlur: GlassMaterial.cardBlur(),
              cardBorderW: GlassMaterial.cardBorderWidth(),
              cardBorderC: GlassMaterial.borderColor(),
              cardShadow: GlassMaterial.cardShadowStyle()
            }) {
              Column({ space: 6 }) {
                Text('关注学校官方公众号')
                  .fontSize(15)
                  .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
                  .fontColor($r('app.color.text_primary'))
                Text('点击「去关注」弹出二维码：打开微信「扫一扫」扫码直达公众号主页；也可复制主页链接在微信内粘贴打开（大部分公众号已收录主页直达链接）。列表按「通用 / 学院」自动分组。')
                  .fontSize(12)
                  .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                  .lineHeight(18)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }

            // 分组卡：大屏横屏两列并排（用户要求适配），手机端保持纵向单列
            if (this.isLandscape) {
              Row({ space: 14 }) {
                Column() {
                  this.oaGroupCard('通用')
                }
                .layoutWeight(1)
                Column() {
                  this.oaGroupCard('学院')
                }
                .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            } else {
              // 通用组：校级 / 公共服务 / 学生组织
              this.oaGroupCard('通用')
              // 学院组：各学院官方号
              this.oaGroupCard('学院')
            }

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
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)

        // 顶栏悬浮（最上层）
        PageHeader({
          title: '校公众号',
          onBack: () => {
            AppState.stack.pop();
          }
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      // 扫码关注面板：挂最外层 Stack（本页唯一 bindSheet，无同组件多次挂载互相覆盖问题）
      .bindSheet($$this.showQrSheet, this.qrSheet(), {
        width: SheetUtil.sheetWidth(),
        preferType: SheetType.BOTTOM,
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        // 关闭按钮由 MaterialSheetPanel 自绘（沉浸光感），系统 showClose 必须关掉避免双按钮
        showClose: false,
        // 必须显式透明：BindOptions.backgroundColor 默认白底会把 MaterialSheetPanel 的材质整块盖住
        backgroundColor: Color.Transparent,
        blurStyle: sheetBlurStyle()
      })
    }
    .backgroundColor($r('app.color.bg_page'))
    .hideTitleBar(true)
    .systemTransition(NavigationSystemTransitionType.SLIDE_RIGHT)
  }
}
