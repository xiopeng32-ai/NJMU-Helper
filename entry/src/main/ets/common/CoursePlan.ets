/**
 * 课程时间展开（唯一时间换算点）
 *
 * 为什么必须集中在这里：
 *  项目里存在三套作息表 —— `SectionUtil.list(cfg)`（尊重用户自定义，**唯一正确来源**）、
 *  `DateUtil.sectionRange`（硬编码 Const.SECTIONS，忽略自定义）、
 *  `EntryFormAbility.SECTION_TIMES`（10 节旧作息，第 3 节算 12:10，完全错）。
 *  提醒与实况窗绝不能走后两者，否则用户改过作息后提醒时间会错。
 *
 * 职责：把 `CourseItem`（weekday + 节次 + 周次）展开为"某一天的具体分钟区间"。
 */
import { CourseItem, TermInfo } from '../model/Models';
import { Occurrence } from '../model/NotifyModels';
import { Const, SectionTime } from './Constants';
import { DateUtil } from './DateUtil';
import { ScheduleConfig } from './ScheduleConfig';
import { SectionUtil } from './SectionUtil';

/** 一天 1440 分钟 */
const DAY_MIN: number = 1440;

export class CoursePlan {
  /**
   * 展开未来 `days` 天内的所有上课实例。
   *
   * @param courses 课表
   * @param term 当前学期（用于周次换算）
   * @param cfg 作息配置（务必传 ScheduleConfig.load()）
   * @param from 起点（一般传 new Date()）
   * @param days 天数窗口（1~7）
   * @param leadMin 提前提醒分钟（用于算 remindMin）
   */
  static expand(courses: CourseItem[], term: TermInfo, cfg: ScheduleConfig,
    from: Date, days: number, leadMin: number): Occurrence[] {
    const sections: SectionTime[] = SectionUtil.list(cfg);
    const out: Occurrence[] = [];
    const base: Date = DateUtil.startOfDay(from);
    for (let d: number = 0; d < days; d++) {
      const day: Date = DateUtil.addDays(base, d);
      const weekday: number = DateUtil.weekdayOf(day);
      const week: number = DateUtil.weekOfTerm(term, day);
      if (week < 1) {
        continue; // 未开学
      }
      const dateStr: string = DateUtil.format(day);
      for (const c of courses) {
        if (c.noSchedule || c.weekday !== weekday || c.weeks.indexOf(week) < 0) {
          continue;
        }
        const sIdx: number = Math.max(1, Math.min(sections.length, c.startSection));
        const eIdx: number = Math.max(sIdx, Math.min(sections.length, c.endSection));
        const st: SectionTime = sections[sIdx - 1];
        const et: SectionTime = sections[eIdx - 1];
        const startMin: number = DateUtil.minutesOf(st.start);
        const endMin: number = DateUtil.minutesOf(et.end);
        if (startMin < 0 || endMin <= startMin) {
          continue; // 脏数据保护
        }
        out.push({
          // key 是通知 id / 实况窗 id 的唯一来源：必须含实际开始分钟与提前量，
          // 否则改作息或改提前分钟后 id 不变 → ReminderGateway 认为"已存在"而跳过更新
          key: `${term.id}|${dateStr}|${c.startSection}|${startMin}|${c.name}|L${leadMin}`,
          date: dateStr,
          weekday: weekday,
          startMin: startMin,
          endMin: endMin,
          startSection: sIdx,
          endSection: eIdx,
          name: c.name,
          location: c.location,
          teacher: c.teacher,
          startText: st.start,
          endText: et.end,
          remindMin: startMin - leadMin
        });
      }
    }
    out.sort((a: Occurrence, b: Occurrence) => {
      const ka: number = CoursePlan.dayIndex(a.date) * DAY_MIN + a.startMin;
      const kb: number = CoursePlan.dayIndex(b.date) * DAY_MIN + b.startMin;
      return ka - kb;
    });
    return out;
  }

  /** 日期字符串 → 粗粒度序号（仅用于排序，不含月份天数精度） */
  private static dayIndex(dateStr: string): number {
    const d: Date = DateUtil.parse(dateStr);
    return Math.floor(d.getTime() / 86400000);
  }

  /** 当前时刻所在/即将开始的第一节（用于实况窗判定），找不到返回 null */
  static currentOrNext(list: Occurrence[], now: Date, leadMin: number): Occurrence | null {
    const today: string = DateUtil.format(now);
    const nowMin: number = DateUtil.minutesOfNow();
    for (const o of list) {
      if (o.date !== today) {
        continue;
      }
      if (nowMin < o.startMin + leadMin && nowMin < o.endMin) {
        return o;
      }
    }
    return null;
  }

  /** 当日分钟数（0:00 起） */
  static minOf(d: Date): number {
    return d.getHours() * 60 + d.getMinutes();
  }

  /** 某分钟的 HH:mm 文本 */
  static textOf(min: number): string {
    const m: number = ((min % DAY_MIN) + DAY_MIN) % DAY_MIN;
    const h: number = Math.floor(m / 60);
    const mm: number = m % 60;
    return `${DateUtil.pad(h)}:${DateUtil.pad(mm)}`;
  }

  /** 把 occurrence 的分钟换算成 Date（支持负数/超 1440 的跨日分钟） */
  static dateAt(o: Occurrence, min: number): Date {
    const d: Date = DateUtil.parse(o.date);
    const dayShift: number = Math.floor(min / 1440);
    const m: number = ((min % 1440) + 1440) % 1440;
    return new Date(d.getFullYear(), d.getMonth(), d.getDate() + dayShift,
      Math.floor(m / 60), m % 60, 0, 0);
  }

  /** 稳定数字 id（供代理提醒 notificationId / 实况窗 id 共用） */
  static stableId(key: string): number {
    let h: number = 0;
    for (let i: number = 0; i < key.length; i++) {
      h = (h * 31 + key.charCodeAt(i)) & 0x7fffffff;
    }
    // 收敛到 10000~999999，避免与系统/其他模块 id 段冲突
    return 10000 + (h % 990000);
  }

  /** 与 Const 的节次文案（"第1-2节"） */
  static sectionText(o: Occurrence): string {
    if (o.startSection === o.endSection) {
      return `第${o.startSection}节`;
    }
    return `第${o.startSection}-${o.endSection}节`;
  }
}
