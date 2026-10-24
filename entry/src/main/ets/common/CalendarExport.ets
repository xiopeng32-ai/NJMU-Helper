/**
 * CalendarExport — 课程表导出到系统日历
 *
 * 使用 calendarManager（@kit.CalendarKit）把当前学期课表逐次写入系统日历：
 *  - 每门课 × 每个上课周 = 一条事件（不做 weekly 递归，周次跳课/单双周最准确）
 *  - 时间 = DateUtil.dateOfWeekDay(周次, 星期) + 节次时间表（Const.SECTIONS）
 *  - 地点 = 教室，描述 = 教师 · 学期 · 周次
 *  - 首次调用时运行时申请日历读写权限（弹授权框）
 *
 * 追加前不清空（避免误删用户自建日程）；重复导出会产生重复事件，
 * 由调用方在确认弹窗里提示。
 */
import { abilityAccessCtrl, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { calendarManager } from '@kit.CalendarKit';
import { CourseItem, ExamItem, TermInfo } from '../model/Models';
import { DateUtil } from './DateUtil';
import { SectionUtil } from './SectionUtil';
import { LogStore } from './LogStore';

const CALENDAR_PERMISSIONS: Permissions[] = [
  'ohos.permission.READ_CALENDAR',
  'ohos.permission.WRITE_CALENDAR'
];

export class CalendarExport {
  /** 某周某日某节次的毫秒时间戳（end=true 取节次结束时间） */
  private static eventTime(term: TermInfo, week: number, weekday: number, section: number, end: boolean): number {
    const day: Date = DateUtil.dateOfWeekDay(term, week, weekday);
    // 必须走当前生效作息：用户改过课表时间后，导出的日程要跟着变
    const min: number = end ? SectionUtil.endMinCurrent(section) : SectionUtil.startMinCurrent(section);
    return new Date(day.getFullYear(), day.getMonth(), day.getDate(),
      Math.floor(min / 60), min % 60, 0, 0).getTime();
  }

  /**
   * 导出整学期课表到系统日历（含运行时权限申请）。
   * @param reminderMinutes 课前提醒提前量（分钟）。空数组 = 不提醒；可多项，如 [10, 30]
   * @returns 成功写入的事件条数；权限未授予时抛异常（由调用方提示）
   */
  static async exportSchedule(context: common.UIAbilityContext, term: TermInfo,
    courses: CourseItem[], reminderMinutes: number[] = []): Promise<number> {
    // 1) 运行时申请日历读写权限（首次会弹系统授权框）
    const granted: boolean = await CalendarExport.ensurePermission(context);
    if (!granted) {
      throw new Error('未授予日历权限');
    }
    // 2) 构造事件并批量写入
    const calMgr: calendarManager.CalendarManager = calendarManager.getCalendarManager(context);
    const calendar: calendarManager.Calendar = await calMgr.getCalendar();
    const events: calendarManager.Event[] = [];
    for (const c of courses) {
      // 无固定时间/地点的实践课、公共选修无法落到具体时段，跳过
      if (c.noSchedule || c.weeks.length === 0) {
        continue;
      }
      for (const w of c.weeks) {
        if (w < 1 || w > term.totalWeeks) {
          continue;
        }
        const startMs: number = CalendarExport.eventTime(term, w, c.weekday, c.startSection, false);
        let endMs: number = CalendarExport.eventTime(term, w, c.weekday, c.endSection, true);
        if (endMs <= startMs) {
          endMs = startMs + 45 * 60 * 1000; // 兜底：单节 45 分钟
        }
        const event: calendarManager.Event = {
          title: c.name,
          type: calendarManager.EventType.NORMAL,
          startTime: startMs,
          endTime: endMs,
          isLunar: false,
          description: `${c.teacher.length > 0 ? c.teacher + ' · ' : ''}${term.label} 第${w}周`,
          location: c.location.length > 0 ? { location: c.location } : undefined
        };
        // 课前提醒（reminderTime 为"提前分钟数"数组，系统日历到点弹通知）
        if (reminderMinutes.length > 0) {
          event.reminderTime = reminderMinutes;
        }
        events.push(event);
      }
    }
    if (events.length > 0) {
      await calendar.addEvents(events);
    }
    LogStore.log('课表', '导出日历', '完成',
      `${courses.length}门课 写入${events.length}条事件 提醒=${reminderMinutes.length > 0 ? reminderMinutes.join('/') + '分钟前' : '无'}`);
    return events.length;
  }

  /**
   * 把考试安排写入系统日历（含提醒）。
   *
   * @param reminderMinutes 提前提醒分钟数，默认 [1440, 60]（提前 1 天 + 提前 1 小时）
   * @returns 成功写入的事件条数
   */
  static async exportExams(context: common.UIAbilityContext, exams: ExamItem[],
    reminderMinutes: number[] = [1440, 60]): Promise<number> {
    const granted: boolean = await CalendarExport.ensurePermission(context);
    if (!granted) {
      throw new Error('未授予日历权限');
    }
    const calMgr: calendarManager.CalendarManager = calendarManager.getCalendarManager(context);
    const calendar: calendarManager.Calendar = await calMgr.getCalendar();
    const events: calendarManager.Event[] = [];
    for (const e of exams) {
      const startMs: number = CalendarExport.examTime(e, false);
      if (startMs <= 0) {
        continue; // 日期/时间解析失败跳过
      }
      let endMs: number = CalendarExport.examTime(e, true);
      if (endMs <= startMs) {
        endMs = startMs + 120 * 60 * 1000; // 兜底 2 小时
      }
      const desc: string[] = [];
      if (e.examType.length > 0) {
        desc.push(e.examType);
      }
      if (e.seat.length > 0 && e.seat !== '待定') {
        desc.push(`座位 ${e.seat}`);
      }
      if (e.teacher.length > 0) {
        desc.push(e.teacher);
      }
      desc.push('来自南医助手');
      const event: calendarManager.Event = {
        title: `${e.courseName} 考试`,
        type: calendarManager.EventType.NORMAL,
        startTime: startMs,
        endTime: endMs,
        isLunar: false,
        description: desc.join(' · '),
        location: e.location.length > 0 && e.location !== '待定'
          ? { location: e.location }
          : undefined
      };
      if (reminderMinutes.length > 0) {
        event.reminderTime = reminderMinutes;
      }
      events.push(event);
    }
    if (events.length > 0) {
      await calendar.addEvents(events);
    }
    LogStore.log('考试', '导出日历', '完成',
      `${exams.length}场 写入${events.length}条 提醒=${reminderMinutes.length > 0 ? reminderMinutes.join('/') + '分钟前' : '无'}`);
    return events.length;
  }

  /** 考试日期 + 时间段（"14:00-16:00"）→ 毫秒时间戳；end=true 取结束时刻，解析失败返回 -1 */
  private static examTime(e: ExamItem, end: boolean): number {
    const day: Date = DateUtil.parse(e.date);
    if (isNaN(day.getTime())) {
      return -1;
    }
    let hh: number = 9;
    let mm: number = 0;
    if (e.timeRange.length > 0) {
      const parts: string[] = e.timeRange.split('-');
      const seg: string = (end && parts.length > 1 ? parts[1] : parts[0]).trim();
      const hm: string[] = seg.split(':');
      const h: number = Number.parseInt(hm[0], 10);
      const m: number = hm.length > 1 ? Number.parseInt(hm[1], 10) : 0;
      if (!isNaN(h)) {
        hh = h;
      }
      if (!isNaN(m)) {
        mm = m;
      }
    } else if (end) {
      hh = 11;
    }
    return new Date(day.getFullYear(), day.getMonth(), day.getDate(), hh, mm, 0, 0).getTime();
  }

  /** 申请日历读写权限，全部授权返回 true */
  private static async ensurePermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const result: PermissionRequestResult = await atManager.requestPermissionsFromUser(context, CALENDAR_PERMISSIONS);
      for (const code of result.authResults) {
        if (code !== 0) {
          return false;
        }
      }
      return true;
    } catch (err) {
      LogStore.log('课表', '导出日历', '权限申请失败', String(err));
      return false;
    }
  }
}
