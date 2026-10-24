/**
 * 成绩 / 公告 / 考试 的指纹快照（用于判断"新增"）
 *
 * 为什么不能用 DataStore.KEY_CACHE_TIME：
 *  它是**全局**时间戳，任何一类数据写入都会刷新它，无法代表"成绩上次检查时间"。
 *
 * 为什么成绩指纹要带 scoreText：
 *  ScoreItem.id = kcmc_xnmmc_xqmmc（不含分数），出分时 id 不变，
 *  若只用 id 比对，永远检测不到"新出分"。必须拼上分数文本。
 *
 * 首次运行保护：initialized=false 时只写基线，不推送（否则会把整学期成绩当新增刷屏）。
 */
import { DataStore } from './DataStore';
import { LogStore } from './LogStore';
import { NoticeItem, TermScore } from '../model/Models';

/** 快照结构（JSON 持久化） */
export class Snapshot {
  v: number = 1;
  /** 是否已完成首次基线写入（false = 首次，禁止推送） */
  initialized: boolean = false;
  scoreFp: string[] = [];
  noticeFp: string[] = [];
  examFp: string[] = [];
  lastRunAt: number = 0;
  lastOkAt: number = 0;
  /** "reason|code|ts" */
  lastError: string = '';
}

export class NotifySnapshot {
  static load(): Snapshot {
    const raw: string = DataStore.get(DataStore.KEY_NOTIFY_SNAPSHOT);
    if (raw.length === 0) {
      return new Snapshot();
    }
    try {
      const s: Snapshot = JSON.parse(raw) as Snapshot;
      if (s.scoreFp === undefined) {
        s.scoreFp = [];
      }
      if (s.noticeFp === undefined) {
        s.noticeFp = [];
      }
      if (s.examFp === undefined) {
        s.examFp = [];
      }
      // v1 → v2 迁移：旧版把位置型 id 也计入公告指纹，升级后会误判全部为"新增"
      if (s.v < 2) {
        s.noticeFp = s.noticeFp.filter((fp: string) => fp.indexOf('id:') !== 0);
        s.v = 2;
        LogStore.log('通知', '快照', '迁移到v2', `公告指纹${s.noticeFp.length}条`);
      }
      return s;
    } catch (e) {
      LogStore.log('通知', '快照', '解析失败重置', LogStore.errorOf(e as Object));
      return new Snapshot();
    }
  }

  static save(s: Snapshot): void {
    try {
      DataStore.put(DataStore.KEY_NOTIFY_SNAPSHOT, JSON.stringify(s));
    } catch (e) {
      // 忽略
    }
  }

  /**
   * 成绩指纹：termId|courseName|scoreText
   * 用 courseName 而非 id（学年/学期名变更时 id 会变，造成假新增）
   */
  static scoreFpOf(list: TermScore[]): string[] {
    const out: string[] = [];
    for (const t of list) {
      for (const it of t.items) {
        if (it.scoreText.length === 0) {
          continue; // 未出分不参与比对
        }
        out.push(`${it.termId}|${it.courseName}|${it.scoreText}`);
      }
    }
    return out;
  }

  /**
   * 公告指纹：只用 title|date。
   * 不能用 n.id —— JwApi 生成的 id 是 `n{index}-{date}`（位置型），
   * 插入一条新公告会让后续所有条目位移、指纹全变，导致每轮误报"等 N 条"。
   */
  static noticeFpOf(list: NoticeItem[]): string[] {
    const out: string[] = [];
    for (const n of list) {
      if (n.title.length === 0) {
        continue;
      }
      out.push(`${n.title}|${n.date}`);
    }
    return out;
  }

  /** 新增项（old 中不存在的） */
  static added(oldFp: string[], newFp: string[]): string[] {
    const set: Set<string> = new Set<string>(oldFp);
    const out: string[] = [];
    for (const fp of newFp) {
      if (!set.has(fp)) {
        out.push(fp);
      }
    }
    return out;
  }

  /** 从成绩指纹还原可读的课程名（用于通知文案） */
  static scoreNames(fps: string[], max: number = 5): string[] {
    const out: string[] = [];
    for (let i: number = 0; i < fps.length && out.length < max; i++) {
      const parts: string[] = fps[i].split('|');
      if (parts.length >= 2 && parts[1].length > 0) {
        out.push(parts[1]);
      }
    }
    return out;
  }

  /** 从公告指纹还原标题 */
  static noticeTitles(fps: string[], max: number = 5): string[] {
    const out: string[] = [];
    for (let i: number = 0; i < fps.length && out.length < max; i++) {
      if (fps[i].startsWith('id:')) {
        continue;
      }
      const parts: string[] = fps[i].split('|');
      if (parts[0].length > 0) {
        out.push(parts[0]);
      }
    }
    return out;
  }

  /**
   * 是否应视为"基线首次"。
   * 注意：不能用 scoreFp.length===0 反推 —— 新生/未出分用户 scoreFp 恒为空，
   * 会让每一轮都被当成首次基线，公告通知永远发不出去。
   */
  static shouldBaseline(s: Snapshot, newScoreFp: string[], newNoticeFp: string[]): boolean {
    if (!s.initialized) {
      return true;
    }
    // 快照被整体清空（清缓存/换账号）后的重建：避免把存量当新增
    const oldEmpty: boolean = s.scoreFp.length === 0 && s.noticeFp.length === 0;
    return oldEmpty && (newScoreFp.length > 0 || newNoticeFp.length > 0);
  }
}
