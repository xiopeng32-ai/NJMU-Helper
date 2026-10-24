/**
 * 实况窗（Live View）
 *
 * 生命周期（本次需求核心）：
 *   T-30 分钟  创建，胶囊 = 倒计时（TimerCapsule，**系统每秒自刷，进程结束也照走**）
 *   T          切换为「上课中」（TextCapsule）
 *   T+grace    停止（grace 默认 10 分钟，受下课时间约束）
 *   now ≥ T+grace 时不再创建（错过窗口）
 *
 * 能力事实（SDK 已核实）：
 *  - 没有时间触发器（startLiveViewByTrigger 只支持地理围栏），因此**应用未运行时
 *    无法自行在 T-30 弹出**；准点由代理提醒保证，实况窗是"进程在时尽力"。
 *  - 不需要 manifest 权限，但需要 AGC 实况窗权益；未开通会抛 1003500005，
 *    此时降级为常驻通知（同样 T+grace 撤销）。
 *  - lifeCycleMode 默认 STOP_BY_APP(0)：进程结束不会自动结束，正好符合"下课后再消失"。
 */
import { liveViewManager } from '@kit.LiveViewKit';
import { common } from '@kit.AbilityKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogStore } from './LogStore';
import { T } from './I18n';
import { DataStore } from './DataStore';
import { NotifySettings } from './NotifySettings';
import { Occurrence } from '../model/NotifyModels';
import { CoursePlan } from './CoursePlan';
import { DateUtil } from './DateUtil';
import { PushNotifier } from './PushNotifier';

/** 实况窗场景常量：SDK 无教育/日程类目，借 TIMER（倒计时）承载；可按权益审核结果改为 PROGRESS */
const LIVE_EVENT: string = 'TIMER';
/** 停止后在通知中心保留的秒数（让 T+grace 后自然淡出） */
const KEEP_SECONDS: number = 60;
/** 不支持标记的有效期（7 天） */
const UNSUPPORTED_TTL_MS: number = 7 * 24 * 3600 * 1000;

export class LiveViewGateway {
  /** 当前是否已创建（进程内标记，用于判断是否需要 update 而非 start） */
  private static activeKey: string = '';
  private static activeId: number = 0;
  /** 已降级为常驻通知（无实况窗），用于到期撤销 */
  private static fallbackOn: boolean = false;
  /** 持久化键：'id|key'，供进程重启后接管残留实况窗（lifeCycleMode=STOP_BY_APP 时进程结束不结束实况窗） */

  /** 能力探测：系统开关 + 是否被标记为不支持 */
  static async probe(): Promise<boolean> {
    if (LiveViewGateway.recentlyUnsupported()) {
      return false;
    }
    try {
      const on: boolean = await liveViewManager.isLiveViewEnabled();
      return on;
    } catch (e) {
      LiveViewGateway.markUnsupported('probe');
      return false;
    }
  }

  private static recentlyUnsupported(): boolean {
    const raw: string = DataStore.get(DataStore.KEY_NOTIFY_LV_UNSUPPORTED);
    if (raw.length === 0) {
      return false;
    }
    const at: number = Number.parseInt(raw, 10);
    if (isNaN(at)) {
      return false;
    }
    return Date.now() - at < UNSUPPORTED_TTL_MS;
  }

  private static markUnsupported(reason: string): void {
    DataStore.put(DataStore.KEY_NOTIFY_LV_UNSUPPORTED, `${Date.now()}`);
    LogStore.log('实况窗', '标记不支持', reason, '7 天内不再尝试');
  }

  /** 点击跳转（进入课程表） */
  private static async clickAgent(): Promise<WantAgent | undefined> {
    try {
      return await wantAgent.getWantAgent({
        wants: [{
          bundleName: 'com.njmu.helper',
          abilityName: 'EntryAbility',
          parameters: { 'open': 'schedule' }
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
    } catch (e) {
      return undefined;
    }
  }

  /**
   * 根据当前时间同步实况窗状态（幂等，可高频调用）。
   * 内部完成：进入窗口 → 创建；跨越上课时刻 → 切"上课中"；超过 T+grace → 停止。
   */
  static async syncForNow(list: Occurrence[], now: Date): Promise<void> {
    if (!NotifySettings.master() || !NotifySettings.liveView()) {
      return;
    }
    LiveViewGateway.ensureRestore();
    const lead: number = NotifySettings.leadMinutes();
    const grace: number = NotifySettings.liveViewGrace();
    const occ: Occurrence | null = LiveViewGateway.pick(list, now, lead, grace);
    if (occ === null) {
      if (LiveViewGateway.activeId > 0) {
        await LiveViewGateway.stop(LiveViewGateway.activeId);
      } else if (LiveViewGateway.fallbackOn) {
        // 降级态的常驻通知也要在窗口结束后撤销，否则会一直挂在通知栏
        await PushNotifier.cancel(PushNotifier.ID_BASE_CLASS_ONGOING);
        LiveViewGateway.fallbackOn = false;
        LiveViewGateway.activeKey = '';
        LogStore.log('实况窗', '降级撤销', '完成', '常驻通知已清除');
      }
      return;
    }
    const nowMin: number = CoursePlan.minOf(now);
    const started: boolean = nowMin >= occ.startMin;
    if (LiveViewGateway.activeId > 0 && LiveViewGateway.activeKey === occ.key) {
      // 同一节课：只在跨越上课时刻时更新一次胶囊（避免高频 update 触发限流）
      if (started && !LiveViewGateway.startedFlag) {
        LiveViewGateway.startedFlag = true;
        await LiveViewGateway.render(occ, now, started, grace);
      }
      return;
    }
    // 新课：先停旧的，再建新的
    if (LiveViewGateway.activeId > 0) {
      await LiveViewGateway.stop(LiveViewGateway.activeId);
    }
    LiveViewGateway.startedFlag = started;
    await LiveViewGateway.render(occ, now, started, grace);
  }

  private static startedFlag: boolean = false;

  /** 选出一节处于 [T-lead, T+grace) 的课；无则 null */
  private static pick(list: Occurrence[], now: Date, lead: number, grace: number): Occurrence | null {
    const today: string = DateUtil.format(now);
    const nowMin: number = CoursePlan.minOf(now);
    for (const o of list) {
      if (o.date !== today) {
        continue;
      }
      const stopMin: number = Math.min(o.startMin + grace, o.endMin);
      if (nowMin >= o.startMin - lead && nowMin < stopMin) {
        return o;
      }
    }
    return null;
  }

  /** 实际渲染（创建或更新） */
  private static async render(occ: Occurrence, now: Date, started: boolean, grace: number): Promise<void> {
    const supported: boolean = await LiveViewGateway.probe();
    if (!supported) {
      await LiveViewGateway.fallbackOngoing(occ, grace);
      return;
    }
    const nowMin: number = CoursePlan.minOf(now);
    const stopMin: number = Math.min(occ.startMin + grace, occ.endMin);
    const alive: number = Math.max(15, Math.min(28800, (stopMin - nowMin) * 60));
    const id: number = CoursePlan.stableId(occ.key);
    const location: string = occ.location.length > 0 ? occ.location : T('地点待定');

    const primary: liveViewManager.PrimaryData = {
      title: started ? T('{0}（上课中）', occ.name) : T('{0} {1} 上课', occ.name, occ.startText),
      content: [{ text: `${occ.startText}-${occ.endText} · ${location} · ${CoursePlan.sectionText(occ)}` }],
      keepTime: KEEP_SECONDS,
      aliveTime: alive,
      clickAction: await LiveViewGateway.clickAgent(),
      layoutData: {
        layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_FLIGHT,
        firstTitle: occ.startText,
        firstContent: location,
        lastTitle: occ.endText,
        lastContent: CoursePlan.sectionText(occ)
      }
    };

    // 注意：TextCapsule 只有 type/status（无可配文本字段），要用 content 必须用 TimerCapsule。
    // 上课中阶段用 TimerCapsule 且 time=0、isCountdown=false，等价于一段静态文本。
    const capsule: liveViewManager.TimerCapsule = started
      ? {
        type: liveViewManager.CapsuleType.CAPSULE_TYPE_TIMER,
        status: 1,
        content: T('上课中'),
        time: 0,
        isCountdown: false
      }
      : {
        type: liveViewManager.CapsuleType.CAPSULE_TYPE_TIMER,
        status: 1,
        content: T('距上课 {0}', occ.startText),
        time: (occ.startMin - nowMin) * 60000,
        isCountdown: true
      };

    const lv: liveViewManager.LiveView = {
      id: id,
      event: LIVE_EVENT,
      lifeCycleMode: liveViewManager.LifeCycleMode.STOP_BY_APP,
      isMute: true,
      liveViewData: {
        primary: primary,
        capsule: capsule
      }
    };

    try {
      if (LiveViewGateway.activeId === id) {
        await liveViewManager.updateLiveView(lv);
        LogStore.log('实况窗', '更新', started ? '上课中' : '倒计时', occ.name);
      } else {
        await liveViewManager.startLiveView(lv);
        LogStore.log('实况窗', '创建', '成功', `${occ.name} 存活${Math.round(alive / 60)}分`);
      }
      LiveViewGateway.activeId = id;
      LiveViewGateway.activeKey = occ.key;
      DataStore.put(DataStore.KEY_NOTIFY_LV_ACTIVE, `${id}|${occ.key}`);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      LogStore.log('实况窗', '创建', '失败降级', `${err.code ?? ''} ${LogStore.errorOf(e as Object)}`);
      if (err.code === 1003500005 || err.code === 1003500004 || err.code === 801) {
        LiveViewGateway.markUnsupported(`code=${err.code}`);
      }
      await LiveViewGateway.fallbackOngoing(occ, grace);
    }
  }

  /** 降级：常驻通知（同样在 T+grace 撤销） */
  private static async fallbackOngoing(occ: Occurrence, grace: number): Promise<void> {
    const nowMin: number = CoursePlan.minOf(new Date());
    const stopMin: number = Math.min(occ.startMin + grace, occ.endMin);
    const stopAt: Date = CoursePlan.dateAt(occ, stopMin);
    const started: boolean = nowMin >= occ.startMin;
    await PushNotifier.push({
      id: PushNotifier.ID_BASE_CLASS_ONGOING,
      group: 'class',
      title: started ? T('{0}（上课中）', occ.name) : T('{0} {1} 上课', occ.name, occ.startText),
      text: `${occ.startText}-${occ.endText} · ${occ.location.length > 0 ? occ.location : T('地点待定')}`,
      open: 'schedule',
      ongoing: true,
      autoDeletedTime: stopAt.getTime()
    });
    LiveViewGateway.fallbackOn = true;
    LiveViewGateway.activeKey = occ.key;
    LogStore.log('实况窗', '降级', '常驻通知', occ.name);
  }

  /** 停止指定 id 的实况窗 */
  static async stop(id: number): Promise<void> {
    try {
      // 结束必须带 capsule.status=-1，否则系统认为"仍在展示"，T+grace 不会消失
      await liveViewManager.stopLiveView({
        id: id,
        event: LIVE_EVENT,
        liveViewData: {
          primary: { title: '', content: [], keepTime: 0 },
          capsule: {
            type: liveViewManager.CapsuleType.CAPSULE_TYPE_TIMER,
            status: -1,
            content: '',
            time: 0,
            isCountdown: false
          }
        }
      });
      LogStore.log('实况窗', '停止', '成功', `id=${id}`);
    } catch (e) {
      LogStore.log('实况窗', '停止', '失败', LogStore.errorOf(e as Object));
    }
    await PushNotifier.cancel(PushNotifier.ID_BASE_CLASS_ONGOING);
    LiveViewGateway.fallbackOn = false;
    DataStore.put(DataStore.KEY_NOTIFY_LV_ACTIVE, '');
    if (LiveViewGateway.activeId === id) {
      LiveViewGateway.activeId = 0;
      LiveViewGateway.activeKey = '';
      LiveViewGateway.startedFlag = false;
    }
  }

  /** 进程重启后接管上次的实况窗（避免 startLiveView 报"已存在"→ 降级出两份） */
  private static ensureRestore(): void {
    if (LiveViewGateway.activeId > 0) {
      return;
    }
    const raw: string = DataStore.get(DataStore.KEY_NOTIFY_LV_ACTIVE);
    if (raw.length === 0) {
      return;
    }
    const parts: string[] = raw.split('|');
    const id: number = Number.parseInt(parts[0], 10);
    if (isNaN(id) || id <= 0) {
      DataStore.put(DataStore.KEY_NOTIFY_LV_ACTIVE, '');
      return;
    }
    LiveViewGateway.activeId = id;
    LiveViewGateway.activeKey = parts.length > 1 ? parts[1] : '';
    LiveViewGateway.startedFlag = false;
    LogStore.log('实况窗', '恢复', '接管上次', `id=${id}`);
  }

  /** 停止当前所有（关开关/退出登录） */
  static async stopAll(): Promise<void> {
    LiveViewGateway.ensureRestore();
    if (LiveViewGateway.activeId > 0) {
      await LiveViewGateway.stop(LiveViewGateway.activeId);
    } else {
      await PushNotifier.cancel(PushNotifier.ID_BASE_CLASS_ONGOING);
      DataStore.put(DataStore.KEY_NOTIFY_LV_ACTIVE, '');
      LiveViewGateway.fallbackOn = false;
    }
  }

  /** 进程不在时记录的"待停止"（下次前台补执行） */
  static markPendingStop(): void {
    DataStore.put(DataStore.KEY_NOTIFY_PENDING_STOP, '1');
  }

  static async runPendingStop(): Promise<void> {
    if (DataStore.get(DataStore.KEY_NOTIFY_PENDING_STOP) !== '1') {
      return;
    }
    DataStore.put(DataStore.KEY_NOTIFY_PENDING_STOP, '0');
    await LiveViewGateway.stopAll();
  }

  /** 诊断信息（设置页/日志用） */
  static diagnostics(): string {
    const unsupported: boolean = LiveViewGateway.recentlyUnsupported();
    const state: string = LiveViewGateway.activeId > 0
      ? '展示中'
      : (LiveViewGateway.fallbackOn ? '已降级为通知' : '未展示');
    return `实况窗：${unsupported ? '本机不支持' : '可用'} · ${state}`;
  }
}
