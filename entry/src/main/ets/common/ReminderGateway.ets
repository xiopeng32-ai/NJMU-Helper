/**
 * 课前提醒（系统代理提醒）
 *
 * 为什么用 reminderAgentManager：
 *  它是"系统代理"——提醒由系统托管，**应用未运行也能准时触发**，
 *  这是本方案唯一能做到"课前 30 分钟准点"的本地能力（WorkScheduler 不保证准时）。
 *
 * 设计要点：
 *  - 幂等对账：先读 getAllValidReminders()，计划内已存在的跳过，计划外的取消；
 *    **不做"先全删再全建"**（会重置已弹提醒、可能短暂丢提醒）。
 *  - 条数上限：d.ts 只暴露错误码 1700002（无常量），按 24 条保守设计，
 *    超限时按"时间最近优先"收缩到 12 → 6 重试。
 *  - 分组隔离：groupId = 'class_reminder'，与考试/其他提醒互不影响。
 */
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogStore } from './LogStore';
import { T } from './I18n';
import { Occurrence } from '../model/NotifyModels';
import { CoursePlan } from './CoursePlan';
import { DateUtil } from './DateUtil';

export class ReminderGateway {
  /** 本模块的提醒分组标识 */
  static readonly GROUP: string = 'class_reminder';
  /** 本应用包名（用于识别"是自己的、但 groupId 不是当前版本"的历史残留提醒） */
  private static readonly PKG: string = 'com.njmu.helper';
  /** 单次最多发布条数（保守值：系统上限未知，日志里 24 附近撞过 1700002） */
  static readonly MAX_REMINDERS: number = 20;
  /** 每次收到过少提醒时，不再继续重试 */
  static readonly MIN_REMINDERS: number = 6;
  /** 超出上限的错误码 */
  private static readonly ERR_LIMIT: number = 1700002;
  /** 本轮是否已撞到系统上限（撞到后不再继续发布） */
  private static limitHit: boolean = false;
  /** 本轮是否已尝试清理历史残留（每轮最多一次，避免反复删） */
  private static legacyCleaned: boolean = false;

  /**
   * 按计划对账（幂等）。
   * @returns 本次新发布的条数
   */
  static async sync(wanted: Occurrence[]): Promise<number> {
    const plan: Occurrence[] = wanted.slice(0, ReminderGateway.MAX_REMINDERS);
    const existing: reminderAgentManager.ReminderInfo[] | null = await ReminderGateway.listOurs();
    if (existing === null) {
      // 读不到已发布列表时**不发布**：否则会把已有提醒当不存在，重复发布直到触发系统上限
      LogStore.log('提醒', '对账', '跳过（读不到已发布列表）', `计划${plan.length}节`);
      return 0;
    }
    const ours: Map<number, number> = new Map<number, number>(); // notificationId -> reminderId
    for (const info of existing) {
      const req: reminderAgentManager.ReminderRequest | undefined = info.reminderReq;
      if (req === undefined || req === null || req.groupId !== ReminderGateway.GROUP) {
        continue;
      }
      ours.set(req.notificationId ?? 0, info.reminderId);
    }

    const keep: Set<number> = new Set<number>();
    const toPublish: Occurrence[] = [];
    // 已过去/已开始的课不再发布（否则晚上打开应用会给当天早课补发"即将上课"）
    const today: string = DateUtil.format(new Date());
    const nowMin: number = DateUtil.minutesOfNow();
    let skipped: number = 0;
    for (const o of plan) {
      const nid: number = CoursePlan.stableId(o.key);
      const isPast: boolean = o.date === today
        && (o.endMin <= nowMin + 1 || o.remindMin <= nowMin + 1);
      if (isPast) {
        skipped++;
        continue;
      }
      keep.add(nid);
      if (!ours.has(nid)) {
        toPublish.push(o);
      }
    }

    // 第一阶段：撤销计划外（含已过去的），先把名额腾出来再发布，
    // 否则"先发后撤"在接近上限时必然撞 1700002（日志里出现过）
    let revoked: number = 0;
    for (const nid of ours.keys()) {
      if (keep.has(nid)) {
        continue;
      }
      const rid: number = ours.get(nid) ?? -1;
      if (rid > 0) {
        await ReminderGateway.cancel(rid);
        revoked++;
      }
    }

    // 第二阶段：发布缺的（撞系统上限就停，剩下的都在更远的将来）
    ReminderGateway.limitHit = false;
    ReminderGateway.legacyCleaned = false;
    let published: number = 0;
    let blocked: number = 0;
    for (const o of toPublish) {
      if (ReminderGateway.limitHit) {
        blocked++;
        continue;
      }
      if (await ReminderGateway.publishOne(o, CoursePlan.stableId(o.key))) {
        published++;
      }
    }

    LogStore.log('提醒', '对账', '完成',
      `计划${plan.length} 新增${published} 跳过${skipped} 撤销${revoked}`
        + (blocked > 0 ? ` 超限未排${blocked}` : ''));
    return published;
  }

  /**
   * 发布单条。
   *
   * 撞到系统上限（1700002）时**不做"删旧的腾地方"**：
   * 计划按时间升序发布，先发的就是最近要上的课，删掉它们去换靠后的课是反向优化。
   * 正确做法是给上层一个信号，让本轮停止继续发布（剩下的都在更远的将来）。
   */
  static async publishOne(o: Occurrence, notificationId: number): Promise<boolean> {
    try {
      await reminderAgentManager.publishReminder(ReminderGateway.build(o, notificationId));
      return true;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      const code: number = Number(err.code ?? 0);
      if (code !== ReminderGateway.ERR_LIMIT) {
        LogStore.log('提醒', '发布', '失败', `${code} ${LogStore.errorOf(e as Object)}`);
        return false;
      }
      // 名额被占：先清一次"本应用的历史残留"（旧版本没写 groupId 的提醒），
      // 清出名额就立刻重试这条；清不出来才认定真到上限。
      if (!ReminderGateway.legacyCleaned) {
        ReminderGateway.legacyCleaned = true;
        const freed: number = await ReminderGateway.cleanupLegacy();
        LogStore.log('提醒', '清理历史', freed > 0 ? '成功' : '无可清理', `释放${freed}个名额`);
        if (freed > 0) {
          return await ReminderGateway.publishOne(o, notificationId);
        }
      }
      ReminderGateway.limitHit = true;
      LogStore.log('提醒', '发布', '达到系统上限', `nid=${notificationId}`);
      return false;
    }
  }

  /** 构造一条日历型提醒（课前 leadMin 分钟） */
  private static build(o: Occurrence, notificationId: number): reminderAgentManager.ReminderRequestCalendar {
    const base: Date = DateUtil.parse(o.date);
    // 提前量可能跨到前一天（如 08:00 课提前 60 分钟 → 07:00，正常；
    // 但凌晨课可能算出负数）：负值交给 Date 自动回退到前一天，同时 clamp 到 0 点前不超过 6 小时
    const remindMin: number = Math.max(o.remindMin, -360);
    const dayShift: number = remindMin < 0 ? -1 : 0;
    const minOfDay: number = ((remindMin % 1440) + 1440) % 1440;
    const remind: Date = new Date(base.getFullYear(), base.getMonth(), base.getDate() + dayShift,
      Math.floor(minOfDay / 60), minOfDay % 60, 0, 0);
    const end: Date = new Date(base.getFullYear(), base.getMonth(), base.getDate(),
      Math.floor(o.endMin / 60), o.endMin % 60, 0, 0);
    const req: reminderAgentManager.ReminderRequestCalendar = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
      dateTime: {
        year: remind.getFullYear(),
        month: remind.getMonth() + 1,
        day: remind.getDate(),
        hour: remind.getHours(),
        minute: remind.getMinutes(),
        second: 0
      },
      title: T('{0} 即将上课', o.name),
      content: `${o.startText} · ${o.location.length > 0 ? o.location : T('地点待定')} · ${CoursePlan.sectionText(o)}`,
      expiredContent: `${o.name} 已开始`,
      notificationId: notificationId,
      groupId: ReminderGateway.GROUP,
      slotType: notificationManager.SlotType.SERVICE_INFORMATION,
      tapDismissed: true,
      // 下课后自动清理该提醒，避免堆积
      autoDeletedTime: end.getTime(),
      wantAgent: {
        pkgName: 'com.njmu.helper',
        abilityName: 'EntryAbility',
        parameters: { 'open': 'schedule' }
      }
    };
    return req;
  }

  /**
   * 列出本模块已发布的提醒。
   * 读失败返回 **null**（而不是空数组）：空数组会被上层当成"一条都没有"，
   * 进而把已存在的提醒全部重发一遍，直接撞上系统上限。
   */
  static async listOurs(): Promise<reminderAgentManager.ReminderInfo[] | null> {
    try {
      const all: reminderAgentManager.ReminderInfo[] = await reminderAgentManager.getAllValidReminders();
      return all.filter((it: reminderAgentManager.ReminderInfo) => {
        const req: reminderAgentManager.ReminderRequest | undefined = it.reminderReq;
        return req !== undefined && req !== null && req.groupId === ReminderGateway.GROUP;
      });
    } catch (e) {
      LogStore.log('提醒', '读取列表', '失败', LogStore.errorOf(e as Object));
      return null;
    }
  }

  /**
   * 清理本应用的历史残留提醒：groupId 不是当前组、但 wantAgent 指向本应用的。
   * 只清自己的（pkgName 必须匹配），绝不碰其他应用。
   * @returns 释放的条数
   */
  static async cleanupLegacy(): Promise<number> {
    try {
      const all: reminderAgentManager.ReminderInfo[] = await reminderAgentManager.getAllValidReminders();
      let freed: number = 0;
      for (const info of all) {
        const req: reminderAgentManager.ReminderRequest | undefined = info.reminderReq;
        if (req === undefined || req === null) {
          continue;
        }
        const gid: string = req.groupId === undefined || req.groupId === null ? '' : `${req.groupId}`;
        if (gid === ReminderGateway.GROUP) {
          continue; // 当前版本发布的，保留
        }
        const wa: reminderAgentManager.WantAgent | undefined = req.wantAgent;
        if (wa === undefined || wa === null || wa.pkgName !== ReminderGateway.PKG) {
          continue; // 不是本应用的，绝不碰
        }
        await ReminderGateway.cancel(info.reminderId);
        freed++;
      }
      return freed;
    } catch (e) {
      LogStore.log('提醒', '清理历史', '读取失败', LogStore.errorOf(e as Object));
      return 0;
    }
  }

  /**
   * 清空**本应用**的全部提醒（系统接口 cancelAllReminders 只作用于本应用）。
   * 用途：名额被无法识别的历史提醒占满时的兜底手段，清完由调用方重排。
   */
  static async resetAll(): Promise<void> {
    try {
      await reminderAgentManager.cancelAllReminders();
      LogStore.log('提醒', '重建', '已清空全部', '等待重排');
    } catch (e) {
      LogStore.log('提醒', '重建', '清空失败', LogStore.errorOf(e as Object));
    }
  }

  /** 撤销本模块全部提醒（关开关/退出登录/假期） */
  static async cancelAllOurs(): Promise<void> {
    const ours: reminderAgentManager.ReminderInfo[] | null = await ReminderGateway.listOurs();
    if (ours === null) {
      LogStore.log('提醒', '撤销全部', '失败', '读不到已发布列表，本轮未撤销');
      return;
    }
    for (const it of ours) {
      await ReminderGateway.cancel(it.reminderId);
    }
    if (ours.length > 0) {
      LogStore.log('提醒', '撤销全部', '完成', `${ours.length} 条`);
    }
  }

  private static async cancel(reminderId: number): Promise<void> {
    try {
      await reminderAgentManager.cancelReminder(reminderId);
    } catch (e) {
      // 已失效的提醒忽略
    }
  }

  /** 当前本模块提醒条数（诊断用）；-1 = 读取失败/未知 */
  static async count(): Promise<number> {
    const ours: reminderAgentManager.ReminderInfo[] | null = await ReminderGateway.listOurs();
    return ours === null ? -1 : ours.length;
  }
}
