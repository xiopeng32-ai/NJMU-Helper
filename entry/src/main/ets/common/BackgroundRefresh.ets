/**
 * 后台刷新（业务体）
 *
 * 与 WorkScheduler 解耦：扩展能力只负责 init + 调用 run() + 立刻返回，
 * 这样同一套逻辑也能被前台（onForeground）复用，且便于单测。
 *
 * 硬约束：WorkSchedulerExtensionAbility.onWorkStart 有 **2 分钟**超时，
 * 因此这里只拉"成绩 + 公告"两类轻数据，每步都有超时预算，总预算 100s。
 */
import { DataStore } from './DataStore';
import { LogStore } from './LogStore';
import { JwApi } from '../api/JwApi';
import { HttpClient } from '../api/HttpClient';
import { NotifySettings } from './NotifySettings';
import { NotifySnapshot, Snapshot } from './NotifySnapshot';
import { PushNotifier } from './PushNotifier';
import { SessionRestorer } from './SessionRestorer';
import { NotifyScheduler } from './NotifyScheduler';
import { NotifyPayload, RefreshResult } from '../model/NotifyModels';
import { DateUtil } from './DateUtil';
import { ExamItem, NoticeItem, TermScore } from '../model/Models';
import { I18n, T } from './I18n';

/** 单步网络预算（压低单步，给后续步骤留时间） */
const STEP_BUDGET_MS: number = 30000;
/** 整体预算：onWorkStart 硬上限 2 分钟，留 30s 余量 */
const TOTAL_BUDGET_MS: number = 90000;

export class BackgroundRefresh {
  /** 连续会话失败计数（进程内，用于"连续 3 次才提示登录过期"） */
  private static sessionFailCount: number = 0;

  /**
   * 执行一次后台刷新。
   * @param reason 触发来源（bg-work / foreground / manual），仅用于日志
   */
  static async run(reason: string): Promise<RefreshResult> {
    const result: RefreshResult = { ok: false, reason: reason, newScores: 0, newNotices: 0 };
    if (!NotifySettings.master() || !NotifySettings.bgRefresh()) {
      result.reason = 'disabled';
      return result;
    }
    const s: Snapshot = NotifySnapshot.load();
    s.lastRunAt = Date.now();
    NotifySnapshot.save(s);

    const t0: number = Date.now();
    try {
      SessionRestorer.restoreTerm();
      JwApi.USE_MOCK = false;
      HttpClient.setOfflineMode(false);
      const sessionOk: boolean = await SessionRestorer.restoreSession(25000);
      if (!sessionOk) {
        BackgroundRefresh.sessionFailCount++;
        result.reason = 'session';
        BackgroundRefresh.saveError('session', '0');
        await BackgroundRefresh.maybeAlertSession();
        NotifySnapshot.save(s);
        return result;
      }

      if (Date.now() - t0 > TOTAL_BUDGET_MS) {
        result.reason = 'budget';
        BackgroundRefresh.saveError('budget', `${Date.now() - t0}`);
        NotifySnapshot.save(s);
        LogStore.log('后台', '刷新', '预算耗尽', `${Date.now() - t0}ms`);
        return result;
      }
      // null = 本次没拿到（超时/异常），与"确实没有数据"区分开，避免污染基线
      const scores: TermScore[] | null = await BackgroundRefresh.fetchOrNull<TermScore>(JwApi.getTermScores());
      const notices: NoticeItem[] | null = await BackgroundRefresh.fetchOrNull<NoticeItem>(JwApi.getNotices());

      if (scores === null && notices === null) {
        result.reason = 'timeout';
        BackgroundRefresh.saveError('timeout', '0');
        NotifySnapshot.save(s);
        return result;
      }
      BackgroundRefresh.sessionFailCount = 0;

      const newScoreFp: string[] = scores !== null ? NotifySnapshot.scoreFpOf(scores) : [];
      const newNoticeFp: string[] = notices !== null ? NotifySnapshot.noticeFpOf(notices) : [];

      // 首次运行：只落基线，绝不推送（防止整学期成绩被当成"新增"）
      if (NotifySnapshot.shouldBaseline(s, newScoreFp, newNoticeFp)) {
        s.initialized = true;
        if (scores !== null) {
          s.scoreFp = newScoreFp;
        }
        if (notices !== null) {
          s.noticeFp = newNoticeFp;
        }
        s.lastOkAt = Date.now();
        s.lastError = '';
        NotifySnapshot.save(s);
        result.ok = true;
        result.reason = 'baseline';
        LogStore.log('后台', '刷新', '基线', `成绩${newScoreFp.length} 公告${newNoticeFp.length}`);
        return result;
      }

      const addS: string[] = scores !== null ? NotifySnapshot.added(s.scoreFp, newScoreFp) : [];
      const addN: string[] = notices !== null ? NotifySnapshot.added(s.noticeFp, newNoticeFp) : [];

      if (addS.length > 0 && NotifySettings.score()) {
        const names: string[] = NotifySnapshot.scoreNames(addS);
        const payload: NotifyPayload = {
          id: PushNotifier.ID_BASE_SCORE,
          group: 'score',
          title: T('有 {0} 门成绩公布了', addS.length),
          text: names.join(I18n.listSep()) + (addS.length > names.length ? T(' 等 {0} 项', addS.length) : ''),
          open: 'score'
        };
        await PushNotifier.push(payload);
        result.newScores = addS.length;
      }
      if (addN.length > 0 && NotifySettings.notice()) {
        const titles: string[] = NotifySnapshot.noticeTitles(addN);
        const payload: NotifyPayload = {
          id: PushNotifier.ID_BASE_NOTICE,
          group: 'notice',
          title: T('教务处有新通知'),
          text: titles.join(I18n.listSep()) + (addN.length > titles.length ? T(' 等 {0} 条', addN.length) : ''),
          open: 'notice'
        };
        await PushNotifier.push(payload);
        result.newNotices = addN.length;
      }

      // 考试临近（T-7 / T-3 / T-1，每场每档只提醒一次）
      if (NotifySettings.exam()) {
        const examFp: string[] = await BackgroundRefresh.checkExams(s.examFp);
        s.examFp = examFp;
      }

      if (scores !== null) {
        s.scoreFp = newScoreFp;
      }
      if (notices !== null) {
        s.noticeFp = newNoticeFp;
      }
      s.lastOkAt = Date.now();
      s.lastError = '';
      NotifySnapshot.save(s);
      result.ok = true;
      result.reason = reason;
      LogStore.log('后台', '刷新', '成功', `新增成绩${addS.length} 新增公告${addN.length}`);

      // 续排课前提醒（预算不足则跳过，避免被系统在 2 分钟处截断）
      if (Date.now() - t0 < TOTAL_BUDGET_MS) {
        await NotifyScheduler.rescheduleAll(`bg-${reason}`);
      } else {
        LogStore.log('后台', '续排', '跳过（预算耗尽）', `${Date.now() - t0}ms`);
      }
    } catch (e) {
      result.reason = 'network';
      BackgroundRefresh.saveError('network', '0');
      LogStore.log('后台', '刷新', '异常', LogStore.errorOf(e as Object));
    }
    return result;
  }

  /**
   * 考试临近提醒：读考试缓存，找"距今天 7/3/1 天"的考试，合并成一条通知。
   * @param oldFp 已提醒过的指纹（courseName|date|N天）
   * @returns 新的指纹集合（含本次提醒的）
   */
  private static async checkExams(oldFp: string[]): Promise<string[]> {
    try {
      const raw: string = DataStore.loadJSON(DataStore.KEY_EXAMS);
      if (raw.length === 0) {
        return oldFp;
      }
      const exams: ExamItem[] = JSON.parse(raw) as ExamItem[];
      const now: Date = new Date();
      const today: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate());
      const hitFp: string[] = [];
      const lines: string[] = [];
      for (const e of exams) {
        const d: Date = DateUtil.parse(e.date);
        if (isNaN(d.getTime())) {
          continue;
        }
        const examDay: Date = new Date(d.getFullYear(), d.getMonth(), d.getDate());
        const days: number = Math.round((examDay.getTime() - today.getTime()) / 86400000);
        if (days !== 7 && days !== 3 && days !== 1) {
          continue;
        }
        const fp: string = `${e.courseName}|${e.date}|${days}`;
        if (oldFp.indexOf(fp) >= 0) {
          continue;
        }
        hitFp.push(fp);
        const when: string = days === 1 ? T('明天') : T('{0} 天后', days);
        lines.push(`${when} ${e.courseName}（${e.timeRange}${e.location.length > 0 ? ' · ' + e.location : ''}）`);
      }
      if (lines.length > 0) {
        await PushNotifier.push({
          id: PushNotifier.ID_BASE_EXAM,
          group: 'exam',
          title: T('考试临近提醒'),
          text: lines.slice(0, 3).join(I18n.listSep()) + (lines.length > 3 ? T(' 等 {0} 场', lines.length) : ''),
          open: 'exam'
        });
        LogStore.log('后台', '考试提醒', '已发送', `${lines.length} 场`);
      }
      // 指纹保留最近 30 天内的，避免无限增长
      const keep: string[] = oldFp.filter((fp: string) => {
        const parts: string[] = fp.split('|');
        const d: Date = parts.length > 1 ? DateUtil.parse(parts[1]) : new Date(0);
        return !isNaN(d.getTime()) && (today.getTime() - d.getTime()) < 30 * 86400000;
      });
      return keep.concat(hitFp);
    } catch (e) {
      LogStore.log('后台', '考试提醒', '失败', LogStore.errorOf(e as Object));
      return oldFp;
    }
  }

  /**
   * 取数并加超时：失败/超时返回 null（区分"没拿到"与"确实为空"）。
   * 内部把 Promise 的 rejection 先转成 null，避免 withTimeout 抱到异常。
   */
  private static async fetchOrNull<T>(p: Promise<T[]>): Promise<T[] | null> {
    try {
      const safe: Promise<T[] | null> = p.then((v: T[]) => v).catch(() => null);
      return await SessionRestorer.withTimeout<T[] | null>(safe, STEP_BUDGET_MS, null);
    } catch (e) {
      return null;
    }
  }

  private static saveError(reason: string, code: string): void {
    const s: Snapshot = NotifySnapshot.load();
    s.lastError = `${reason}|${code}|${Date.now()}`;
    NotifySnapshot.save(s);
    DataStore.put(DataStore.KEY_NOTIFY_LAST_ERROR, s.lastError);
  }

  /** 连续 3 次会话失败 → 每天最多提示 1 次"登录已过期" */
  private static async maybeAlertSession(): Promise<void> {
    if (BackgroundRefresh.sessionFailCount < 3) {
      return;
    }
    const today: string = BackgroundRefresh.todayKey();
    if (DataStore.get(DataStore.KEY_NOTIFY_SESSION_DATE) === today) {
      return;
    }
    DataStore.put(DataStore.KEY_NOTIFY_SESSION_DATE, today);
    await PushNotifier.push({
      id: PushNotifier.ID_BASE_SESSION,
      group: 'session',
      title: T('登录已过期'),
      text: T('后台同步已暂停，打开应用重新登录即可恢复'),
      open: 'home'
    });
    LogStore.log('后台', '会话提示', '已发送', today);
  }

  private static todayKey(): string {
    const d: Date = new Date();
    return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
  }
}
