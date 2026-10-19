/**
 * 云课堂（智教云 TeachingCenterStudentWeb）数据模型
 * 依据抓包记录《云课堂接入抓包记录.md》的响应字段映射。
 */

/** 云课堂会话（登录后持久化） */
export interface CloudSession {
  /** 云课堂 userId（ff8081...） */
  userId: string;
  /** 服务端下发的 sessionId（DES 密文，96 hex） */
  sessionId: string;
  /** DES 解密后的 x-Token（UUID） */
  xToken: string;
  /** 登录时间戳（用于 2h ClientToken 过期判断） */
  loginAt: number;
  /** 用户姓名 */
  userName: string;
  /** 学号 */
  userNo: string;
}

/** 云课堂学期 */
export interface CloudTerm {
  id: string;        // 如 "2026-2027-1"
  schoolYear: string; // 如 "2026-2027"
  term: string;       // 如 "1"
  startDate: string;
  endDate: string;
  description: string;
}

/** 云课堂教学班 */
export interface CloudClass {
  classId: string;
  className: string;
  classType: string;
  classMembers: number;
}

/** 云课堂课程（我的课程） */
export interface CloudCourse {
  courseId: string;
  courseCode: string;
  courseName: string;
  collegeName: string;
  teacherId: string;
  teacherName: string;
  courseCategory: string;
  teachingClasses: CloudClass[];
  schoolYear: string;
  term: string;
}

/** 课堂实录课程汇总（有录播的课程） */
export interface RecordCourse {
  courseId: string;
  courseName: string;
  classIds: string;
  classNames: string;
  weeks: string[];
  maxUpdateDate: string;
  coverUrl: string;
  teacherNames: string;
}

/** 课堂实录视频条目 */
export interface RecordVideo {
  id: string;
  videoInfoName: string;
  week: string;
  teacherNames: string;
  className: string;
  courseId: string;
  courseName: string;
  thumbnailUrl: string;
  startTime: string;
  endTime: string;
  classroomName: string;
  weekDay: string;
  segment: number;
  playUrl: string;   // 播放地址（详情接口返回后填充）
}

/** 课堂实录视频详情（含三路画面 MP4） */
export interface RecordVideoDetail {
  id: string;
  videoInfoName: string;
  courseName: string;
  teacherNames: string;
  startTime: string;
  endTime: string;
  classroomName: string;
  playUrls: string[];   // 教师/学生/VGA 三路 MP4
  pptUrls: string[];
}

/** 云课堂通知 */
export interface CloudNotice {
  notificationType: number;
  content: string;
  notificationDate: string;
  schoolYear: string;
  term: string;
  courseId: string;
}

/** 云课堂分页结果 */
export interface CloudPage<T> {
  page: number;
  pageSize: number;
  pageCount: number;
  total: number;
  list: T[];
}
