/**
 * 通知与提醒相关纯类型（不依赖任何平台 API，便于复用与单测）
 */

/** 一条待发送的系统通知 */
export interface NotifyPayload {
  /** 通知 id（同一 group 下唯一，用于去重与撤销） */
  id: number;
  /** 通知分组（score / notice / exam / session / class） */
  group: string;
  title: string;
  text: string;
  /** 点击后打开的目标页面标记（score / notice / schedule / home） */
  open: string;
  /** 是否常驻（实况窗降级时使用） */
  ongoing?: boolean;
  /** 自动消失时间戳（0 = 不设置） */
  autoDeletedTime?: number;
}

/** 后台刷新结果 */
export interface RefreshResult {
  ok: boolean;
  /** ok / session / timeout / network / baseline / disabled */
  reason: string;
  newScores: number;
  newNotices: number;
}

/** 一节课在具体日期上的实例（带分钟，供提醒与实况窗使用） */
export interface Occurrence {
  /** 稳定标识：termId|date|startSection|courseName */
  key: string;
  /** yyyy-MM-dd */
  date: string;
  /** 1=周一 … 7=周日 */
  weekday: number;
  /** 当日分钟数（0:00 起） */
  startMin: number;
  endMin: number;
  startSection: number;
  endSection: number;
  name: string;
  location: string;
  teacher: string;
  /** HH:mm */
  startText: string;
  endText: string;
  /** 提醒触发时刻（startMin - leadMin），可早于当日 0 点 */
  remindMin: number;
}
