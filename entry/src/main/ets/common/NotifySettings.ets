/**
 * 通知与提醒设置（唯一读写入口）
 *
 * 约定：
 *  - 存 '1' / '0'，缺省时用 defaultOn 兜底（避免历史用户第一次进来全关）；
 *  - 总开关默认关（首次由用户主动开启，开启时才申请通知权限）；
 *  - 所有键均已加入 DataStore.BACKUP_KEYS（换机恢复不丢设置），
 *    唯独快照键 notify_snapshot 不参与备份（指纹是设备本地的，跨设备恢复会造成假新增）。
 */
import { DataStore } from './DataStore';
import { T } from './I18n';

export class NotifySettings {
  /** 提前提醒分钟数候选 */
  static readonly LEAD_OPTIONS: number[] = [10, 15, 30, 60];
  /** 实况窗收起延迟候选（分钟） */
  static readonly GRACE_OPTIONS: number[] = [5, 10, 15];
  /** 滚动窗口天数候选 */
  static readonly HORIZON_OPTIONS: number[] = [1, 3, 7];

  private static on(key: string, defaultOn: boolean): boolean {
    const v: string = DataStore.get(key);
    if (v.length === 0) {
      return defaultOn;
    }
    return v === '1';
  }

  private static setOn(key: string, on: boolean): void {
    DataStore.put(key, on ? '1' : '0');
  }

  private static num(key: string, def: number, allow: number[]): number {
    const raw: string = DataStore.get(key);
    const n: number = Number.parseInt(raw, 10);
    if (isNaN(n) || allow.indexOf(n) < 0) {
      return def;
    }
    return n;
  }

  // ── 开关 ──

  /** 总开关（默认关：用户主动开启后才申请通知权限并排程） */
  static master(): boolean {
    return NotifySettings.on(DataStore.KEY_NOTIFY_MASTER, false);
  }

  static setMaster(on: boolean): void {
    NotifySettings.setOn(DataStore.KEY_NOTIFY_MASTER, on);
  }

  /** 课前提醒（代理提醒） */
  static classReminder(): boolean {
    return NotifySettings.on(DataStore.KEY_NOTIFY_CLASS, true);
  }

  static setClassReminder(on: boolean): void {
    NotifySettings.setOn(DataStore.KEY_NOTIFY_CLASS, on);
  }

  /** 实况窗 */
  static liveView(): boolean {
    return NotifySettings.on(DataStore.KEY_NOTIFY_LIVE, true);
  }

  static setLiveView(on: boolean): void {
    NotifySettings.setOn(DataStore.KEY_NOTIFY_LIVE, on);
  }

  /** 新成绩通知 */
  static score(): boolean {
    return NotifySettings.on(DataStore.KEY_NOTIFY_SCORE, true);
  }

  static setScore(on: boolean): void {
    NotifySettings.setOn(DataStore.KEY_NOTIFY_SCORE, on);
  }

  /** 教务公告通知 */
  static notice(): boolean {
    return NotifySettings.on(DataStore.KEY_NOTIFY_NOTICE, true);
  }

  static setNotice(on: boolean): void {
    NotifySettings.setOn(DataStore.KEY_NOTIFY_NOTICE, on);
  }

  /** 考试临近提醒 */
  static exam(): boolean {
    return NotifySettings.on(DataStore.KEY_NOTIFY_EXAM, true);
  }

  static setExam(on: boolean): void {
    NotifySettings.setOn(DataStore.KEY_NOTIFY_EXAM, on);
  }

  /** 后台自动刷新 */
  static bgRefresh(): boolean {
    return NotifySettings.on(DataStore.KEY_NOTIFY_BG, true);
  }

  static setBgRefresh(on: boolean): void {
    NotifySettings.setOn(DataStore.KEY_NOTIFY_BG, on);
  }

  // ── 参数 ──

  /** 课前提前分钟（默认 30） */
  static leadMinutes(): number {
    return NotifySettings.num(DataStore.KEY_NOTIFY_LEAD, 30, NotifySettings.LEAD_OPTIONS);
  }

  static setLeadMinutes(v: number): void {
    DataStore.put(DataStore.KEY_NOTIFY_LEAD, `${v}`);
  }

  /** 实况窗上课后收起延迟（默认 10 分钟） */
  static liveViewGrace(): number {
    return NotifySettings.num(DataStore.KEY_NOTIFY_GRACE, 10, NotifySettings.GRACE_OPTIONS);
  }

  static setLiveViewGrace(v: number): void {
    DataStore.put(DataStore.KEY_NOTIFY_GRACE, `${v}`);
  }

  /** 滚动窗口天数（默认 3） */
  static horizonDays(): number {
    return NotifySettings.num(DataStore.KEY_NOTIFY_HORIZON, 3, NotifySettings.HORIZON_OPTIONS);
  }

  static setHorizonDays(v: number): void {
    DataStore.put(DataStore.KEY_NOTIFY_HORIZON, `${v}`);
  }

  /** 是否有任一"需要排程"的能力开启（总开关 + 至少一项） */
  static anyActive(): boolean {
    if (!NotifySettings.master()) {
      return false;
    }
    return NotifySettings.classReminder() || NotifySettings.liveView() || NotifySettings.bgRefresh()
      || NotifySettings.score() || NotifySettings.notice() || NotifySettings.exam();
  }

  /** 设置页顶部的状态摘要 */
  static summary(): string {
    if (!NotifySettings.master()) {
      return T('未开启');
    }
    let n: number = 0;
    if (NotifySettings.classReminder()) {
      n++;
    }
    if (NotifySettings.liveView()) {
      n++;
    }
    if (NotifySettings.score()) {
      n++;
    }
    if (NotifySettings.notice()) {
      n++;
    }
    if (NotifySettings.exam()) {
      n++;
    }
    if (NotifySettings.bgRefresh()) {
      n++;
    }
    return n > 0 ? `已开启 ${n} 项` : '已开启（未选具体项）';
  }
}
