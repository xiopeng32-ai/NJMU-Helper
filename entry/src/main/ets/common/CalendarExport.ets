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
import { CourseItem, TermInfo } from '../model/Models';
import { Const } from './Constants';
import { DateUtil } from './DateUtil';
import { LogStore } from './LogStore';

const CALENDAR_PERMISSIONS: Permissions[] = [
  'ohos.permission.READ_CALENDAR',
  'ohos.permission.WRITE_CALENDAR'
];

export class CalendarExport {
  /** 某周某日某节次的毫秒时间戳（end=true 取节次结束时间） */
  private static eventTime(term: TermInfo, week: number, weekday: number, section: number, end: boolean): number {
    const day: Date = DateUtil.dateOfWeekDay(term, week, weekday);
    const idx: number = Math.max(1, Math.min(Const.SECTION_COUNT, section)) - 1;
    const hhmm: string = end ? Const.SECTIONS[idx].end : Const.SECTIONS[idx].start;
    const parts: string[] = hhmm.split(':');
    return new Date(day.getFullYear(), day.getMonth(), day.getDate(),
      Number.parseInt(parts[0], 10), Number.parseInt(parts[1], 10), 0, 0).getTime();
  }

  /**
   * 导出整学期课表到系统日历（含运行时权限申请）。
   * @returns 成功写入的事件条数；权限未授予时抛异常（由调用方提示）
   */
  static async exportSchedule(context: common.UIAbilityContext, term: TermInfo,
    courses: CourseItem[]): Promise<number> {
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
        events.push(event);
      }
    }
    if (events.length > 0) {
      await calendar.addEvents(events);
    }
    LogStore.log('课表', '导出日历', '完成', `${courses.length}门课 写入${events.length}条事件`);
    return events.length;
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
