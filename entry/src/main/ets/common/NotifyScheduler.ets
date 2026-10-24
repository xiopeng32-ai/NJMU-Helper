/**
 * 提醒编排（统一入口）
 *
 * 所有会改变"该提醒什么"的事件都走这里：
 *  - 应用进入前台 / 后台
 *  - 后台任务唤醒
 *  - 用户改设置（开关、提前分钟、收起延迟）
 *  - 课表同步成功、作息变更
 *
 * 幂等设计：重复调用不会产生重复提醒（ReminderGateway 内部对账），
 * 但仍有 60s 节流，避免"前台反复切换"造成频繁的系统调用。
 */
import { workScheduler } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogStore } from './LogStore';
import { DataStore } from './DataStore';
import { NotifySettings } from './NotifySettings';
import { CoursePlan } from './CoursePlan';
import { ReminderGateway } from './ReminderGateway';
import { LiveViewGateway } from './LiveViewGateway';
import { JwApi } from '../api/JwApi';
import { AppState } from './AppState';
import { ScheduleConfig } from './ScheduleConfig';
import { DateUtil } from './DateUtil';
import { Occurrence } from '../model/NotifyModels';
import { CourseItem, TermInfo } from '../model/Models';

/** 后台任务 workId（固定，便于 stopWork） */
const WORK_ID: number = 20261021;
/** 重复周期：30 分钟（系统实际调度会更晚，这里只是"最小间隔"） */
const REPEAT_MS: number = 30 * 60 * 1000;
/** 重排节流 */
const THROTTLE_MS: number = 60 * 1000;
/** startWork 重复注册的错误码（任务已存在，属正常） */
const ERR_ALREADY_ADDED: number = 9700005;

export class NotifyScheduler {
  private static lastRunAt: number = 0;
  private static running: boolean = false;
  /** 重入时挂起的请求（跑完当前轮后补跑一次，不丢弃） */
  private static pending: string = '';
  /** 这些原因不受 60s 节流限制（用户改设置/学期就绪/手动） */
  private static readonly FORCE: string[] = ['settings', 'term-ready', 'manual', 'retry'];
  private static foreground: boolean = false;
  /** 前台心跳（每分钟检查一次实况窗窗口） */
  private static tickTimer: number = -1;
  /** "数据未就绪"时的补排次数与定时器（冷启动早期课表/学期还没进内存） */
  private static retryCount: number = 0;
  private static retryTimer: number = -1;

  /** 前台/后台切换（EntryAbility 调用） */
  static markForeground(on: boolean): void {
    NotifyScheduler.foreground = on;
    if (on) {
      NotifyScheduler.startTick();
    } else {
      NotifyScheduler.stopTick();
      // 进后台前做一次状态收敛（实况窗该建就建、该停就停）
      NotifyScheduler.onTick().catch(() => {
      });
    }
  }

  private static startTick(): void {
    if (NotifyScheduler.tickTimer > 0) {
      return;
    }
    NotifyScheduler.tickTimer = setInterval(() => {
      NotifyScheduler.onTick().catch(() => {
      });
    }, 60 * 1000);
  }

  private static stopTick(): void {
    if (NotifyScheduler.tickTimer > 0) {
      clearInterval(NotifyScheduler.tickTimer);
      NotifyScheduler.tickTimer = -1;
    }
  }

  /** 每分钟 tick：只驱动实况窗状态机（轻量，不重排提醒） */
  static async onTick(): Promise<void> {
    await LiveViewGateway.runPendingStop();
    // 实况窗关闭时整条链路无需运行（每分钟省掉一次课表展开）
    if (!NotifySettings.master() || !NotifySettings.liveView()) {
      return;
    }
    // tick 只关心"今天这一节"，用 1 天窗口代替默认 3~7 天
    const list: Occurrence[] | null = NotifyScheduler.buildPlan(1);
    if (list === null) {
      return; // 未就绪：不改动现有实况窗
    }
    await LiveViewGateway.syncForNow(list, new Date());
  }

  /**
   * 计划算不出来时补排（最多 3 次，6s / 15s / 30s）。
   * 只在"数据未就绪"时触发，成功一次就清零计数。
   */
  private static scheduleRetry(reason: string): void {
    if (NotifyScheduler.retryTimer > 0 || NotifyScheduler.retryCount >= 3) {
      return;
    }
    const delays: number[] = [6000, 15000, 30000];
    const delay: number = delays[NotifyScheduler.retryCount];
    NotifyScheduler.retryCount++;
    LogStore.log('提醒', '补排', '已安排', `${delay / 1000}s 后重试（原因 ${reason}）`);
    NotifyScheduler.retryTimer = setTimeout(() => {
      NotifyScheduler.retryTimer = -1;
      NotifyScheduler.rescheduleAll('retry').catch(() => {
      });
    }, delay);
  }

  /** 挂起：停心跳、清状态（退出登录/清缓存时调用，防止实况窗与提醒"复活"） */
  static suspend(reason: string): void {
    NotifyScheduler.stopTick();
    if (NotifyScheduler.retryTimer > 0) {
      clearTimeout(NotifyScheduler.retryTimer);
      NotifyScheduler.retryTimer = -1;
    }
    NotifyScheduler.retryCount = 0;
    NotifyScheduler.foreground = false;
    NotifyScheduler.running = false;
    NotifyScheduler.pending = '';
    NotifyScheduler.lastRunAt = 0;
    LogStore.log('提醒', '挂起', '完成', reason);
  }

  /** 重排全部（提醒 + 实况窗 + 后台任务）。幂等、带节流 */
  static async rescheduleAll(reason: string): Promise<void> {
    if (NotifyScheduler.running) {
      NotifyScheduler.pending = reason; // 不丢弃：当前轮结束后补跑
      return;
    }
    const now: number = Date.now();
    if (now - NotifyScheduler.lastRunAt < THROTTLE_MS && NotifyScheduler.FORCE.indexOf(reason) < 0) {
      return;
    }
    NotifyScheduler.running = true;
    NotifyScheduler.lastRunAt = now;
    try {
      if (!NotifySettings.master()) {
        await ReminderGateway.cancelAllOurs();
        await LiveViewGateway.stopAll();
        await NotifyScheduler.cancelBackgroundWork();
        LogStore.log('提醒', '重排', '跳过（总开关关闭）', reason);
        return;
      }
      // 先算计划，但"关闭"分支不依赖计划：数据未就绪时关开关也必须立即撤销，
      // 否则用户关掉课前提醒后旧提醒还在（曾表现为"点了没反应"）
      const list: Occurrence[] | null = NotifyScheduler.buildPlan();
      if (list === null) {
        // 冷启动时 Index 还没把 profile/学期/课表放进内存，本轮算不出计划。
        // 之前直接跳过后就不再重试，导致"打开应用但一条提醒都没排上"（19:51 日志）。
        NotifyScheduler.scheduleRetry(reason);
      } else {
        NotifyScheduler.retryCount = 0;
      }
      if (NotifySettings.classReminder()) {
        if (list === null) {
          LogStore.log('提醒', '重排', '跳过提醒（数据未就绪）', reason);
        } else {
          await ReminderGateway.sync(list);
        }
      } else {
        await ReminderGateway.cancelAllOurs();
      }
      if (NotifySettings.liveView()) {
        if (list !== null) {
          await LiveViewGateway.syncForNow(list, new Date());
        }
      } else {
        LiveViewGateway.markPendingStop();
        await LiveViewGateway.stopAll();
      }
      if (NotifySettings.bgRefresh()) {
        await NotifyScheduler.ensureBackgroundWork();
      } else {
        await NotifyScheduler.cancelBackgroundWork();
      }
      LogStore.log('提醒', '重排', '完成',
        `${reason} 计划${list === null ? '未就绪' : list.length + '节'}`);
    } catch (e) {
      LogStore.log('提醒', '重排', '失败', LogStore.errorOf(e as Object));
    } finally {
      NotifyScheduler.running = false;
      const next: string = NotifyScheduler.pending;
      NotifyScheduler.pending = '';
      if (next.length > 0) {
        // 延后一拍，避免在 finally 里同步递归
        setTimeout(() => {
          NotifyScheduler.rescheduleAll(next).catch(() => {
          });
        }, 0);
      }
    }
  }

  /**
   * 生成未来的上课计划。
   * 假期/学期外返回空数组（进而撤销全部提醒，避免假期乱弹）。
   */
  static buildPlan(daysOverride: number = 0): Occurrence[] | null {
    try {
      // 未登录（退出登录后 tick 仍在跑）不再生成计划，避免旧账号提醒"复活"
      if (AppState.profile === null || AppState.profile === undefined) {
        return null;
      }
      const term: TermInfo | null = NotifyScheduler.resolveTerm();
      if (term === null) {
        return null; // 数据未就绪：调用方必须跳过，不能按空计划撤销已有提醒
      }
      const week: number = DateUtil.weekOfTerm(term, new Date());
      if (week < 1 || week > term.totalWeeks) {
        return []; // 假期/学期外：确实应该清空
      }
      // 走 JwApi 内存层：tick 每分钟调用，不能每次都 JSON.parse 上百条课表
      const courses: CourseItem[] = JwApi.loadCachedCourses();
      if (courses.length === 0) {
        return null; // 课表未缓存：同样视为未就绪
      }
      const cfg: ScheduleConfig = ScheduleConfig.load();
      const lead: number = NotifySettings.leadMinutes();
      const days: number = daysOverride > 0 ? daysOverride : NotifySettings.horizonDays();
      return CoursePlan.expand(courses, term, cfg, new Date(), days, lead);
    } catch (e) {
      LogStore.log('提醒', '生成计划', '失败', LogStore.errorOf(e as Object));
      return null;
    }
  }

  /**
   * 解析当前学期：进程内 AppState 优先，缺失时从 DataStore 恢复。
   * 后台扩展进程与冷启动早期 AppState.term 可能未初始化（Index 才设），
   * 若不兜底会算出空计划，把已有提醒全撤销。
   */
  private static resolveTerm(): TermInfo | null {
    try {
      const now: Date = new Date();
      const cands: TermInfo[] = [];
      // ① 已显式设置的学期（JwApi.setTerm 内置标记；默认值不算）
      if (AppState.termExplicit && AppState.term !== null && AppState.term !== undefined) {
        cands.push(AppState.term);
      }
      // ② 持久化的上次选择
      const termId: string = DataStore.get(DataStore.KEY_DS_TERM);
      if (termId.length > 0) {
        const terms: TermInfo[] = JwApi.buildLocalTerms();
        for (const t of terms) {
          if (t.id === termId) {
            cands.push(JwApi.applyCustomStart(t));
            break;
          }
        }
      }
      // ③ 按当前日期推算（1~8 月为第二学期）+ ④ 寒假仍在第一学期
      cands.push(DateUtil.buildCurrentTerm());
      cands.push(DateUtil.buildPrevFirstTerm(now));
      // 取"今天确实落在该学期周次内"的第一个候选
      for (const t of cands) {
        const w: number = DateUtil.weekOfTerm(t, now);
        if (w >= 1 && w <= t.totalWeeks) {
          return t;
        }
      }
      // 全部越界 = 真假期：返回当前推算学期，交给 buildPlan 返回 []（此时确实该清空）
      return DateUtil.buildCurrentTerm();
    } catch (e) {
      LogStore.log('提醒', '解析学期', '失败', LogStore.errorOf(e as Object));
      return null;
    }
  }

  /** 是否已确认注册过后台任务（避免每次重排都去调一次 startWork，日志被 9700005 刷屏） */
  private static bgRegistered: boolean = false;

  /** 确保后台延迟任务已注册（持久化，重启后仍在） */
  static async ensureBackgroundWork(): Promise<void> {
    if (NotifyScheduler.bgRegistered) {
      return;
    }
    try {
      const info: workScheduler.WorkInfo = {
        workId: WORK_ID,
        bundleName: 'com.njmu.helper',
        abilityName: 'BackgroundWorkAbility',
        isPersisted: true,
        networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY,
        repeatCycleTime: REPEAT_MS,
        isRepeat: true,
        batteryLevel: 20
      };
      workScheduler.startWork(info);
      NotifyScheduler.bgRegistered = true;
      LogStore.log('后台', '注册任务', '成功', `workId=${WORK_ID} 周期${REPEAT_MS / 60000}分`);
    } catch (e) {
      // code 可能是字符串（'9700005'），严格 === 数字会判不中，统一转数值
      const code: number = Number((e as BusinessError).code ?? 0);
      if (code === ERR_ALREADY_ADDED) {
        NotifyScheduler.bgRegistered = true;
        // 9700005 = 任务已存在。startWork 是幂等的，重复调用必然抛这个，
        // 之前记成"失败"会误导排查（2026-10-23 日志里就出现过）
        LogStore.log('后台', '注册任务', '已存在', `workId=${WORK_ID}`);
      } else {
        LogStore.log('后台', '注册任务', '失败', `${code} ${LogStore.errorOf(e as Object)}`);
      }
    }
  }

  /** 取消后台任务 */
  static async cancelBackgroundWork(): Promise<void> {
    try {
      workScheduler.stopWork({
        workId: WORK_ID,
        bundleName: 'com.njmu.helper',
        abilityName: 'BackgroundWorkAbility'
      }, true);
      LogStore.log('后台', '取消任务', '成功', `workId=${WORK_ID}`);
    } catch (e) {
      // 未注册时忽略
    }
    NotifyScheduler.bgRegistered = false;
  }
}
