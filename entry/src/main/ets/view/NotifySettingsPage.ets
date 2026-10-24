/**
 * 通知与提醒设置页
 *
 * 内容：
 *  - 顶部权限提示条（通知未授权时显示，可一键去系统设置）
 *  - 总开关（默认关，开启时才申请通知权限并排程）
 *  - 课前提醒 / 实况窗 / 新成绩 / 教务公告 / 考试临近 / 后台自动刷新
 *  - 提前提醒分钟、实况窗收起延迟、滚动窗口天数
 *  - 底部：实况窗能力状态 + 提醒条数诊断（便于排查）
 *
 * 交互原则：任何一个开关变化都立即调用 NotifyScheduler.rescheduleAll('settings')，
 * 关闭时由 Scheduler 内部成对撤销（撤提醒 / 停实况窗 / 停后台任务）。
 */
import { common } from '@kit.AbilityKit';
import { AppState } from '../common/AppState';
import { PageHeader } from './common/UiKit';
import { GlassMaterial } from '../common/GlassMaterial';
import { WallpaperFill } from './common/WallpaperFill';
import { Theme } from '../common/ThemeUtil';
import { DataStore } from '../common/DataStore';
import { LogStore } from '../common/LogStore';
import { NotifySettings } from '../common/NotifySettings';
import { NotifyScheduler } from '../common/NotifyScheduler';
import { PushNotifier } from '../common/PushNotifier';
import { ReminderGateway } from '../common/ReminderGateway';
import { LiveViewGateway } from '../common/LiveViewGateway';
import { T } from '../common/I18n';

/**
 * 开关行。
 *
 * 为什么必须是 @Component 而不是 @Builder：@Builder 的按值传参在 ArkUI 里不会随状态变化重建，
 * 参数改了界面也不刷新（表现为"点了没反应，退出重进才变"）。@Link 双向 + @Prop 派生才是正解。
 */
@Component
struct NotifySwitchRow {
  /** 界面语言版本号：切换语言后自增，订阅它即可重建本组件 */
  @StorageProp('langRev') langRev: number = 0;
  title: string = '';
  desc: string = '';
  @Link isOn: boolean;
  @Prop disabled: boolean = false;
  @StorageProp('themeColor') themeColor: string = 'green';
  onToggle: (v: boolean) => void = () => {
  };

  build() {
    Row() {
      Column() {
        Text(this.title)
          .fontSize(15)
          .fontColor(this.disabled ? $r('app.color.text_tertiary') : $r('app.color.text_primary'))
        if (this.desc.length > 0) {
          Text(this.desc)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ top: 3 })
            .maxLines(2)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .enabled(!this.disabled)
        .selectedColor(Theme.colorOf(this.themeColor))
        .onChange((v: boolean) => {
          // 先回写：界面立刻跟随；父级若判定不允许（如权限被拒）会再改回来
          this.isOn = v;
          this.onToggle(v);
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(12)
    .margin({ bottom: 8 })
  }
}

/** 参数选择行（同上的原因，不能用 @Builder 传 current） */
@Component
struct NotifyChipRow {
  /** 界面语言版本号：切换语言后自增，订阅它即可重建本组件 */
  @StorageProp('langRev') langRev: number = 0;
  label: string = '';
  options: number[] = [];
  suffix: string = '';
  @Prop current: number = 0;
  @StorageProp('themeColor') themeColor: string = 'green';
  onPick: (v: number) => void = () => {
  };

  build() {
    Column() {
      Text(this.label)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.options, (v: number) => {
          Text(`${v}${this.suffix}`)
            .fontSize(12)
            .fontColor(this.current === v ? '#FFFFFF' : $r('app.color.text_secondary'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.current === v ? Theme.colorOf(this.themeColor) : $r('app.color.bg_chip'))
            .borderRadius(14)
            .margin({ right: 8, bottom: 4 })
            .onClick(() => {
              this.onPick(v);
            })
          // key 带上"是否选中"：ForEach 对 key 未变的项不会重新执行 itemGenerator，
          // 只写 `${v}` 会让选中态永远停在首次渲染的颜色上
        }, (v: number) => `${v}_${this.current === v ? 1 : 0}`)
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(12)
    .margin({ bottom: 8 })
  }
}

@Component
export struct NotifySettingsPage {
  /** 界面语言版本号：切换语言后自增，订阅它即可重建本组件 */
  @StorageProp('langRev') langRev: number = 0;
  @StorageProp('topInsetPx') topInsetPx: number = 0;
  @StorageProp('bottomInsetPx') bottomInsetPx: number = 0;
  @StorageProp('grayTick') grayTick: number = 0;
  @StorageProp('themeColor') themeColor: string = 'green';

  @State masterOn: boolean = false;
  @State classOn: boolean = false;
  @State liveOn: boolean = false;
  @State scoreOn: boolean = false;
  @State noticeOn: boolean = false;
  @State examOn: boolean = false;
  @State bgOn: boolean = false;
  @State leadMin: number = 30;
  @State graceMin: number = 10;
  @State horizonDays: number = 3;
  @State notifyEnabled: boolean = false;
  @State reminderCount: number = 0;
  @State busy: boolean = false;

  /** 页面是否已销毁（延迟回调不再写状态） */
  private disposed: boolean = false;

  aboutToAppear(): void {
    this.disposed = false;
    this.reload();
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  private reload(): void {
    this.masterOn = NotifySettings.master();
    this.classOn = NotifySettings.classReminder();
    this.liveOn = NotifySettings.liveView();
    this.scoreOn = NotifySettings.score();
    this.noticeOn = NotifySettings.notice();
    this.examOn = NotifySettings.exam();
    this.bgOn = NotifySettings.bgRefresh();
    this.leadMin = NotifySettings.leadMinutes();
    this.graceMin = NotifySettings.liveViewGrace();
    this.horizonDays = NotifySettings.horizonDays();
    this.notifyEnabled = PushNotifier.enabled();
    ReminderGateway.count().then((n: number) => {
      this.reminderCount = n;
    });
  }

  /** 改任意设置后统一重排 */
  private async apply(): Promise<void> {
    this.busy = true;
    try {
      await NotifyScheduler.rescheduleAll('settings');
    } finally {
      this.busy = false;
      this.reload();
      NotifySettingsPage.broadcastChanged();
      // 排程是异步的：稍后再取一次条数，否则"已排程 N 条"停在旧值
      setTimeout(() => {
        if (!this.disposed) {
          this.reload();
        }
      }, 900);
    }
  }

  /** 通知"我的"页刷新摘要（该页是常驻 Tab，不会重新 aboutToAppear） */
  private static broadcastChanged(): void {
    const n: number = AppStorage.get<number>('notifyRev') ?? 0;
    AppStorage.setOrCreate<number>('notifyRev', n + 1);
  }

  /** 打开总开关：先申请通知权限 + 建槽，再排程 */
  private async enableMaster(): Promise<void> {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const ok: boolean = await PushNotifier.requestPermission(ctx);
    if (!ok) {
      // 没有通知权限时不能"开启"：否则开关显示已开，提醒却一条都送不出去
      this.masterOn = false;
      this.notifyEnabled = false;
      this.getUIContext().getPromptAction().showToast({
        message: T('未获得通知权限，已保持关闭；可点上方「去开启」到系统设置授权'),
        duration: 2800
      });
      return;
    }
    await PushNotifier.ensureSlot();
    NotifySettings.setMaster(true);
    this.masterOn = true;
    this.notifyEnabled = true;
    await this.apply();
  }

  private async disableMaster(): Promise<void> {
    NotifySettings.setMaster(false);
    this.masterOn = false;
    await this.apply();
  }

  /** 发送一条测试通知（验证权限/渠道）；未授权则引导申请 */
  /** 清空本应用全部提醒并重排（解决"系统名额被历史提醒占满"导致排不上） */
  private async rebuildReminders(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await ReminderGateway.resetAll();
      await NotifyScheduler.rescheduleAll('manual');
      this.getUIContext().getPromptAction().showToast({ message: T('已清空并重建提醒'), duration: 2000 });
    } finally {
      this.busy = false;
      this.reload();
      NotifySettingsPage.broadcastChanged();
    }
  }

  private async sendTest(): Promise<void> {
    if (!this.notifyEnabled) {
      this.goSystemSettings();
      return;
    }
    const ok: boolean = await PushNotifier.push({
      id: 1999,
      group: 'test',
      title: T('测试通知'),
      text: T('如果你看到这条通知，说明提醒功能已就绪'),
      open: 'schedule'
    });
    this.getUIContext().getPromptAction().showToast({
      message: ok ? T('已发送，请查看通知栏') : T('发送失败，请检查通知权限')
    });
  }

  private goSystemSettings(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    PushNotifier.requestPermission(ctx).then((ok: boolean) => {
      this.notifyEnabled = ok;
    });
  }

  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(GlassMaterial.grayTertiary(this.grayTick, $r('app.color.text_tertiary')))
      .width('100%')
      .margin({ top: 16, bottom: 6, left: 4 })
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.TopStart }) {
        WallpaperFill()

        Scroll() {
          Column() {
            Column()
              .width('100%')
              .height(this.getUIContext().px2vp(this.topInsetPx) + 60)

            // 权限提示
            if (!this.notifyEnabled) {
              Row() {
                Text(T('系统通知权限未开启，提醒与通知无法送达'))
                  .fontSize(12)
                  .fontColor('#B3261E')
                  .layoutWeight(1)
                Text(T('去开启'))
                  .fontSize(12)
                  .fontColor(Theme.colorOf(this.themeColor))
                  .onClick(() => {
                    this.goSystemSettings();
                  })
              }
              .width('100%')
              .padding(12)
              .backgroundColor('rgba(179,38,30,0.10)')
              .borderRadius(12)
              .margin({ bottom: 10 })
            }

            this.sectionTitle(T('总开关'))
            NotifySwitchRow({
              title: T('通知与提醒'),
              desc: T('开启后才会排程课前提醒与后台检查'),
              isOn: $masterOn,
              onToggle: (v: boolean) => {
                if (v) {
                  this.enableMaster();
                } else {
                  this.disableMaster();
                }
              }
            })

            this.sectionTitle(T('提醒内容'))
            NotifySwitchRow({
              title: T('课前提醒'),
              desc: T('上课前推送提醒，即使应用未打开也会准时送达'),
              isOn: $classOn,
              disabled: !this.masterOn,
              onToggle: (v: boolean) => {
                NotifySettings.setClassReminder(v);
                this.apply();
              }
            })
            NotifySwitchRow({
              title: T('实况窗'),
              desc: T('上课前显示倒计时，上课 10 分钟后自动收起'),
              isOn: $liveOn,
              disabled: !this.masterOn,
              onToggle: (v: boolean) => {
                NotifySettings.setLiveView(v);
                this.apply();
              }
            })
            NotifySwitchRow({
              title: T('新成绩公布'),
              desc: T('后台检查到新成绩时通知'),
              isOn: $scoreOn,
              disabled: !this.masterOn,
              onToggle: (v: boolean) => {
                NotifySettings.setScore(v);
                this.apply();
              }
            })
            NotifySwitchRow({
              title: T('教务公告'),
              desc: T('教务处发布新通知时提醒'),
              isOn: $noticeOn,
              disabled: !this.masterOn,
              onToggle: (v: boolean) => {
                NotifySettings.setNotice(v);
                this.apply();
              }
            })
            NotifySwitchRow({
              title: T('考试临近'),
              desc: T('考试前 7 天、3 天、1 天各提醒一次'),
              isOn: $examOn,
              disabled: !this.masterOn,
              onToggle: (v: boolean) => {
                NotifySettings.setExam(v);
                this.apply();
              }
            })
            NotifySwitchRow({
              title: T('后台自动刷新'),
              desc: T('系统空闲时检查（通常几小时一次，时间不精确）'),
              isOn: $bgOn,
              disabled: !this.masterOn,
              onToggle: (v: boolean) => {
                NotifySettings.setBgRefresh(v);
                this.apply();
              }
            })

            this.sectionTitle(T('时间参数'))
            NotifyChipRow({
              label: T('提前提醒'),
              options: NotifySettings.LEAD_OPTIONS,
              current: this.leadMin,
              suffix: T(' 分钟'),
              onPick: (v: number) => {
                NotifySettings.setLeadMinutes(v);
                this.apply();
              }
            })
            NotifyChipRow({
              label: T('实况窗上课后收起'),
              options: NotifySettings.GRACE_OPTIONS,
              current: this.graceMin,
              suffix: T(' 分钟'),
              onPick: (v: number) => {
                NotifySettings.setLiveViewGrace(v);
                this.apply();
              }
            })
            NotifyChipRow({
              label: T('滚动排程窗口'),
              options: NotifySettings.HORIZON_OPTIONS,
              current: this.horizonDays,
              suffix: T(' 天'),
              onPick: (v: number) => {
                NotifySettings.setHorizonDays(v);
                this.apply();
              }
            })

            // 诊断
            this.sectionTitle(T('状态'))
            Column() {
              Text(LiveViewGateway.diagnostics())
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
              Text(`已排程课前提醒：${this.reminderCount < 0 ? '未知' : `${this.reminderCount} 条`}${this.busy ? '（更新中…）' : ''}`)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .margin({ top: 4 })
              Text(T('说明：在系统设置里"强行停止"本应用后提醒会暂停，重新打开即恢复。'))
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .margin({ top: 8 })
              // 兜底：名额被历史提醒占满、怎么都排不上时，一键清空本应用提醒再重建
              Text(T('重建全部课前提醒'))
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .height(36)
                .margin({ top: 8 })
                .backgroundColor($r('app.color.bg_chip'))
                .borderRadius(18)
                .enabled(!this.busy)
                .onClick(() => {
                  this.rebuildReminders();
                })

              // 诊断：发一条测试通知，验证权限与渠道是否正常
              Text(this.notifyEnabled ? T('发送测试通知') : T('开启系统通知权限'))
                .fontSize(13)
                .fontColor(Theme.colorOf(this.themeColor))
                .width('100%')
                .textAlign(TextAlign.Center)
                .height(36)
                .margin({ top: 10 })
                .backgroundColor(Theme.rgba(Theme.colorOf(this.themeColor), 0.10))
                .borderRadius(18)
                .onClick(() => {
                  this.sendTest();
                })
            }
            .width('100%')
            .padding(14)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(12)

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
          title: T('通知与提醒'),
          onBack: () => {
            AppState.stack.pop();
          }
        })
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    // 从系统通知设置返回、或页面重新可见时，重读权限与实际排程数量
    .onShown(() => {
      this.reload();
      // 从系统设置授权后回来，补一次排程（总开关未开时无需重排）
      if (NotifySettings.master()) {
        NotifyScheduler.rescheduleAll('settings').catch(() => {
        });
      }
    })
  }
}
