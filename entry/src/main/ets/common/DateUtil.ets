/**
 * 日期 / 周次工具
 * 教务类应用的核心是"学期第几周 + 星期几 + 第几节"，这里统一处理。
 */
import { Const } from './Constants';
import { TermInfo } from '../model/Models';
import { I18n, T } from './I18n';

const DAY_MS: number = 24 * 60 * 60 * 1000;

export class DateUtil {
  /** 数字补零（1 -> 01） */
  static pad(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  /** Date -> yyyy-MM-dd */
  static format(date: Date): string {
    return `${date.getFullYear()}-${DateUtil.pad(date.getMonth() + 1)}-${DateUtil.pad(date.getDate())}`;
  }

  /** Date -> 中文「10月24日」/ 英文「Oct 24」（列表、卡片、导出图片统一走这里） */
  static formatCn(date: Date): string {
    return I18n.monthDay(date);
  }

  /** yyyy-MM-dd -> Date（按本地 0 点） */
  static parse(text: string): Date {
    const parts: string[] = text.split('-');
    const y: number = Number.parseInt(parts[0], 10);
    const m: number = Number.parseInt(parts[1], 10);
    const d: number = Number.parseInt(parts[2], 10);
    return new Date(y, m - 1, d);
  }

  /** 取当天 0 点 */
  static startOfDay(date: Date): Date {
    return new Date(date.getFullYear(), date.getMonth(), date.getDate());
  }

  /** 相差天数（b - a） */
  static diffDays(a: Date, b: Date): number {
    const ms: number = DateUtil.startOfDay(b).getTime() - DateUtil.startOfDay(a).getTime();
    return Math.round(ms / DAY_MS);
  }

  /** 日期加 N 天（负数即往前推） */
  static addDays(date: Date, days: number): Date {
    return new Date(date.getTime() + days * DAY_MS);
  }

  /** 星期几：1=周一 ... 7=周日 */
  static weekdayOf(date: Date): number {
    const w: number = date.getDay();
    return w === 0 ? 7 : w;
  }


  /**
   * 构造"当前学期"。
   * 按真实开学日计算：第一学期 9-01、第二学期次年 3-01，
   * 与教务系统学期（正方 xnm/xqm）一致，保证课表周次正确。
   */
  /** 按当前系统日期构造学期（9月后为第一学期） */
  static buildCurrentTerm(): TermInfo {
    const now: Date = new Date();
    const year: number = now.getFullYear();
    const month: number = now.getMonth() + 1;
    let firstTerm: boolean = month >= 9;
    let beginYear: number = firstTerm ? year : year - 1;
    const id: string = `${beginYear}-${beginYear + 1}-${firstTerm ? 1 : 2}`;
    const label: string = `${beginYear}-${beginYear + 1}学年 ${firstTerm ? '第一学期' : '第二学期'}`;
    return {
      id: id,
      label: label,
      // 统一走 defaultTermStart（含各学年特例），避免与自定义/列表基线出现 9-07 与 9-01 两个来源
      startDate: DateUtil.defaultTermStart(id),
      totalWeeks: 19
    };
  }


  /** 当前学年第一学期（按当前日期判断学年，非盲目取最新） */
  /**
   * 上一学年第一学期（1~2 月寒假期间仍在第一学期，buildCurrentTerm 会算成第二学期）。
   * 与 buildLatestTerm 同构，仅 beginYear 固定为 year-1。
   */
  static buildPrevFirstTerm(now: Date): TermInfo {
    const beginYear: number = now.getFullYear() - 1;
    return {
      id: `${beginYear}-${beginYear + 1}-1`,
      label: `${beginYear}-${beginYear + 1}学年 第一学期`,
      startDate: DateUtil.defaultTermStart(`${beginYear}-${beginYear + 1}-1`),
      totalWeeks: 19
    } as TermInfo;
  }

  static buildLatestTerm(): TermInfo {
    const now: Date = new Date();
    const year: number = now.getFullYear();
    const month: number = now.getMonth() + 1;
    // 9月及之后：本学年刚开始（如 2026-09 → 2026-2027学年）
    // 9月之前：上学年仍在进行（如 2026-03 → 2025-2026学年）
    const beginYear: number = month >= 9 ? year : year - 1;
    const label: string = `${beginYear}-${beginYear + 1}学年 第一学期`;
    const id: string = `${beginYear}-${beginYear + 1}-1`;
    return {
      id: id,
      label: label,
      // 统一走 defaultTermStart（含各学年特例，如 2026-2027 第一学期实为 9-07），
      // 避免与「跟随教务系统」基线/自定义开学日出现 9-07 与 9-01 两个来源
      startDate: DateUtil.defaultTermStart(id),
      totalWeeks: 19
    };
  }

  /** 学期 id（如 2025-2026-1）-> 默认开学日（第一学期 9-01、第二学期次年 3-01） */
  static defaultTermStart(termId: string): string {
    const parts: string[] = termId.split('-');
    const s: string = parts[parts.length - 1];
    const y: number = Number.parseInt(parts[0], 10);
    // 2026-2027 学年第一学期实际开学日（上课日）为 2026-09-07（官方校历：9月5日报到注册，9月7日上课）。
    // 之前误写 8-31，导致课表周次与校历差一周，已按官方校历 xlsx 纠正。
    if (y === 2026 && s === '1') {
      return '2026-09-07';
    }
    return s === '2' ? `${y + 1}-03-01` : `${y}-09-01`;
  }

  /** 根据学期算出某天是第几周（1 起，未开学返回 0）
   * 以"含 startDate 的那个自然周（Mon-Sun）为第 1 周"为基准，
   * 即使 startDate 不是周一也能正确对应。
   */
  /** 计算某天在学期中的第几周（1 起，未开学返回 0） */
  static weekOfTerm(term: TermInfo, date: Date): number {
    const start: Date = DateUtil.parse(term.startDate);
    const startWeekday: number = DateUtil.weekdayOf(start); // 1=周一 ... 7=周日
    const monday: Date = DateUtil.addDays(start, 1 - startWeekday);
    const days: number = DateUtil.diffDays(monday, date);
    if (days < 0) {
      return 0;
    }
    return Math.floor(days / 7) + 1;
  }

  /** 第 n 周周几的日期（按周一为一周首日的自然周计算，
   * 即使学期 startDate 不是周一也能正确对应）。
   */
  /** 计算第 N 周星期几对应的日期（周一为一周首日） */
  static dateOfWeekDay(term: TermInfo, week: number, weekday: number): Date {
    const start: Date = DateUtil.parse(term.startDate);
    const w0: number = DateUtil.weekdayOf(start); // 1=周一 ... 7=周日
    // 把 startDate 拉回到它所在周的周一，再按周次/星期推算
    const monday: Date = DateUtil.addDays(start, 1 - w0);
    return DateUtil.addDays(monday, (week - 1) * 7 + (weekday - 1));
  }

  /** 拼接节次时间：1-2 节 -> 10:00-11:40 */
  /** @deprecated 硬编码 Const.SECTIONS，忽略用户自定义作息；请用 SectionUtil.rangeTextCurrent */
  static sectionRange(startSection: number, endSection: number): string {
    const s: number = Math.max(1, Math.min(Const.SECTION_COUNT, startSection));
    const e: number = Math.max(1, Math.min(Const.SECTION_COUNT, endSection));
    return `${Const.SECTIONS[s - 1].start}-${Const.SECTIONS[e - 1].end}`;
  }

  /** 某节次的开始分钟数（越界夹取，避免课表存在第16-17节等非常规节次时索引 undefined 崩溃） */
  /** @deprecated 硬编码作息；请用 SectionUtil.startMinCurrent */
  static sectionStartMin(section: number): number {
    const i: number = Math.max(1, Math.min(Const.SECTION_COUNT, Math.floor(section)));
    return DateUtil.minutesOf(Const.SECTIONS[i - 1].start);
  }

  /** 某节次的结束分钟数（越界夹取） */
  /** @deprecated 硬编码作息；请用 SectionUtil.endMinCurrent */
  static sectionEndMin(section: number): number {
    const i: number = Math.max(1, Math.min(Const.SECTION_COUNT, Math.floor(section)));
    return DateUtil.minutesOf(Const.SECTIONS[i - 1].end);
  }

  /** 当前时间的分钟数 */
  static minutesOfNow(): number {
    const now: Date = new Date();
    return now.getHours() * 60 + now.getMinutes();
  }

  /** HH:mm -> 分钟数 */
  static minutesOf(hhmm: string): number {
    const parts: string[] = hhmm.split(':');
    return Number.parseInt(parts[0], 10) * 60 + Number.parseInt(parts[1], 10);
  }

  /** 友好的相对天数描述 */
  static relativeDay(target: Date): string {
    const d: number = DateUtil.diffDays(new Date(), target);
    if (d === 0) {
      return T('今天');
    }
    if (d === 1) {
      return T('明天');
    }
    if (d === 2) {
      return T('后天');
    }
    if (d < 0) {
      return T('{0}天前', -d);
    }
    return T('{0}天后', d);
  }
}
