/**
 * 关于页：应用图标 + 版本号 + 更新日志 + 项目链接（独立页面）
 * 隐藏调试入口：连点应用图标 5 次，输入密码 admin——
 *  - 功能浏览模式（USE_MOCK）：开启/关闭调试联网（debugNetwork）
 *  - 真实登录模式：开启/关闭日志调试（logEnabled）
 *
 * 卡片外观接入（照首页 HomeView 的写法推广）：
 *  - 卡片统一用 `MaterialCard` 承载（材质层在卡片内部、位于内容之下），材质生效时卡片自身的
 *    底色/磨砂/亮边/阴影一并让出，每张卡只有一层视觉；关闭光感回落为原来的纯色/毛玻璃卡片；
 *  - 更新日志卡为共享组件 `ChangelogCard`（关于页「最近 5 条」与更新日志页共用），该组件已迁到
 *    `MaterialCard`，两页的更新日志卡因此都带沉浸光感；
 *  - 半模态弹窗（调试模式密码）内容套 `MaterialSheetPanel`，`bindSheet` 显式 `backgroundColor: Color.Transparent`。
 */
import { SheetUtil } from '../common/SheetUtil';
import { http } from '@kit.NetworkKit';
import { AppState } from '../common/AppState';
import { Theme } from '../common/ThemeUtil';
import { ResponsiveUtil } from '../common/ResponsiveUtil';
import { GlassMaterial } from '../common/GlassMaterial';
import { Const } from '../common/Constants';
import { LogStore } from '../common/LogStore';
import { JwApi } from '../api/JwApi';
import { DataStore } from '../common/DataStore';
import { common, Want } from '@kit.AbilityKit';
import { WallpaperTone } from '../common/WallpaperTone';
import { PageHeader } from './common/UiKit';
import { WallpaperFill } from './common/WallpaperFill';
import { ChangelogCard } from './common/ChangelogCard';
// 沉浸光感：卡片统一走 MaterialCard（材质承载层在卡片内容之下，材质生效时卡片底色/磨砂/亮边/阴影一并让出，
// 每张卡只剩一层视觉），胶囊按钮走 MaterialButton，半模态弹窗内容走 MaterialSheetPanel
import { MaterialCard, MaterialSheetPanel } from './common/MaterialCard';
import { MaterialButton } from './common/MaterialButton';
import { materialActive, sheetBlurStyle } from '../common/SystemMaterial';
import { MaterialCardLayer } from './common/MaterialCarrier';
import { CHANGELOG_ALL, CHANGELOG_MAX, ChangelogItem } from '../common/Changelog';
import { AppearanceStore } from '../common/AppearanceStore';
import { T } from '../common/I18n';


/** 版本清单解析结果 */
class UpdateInfo {
  version: string = '';
  notes: string = '';
}

@Component
export struct AboutPage {
  /** 界面语言版本号：切换语言后自增，订阅它即可重建本组件 */
  @StorageProp('langRev') langRev: number = 0;
  @StorageProp('topInsetPx') topInsetPx: number = 0;
  /** 灰字广播订阅：颜色表达式需传 this.grayTick 才登记响应式依赖（否则改色不实时刷新） */
  @StorageProp('grayTick') grayTick: number = 0;
  /** 响应式依赖：玻璃/灰字设置变化时触发本页重渲染（取值经 GlassMaterial 静态方法读取） */
  @StorageProp('glassStrength') glassStrength: number = 70;
  @StorageProp('cardMaterial') cardMaterial: boolean = false;
  @StorageProp('grayTextMode') grayTextMode: string = 'default';
  @StorageProp('grayTextColor') grayTextColor: string = '';
  /** 全局字重响应式订阅：表达式读 this.fwMode 才登记依赖，fwValue 声明即订阅 */
  @StorageProp('fontWeightMode') fwMode: string = 'follow';
  @StorageProp('fontWeightValue') fwValue: number = 400;
  @StorageProp('themeColor') themeColor: string = 'green';
  /** 壁纸亮度（文字自适应用） */
  @StorageProp('wallpaperTone') wallpaperTone: number = -1;
  @StorageProp('bottomInsetPx') bottomInsetPx: number = 0;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  /** 应用图标连点计数（5 次内有效） */
  @State iconTapCount: number = 0;
  /** 调试模式密码输入弹窗开关 */
  @State showDebugSheet: boolean = false;
  @State debugPwd: string = '';
  /** 调试模式是否开启（日志/联网任一）：驱动「退出调试」红胶囊显隐（AppState 静态字段非响应式，需本地镜像） */
  @State debugActive: boolean = false;
  /** 当前应用版本（启动时从 bundleManager 读取，见 AppState.appVersion；不再硬编码） */
  private currentVersion(): string {
    return AppState.appVersion;
  }
  /** 检查更新请求进行中 */
  @State checkingUpdate: boolean = false;
  /** 连点计时器（超时重置计数） */
  private iconTapTimer: number = -1;

  aboutToAppear(): void {
    // 进入页面同步一次调试模式状态（「退出调试」红胶囊显隐）
    this.debugActive = AppState.logEnabled || AppState.debugNetwork;
  }

  /** 应用图标连点：5 次内累计，满 5 次——
   *  已开启对应模式 → 弹"是否退出"；未开启 → 弹密码输入 */
  private onIconTapped(): void {
    this.iconTapCount++;
    if (this.iconTapTimer >= 0) {
      clearTimeout(this.iconTapTimer);
    }
    // 3 秒内未继续点击则重置计数
    this.iconTapTimer = setTimeout(() => {
      this.iconTapCount = 0;
    }, 3000);
    if (this.iconTapCount < 5) {
      return;
    }
    this.iconTapCount = 0;
    const active: boolean = AppState.logEnabled || AppState.debugNetwork;
    if (active) {
      // 已开启：询问是否退出（按当前生效的模式提示）——与「退出调试」红胶囊共用
      this.confirmExitDebug();
    } else {
      // 未开启：弹密码输入
      this.debugPwd = '';
      this.showDebugSheet = true;
    }
  }

  /** 退出调试模式确认弹窗：应用图标连点 5 次 / 「退出调试」红胶囊共用入口 */
  private confirmExitDebug(): void {
    const isLog: boolean = AppState.logEnabled;
    const isNet: boolean = AppState.debugNetwork;
    this.getUIContext().getPromptAction().showDialog({
      title: isLog ? T('日志调试已开启') : T('调试模式已开启'),
      message: isLog && isNet ? '当前正在收集使用日志，且功能浏览模式允许联网。是否退出调试模式？' :
        (isLog ? '当前正在收集功能使用日志。是否退出日志调试？' : '当前功能浏览模式允许联网。是否退出调试模式？'),
      buttons: [
        { text: T('取消'), color: '#888888' },
        { text: T('退出调试模式'), color: '#DB5252', primary: true }
      ]
    }).then((res) => {
      if (res.index === 1) {
        AppState.logEnabled = false;
        AppState.debugNetwork = false;
        LogStore.clearAll(); // 退出调试：自动删除已收集日志与附件
        this.debugActive = false;
        this.getUIContext().getPromptAction().showToast({ message: '已退出调试模式，日志已清除' });
      }
    });
  }

  /** 提交调试模式密码：admin——
   *  功能浏览模式（USE_MOCK）开启调试联网 + 日志收集；真实登录模式开启日志调试 */
  private submitDebugPwd(): void {
    if (this.debugPwd !== 'admin') {
      this.getUIContext().getPromptAction().showToast({ message: T('密码错误') });
      return;
    }
    this.showDebugSheet = false;
    if (AppState.logEnabled || AppState.debugNetwork) {
      // 已开启：提示已开启，避免重复开启
      this.getUIContext().getPromptAction().showToast({ message: AppState.logEnabled ? T('日志调试已开启') : T('调试模式已开启') });
      return;
    }
    if (JwApi.USE_MOCK) {
      // 功能浏览模式：开启调试联网 + 日志收集（联网请求与使用日志一并收集）
      AppState.debugNetwork = true;
      AppState.logEnabled = true;
      LogStore.log('日志调试', '开启', '成功', '功能浏览模式调试开启（联网 + 日志收集）');
      this.getUIContext().getPromptAction().showToast({ message: T('调试模式已开启：功能浏览允许联网并收集日志') });
    } else {
      // 真实登录：开启日志调试
      AppState.logEnabled = true;
      LogStore.log('日志调试', '开启', '成功', '真实登录模式');
      this.getUIContext().getPromptAction().showToast({ message: '日志调试已开启，开始收集使用日志' });
    }
    this.debugActive = true;
  }

  /** 底部链接 + 开源等级 */
  @Builder
  footer() {
    // MaterialCard 承载：材质层是卡片内部底层、与卡片同尺寸同圆角，材质生效时卡片底色/磨砂/亮边/阴影让出；
    // 原卡片上的 padding / alignItems / margin 改走 cardPadding / cardAlignItems / cardMargin
    // （尾随闭包初始化的自定义组件之后不能再链式加属性）。
    MaterialCard({
      cardRadius: 16,
      cardPadding: 16,
      cardAlignItems: ItemAlign.Start,
      cardBg: GlassMaterial.homeCardBg($r('app.color.bg_card')),
      cardBlur: GlassMaterial.cardBlur(),
      cardBorderW: GlassMaterial.cardBorderWidth(),
      cardBorderC: GlassMaterial.borderColor(),
      cardShadow: GlassMaterial.cardShadowStyle(),
      cardMargin: { top: 0 }
    }) {
    Column() {
      Text(T('项目链接'))
        .fontSize(13)
        .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: 10 })
      // 本项目入口：仓库 / 问题反馈 / 官网（地址以本应用实际仓库为准，勿再指向其它项目的同名仓库）
      this.linkRow(T('GitHub 开源仓库'), 'https://github.com/xiopeng32-ai/NJMU-Helper')
      this.linkRow(T('问题反馈') + ' · Issues', 'https://github.com/xiopeng32-ai/NJMU-Helper/issues')
      this.linkRow(T('官方网站'), 'https://www.sydxky.cn/')
      // 上游与参考项目（如实署名，链接需可达）
      this.linkRow(T('上游项目') + ' · XJAU-Helper', 'https://github.com/FengHDSL/XJAU-Helper')
      this.linkRow('miha_hm', 'https://github.com/MrCashmere/miha_hm')
      this.linkRow('zhengfang-apk', 'https://github.com/znjhahaha/zhengfang-apk')
      this.linkRow('HiXD', 'https://github.com/PollenWang6/HiXD')
      this.linkRow('Traintime PDA', 'https://github.com/BenderBlog/traintime_pda')

      Text(T('开源等级: MIT License'))
        .fontSize(12)
        .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 18 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    }
  }

  /** 新版本清单地址（优先）：结构稳定，可带更新说明与下载路径 */
  private static readonly VERSION_JSON_URL: string = 'https://www.sydxky.cn/version.json';
  /** 详情页地址（兜底）：清单不可用时按旧方式解析版本徽标 */
  private static readonly DETAIL_PAGE_URL: string = 'https://www.sydxky.cn/detail.php?id=1034';
  /** 检查结果缓存时长（30 分钟内重复点击直接给结论，不重复请求） */
  private static readonly CHECK_TTL: number = 30 * 60 * 1000;

  /**
   * 检查更新（优化版）：
   *  1) 30 分钟内已检查过 → 直接复用结果（避免频繁请求、也防止用户连点）
   *  2) 优先读 version.json（带更新说明），失败回退详情页 HTML 解析
   *  3) 超时 6 秒 + 自动重试 1 次
   */
  private checkUpdate(): void {
    if (this.checkingUpdate) {
      return;
    }
    const lastAt: number = Number.parseInt(DataStore.get('update_last_check_at'), 10);
    const lastVer: string = DataStore.get('update_last_check_ver');
    if (lastAt > 0 && Date.now() - lastAt < AboutPage.CHECK_TTL && lastVer.length > 0) {
      this.presentUpdateResult(lastVer, '');
      return;
    }
    this.checkingUpdate = true;
    this.fetchVersionJson().then((info: UpdateInfo | null) => {
      if (info !== null) {
        this.finishCheck(info.version, info.notes);
        return;
      }
      // 清单不可用 → 回退 HTML 解析
      this.fetchVersionFromHtml(1).then((v: string) => {
        this.finishCheck(v, '');
      });
    }).catch(() => {
      this.fetchVersionFromHtml(1).then((v: string) => {
        this.finishCheck(v, '');
      });
    });
  }

  /** 拉取 version.json；失败返回 null（不抛错，交由上层兜底） */
  private async fetchVersionJson(): Promise<UpdateInfo | null> {
    try {
      const req: http.HttpRequest = http.createHttp();
      const resp: http.HttpResponse = await req.request(AboutPage.VERSION_JSON_URL, {
        method: http.RequestMethod.GET,
        connectTimeout: 6000,
        readTimeout: 6000,
        header: { 'User-Agent': 'Mozilla/5.0 (HarmonyOS) 南医助手', 'Cache-Control': 'no-cache' }
      });
      req.destroy();
      if (resp.responseCode !== 200) {
        return null;
      }
      const body: string = typeof resp.result === 'string' ? resp.result : '';
      if (body.length === 0 || body.indexOf('{') < 0) {
        return null;
      }
      const root: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
      const v: string = String(root['version'] ?? '');
      if (v.length === 0) {
        return null;
      }
      const info: UpdateInfo = new UpdateInfo();
      info.version = v;
      const rawNotes: Object = root['notes'] ?? '';
      if (Array.isArray(rawNotes)) {
        const arr: Object[] = rawNotes as Object[];
        const lines: string[] = [];
        for (let i: number = 0; i < arr.length && i < 4; i++) {
          lines.push(`· ${String(arr[i])}`);
        }
        info.notes = lines.join('\n');
      }
      return info;
    } catch (e) {
      LogStore.log('更新', '清单', '读取失败', LogStore.errorOf(e as Object));
      return null;
    }
  }

  /** 从详情页 HTML 解析版本号（带一次重试） */
  private async fetchVersionFromHtml(retryLeft: number): Promise<string> {
    try {
      const req: http.HttpRequest = http.createHttp();
      const resp: http.HttpResponse = await req.request(AboutPage.DETAIL_PAGE_URL, {
        method: http.RequestMethod.GET,
        connectTimeout: 6000,
        readTimeout: 6000,
        header: { 'User-Agent': 'Mozilla/5.0 (HarmonyOS) 南医助手' }
      });
      req.destroy();
      const html: string = typeof resp.result === 'string' ? resp.result : '';
      const v: string = this.parseRemoteVersion(html);
      if (v.length === 0 && retryLeft > 0) {
        return await this.fetchVersionFromHtml(retryLeft - 1);
      }
      return v;
    } catch (e) {
      if (retryLeft > 0) {
        return await this.fetchVersionFromHtml(retryLeft - 1);
      }
      return '';
    }
  }

  /** 收尾：缓存结果 + 按比对结果给出界面反馈 */
  private finishCheck(remote: string, notes: string): void {
    this.checkingUpdate = false;
    if (remote.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: T('检查更新失败，请检查网络后重试') });
      return;
    }
    DataStore.put('update_last_check_at', `${Date.now()}`);
    DataStore.put('update_last_check_ver', remote);
    this.presentUpdateResult(remote, notes);
  }

  /** 展示检查结果（有更新弹窗 + 更新说明，否则轻提示） */
  private presentUpdateResult(remote: string, notes: string): void {
    const cmp: number = this.compareVersion(this.currentVersion(), remote);
    if (cmp < 0) {
      const noteText: string = notes.length > 0 ? `\n\n更新内容：\n${notes}` : '';
      this.getUIContext().getPromptAction().showDialog({
        title: `发现新版本 v${remote}`,
        message: `当前版本 v${this.currentVersion()}${noteText}`,
        buttons: [
          { text: T('前往更新'), color: '#005BAC' },
          { text: T('稍后'), color: '#666666' }
        ]
      }).then((res) => {
        if (res.index === 0) {
          this.openUpdateSite();
        }
      });
    } else if (cmp > 0) {
      this.getUIContext().getPromptAction().showToast({
        message: `当前已是最新发布版本（线上 v${remote}）`, duration: 2200
      });
    } else {
      this.getUIContext().getPromptAction().showToast({ message: `已是最新版本（v${this.currentVersion()}）` });
    }
  }

  /** 从资源站 HTML 解析最新版本号（优先版本徽标锚点，兜底全页第一个 span vX.Y.Z；取不到返回空串） */
  private parseRemoteVersion(html: string): string {
    const anchor: number = html.indexOf('fa-code-branch');
    if (anchor >= 0) {
      const seg: string = html.substring(anchor, Math.min(anchor + 400, html.length));
      const m: RegExpMatchArray | null = seg.match(/<span>v(\d+\.\d+(?:\.\d+)?)<\/span>/);
      if (m !== null && m.length > 1) {
        return m[1];
      }
    }
    const m2: RegExpMatchArray | null = html.match(/<span>v(\d+\.\d+(?:\.\d+)?)<\/span>/);
    if (m2 !== null && m2.length > 1) {
      return m2[1];
    }
    return '';
  }

  /** 版本号比较：a>b 返回 1，a<b 返回 -1，相等返回 0（按数字段逐段比较） */
  private compareVersion(a: string, b: string): number {
    const pa: string[] = a.split('.');
    const pb: string[] = b.split('.');
    const n: number = Math.max(pa.length, pb.length);
    for (let i = 0; i < n; i++) {
      const x: number = i < pa.length ? parseInt(pa[i], 10) : 0;
      const y: number = i < pb.length ? parseInt(pb[i], 10) : 0;
      if (x !== y) {
        return x > y ? 1 : -1;
      }
    }
    return 0;
  }

  /** 用系统浏览器打开 HAP 资源站更新页 */
  private openUpdateSite(): void {
    try {
      const ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: AboutPage.DETAIL_PAGE_URL
      };
      ctx.startAbility(want);
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: T('打开浏览器失败') });
    }
  }

  /** 检查更新胶囊：主题色液态玻璃（材质开=主题色叠层玻璃绿，关=主题色实底绿） */
  @Builder
  checkUpdateChip() {
    MaterialButton({
      btnRadius: 18,
      btnBg: Theme.colorOf(this.themeColor),
      btnBlur: GlassMaterial.bgBlur(AppStorage.get<boolean>('immersiveEffect') ?? false),
      btnBorderW: GlassMaterial.borderWidth(),
      btnBorderC: GlassMaterial.borderColor(),
      btnTint: Theme.colorOf(this.themeColor),
      btnTintRatio: 0.55,
      btnOnClick: (): void => {
        this.checkUpdate();
      }
    }) {
      Row({ space: 5 }) {
        if (this.checkingUpdate) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color(Color.White)
        }
        Text(this.checkingUpdate ? T('检查中…') : T('检查更新'))
          .fontSize(13)
          .fontColor(Color.White)
      }
      .alignItems(VerticalAlign.Center)
      .padding({ left: 18, right: 18, top: 8, bottom: 8 })
    }
  }

  /** 「退出调试」红胶囊：调试模式开启时常驻（免去连点 5 次应用图标退出） */
  @Builder
  exitDebugChip() {
    MaterialButton({
      btnRadius: 18,
      btnBg: '#DB5252',
      btnBlur: GlassMaterial.bgBlur(AppStorage.get<boolean>('immersiveEffect') ?? false),
      btnBorderW: GlassMaterial.borderWidth(),
      btnBorderC: GlassMaterial.borderColor(),
      btnTint: '#DB5252',
      btnTintRatio: 0.85,
      btnOnClick: (): void => {
        this.confirmExitDebug();
      }
    }) {
      Text(T('退出调试'))
        .fontSize(13)
        .fontColor($r('sys.color.font_primary'))
        .padding({ left: 18, right: 18, top: 8, bottom: 8 })
    }
  }

  /** 链接行右侧展示用：去掉协议与末尾斜杠，过长的靠省略号截断 */
  private static shortUrl(url: string): string {
    let s: string = url;
    if (s.startsWith('https://')) {
      s = s.substring(8);
    } else if (s.startsWith('http://')) {
      s = s.substring(7);
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  @Builder
  linkRow(title: string, url: string) {
    Row() {
      Text(title)
        .fontSize(13)
        .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
        .layoutWeight(1)
      Text(AboutPage.shortUrl(url))
        .fontSize(12)
        .fontColor(Theme.colorOf(this.themeColor))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(38)
    .alignItems(VerticalAlign.Center)
    .padding({ left: 4, right: 4 })
    .borderRadius(8)
    .onClick(() => {
      // 所有开源链接直接用应用内网页打开（GitHub 页面在功能浏览模式下也可访问）
      AppState.webUrl = url;
      AppState.webTitle = title;
      AppState.stack.pushPath({ name: Const.ROUTE_WEB_PAGE });
    })
  }

  /** 取消同意：询问是否清除数据 → 取消同意并退出应用（功能浏览模式不提供） */
  private cancelAgreement(): void {
    if (JwApi.USE_MOCK) {
      return;
    }
    this.getUIContext().getPromptAction().showDialog({
      title: T('取消同意'),
      message: T('取消同意后将无法使用本应用，下次打开需重新同意。是否同时清除本地数据？'),
      buttons: [
        // 用户指定配色：「清除数据并退出」红、「保留数据并退出」天蓝、「取消」绿
        { text: T('清除数据并退出'), color: '#DB5252' },
        { text: T('保留数据并退出'), color: '#1E90FF' },
        { text: T('取消'), color: '#4CAF50' }
      ]
    }).then((res) => {
      if (res.index === 2) {
        return;
      }
      if (res.index === 0) {
        DataStore.clearAll();
      }
      DataStore.clearPrivacyAgreed();
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      ctx.terminateSelf();
    });
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 二级页壁纸底层（无壁纸回 bg_page，不透下层）
        WallpaperFill()
        // 内容全屏：顶部占位随内容滚走，让上滑的内容进入悬浮顶栏下层
        Scroll() {
          Column() {
            // 顶栏占位（滚动时随内容滚走）：初始内容位于渐变顶栏下方
            Column()
              .width('100%')
              .height(this.getUIContext().px2vp(this.topInsetPx) + 60)
            // 应用图标 + 名称 + 版本（连点 5 次进入隐藏调试模式）
            Column() {
              Image($r('app.media.startIcon'))
                .width(88)
                .height(88)
                .borderRadius(20)
                .backgroundColor('#FFFFFF').backgroundBlurStyle((AppStorage.get<boolean>('immersiveEffect') ?? false) ? BlurStyle.Thin : BlurStyle.NONE).border({ width: 1, color: 'rgba(255,255,255,0.28)' }).shadow({ radius: 6, color: 'rgba(0,0,0,0.10)', offsetY: 1 }).clip(true)
                .onClick(() => {
                  this.onIconTapped();
                })
              Text('南医助手')
                .fontSize(20)
                .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
                .fontColor(WallpaperTone.onWallpaper(this.wallpaperTone, this.isDarkMode))
                .margin({ top: 12 })
              Text(`版本 ${this.currentVersion()} · ${ResponsiveUtil.deviceTypeLabel()}`)
                .fontSize(12)
                .fontColor(WallpaperTone.onWallpaperSecondary(this.wallpaperTone, this.isDarkMode))
                .margin({ top: 4 })
              Text(T('仅供学习交流使用，严禁用于商业用途！'))
                .fontSize(11)
                .fontColor(WallpaperTone.onWallpaperSecondary(this.wallpaperTone, this.isDarkMode))
                .margin({ top: 8 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 10, bottom: 16 })

            // 检查更新胶囊（应用介绍上方）；调试模式开启时右侧并列「退出调试」红胶囊
            Row({ space: 10 }) {
              this.checkUpdateChip()
              if (this.debugActive) {
                this.exitDebugChip()
              }
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: 2, bottom: 12 })

            // 应用简介（单独卡片）
            // MaterialCard 承载：材质层是卡片内部底层、与卡片同尺寸同圆角，材质生效时卡片底色让出；
            // 原来的 16vp 内边距走 cardPadding、12vp 下间距走 cardMargin。
            MaterialCard({
              cardRadius: 16,
              cardPadding: 16,
              cardBg: GlassMaterial.homeCardBg($r('app.color.bg_card')),
              cardBlur: GlassMaterial.cardBlur(),
              cardBorderW: GlassMaterial.cardBorderWidth(),
              cardBorderC: GlassMaterial.borderColor(),
              cardShadow: GlassMaterial.cardShadowStyle(),
              cardMargin: { bottom: 12 }
            }) {
            Column() {
              Text(T('南医助手（NJMU Helper）是一款专为南京医科大学学生打造的校园工具：原生鸿蒙开发，完全开源，完全免费，轻量小巧。课表、成绩、考试、学业、教室查询一站集成，南医新闻、校公众号随时掌握校园动态。数据来源于学校官方网页，不经过也不保存于非学校官方服务器。南医助手，让你的校园生活更便利！'))
                .fontSize(12)
                .lineHeight(20)
                .fontColor(GlassMaterial.graySecondary(this.grayTick, $r('app.color.text_secondary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
                .textAlign(TextAlign.Center)
                .width('100%')
              // 独立开发者免责声明（红色醒目；措辞与 PrivacyText.ets 独立开发声明保持一致）
              Text(T('本应用由学生独立开发，非学校官方应用，与校方无任何隶属或合作关系！'))
                .fontSize(12)
                .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
                .fontColor('#DB5252')
                .textAlign(TextAlign.Center)
                .width('100%')
                .margin({ top: 8 })
            }
            .width('100%')
            }

            // 更新日志：固定只显示最近 CHANGELOG_MAX（5）条；完整历史在「更新日志」页查看
            ForEach(CHANGELOG_ALL.slice(0, CHANGELOG_MAX), (e: ChangelogItem) => {
              ChangelogCard({ version: e.version, date: e.date, items: e.items })
            }, (e: ChangelogItem) => e.version)

            // 入口：查看全部历史更新日志
            Row() {
              Text(T('查看全部更新日志 ›'))
                .fontSize(12)
                .fontColor(Theme.colorOf(this.themeColor))
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: 2, bottom: 10 })
            .onClick(() => {
              AppState.stack.pushPath({ name: Const.ROUTE_CHANGELOG });
            })

            this.footer()

            // 用户协议 & 隐私政策（居中，可分别查看）
            // MaterialCard 承载（居中卡片同样走材质卡；内边距挂内部内容容器、上下间距走 cardMargin）
            MaterialCard({
              cardRadius: 16,
              cardAlignItems: ItemAlign.Center,
              cardBg: GlassMaterial.homeCardBg($r('app.color.bg_card')),
              cardBlur: GlassMaterial.cardBlur(),
              cardBorderW: GlassMaterial.cardBorderWidth(),
              cardBorderC: GlassMaterial.borderColor(),
              cardShadow: GlassMaterial.cardShadowStyle(),
              cardMargin: { top: 14, bottom: 12 }
            }) {
            Column() {
              Row({ space: 22 }) {
                Text(T('《用户协议》'))
                  .fontSize(12)
                  .fontColor(Theme.colorOf(this.themeColor))
                  .onClick(() => {
                    AppState.stack.pushPath({ name: Const.ROUTE_TERMS });
                  })
                Text(T('《隐私政策》'))
                  .fontSize(12)
                  .fontColor(Theme.colorOf(this.themeColor))
                  .onClick(() => {
                    AppState.stack.pushPath({ name: Const.ROUTE_PRIVACY });
                  })
              }
              .margin({ top: 8 })

              // 取消同意（胶囊按钮：材质走 MaterialButton 的 Toggle 承载层，点击行为不变；
              // 原 .margin({ top: 12 }) 改走 btnMargin——尾随闭包之后不能再链式加属性）
              if (!JwApi.USE_MOCK) {
                MaterialButton({
                  btnRadius: 14,
                  btnBg: 'rgba(219,82,82,0.10)',
                  btnBlur: GlassMaterial.bgBlur(AppStorage.get<boolean>('immersiveEffect') ?? false),
                  btnBorderW: GlassMaterial.borderWidth(),
                  btnBorderC: GlassMaterial.borderColor(),
                  btnMargin: { top: 12 },
                  btnOnClick: () => {
                    this.cancelAgreement();
                  }
                }) {
                  Text(T('取消同意并退出'))
                    .fontSize(12)
                    .fontColor('#DB5252')
                    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                }
              }
            }
            .width('100%')
            .padding({ top: 12, bottom: 12, left: 16, right: 16 })
            }

            Column()
              .height(this.getUIContext().px2vp(this.bottomInsetPx) + 24)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4 })
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)

        // 悬浮顶栏：主题色渐变到透明，内容可滚入其下层
        PageHeader({
          title: T('关于应用'),
          subtitle: '南医助手',
          onBack: () => {
            AppState.stack.pop();
          }
        })
      }
      .width('100%')
      .height('100%')
      // 全局壁纸：二级页根背景透明，透出主框架底层壁纸（无壁纸时由 MainView 底层纯色兜底）
      .backgroundColor(Color.Transparent)
    }
    .backgroundColor($r('app.color.bg_page'))
    .hideTitleBar(true)
    .systemTransition(NavigationSystemTransitionType.SLIDE_RIGHT)
    .width('100%')
    .height('100%')
    // 调试模式密码输入弹窗（连点图标 5 次触发）
    .bindSheet($$this.showDebugSheet, this.debugSheet(), {
      width: SheetUtil.sheetWidth(),
      preferType: SheetType.BOTTOM,
      height: SheetSize.FIT_CONTENT,
      dragBar: false,
      // 关闭按钮由 MaterialSheetPanel 自绘（沉浸光感），系统 showClose 必须关掉避免双按钮
      showClose: false,
      // 必须显式透明：BindOptions.backgroundColor 默认 Color.White，而沉浸光感材质的视觉层级位于
      // backgroundColor **之下**，白底会把面板材质整块盖住（表现为「弹窗一点光感都没有」）。
      backgroundColor: Color.Transparent,
      blurStyle: sheetBlurStyle()
    })
  }

  /** 隐藏调试入口：输入密码开启对应模式的调试能力（功能浏览=联网；真实登录=日志） */
  @Builder
  debugSheet() {
    // 弹窗内容套 MaterialSheetPanel：bindSheet 自身的 systemMaterial 挂在面板上、内容区不生效，
    // 由 MaterialSheetPanel 的 Toggle 承载层渲染材质；配套要求是 bindSheet 显式 backgroundColor: Color.Transparent。
    // 本弹窗高度随内容（SheetSize.FIT_CONTENT），传 panelFillHeight: false（不写 height('100%')，避免被撑成整屏）。
    MaterialSheetPanel({ panelRadius: 20, panelPadding: 0, panelFillHeight: false, panelShowClose: true, panelOnClose: (): void => { this.showDebugSheet = false; } }) {
    Column() {
      Text(T('调试模式'))
        .fontSize(17)
        .fontWeight(this.fwMode === 'follow' ? FontWeight.Bold : AppearanceStore.fontWeight(FontWeight.Bold))
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ top: 16, bottom: 8 })

      Text(JwApi.USE_MOCK ? T('输入密码以开启功能浏览模式的联网能力') : T('输入密码以开启日志调试（收集使用日志）'))
        .fontSize(12)
        .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary'))).fontStyle(GlassMaterial.styleItalic(this.grayTick)).fontWeight(GlassMaterial.styleWeight(this.grayTick)).linearGradient({ angle: 90, colors: GlassMaterial.styleGlowColors(this.grayTick) })
        .width('100%')
        .margin({ bottom: 12 })

      // 密码输入框：TextInput 属表单控件，不能走 Toggle 承载层 → Stack 兄弟结构：
      // MaterialCardLayer 纯视觉承载层画沉浸光感（受全局开关控制），输入框自身透明底；
      // 材质关闭时回落原 comp_background_tertiary 实色底（与全站输入框一致）。
      Stack() {
        if (materialActive()) {
          MaterialCardLayer({ layerRadius: $r('sys.float.corner_radius_level12'), layerShadow: false })
        }
        TextInput({ text: this.debugPwd, placeholder: T('请输入密码') })
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
          .width('100%')
          .onChange((v: string) => {
            this.debugPwd = v;
          })
          .onSubmit(() => {
            this.submitDebugPwd();
          })
      }
      .width('100%')
      .borderRadius($r('sys.float.corner_radius_level12'))

      // 确认按钮：材质走 MaterialButton 的 Toggle 承载层（普通 Button 直接挂材质真机不渲染）；
      // 绿色语义在材质生效时靠 btnTint 叠回（比例 0.85），文字随系统深浅色自动黑白
      MaterialButton({
        btnRadius: 20,
        btnBg: $r('app.color.brand'),
        btnBlur: GlassMaterial.bgBlur(AppStorage.get<boolean>('immersiveEffect') ?? false),
        btnBorderW: GlassMaterial.borderWidth(),
        btnBorderC: GlassMaterial.borderColor(),
        btnTint: '#005BAC',
        btnTintRatio: 0.85,
        btnMargin: { top: 12, bottom: 16 },
        btnOnClick: () => {
          this.submitDebugPwd();
        }
      }) {
        Text(T('确认'))
          .fontSize(14)
          .fontWeight(this.fwMode === 'follow' ? FontWeight.Medium : AppearanceStore.fontWeight(FontWeight.Medium))
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .height(40)
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20 })
    }
  }
}