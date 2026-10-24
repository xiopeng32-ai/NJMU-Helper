/**
 * 教务数据接口层（唯一的数据出口）
 *
 * ── 后续接入真实教务系统时，只需要改这个文件 ──
 * 1. 把 USE_MOCK 置为 false；
 * 2. 把 HttpClient.baseUrl 改成学校教务系统地址；
 * 3. 在每个方法的"真实分支"里已是"请求 + JSON 解析 -> 模型"逻辑（基于已探测的正方字段映射）。
 * UI 层完全不感知数据来自 mock 还是真实网络。
 *
 * 已验证的正方字段映射（zftal-ui v5 / 南医大 jwpt.njmu.edu.cn）：
 *  - 课表  POST /jwglxt/kbcx/xskbcx_cxXsgrkb.html {xnm,xqm} -> { xsxx, kbList[] }
 *           kbList: kcmc=课程, xm=教师, cdmc=教室, xqj=星期(1-7), jcs="1-2"节次, zcd="1-5周,8-14周"周次
 *  - 成绩  POST /jwglxt/cjcx/cjcx_cxDgXscj.html {doType:query,xnm,xqm,queryModel.showCount:100} -> { items[] }
 *           items: kcmc, cj=分数, jd=绩点, xf=学分, kcxzmc=属性, ksxz=考试性质(重修/正常)
 *  - 考试  POST /jwglxt/kwgl/kscx_cxXsksxxIndex.html {doType:query,xnm,xqm} -> { items[] }
 *           items: ksmc=考试名, kssj=时间, cdbh=考场, zwh=座位, ksfs=方式
 *  - 学生信息含在课表 xsxx 中（XM/BJMC/ZYMC/NJDM_ID...），正方不返回辅导员字段
 *  - 消息  POST /jwglxt/xtgl/index_cxDbsy.html?doType=query {sfyy=0全部/1已阅/2待阅, sortName=cjsj+}
 *           items: xxbt=标题, xxnr=正文, cjsj=创建时间, clzt=0已读/2未读
 *  - 证件照 GET /jwglxt/xtgl/photo_cxXszp4.html?xh_id=学号&zplx=rxhzp -> image/jpeg（330×480）
 *  - 学业总评 GET /jwglxt/cjpmtj/cjpmtj_cxXsxytjdIndex.html -> HTML 直出（学业总评成绩/核心GPA/必修GPA/CET4）
 */
import { AcademicReport, CourseItem, CreditCategory, OverallGradeStats, OverallGrades, OfficialOverall, EmptyRoomCondition, EmptyRoomConditions, EmptyRoomItem, EmptyRoomQueryParams, EmptyRoomResult, ExamItem, LevelExamItem, LevelExamSummary, LoginResult, NoticeItem, PlanProgress, ScoreItem, SectionInfo, TermInfo, TermScore,
  UserProfile, WeekInfo } from '../model/Models';
import { TeachingCalendar } from '../model/TeachingCalendar';
import { MockData } from '../mock/MockData';
import { AppState } from '../common/AppState';
import { DataStore } from '../common/DataStore';
import { DateUtil } from '../common/DateUtil';
import { EMPTY_REPORT } from '../model/Empty';
import { Const } from '../common/Constants';
import { HttpClient, HttpResult, BinaryResult } from './HttpClient';
import { CasApi, CasCaptchaRequiredError, CasLoginResult } from './CasApi';
import { RsaUtil } from '../common/RsaUtil';
import { LogStore } from '../common/LogStore';
import zlib from '@ohos.zlib';
import { fileIo } from '@kit.CoreFileKit';
import { CourseRawStore } from '../common/CourseRawStore';
import { T } from '../common/I18n';

/** 正方下发的 RSA 公钥 */
interface RsaPublicKey {
  modulus: string;
  exponent: string;
}

/** 数据刷新状态（供页面层展示「获取状态提示」：全部成功 / 部分用缓存 / 全部失败） */
interface RefreshStatus {
  /** 是否全部接口都拿到了最新数据（无一项回退缓存） */
  allFresh: boolean;
  /** 回退到上次成功缓存的接口数量 */
  fromCacheCount: number;
  /** 参与统计的接口总数 */
  totalCount: number;
  /** 刷新完成时间戳 */
  time: number;
}

/** 容错拉取结果：data=数据（最新或缓存回退），fromCache=是否来自缓存回退 */
interface FetchResult<T> {
  data: T;
  fromCache: boolean;
}

/** 校历缓存结构：来源（最新校历文章/PDF URL）+ 转换结果数据 */
interface JwcCalCacheStore {
  sourceArticleUrl: string;
  sourcePdfUrl: string;
  data: string;
}

/** 培养方案课程池单门课程（教学执行计划 N153540 接口 C） */
interface PlanCourse {
  kch: string;      // 课程号（去重主键）
  name: string;     // 课程名（已 trim）
  credit: number;   // 学分
  category: string; // 修读要求节点名（xfyqjdmc：核心课程/非核心课程/毕业考试）
  courseType: string; // 课程性质（kcxzmc：核心/非核心/任选）
}

export class JwApi {
  /** demo 开关：true = 使用本地模拟数据。默认 true（开发期直接看模拟数据）。
   *  登录页底部"Demo 体验"入口会置为 true；真实登录成功会复位为 false（直连真实教务系统）。 */
  static USE_MOCK: boolean = true;
  /** 总体成绩接口单飞缓存（并发去重） */
  private static overallInflight: Promise<OverallGrades> | null = null;

  /** 数据刷新状态广播键（AppStorage）：refreshAll 完成后写入 RefreshStatus，页面层据此展示获取状态提示 */
  static readonly KEY_REFRESH_STATUS: string = 'dataRefreshStatus';

  private static term: TermInfo = DateUtil.buildCurrentTerm();

  private static delay<T>(data: T, ms: number): Promise<T> {
    return new Promise<T>((resolve: (value: T) => void) => {
      setTimeout(() => {
        resolve(data);
      }, ms);
    });
  }

  /** 学期 id（如 2025-2026-1）-> 正方 xqm：第一学期=3，第二学期=12，第三/短学期=16 */
  private static xqmOf(termId: string): string {
    const parts: string[] = termId.split('-');
    const idx: string = parts[parts.length - 1];
    if (idx === '1') {
      return '3';
    }
    if (idx === '2') {
      return '12';
    }
    return '16';
  }


  /**
   * 本地生成学年学期列表（不依赖网络，与正方 select 结构一致）。
   * 学年 xnm = 起始年（如 "2026" -> "2026-2027"），范围：入学年 .. 当前学年+1。
   * 每学期含第一/第二学期；当前学年额外含短学期。
   *
   * startDate 取合理开学日（第一学期 9-01、第二学期次年 3-01），
   * 保证 DateUtil.weekOfTerm 能正确算周次（否则空串解析为 NaN，课表空白）。
   */
  /** 生成本地学期列表（mock 模式使用） */
  static buildLocalTerms(): TermInfo[] {
    const now: Date = new Date();
    const curYear: number = now.getFullYear();
    const month: number = now.getMonth() + 1;
    // 当前学年起始年：9月及以后算当年，否则上一年
    const curStartYear: number = month >= 9 ? curYear : curYear - 1;
    // 入学年：从 AppState.profile.grade（"2023级"）解析，失败回退 curStartYear-3
    let startYear: number = curStartYear - 3;
    if (AppState.profile !== null && AppState.profile.grade.length > 0) {
      const m: RegExpExecArray | null = /(\d{4})/.exec(AppState.profile.grade);
      if (m !== null) {
        const y: number = Number(m[1]);
        if (!isNaN(y) && y >= 2000) {
          startYear = y;
        }
      }
    }
    const list: TermInfo[] = [];
    // 从当前学年起始年（如 2026 年 10 月 → 2026-2027 学年）往下生成；
    // 之前误写 curStartYear + 1，导致列表顶部是"下一学年"（未开学），
    // 启动兜底取列表第一个后默认学期变成 2027-2028，所有接口用错误 xnm 查询返回空数据。
    for (let y: number = curStartYear; y >= startYear; y--) {
      for (let s: number = 1; s <= 2; s++) {
        const id: string = `${y}-${y + 1}-${s}`;
        list.push({
          id: id,
          label: `${y}-${y + 1}学年 ${s === 1 ? '第一' : '第二'}学期`,
          // 统一走 defaultTermStart（含各学年特例，如 2026-2027 第一学期为 9-07），
          // 与启动默认学期、自定义开学日覆盖保持同一基线
          startDate: DateUtil.defaultTermStart(id),
          totalWeeks: 19
        });
      }
    }
    return list;
  }

  /**
   * 把"1-5周,8-14周(双)"解析成周次数组与原文。
   * 同时兼容**单周写法**（"7周"、"9"）与混合列表（"3,5,7周"）——
   * 旧实现只识别 "a-b" 区间，遇到单周写法会整条丢弃，
   * 导致该类课程（含周末课程）在任何周都不显示。
   */
  private static parseWeeks(zcd: string): WeekInfo {
    const text: string = zcd ?? '';
    const weeks: number[] = [];
    if (text.length === 0) {
      return { weeks: weeks, text: '' };
    }
    const segs: string[] = text.split(',');
    const rangeReg: RegExp = /(\d+)\s*-\s*(\d+)/;
    const singleReg: RegExp = /(\d+)/;
    for (const seg of segs) {
      const odd: boolean = seg.indexOf('单') >= 0;
      const even: boolean = seg.indexOf('双') >= 0;
      const m: ESObject | null = seg.match(rangeReg);
      if (m !== null) {
        const from: number = Number(m[1]);
        const to: number = Number(m[2]);
        for (let w = from; w <= to; w++) {
          if (odd && w % 2 === 0) {
            continue;
          }
          if (even && w % 2 === 1) {
            continue;
          }
          if (weeks.indexOf(w) < 0) {
            weeks.push(w);
          }
        }
      } else {
        const s: ESObject | null = seg.match(singleReg);
        if (s !== null) {
          const w: number = Number(s[1]);
          if (w > 0 && weeks.indexOf(w) < 0) {
            weeks.push(w);
          }
        }
      }
    }
    weeks.sort((a: number, b: number) => a - b);
    return { weeks: weeks, text: text };
  }

  /** 把"1-2"解析成起始/结束节次 */
  private static parseSections(jcs: string): SectionInfo {
    const reg: RegExp = /(\d+)\s*-\s*(\d+)/;
    const m: ESObject | null = (jcs ?? '').match(reg);
    if (m !== null) {
      return { start: Number(m[1]), end: Number(m[2]) };
    }
    const single: number = Number(jcs);
    if (!isNaN(single)) {
      return { start: single, end: single };
    }
    return { start: 1, end: 1 };
  }

  /**
   * 解析星期（1=周一 … 7=周日）：优先取数字字段 xqj；
   * 若接口未返回或值非法，则按中文星期字段（xqjmc，如"星期日""星期天"）兜底，
   * 避免周末课程因字段缺失被当成周一。
   */
  private static parseWeekday(raw: ESObject): number {
    const n: number = Number(raw['xqj'] ?? 0);
    if (n >= 1 && n <= 7) {
      return n;
    }
    const mc: string = (raw['xqjmc'] as string) ?? '';
    if (mc.indexOf('日') >= 0 || mc.indexOf('天') >= 0) {
      return 7;
    }
    if (mc.indexOf('六') >= 0) {
      return 6;
    }
    if (mc.indexOf('五') >= 0) {
      return 5;
    }
    if (mc.indexOf('四') >= 0) {
      return 4;
    }
    if (mc.indexOf('三') >= 0) {
      return 3;
    }
    if (mc.indexOf('二') >= 0) {
      return 2;
    }
    if (mc.indexOf('一') >= 0) {
      return 1;
    }
    return 1;
  }

  private static mapCourse(raw: ESObject): CourseItem {
    const zcd: string = (raw['zcd'] as string) ?? '';
    const jcs: string = (raw['jcs'] as string) ?? '1';
    const xqj: number = JwApi.parseWeekday(raw);
    const weeksInfo = JwApi.parseWeeks(zcd);
    const name: string = (raw['kcmc'] as string) ?? '未知课程';
    const teacher: string = (raw['xm'] as string) ?? '';
    const location: string = (raw['cdmc'] as string) ?? '';
    // 无时间课程判定：节次字段 jcs 为空 / "0" / 纯空白，表示该课未安排具体节次（如线上课/待排课），
    // 应归入「无时间课程」在课表下方单独展示，而不是被默认塞进周一第 1 节。
    const noSchedule: boolean = JwApi.isEmptySection(jcs);
    const secInfo: SectionInfo = noSchedule
      ? { start: 0, end: 0 }
      : JwApi.parseSections(jcs);
    return {
      id: `${name}_${teacher}_${xqj}_${jcs}`,
      name: name,
      teacher: teacher,
      location: location,
      weekday: noSchedule ? 0 : xqj,
      startSection: secInfo.start,
      endSection: secInfo.end,
      weeks: weeksInfo.weeks,
      weeksText: weeksInfo.text,
      courseType: (raw['kcxzmc'] as string) ?? (raw['kcxz'] as string) ?? T('必修'),
      credit: Number(raw['xf'] ?? 0),
      colorIndex: (xqj + name.length) % 8,
      noSchedule: noSchedule
    };
  }

  /** 判断节次字段是否为空（未安排具体时间）：空串 / "0" / 纯空白 均视为无时间 */
  private static isEmptySection(jcs: string): boolean {
    const t: string = (jcs ?? '').trim();
    if (t.length === 0) {
      return true;
    }
    if (t === '0') {
      return true;
    }
    return false;
  }

  /** 映射 sjkList（线上选修课/实践课，无固定时间地点）为 CourseItem（noSchedule=true，不画到周课表格子） */
  private static mapSjkCourse(raw: ESObject): CourseItem {
    const name: string = (raw['kcmc'] as string) ?? '未知课程';
    const teacher: string = (raw['jsxm'] as string) ?? (raw['xm'] as string) ?? '';
    const kclb: string = (raw['kclb'] as string) ?? '';
    const qsjsz: string = (raw['qsjsz'] as string) ?? (raw['sjkcgs'] as string) ?? '';
    // 周次文本：qsjsz（如"1-7周"）或 sjkcgs（"大国兵器▲待定(共7周)/1-7周"）里提取周次段
    const weeksInfo = JwApi.parseWeeks(qsjsz);
    return {
      id: `sjk_${name}_${teacher}`,
      name: name,
      teacher: teacher.length > 0 && teacher !== '待定' ? teacher : '',
      location: '',
      weekday: 0,
      startSection: 0,
      endSection: 0,
      weeks: weeksInfo.weeks,
      weeksText: weeksInfo.weeks.length > 0 ? weeksInfo.text : qsjsz,
      courseType: kclb.length > 0 ? kclb : '线上选修',
      credit: Number(raw['xf'] ?? 0),
      colorIndex: JwApi.colorIndexOf(name),
      noSchedule: true
    };
  }

  private static mapExam(raw: ESObject): ExamItem {
    const kssj: string = (raw['kssj'] as string) ?? '';
    const parsed: string[] = JwApi.parseExamTime(kssj);
    // 考场优先 cdmc（"博学楼A207"），cdbh 只是场地编号（如 "001"），直接用会显示成一串数字
    const cdmc: string = ((raw['cdmc'] as string) ?? '').trim();
    const cdbh: string = ((raw['cdbh'] as string) ?? '').trim();
    // 类型优先 ksxz（考试性质：期末/期中/补考），ksfs 是考试方式（闭卷/开卷）
    const ksxz: string = ((raw['ksxz'] as string) ?? '').trim();
    const ksfs: string = ((raw['ksfs'] as string) ?? '').trim();
    // 课程名优先 kcmc（如「人体结构与功能01」）；ksmc 是考试批次名
    // （如「2026-2027学年第一学期期末考试」），直接用会让所有考试同名
    const kcmc: string = ((raw['kcmc'] as string) ?? '').trim();
    const ksmc: string = ((raw['ksmc'] as string) ?? '').trim();
    const courseName: string = kcmc.length > 0 ? kcmc : (ksmc.length > 0 ? ksmc : '未知考试');
    return {
      id: `${courseName}_${kssj}`,
      courseName: courseName,
      date: parsed[0],
      timeRange: parsed[1],
      location: cdmc.length > 0 ? cdmc : (cdbh.length > 0 ? cdbh : '待定'),
      seat: (raw['zwh'] as string) ?? '待定',
      examType: ksxz.length > 0 ? ksxz : (ksfs.length > 0 ? ksfs : T('考试')),
      teacher: (raw['jsxm'] as string) ?? ''
    };
  }

  /**
   * 解析教务返回的考试时间字符串，兼容三种常见形态：
   *   "2026-01-05 09:00-11:00" / "2026-01-05(09:00-11:00)" / "2026/1/5 9:00~11:00"
   * 返回 [日期(yyyy-MM-dd), 时间段(HH:mm-HH:mm)]，缺项为空串。
   */
  private static parseExamTime(kssj: string): string[] {
    const out: string[] = ['', ''];
    if (kssj.length === 0) {
      return out;
    }
    const dm: RegExpMatchArray | null = kssj.match(/(\d{4})[-/](\d{1,2})[-/](\d{1,2})/);
    if (dm !== null) {
      const mm: string = dm[2].length === 1 ? `0${dm[2]}` : dm[2];
      const dd: string = dm[3].length === 1 ? `0${dm[3]}` : dm[3];
      out[0] = `${dm[1]}-${mm}-${dd}`;
    }
    const tm: RegExpMatchArray | null = kssj.match(/(\d{1,2}:\d{2})\s*[-~至—–]\s*(\d{1,2}:\d{2})/);
    if (tm !== null) {
      out[1] = `${tm[1]}-${tm[2]}`;
    } else {
      const single: RegExpMatchArray | null = kssj.match(/(\d{1,2}:\d{2})/);
      if (single !== null) {
        out[1] = single[1];
      }
    }
    return out;
  }

  /** 判断是否核心课程（CC）：课程类别/性质名称含「核心」字样。
   *  南医大培养方案中核心课程在 kclbmc / kcxzmc 字段标记，用于学业总评成绩计算。 */
  private static isCoreCourse(kclbmc: string, kcxzmc: string): boolean {
    const combined: string = `${kclbmc ?? ''}${kcxzmc ?? ''}`;
    return combined.indexOf('核心') >= 0;
  }

  private static mapScore(raw: ESObject, termId: string): ScoreItem {
    const cj: number = Number(raw['cj']);
    const valid: boolean = !isNaN(cj);
    const kclbmc: string = (raw['kclbmc'] as string) ?? '';
    const kcxzmc: string = (raw['kcxzmc'] as string) ?? T('必修');
    return {
      id: `${raw['kcmc']}_${raw['xnmmc']}_${raw['xqmmc']}`,
      courseName: (raw['kcmc'] as string) ?? '未知课程',
      credit: Number(raw['xf'] ?? 0),
      score: valid ? cj : -1,
      scoreText: valid ? `${cj}` : (raw['cj'] as string),
      gradePoint: Number(raw['jd'] ?? 0),
      courseType: kcxzmc,
      examType: (raw['ksxz'] as string) ?? T('正常考试'),
      // 任课教师名：教务返回的字段是 jsxm，xm 是学生本人名字（不能错位）
      teacher: (raw['jsxm'] as string) ?? '',
      termId: termId,
      kclbmc: kclbmc,
      isCore: JwApi.isCoreCourse(kclbmc, kcxzmc)
    };
  }

  /**
   * 按课程名生成稳定的颜色索引（0-7），同名课程始终返回同一颜色。
   * 使用 djb2 hash 算法 → 模 8 取索引，颜色板与 Const.COURSE_BG / COURSE_FG 对齐。
   * 课程名做 trim 处理避免空格差异；空名回退到 0。
   */
  static colorIndexOf(name: string): number {
    const key: string = (name ?? '').trim();
    if (key.length === 0) {
      return 0;
    }
    let hash: number = 5381;
    for (let i = 0; i < key.length; i++) {
      hash = ((hash << 5) + hash + key.charCodeAt(i)) & 0x7FFFFFFF;
    }
    return hash % 8;
  }

  /**
   * 课程颜色索引缓存：保证用户首次打开应用时同名课程使用一致颜色，
   * 同时减少 hash 计算（虽然 djb2 极快，但缓存是 O(1) 直查）。
   * 格式：{ "课程名": "颜色索引(0-7)", ... }
   */
  static loadColorMap(): Record<string, number> {
    const raw: string = DataStore.loadJSON(DataStore.KEY_COURSE_COLOR_MAP);
    if (raw.length === 0) {
      return {};
    }
    try {
      const parsed: Record<string, number> = JSON.parse(raw) as Record<string, number>;
      return parsed;
    } catch (e) {
      return {};
    }
  }

  static saveColorMap(map: Record<string, number>): void {
    DataStore.cacheJSON(DataStore.KEY_COURSE_COLOR_MAP, JSON.stringify(map));
  }

  /**
   * ArrayBuffer → base64 字符串（用于图片转 DataStore 持久化）。
   * 逐字节读 Uint8Array，拼接标准 base64 字符表。
   */
  static arrayBufferToBase64(buf: ArrayBuffer): string {
    const u8: Uint8Array = new Uint8Array(buf);
    const chars: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let out: string = '';
    let i: number = 0;
    for (; i + 2 < u8.length; i += 3) {
      const b0: number = u8[i];
      const b1: number = u8[i + 1];
      const b2: number = u8[i + 2];
      out += chars.charAt(b0 >> 2);
      out += chars.charAt(((b0 & 0x03) << 4) | (b1 >> 4));
      out += chars.charAt(((b1 & 0x0F) << 2) | (b2 >> 6));
      out += chars.charAt(b2 & 0x3F);
    }
    if (i < u8.length) {
      const b0: number = u8[i];
      const b1: number = i + 1 < u8.length ? u8[i + 1] : 0;
      out += chars.charAt(b0 >> 2);
      out += chars.charAt(((b0 & 0x03) << 4) | (b1 >> 4));
      out += i + 1 < u8.length ? chars.charAt(((b1 & 0x0F) << 2)) : '=';
      out += '=';
    }
    return out;
  }

  /**
   * 确保课程名有颜色索引：先读缓存，命中直接返回；未命中按 name hash 计算并写入缓存。
   * 用于 ScheduleView 渲染时按 course.name 取颜色。
   */
  static ensureColorIndex(name: string): number {
    const trimmed: string = (name ?? '').trim();
    if (trimmed.length === 0) {
      return 0;
    }
    const map: Record<string, number> = JwApi.loadColorMap();
    const cached: number | undefined = map[trimmed];
    if (cached !== undefined) {
      return cached;
    }
    const idx: number = JwApi.colorIndexOf(trimmed);
    map[trimmed] = idx;
    JwApi.saveColorMap(map);
    return idx;
  }

  /** 登录教务系统 */
  /**
   * 登录入口（2026-08 学校改版：统一身份认证 CAS 单点登录）。
   * @param mode 登录系统：
   *   'original'=原版（教务系统 RSA 直登，与原版 App 行为一致）；
   *   'service'=新版（服务大厅/CAS 登录，登录后后台自动打开教务系统；7天免登录仅在此时生效）；
   *   'auto'=自动（CAS 优先→RSA 兜底，冷启动自动重登用）。
   */
  static async login(account: string, password: string, captcha: string = '', mode: string = 'original'): Promise<LoginResult> {
    if (JwApi.USE_MOCK) {
      const ok: boolean = account.length >= 6 && password.length >= 6;
      const result: LoginResult = {
        success: ok,
        message: ok ? T('登录成功') : '学号或密码格式不正确（demo：学号 6 位以上、密码 6 位以上即可）',
        profile: ok ? MockData.PROFILE : null,
        needCaptcha: false
      };
      // 功能浏览模式同样记录登录日志（日志调试开启后收集，便于排查登录问题）
      LogStore.log('登录', '登录', ok ? '成功' : '失败',
        ok ? '功能浏览模式登录成功' : '功能浏览模式登录失败（学号/密码长度不足）');
      return JwApi.delay(result, 900);
    }
    // 原版登录：教务系统 RSA 直登（与原版一致，不经过 CAS）
    if (mode === 'original') {
      AppState.account = account;
      try {
        const result: LoginResult = await JwApi.loginReal(account, password, captcha);
        if (result.success) {
          DataStore.put(DataStore.KEY_LOGIN_SYSTEM, 'original'); // 教务登录
          DataStore.put(DataStore.KEY_LOGIN_METHOD, 'pwd'); // 实际登录方式：教务系统密码直登
        }
        return result;
      } catch (e) {
        // 登录链路任一步异常（网络失败/解析失败/RSA 异常）：记录完整诊断，便于定位登录失败根因
        const errText: string = LogStore.errorOf(e as Object);
        LogStore.logNet(T('登录'), '原版', T('异常'),
          {
            method: 'POST',
            url: '/jwglxt/xtgl/login_slogin.html',
            status: '',
            error: errText,
            detail: `原版登录链路异常（${JwApi.loginStage}），请检查网络与教务系统可用性`
          });
        throw e as Error;
      }
    }
    // 新版登录：服务大厅（CAS）登录，失败不自动回退 RSA，交由 UI 提示（验证码异常直接抛给 UI）
    if (mode === 'service') {
      AppState.account = account;
      const casResult: LoginResult | null = await JwApi.loginViaCas(account, password, captcha);
      if (casResult !== null) {
        DataStore.put(DataStore.KEY_LOGIN_SYSTEM, 'service'); // 服务大厅登录
        return casResult;
      }
      const detail: string = JwApi.lastCasError;
      return {
        success: false,
        message: detail.length > 0 ? `服务大厅登录失败：${detail}` : '服务大厅登录失败，请检查账号密码或稍后重试',
        profile: null,
        needCaptcha: false
      };
    }
    // 自动（默认）：CAS 优先 → 教务系统 RSA 直登兜底
    AppState.account = account;
    const casResult: LoginResult | null = await JwApi.loginViaCas(account, password, captcha);
    if (casResult !== null) {
      DataStore.put(DataStore.KEY_LOGIN_SYSTEM, 'service'); // 服务大厅登录
      return casResult;
    }
    try {
      const result: LoginResult = await JwApi.loginReal(account, password, captcha);
      if (result.success) {
        DataStore.put(DataStore.KEY_LOGIN_SYSTEM, 'original'); // 教务登录
        DataStore.put(DataStore.KEY_LOGIN_METHOD, 'pwd'); // 实际登录方式：教务系统密码直登
      }
      return result;
    } catch (e) {
      // 登录链路任一步异常（网络失败/解析失败/RSA 异常）：记录完整诊断，便于定位登录失败根因
      const errText: string = LogStore.errorOf(e as Object);
      LogStore.logNet(T('登录'), T('登录'), T('异常'),
        {
          method: 'POST',
          url: '/jwglxt/xtgl/login_slogin.html',
          status: '',
          error: errText,
          detail: `登录链路异常（${JwApi.loginStage}），请检查网络与教务系统可用性`
        });
      throw e as Error;
    }
  }

  /** 当前登录阶段（日志诊断用）：getPage=取登录页 / getKey=取公钥 / encrypt=RSA加密 / submit=提交表单 / profile=验证资料 */
  private static loginStage: string = 'init';

  /** 最近一次 CAS 登录失败原因（供 UI 明确提示，不再笼统报"服务大厅登录失败"） */
  private static lastCasError: string = '';

  /** 当前登录阶段（供 UI 判断登录是否已进入收尾：'profile' 表示会话已建立、正在校验资料） */
  static stage(): string {
    return JwApi.loginStage;
  }

  /**
   * 统一身份认证（CAS）原生登录主链路。
   * - 成功：建立 jwglxt 会话、缓存资料、按需持久化 CASTGC（7天免登录），返回 LoginResult。
   * - 需要验证码：抛出 CasCaptchaRequiredError（由 UI 转"网页版登录"兜底）。
   * - 其它网络/解析失败：返回 null，交由下方旧的 RSA 直登兜底。
   */
  private static async loginViaCas(account: string, password: string, captcha: string = ''): Promise<LoginResult | null> {
    const remember7d: boolean = AppState.remember7d;
    JwApi.loginStage = 'cas';
    JwApi.lastCasError = '';
    try {
      const res: CasLoginResult = await CasApi.nativeCasLogin(account, password, remember7d, captcha);
      if (res.cookie.length === 0) {
        JwApi.lastCasError = '未获取到教务会话';
        return null; // 无会话 Cookie，回退 RSA
      }
      // 注入教务系统会话给全站接口
      HttpClient.setCookie(res.cookie);
      DataStore.put(DataStore.KEY_SESSION_COOKIE, res.cookie);
      // 会话已建立 → 进入收尾阶段（后续仅为资料校验）；UI 超时保护据此判定"登录实际已成功"
      JwApi.loginStage = 'profile';
      // 服务大厅登录：始终持久化 CASTGC（冷启动从服务大厅重新桥接"新教务系统"刷新用）。
      // rememberMe（7天免登录）只影响服务端 TGT 有效期；本地持久化不依赖勾选。
      if (res.castgc.length > 0) {
        DataStore.put(DataStore.KEY_CAS_TGC, res.castgc);
      }
      DataStore.put(DataStore.KEY_LOGIN_METHOD, 'cas');
      // 验证会话是否真正建立（避免被登录页 HTML 误导）
      const profile: UserProfile = await JwApi.getProfile();
      if (profile.name.length > 0) {
        DataStore.cacheProfile(profile);
        LogStore.logNet(T('登录'), 'CAS', T('成功'),
          { method: 'POST', url: '/authserver/login', status: '200', detail: '已建立教务系统会话' });
        return { success: true, message: T('登录成功'), profile: profile, needCaptcha: false };
      }
      // 会话 Cookie 有但资料取不到：视为失败，回退
      JwApi.lastCasError = '会话已建立但资料校验失败';
      return null;
    } catch (e) {
      if (e instanceof CasCaptchaRequiredError) {
        throw e; // 直接抛出，UI 展示验证码图片让用户输入后重试
      }
      // 网络/解析等其它异常：CAS 不可用，回退 RSA（记录原因供 UI 明确提示）
      JwApi.lastCasError = LogStore.errorOf(e as Object);
      LogStore.logNet(T('登录'), 'CAS', T('异常'),
        { method: 'POST', url: '/authserver/login', status: '', error: LogStore.errorOf(e as Object),
          detail: 'CAS 登录失败，将回退旧版 RSA 直登' });
      return null;
    }
  }

  /** 冷启动静默重登：用持久化 CASTGC 重新桥接 jwxt 会话（无需重新输入密码）。成功返回 true。 */
  static async silentCasRelogin(): Promise<boolean> {
    const tgc: string = DataStore.get(DataStore.KEY_CAS_TGC);
    if (tgc.length === 0) {
      return false;
    }
    try {
      const cookie: string = await CasApi.silentRelogin(tgc);
      if (cookie.length === 0) {
        return false;
      }
      HttpClient.setCookie(cookie);
      DataStore.put(DataStore.KEY_SESSION_COOKIE, cookie);
      LogStore.log('登录', 'CAS', '自动重登', '使用 CASTGC 静默恢复教务系统会话');
      return true;
    } catch (e) {
      LogStore.log('登录', 'CAS', '自动重登', '失败：' + LogStore.errorOf(e as Object));
      return false;
    }
  }

  /** 会话过期自动恢复：优先 CASTGC 静默桥接，其次用保存的账号密码直登。成功返回 true。 */
  static async tryAutoRecoverSession(): Promise<boolean> {
    if (JwApi.USE_MOCK) {
      return false;
    }
    // 1) CASTGC 静默桥接（无需密码，最快）
    if (await JwApi.silentCasRelogin()) {
      LogStore.log('登录', '自动恢复', '成功', 'CASTGC 静默桥接恢复会话');
      return true;
    }
    // 2) 保存的账号密码 RSA 直登
    const acct: string = DataStore.get(DataStore.KEY_AUTO_ACCOUNT);
    const pwd: string = DataStore.decodePwd(DataStore.get(DataStore.KEY_AUTO_PWD));
    if (acct.length === 0 || pwd.length === 0) {
      LogStore.log('登录', '自动恢复', '跳过', '无可用凭据（CASTGC/账号密码均缺失）');
      return false;
    }
    try {
      const r: LoginResult = await JwApi.login(acct, pwd, '', 'original');
      if (r.success) {
        LogStore.log('登录', '自动恢复', '成功', '账号密码直登恢复会话');
        return true;
      }
      LogStore.log('登录', '自动恢复', '失败', r.message);
      return false;
    } catch (e) {
      LogStore.log('登录', '自动恢复', '异常', LogStore.errorOf(e as Object));
      return false;
    }
  }

  /**
   * 会话过期后按需自动恢复（fire-and-forget，不阻塞调用方）。
   * 每进程最多尝试 2 次，避免密码错误/账号被锁时反复登录。
   */
  static autoRecoverIfNeeded(): void {
    if (!AppState.sessionExpired || JwApi.recovering || JwApi.recoverCount >= 2) {
      return;
    }
    JwApi.recovering = true;
    JwApi.recoverCount += 1;
    JwApi.tryAutoRecoverSession().then((ok: boolean) => {
      JwApi.recovering = false;
      if (ok) {
        HttpClient.clearSessionExpired();
        LogStore.log('首页', '会话', '恢复成功', '重新拉取数据');
        // 重置节流并重拉（延迟 300ms 让会话 Cookie 生效）
        JwApi.lastRefreshAt = 0;
        setTimeout(() => {
          JwApi.refreshAll().catch(() => {
            // ignore
          });
        }, 300);
      } else {
        LogStore.log('首页', '会话', '恢复失败', '需手动点击「登录已过期 · 重登」');
      }
    }).catch((_e: Object) => {
      JwApi.recovering = false;
    });
  }

  /** 真实登录主流程（被 login 包装，带阶段跟踪与异常日志） */
  private static async loginReal(account: string, password: string, captcha: string): Promise<LoginResult> {
    JwApi.loginStage = 'getPage';
    const pageRes: HttpResult = await HttpClient.get('/jwglxt/xtgl/login_slogin.html');
    // 提取登录页【全部】隐藏域（csrftoken、xxdm、yzcskz、mmsfjm 等约 18 个）。
    // 只提交部分字段会导致服务端退回登录页 / 误判"验证码错误"，必须整表单提交。
    const hidden: Record<string, string> = JwApi.extractAllHidden(pageRes.body);
    const csrf: string = hidden['csrftoken'] ?? '';
    JwApi.loginStage = 'getKey';
    const pub: RsaPublicKey = await JwApi.fetchPublicKey();
    JwApi.loginStage = 'encrypt';
    const encPwd: string = await RsaUtil.encryptPassword(password, pub.modulus, pub.exponent);

    const form: Record<string, string> = hidden; // 已包含全部隐藏域
    form['csrftoken'] = csrf;
    form['yhm'] = account;
    form['mm'] = encPwd;   // 密码经 RSA 加密；mmsfjm=1 表示密码已加密
    form['mmsfjm'] = '1';
    if (captcha.length > 0) {
      form['yzm'] = captcha; // 服务端要求验证码时携带
    }

    JwApi.loginStage = 'submit';
    const res: HttpResult = await HttpClient.postForm('/jwglxt/xtgl/login_slogin.html', form);
    const body: string = res.body;
    // ── 模仿 HiXD CasLoginService：先按 HTML 具体关键词提取错误 ──
    const hasJsession: boolean = res.cookie.indexOf('JSESSIONID') >= 0;
    const enteredHome: boolean = body.indexOf('index_initMenu') >= 0 || body.indexOf('教学管理信息服务平台') >= 0 ||
      body.indexOf('学生个人信息') >= 0 || body.indexOf('当前角色消息') >= 0;
    // 失败关键词（登录页会回显这些提示）
    const failByPwd: boolean = body.indexOf('用户名或密码') >= 0 || body.indexOf('密码错误') >= 0 ||
      body.indexOf('账号错误') >= 0 || body.indexOf('账号被锁定') >= 0 || body.indexOf('账号被冻结') >= 0;
    const needCaptcha: boolean = body.indexOf('验证码') >= 0 || body.indexOf('校验码') >= 0;

    if (body.indexOf('账号被锁定') >= 0 || body.indexOf('账号被冻结') >= 0) {
      LogStore.logNet(T('登录'), T('登录'), T('失败'),
        {
          method: 'POST',
          url: '/jwglxt/xtgl/login_slogin.html',
          status: `${res.code}`,
          body: body,
          detail: `账号被锁定/冻结；hasJsession=${hasJsession} enteredHome=${enteredHome}；错误提示：${JwApi.extractLoginError(body)}`
        });
      return { success: false, message: '账号已被锁定/冻结，请稍后再试', profile: null, needCaptcha: false };
    }

    // 明确的密码错误且未要求验证码：直接返回失败，避免多余请求
    if (failByPwd && !needCaptcha) {
      LogStore.logNet(T('登录'), T('登录'), T('失败'),
        {
          method: 'POST',
          url: '/jwglxt/xtgl/login_slogin.html',
          status: `${res.code}`,
          body: body,
          detail: `服务端返回密码错误；hasJsession=${hasJsession} enteredHome=${enteredHome}；错误提示：${JwApi.extractLoginError(body)}`
        });
      return { success: false, message: '学号或密码错误', profile: null, needCaptcha: false };
    }

    // ── 成功判定：进入主页 或 携带 JSESSIONID 且资料可获取（双保险，模仿 HiXD）──
    if (enteredHome || hasJsession) {
      // 会话已建立 → 进入收尾阶段（后续仅为资料校验）；UI 超时保护据此判定"登录实际已成功"
      JwApi.loginStage = 'profile';
      try {
        const profile: UserProfile = await JwApi.getProfile();
        if (profile.name.length > 0) {
          // 登录成功：记录账号 + 缓存资料
          DataStore.cacheProfile(profile);
          LogStore.logNet(T('登录'), T('登录'), T('成功'),
            { method: 'POST', url: '/jwglxt/xtgl/login_slogin.html', status: `${res.code}`, detail: `enteredHome=${enteredHome} hasJsession=${hasJsession}` });
          return { success: true, message: T('登录成功'), profile: profile, needCaptcha: false };
        }
      } catch (e) {
        LogStore.log('登录', '登录', '资料获取异常', LogStore.errorOf(e as Object));
        // 忽略，走下面的失败分支
      }
    }
    LogStore.logNet(T('登录'), T('登录'), T('失败'),
      {
        method: 'POST',
        url: '/jwglxt/xtgl/login_slogin.html',
        status: `${res.code}`,
        body: body,
        detail: `needCaptcha=${needCaptcha} enteredHome=${enteredHome} hasJsession=${hasJsession} failByPwd=${failByPwd}`
      });
    return {
      success: false,
      message: needCaptcha ? '请输入验证码后重试' : '登录失败，请检查学号密码',
      profile: null,
      needCaptcha: needCaptcha
    };
  }

  /** 验证码图片地址（与服务端会话绑定）。正方 zftal-ui v5 实际端点为 /kaptcha（带 time 防缓存）。 */
  static CAPTCHA_URL: string = '/jwglxt/kaptcha';

  /** 从登录失败响应 HTML 中提取具体错误提示（用于日志诊断）：
   *  依次匹配常见提示关键词，命中即返回；无命中则截取响应体中可读文本片段。 */
  private static extractLoginError(body: string): string {
    const hints: string[] = [
      '账号被锁定', '账号被冻结', '用户名或密码错误', T('密码错误'), '账号错误',
      '验证码错误', '验证码不正确', '校验码', '请输入验证码', '该账号已过期',
      T('登录已过期'), '系统繁忙', T('网络异常'), '服务器错误'
    ];
    for (let i = 0; i < hints.length; i++) {
      const idx: number = body.indexOf(hints[i]);
      if (idx >= 0) {
        // 取关键词前后各 40 字符作为上下文
        const start: number = Math.max(0, idx - 40);
        const end: number = Math.min(body.length, idx + hints[i].length + 40);
        return body.substring(start, end).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
      }
    }
    // 无关键词命中：尝试取提示 div（正方登录页常见 .tip / .alert）
    const tipIdx: number = body.indexOf('提示');
    if (tipIdx >= 0) {
      return body.substring(Math.max(0, tipIdx - 30), tipIdx + 60).replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
    }
    return '未提取到具体提示（响应体已记录，可在日志详情查看完整内容）';
  }

  /** 拉取验证码图片，返回 base64（无 data: 前缀）；mock 模式或无图时返回空串。 */
  static async getCaptcha(): Promise<string> {
    if (JwApi.USE_MOCK) {
      return '';
    }
    const ts: number = new Date().getTime();
    return HttpClient.getImageBase64(`${JwApi.CAPTCHA_URL}?time=${ts}`);
  }

  /** 提取登录页【全部】隐藏域（name -> value），覆盖 csrftoken、xxdm、yzcskz、mmsfjm 等约 18 个字段。
   *  该站点 input 写法不统一（value= 1 或 value="..."），这里做容错解析，确保整表单提交。 */
  private static extractAllHidden(html: string): Record<string, string> {
    const map: Record<string, string> = {};
    const tagRe: RegExp = /<input[^>]*type\s*=\s*["']?hidden["']?[^>]*>/gi;
    const tags: ESObject | null = html.match(tagRe);
    if (tags === null) {
      return map;
    }
    for (let i = 0; i < tags.length; i++) {
      const tag: string = tags[i];
      const nameM: ESObject | null = tag.match(/name\s*=\s*["']?([^"'>\s]+)/i);
      const valM: ESObject | null = tag.match(/value\s*=\s*["']?([^"'>\s]*)/i);
      if (nameM !== null) {
        map[nameM[1]] = valM !== null ? valM[1] : '';
      }
    }
    return map;
  }

  /** 从登录页 HTML 取 RSA 公钥 {modulus, exponent}，均为 base64。 */
  private static async fetchPublicKey(): Promise<RsaPublicKey> {
    const res: HttpResult = await HttpClient.get('/jwglxt/xtgl/login_getPublicKey.html');
    try {
      const obj: ESObject = JSON.parse(res.body);
      return {
        modulus: (obj['modulus'] as string) ?? '',
        exponent: (obj['exponent'] as string) ?? ''
      };
    } catch (e) {
      return { modulus: '', exponent: '' };
    }
  }


  /** 退出登录：清空会话、本地 Cookie 持久化、自动重登凭据、缓存资料、离线模式 */
  static logout(): void {
    HttpClient.clearCookie();
    DataStore.put(DataStore.KEY_SESSION_COOKIE, '');
    DataStore.put(DataStore.KEY_AUTO_ACCOUNT, '');
    DataStore.put(DataStore.KEY_AUTO_PWD, '');
    DataStore.put(DataStore.KEY_CAS_TGC, ''); // 清除 7天免登录的 CASTGC
    DataStore.put(DataStore.KEY_SSO_COOKIES, ''); // 清除统一认证/服务大厅 SSO 会话
    // 清除缓存的登录资料，确保下次打开回到登录页而不是直接进主页
    DataStore.cacheProfile(null);
    AppState.clear();
    HttpClient.setOfflineMode(true);
  }



  /**
   * 切换学期（全局设置）。同步更新 JwApi.term 与 AppState.term，
   * 持久化到 DataStore.KEY_DS_TERM 供启动恢复。各页（首页/课表/成绩/考试）依赖 term 重新计算周次/拉数据。
   */
  /**
   * 应用「自定义开学时间」覆盖：仅当开学时间来源为「使用自定义时间」（DataStore.termStartMode()==='custom'）
   * 且该学期存在自定义开学日时，返回覆盖后的副本；「跟随教务系统」或未自定义时原样返回。
   * 集中在此处理，保证首页/课程表/桌面卡片等所有周次推算一致，且同步课表不会被教务值改回。
   */
  static applyCustomStart(term: TermInfo): TermInfo {
    if (DataStore.termStartMode() !== 'custom') {
      return term;
    }
    const custom: string = DataStore.getCustomTermStart(term.id);
    return custom.length > 0
      ? { id: term.id, label: term.label, startDate: custom, totalWeeks: term.totalWeeks }
      : term;
  }

  static setTerm(term: TermInfo): void {
    const t: TermInfo = JwApi.applyCustomStart(term);
    JwApi.term = t;
    AppState.term = t;
    AppState.termExplicit = true; // 标记"学期已就绪"，提醒排程不再回退到默认值
    DataStore.put(DataStore.KEY_DS_TERM, term.id);
    // 广播学期变化，供各页（课程表等）@StorageProp @Watch 监听同步切换
    AppStorage.setOrCreate('currentTermId', term.id);
  }

  /** 学生基本信息（真实数据取自课表接口返回的 xsxx） */
  static async getProfile(): Promise<UserProfile> {
    if (JwApi.USE_MOCK) {
      return JwApi.delay(MockData.PROFILE, 200);
    }
    // 优先读缓存
    const cached: UserProfile | null = DataStore.loadCachedProfile();
    if (cached !== null && cached.name.length > 0) {
      return cached;
    }
    const parts: string[] = JwApi.term.id.split('-');
    const xnm: string = parts[0];
    const xqm: string = JwApi.xqmOf(JwApi.term.id);
    const res: HttpResult = await HttpClient.postForm('/jwglxt/kbcx/xskbcx_cxXsgrkb.html', { 'xnm': xnm, 'xqm': xqm });
    try {
      const root: ESObject = JSON.parse(res.body);
      const xs: ESObject = (root['xsxx'] as ESObject) ?? {};
      if (xs === null || xs === undefined) {
        throw new Error('no xsxx');
      }
      const nj: string = (xs['NJDM_ID'] as string) ?? '';
      const profile: UserProfile = {
        studentId: (xs['XH'] as string) ?? AppState.account,
        name: (xs['XM'] as string) ?? '',
        college: (xs['JGMC'] as string) ?? '',
        major: (xs['ZYMC'] as string) ?? '',
        className: (xs['BJMC'] as string) ?? '',
        grade: nj.length > 0 ? `${nj}级` : '',
        counselor: '', // 教务系统不提供辅导员字段
        eduSystem: (xs['XZ'] as string) ?? '',
        status: (xs['XJZT'] as string) ?? T('在读')
      };
      // 学院字段：课表 xsxx 无 JGMC，尝试从"查询个人信息"页面补全
      if (profile.name.length > 0 && profile.college.length === 0) {
        const enriched: UserProfile | null = await JwApi.fetchFullProfile();
        if (enriched !== null) {
          if (enriched.college.length > 0) {
            profile.college = enriched.college;
          }
          if (enriched.major.length > 0) {
            profile.major = enriched.major;
          }
          if (enriched.className.length > 0) {
            profile.className = enriched.className;
          }
          if (enriched.grade.length > 0) {
            profile.grade = enriched.grade;
          }
          if (enriched.eduSystem.length > 0) {
            profile.eduSystem = enriched.eduSystem;
          }
        }
      }
      if (profile.name.length > 0) {
        DataStore.cacheProfile(profile);
      }
      return profile;
    } catch (e) {
      // 未登录或返回非 JSON（如登录页 HTML）时，返回空资料，交由上层判断登录态
      return {
        studentId: AppState.account,
        name: '',
        college: '',
        major: '',
        className: '',
        grade: '',
        counselor: '',
        eduSystem: '',
        status: '未登录'
      };
    }
  }

  /**
   * 拉取"查询个人信息"页面，补充学生资料的学院、年级等字段（课表 xsxx 不含 JGMC）。
   * 从 /jwglxt/xsxxxggl/xsgrxxwh_cxXsgrxx.html?gnmkdm=N100801 解析纯文本。
   */
  static async fetchFullProfile(): Promise<UserProfile | null> {
    if (JwApi.USE_MOCK) {
      return null;
    }
    try {
      const res: HttpResult = await HttpClient.get(
        '/jwglxt/xsxxxggl/xsgrxxwh_cxXsgrxx.html?gnmkdm=N100801&layout=default');
      const html: string = res.body;
      // 提取字段：学号/姓名/性别/出生/民族/政治面貌/年级/学院/专业/班级/学制/学籍状态
      const grab: (re: RegExp) => string = (re: RegExp): string => {
        const m: RegExpExecArray | null = re.exec(html);
        return m !== null ? m[1].trim() : '';
      };
      const name: string = grab(/姓名[：:]\s*<[^>]*>([^<]+)/);
      const xh: string = grab(/学号[：:]\s*<[^>]*>([^<]+)/);
      const xb: string = grab(/性别[：:]\s*<[^>]*>([^<]+)/);
      const mz: string = grab(/民族[：:]\s*<[^>]*>([^<]+)/);
      const zzmm: string = grab(/政治面貌[：:]\s*<[^>]*>([^<]+)/);
      const nj: string = grab(/年级[：:]\s*<[^>]*>([^<]+)/);
      const xy: string = grab(/学院[：:]\s*<[^>]*>([^<]+)/) || grab(/学院名称[：:]\s*<[^>]*>([^<]+)/);
      const zy: string = grab(/专业[：:]\s*<[^>]*>([^<]+)/) || grab(/专业名称[：:]\s*<[^>]*>([^<]+)/);
      const bj: string = grab(/班级[：:]\s*<[^>]*>([^<]+)/) || grab(/班级名称[：:]\s*<[^>]*>([^<]+)/);
      const xz: string = grab(/学制[：:]\s*<[^>]*>([^<]+)/);
      const xjzt: string = grab(/学籍状态[：:]\s*<[^>]*>([^<]+)/);
      if (name.length === 0 && xh.length === 0) {
        return null;
      }
      // 合并到现有 profile（保留课表已有字段，未取到的置空）
      const merged: UserProfile = {
        studentId: xh.length > 0 ? xh : AppState.account,
        name: name,
        college: xy,
        major: zy,
        className: bj,
        grade: nj,
        counselor: '',
        eduSystem: xz,
        status: xjzt.length > 0 ? xjzt : (AppState.profile !== null ? AppState.profile.status : '在读')
      };
      DataStore.cacheProfile(merged);
      return merged;
    } catch (e) {
      return null;
    }
  }

  /** 课程表 */
  static async getCourses(termId: string): Promise<CourseItem[]> {
    if (JwApi.USE_MOCK) {
      const list: CourseItem[] = MockData.courses();
      // ⚠ 演示数据不写真实缓存：否则切回真实登录后首页会读到 mock 课表（个人数据显示成演示学生）
      JwApi.markCoursesFetched(termId);
      return JwApi.delay(list, 500);
    }
    const parts: string[] = termId.split('-');
    const xnm: string = parts[0];
    const xqm: string = JwApi.xqmOf(termId);
    const res: HttpResult = await HttpClient.postForm(JwApi.COURSE_URL, { 'xnm': xnm, 'xqm': xqm });
    let root: ESObject;
    try {
      root = JSON.parse(res.body);
    } catch (e) {
      LogStore.logNet(T('课表'), '解析', T('异常'),
        { url: JwApi.COURSE_URL, status: `${res.code}`, error: LogStore.errorOf(e as Object), body: res.body, detail: `xnm=${xnm} xqm=${xqm}` });
      throw e as Error;
    }
    const kbList: ESObject[] = (root['kbList'] as ESObject[]) ?? [];
    const list: CourseItem[] = [];
    for (let i = 0; i < kbList.length; i++) {
      list.push(JwApi.mapCourse(kbList[i]));
    }
    // 合并 sjkList（线上选修课/实践课，无固定时间地点，如"大国兵器""脑洞大开"）。
    // 2026-10 抓包实测：这些课只有周次（qsjsz="1-7周"）、无星期节次，只出现在 sjkList，
    // 不画到周课表格子，但属于本学期的选课清单，必须一并纳入，否则"课缺失"。
    const sjkList: ESObject[] = (root['sjkList'] as ESObject[]) ?? [];
    for (let i = 0; i < sjkList.length; i++) {
      const sc: CourseItem = JwApi.mapSjkCourse(sjkList[i]);
      // 与 kbList 去重（同名课程不重复加）
      if (!JwApi.hasCourseName(list, sc.name)) {
        list.push(sc);
      }
    }
    DataStore.cacheJSON(DataStore.KEY_COURSES, JSON.stringify(list));
    // 保存"原始导入识别文件"：教务系统课表接口的原始响应体全文（课表页底部可查看）
    CourseRawStore.save(termId, res.body, JwApi.COURSE_URL, list.length);
    // 记录"今天已查询识别"，同一天内不再自动重复请求
    JwApi.markCoursesFetched(termId);
    LogStore.logNet(T('课表'), '获取', T('成功'),
      { url: JwApi.COURSE_URL, status: `${res.code}`, detail: `${list.length}节 xnm=${xnm} xqm=${xqm}` });
    return list;
  }

  /** 正方课表查询接口（同时作为"课表原文件"的来源标识） */
  private static readonly COURSE_URL: string = '/jwglxt/kbcx/xskbcx_cxXsgrkb.html';

  /** 标记"今天已成功查询识别课表"（学期 + 日期） */
  private static markCoursesFetched(termId: string): void {
    DataStore.put(DataStore.KEY_COURSES_FETCH, `${termId}|${DateUtil.format(new Date())}`);
  }

  /** 今天是否已成功查询识别过该学期课表（同一天内直接读缓存，每天只自动查询一次） */
  static coursesFetchedToday(termId: string): boolean {
    const raw: string = DataStore.get(DataStore.KEY_COURSES_FETCH);
    if (raw.length === 0) {
      return false;
    }
    const idx: number = raw.lastIndexOf('|');
    if (idx < 0) {
      return false;
    }
    const storedTerm: string = raw.substring(0, idx);
    const storedDate: string = raw.substring(idx + 1);
    return storedTerm === termId && storedDate === DateUtil.format(new Date());
  }

  /**
   * 课表智能获取：默认**每天只查询识别一次**（当天已有成功记录 → 直接返回缓存，不再请求教务系统）；
   * force=true 时强制重新查询识别（课表页刷新按钮、原文件缺失需要重取时）。
   * 获取失败时回退上次成功缓存（有缓存返回缓存，无缓存才抛出）。
   */
  static async getCoursesSmart(termId: string, force: boolean): Promise<CourseItem[]> {
    const key: string = `${termId}|${force}`;
    const running: Promise<CourseItem[]> | undefined = JwApi.coursesInflight.get(key);
    if (running !== undefined) {
      return running;
    }
    const task: Promise<CourseItem[]> = JwApi.getCoursesSmartInner(termId, force).then((v: CourseItem[]) => {
      JwApi.coursesInflight.delete(key);
      return v;
    }).catch((e: Object) => {
      JwApi.coursesInflight.delete(key);
      throw e as Error;
    });
    JwApi.coursesInflight.set(key, task);
    return task;
  }

  /** getCoursesSmart 实际执行体（单飞内层） */
  private static async getCoursesSmartInner(termId: string, force: boolean): Promise<CourseItem[]> {
    if (!force && JwApi.coursesFetchedToday(termId)) {
      const cached: CourseItem[] = JwApi.loadCachedCourses();
      if (cached.length > 0) {
        return cached;
      }
    }
    try {
      return await JwApi.getCourses(termId);
    } catch (e) {
      const cached: CourseItem[] = JwApi.loadCachedCourses();
      if (cached.length > 0) {
        LogStore.log('课表', '获取', '失败回退缓存', LogStore.errorOf(e as Object));
        return cached;
      }
      throw e as Error;
    }
  }

  /** 考试安排 */
  static async getExams(termId: string): Promise<ExamItem[]> {
    if (JwApi.USE_MOCK) {
      const list: ExamItem[] = MockData.exams();
      // 演示数据不写真实缓存（避免污染真实登录后的考试安排）
      return JwApi.delay(list, 500);
    }
    // 单飞：日志里出现过同一参数并行请求两次（refreshAll + 页面），直接复用进行中的 Promise
    const running: Promise<ExamItem[]> | undefined = JwApi.examsInflight.get(termId);
    if (running !== undefined) {
      return running;
    }
    const task: Promise<ExamItem[]> = JwApi.getExamsInner(termId).then((list: ExamItem[]) => {
      JwApi.examsInflight.delete(termId);
      return list;
    }).catch((err: Object) => {
      JwApi.examsInflight.delete(termId);
      throw err as Error;
    });
    JwApi.examsInflight.set(termId, task);
    try {
      return await task;
    } catch (e) {
      const cached: ExamItem[] = JwApi.loadCachedExams(termId);
      if (cached.length > 0) {
        LogStore.log('考试', '获取', '失败回退缓存', LogStore.errorOf(e as Object));
        return cached;
      }
      throw e as Error;
    }
  }

  /** 考试安排真实拉取（内部，失败由 getExams 统一回退缓存） */
  private static async getExamsInner(termId: string): Promise<ExamItem[]> {
    const parts: string[] = termId.split('-');
    const xnm: string = parts[0];
    const xqm: string = JwApi.xqmOf(termId);
    // 补全分页/排序参数：缺 showCount 时教务默认每页 10 条，考试多于一页会被截断（表现为"考试不全"）
    const res: HttpResult = await HttpClient.postForm('/jwglxt/kwgl/kscx_cxXsksxxIndex.html', {
      'doType': 'query',
      'xnm': xnm,
      'xqm': xqm,
      'queryModel.showCount': '100',
      'queryModel.currentPage': '1',
      'queryModel.sortName': 'kssj',
      'queryModel.sortOrder': 'asc'
    });
    let root: ESObject;
    try {
      root = JSON.parse(res.body);
    } catch (e) {
      LogStore.logNet(T('考试'), '解析', T('异常'),
        { url: '/jwglxt/kwgl/kscx_cxXsksxxIndex.html', status: `${res.code}`, error: LogStore.errorOf(e as Object), body: res.body, detail: `xnm=${xnm} xqm=${xqm}` });
      throw e as Error;
    }
    const items: ESObject[] = (root['items'] as ESObject[]) ?? [];
    const list: ExamItem[] = [];
    for (let i = 0; i < items.length; i++) {
      list.push(JwApi.mapExam(items[i]));
    }
    // 按学期分别缓存：同一键会被不同学期的结果互相覆盖，切回上学期会读到别的学期考试
    DataStore.cacheJSON(JwApi.examCacheKey(termId), JSON.stringify(list));
    LogStore.logNet(T('考试'), '获取', T('成功'),
      { url: '/jwglxt/kwgl/kscx_cxXsksxxIndex.html', status: `${res.code}`, detail: `${list.length}条 xnm=${xnm} xqm=${xqm}` });
    return list;
  }

  /** 考试缓存键（按学期隔离） */
  private static examCacheKey(termId: string): string {
    // v2：修正课程名字段（kcmc）后升版，旧缓存里的「学期期末考试」标题自然失效
    return `cache_exams_v2_${termId}`;
  }

  /** 等级考试（考级项目报名 kjbm_cxXskjbm）请求 URL（xmlbfl 只能放 query，不能进 body） */
  private static readonly LEVEL_EXAM_URL: string =
    '/jwglxt/kjgl/kjbm_cxXskjbm.html?doType=query&pkey=&xmlbfl=1001&gnmkdm=N2510';

  /**
   * 等级考试成绩（四六级 CET4/CET6 + 全国计算机等级）。
   * 南医大无独立「等级考试成绩查询」模块，四六级与计算机等级成绩都挤在
   * 「考级项目报名」接口 kjbm_cxXskjbm.html?doType=query 的列表里。
   * 关键：通过判定只能用 xmcj（项目成绩），不能用 shjg（那是报名审核，不是考试通过）。
   */
  static async getLevelExams(): Promise<LevelExamSummary> {
    const empty: LevelExamSummary = {
      hasData: false, cet4: -1, cet4Passed: false, cet6: -1, cet6Passed: false,
      computerName: '', computerPassed: false, items: []
    };
    if (JwApi.USE_MOCK) {
      return JwApi.delay(MockData.levelExams(), 300);
    }
    try {
      const res: HttpResult = await HttpClient.postForm(JwApi.LEVEL_EXAM_URL, {
        '_search': 'false',
        'nd': `${Date.now()}`,
        'queryModel.showCount': '500',
        'queryModel.currentPage': '1',
        'queryModel.sortName': 'bmsj ',
        'queryModel.sortOrder': 'desc',
        'time': '0'
      });
      const root: ESObject = JSON.parse(res.body);
      const items: ESObject[] = (root['items'] as ESObject[]) ?? [];
      const list: LevelExamItem[] = [];
      for (let i = 0; i < items.length; i++) {
        const it: ESObject = items[i];
        const catCode: string = (it['xmlbdm'] as string) ?? '';
        // 过滤火车票优惠卡（03）等无成绩项目，只留 CET(05) 与全国计算机(08)
        if (catCode !== '05' && catCode !== '08') {
          continue;
        }
        const scoreRaw: string = (it['xmcj'] as string) ?? '';
        list.push({
          id: (it['xsbmqk_id'] as string) ?? '',
          categoryCode: catCode,
          categoryName: (it['xmlbmc'] as string) ?? '',
          name: (it['xmmc'] as string) ?? '',
          score: scoreRaw,
          examTime: (it['kssj'] as string) ?? '',
          schoolYear: (it['xnmc'] as string) ?? '',
          certNo: (it['zsbh'] as string) ?? ''
        });
      }
      const summary: LevelExamSummary = JwApi.summarizeLevelExams(list);
      DataStore.cacheJSON(DataStore.KEY_LEVEL_EXAMS, JSON.stringify(summary));
      LogStore.logNet(T('等级考试'), '获取', T('成功'),
        { url: JwApi.LEVEL_EXAM_URL, status: `${res.code}`, detail: `${list.length}条` });
      return summary;
    } catch (e) {
      LogStore.log('等级考试', '获取', '失败', LogStore.errorOf(e as Object));
      return empty;
    }
  }

  /** 汇总等级考试记录：按类别取最优成绩 + 通过判定（CET≥425，计算机"合格"档） */
  private static summarizeLevelExams(items: LevelExamItem[]): LevelExamSummary {
    const out: LevelExamSummary = {
      hasData: items.length > 0, cet4: -1, cet4Passed: false, cet6: -1, cet6Passed: false,
      computerName: '', computerPassed: false, items: items
    };
    for (const it of items) {
      if (it.categoryCode === '05') {
        // CET：取 float(xmcj) 最高分
        const num: number = JwApi.levelExamScoreNumber(it.score);
        if (it.name.indexOf('CET4') >= 0 || it.name.indexOf('四级') >= 0) {
          if (num > out.cet4) {
            out.cet4 = num;
          }
        } else if (it.name.indexOf('CET6') >= 0 || it.name.indexOf('六级') >= 0) {
          if (num > out.cet6) {
            out.cet6 = num;
          }
        }
      } else if (it.categoryCode === '08') {
        // 全国计算机：任一条 xmcj 为"合格"档即通过
        if (JwApi.levelExamComputerPassed(it.score)) {
          out.computerPassed = true;
        }
        if (out.computerName.length === 0 && it.name.length > 0) {
          out.computerName = it.name;
        }
      }
    }
    out.cet4Passed = out.cet4 >= 425;
    out.cet6Passed = out.cet6 >= 425;
    return out;
  }

  /** 等级考试分数转数字：数字字符串转 float，中文/空返回 -1 */
  private static levelExamScoreNumber(score: string): number {
    const t: string = (score ?? '').trim();
    if (t.length === 0) {
      return -1;
    }
    const num: number = Number(t);
    if (isNaN(num)) {
      return -1;
    }
    return num;
  }

  /** 计算机等级是否通过：xmcj 为"合格"档（合格/优秀/良好等非"不及格/不合格"） */
  private static levelExamComputerPassed(score: string): boolean {
    const t: string = (score ?? '').trim();
    if (t.length === 0) {
      return false;
    }
    if (t.indexOf('不合格') >= 0 || t.indexOf('不及格') >= 0) {
      return false;
    }
    // 五级制合格档：合格 / 良好 / 优秀 / 中等 / 及格 均视为通过
    return t.indexOf('合格') >= 0 || t.indexOf('良好') >= 0 || t.indexOf('优秀') >= 0
      || t.indexOf('中等') >= 0 || t.indexOf('及格') >= 0 || t.indexOf('通过') >= 0;
  }

  /** 读取等级考试缓存（无返回 null） */
  static loadCachedLevelExams(): LevelExamSummary | null {
    if (JwApi.USE_MOCK) {
      return null;
    }
    const raw: string = DataStore.loadJSON(DataStore.KEY_LEVEL_EXAMS);
    if (raw.length === 0) {
      return null;
    }
    try {
      return JSON.parse(raw) as LevelExamSummary;
    } catch (e) {
      return null;
    }
  }

  /** 读取缓存中的培养方案完成情况（功能浏览模式不读真实缓存） */
  static loadCachedPlanProgress(): PlanProgress | null {
    if (JwApi.USE_MOCK) {
      return null;
    }
    const raw: string = DataStore.loadJSON(DataStore.KEY_PLAN_PROGRESS);
    if (raw.length === 0) {
      return null;
    }
    try {
      return JSON.parse(raw) as PlanProgress;
    } catch (e) {
      return null;
    }
  }

  /** 学期列表：本地生成（与正方学年/学期 select 一致，不依赖网络），保证学年学期选择可用 */
  static async getTerms(): Promise<TermInfo[]> {
    if (JwApi.USE_MOCK) {
      return JwApi.delay(MockData.terms(JwApi.term), 150);
    }
    return JwApi.buildLocalTerms();
  }

  /** 各学期成绩（默认当前学期，可传入指定学期 id 如 2024-2025-2） */
  static async getTermScores(termId?: string): Promise<TermScore[]> {
    const key: string = termId ?? '';
    const running: Promise<TermScore[]> | undefined = JwApi.scoresInflight.get(key);
    if (running !== undefined) {
      return running;
    }
    const task: Promise<TermScore[]> = JwApi.getTermScoresFetch(termId).then((v: TermScore[]) => {
      JwApi.scoresInflight.delete(key);
      return v;
    }).catch((e: Object) => {
      JwApi.scoresInflight.delete(key);
      throw e as Error;
    });
    JwApi.scoresInflight.set(key, task);
    return task;
  }

  /** getTermScores 的外层（mock + 失败回退缓存），真实拉取在 getTermScoresInner */
  private static async getTermScoresFetch(termId?: string): Promise<TermScore[]> {
    if (JwApi.USE_MOCK) {
      return JwApi.delay(MockData.termScores(MockData.terms(JwApi.term)), 600);
    }
    const realTermId: string = termId ?? JwApi.term.id;
    try {
      return await JwApi.getTermScoresInner(realTermId);
    } catch (e) {
      // 失败回退缓存：仅当前学期有缓存（其他学期成绩不落缓存）
      if (realTermId === JwApi.term.id) {
        const cached: TermScore[] = JwApi.loadCachedTermScores();
        if (cached.length > 0) {
          LogStore.log('成绩', '获取', '失败回退缓存', LogStore.errorOf(e as Object));
          return cached;
        }
      }
      throw e as Error;
    }
  }

  /** 各学期成绩真实拉取（内部，失败由 getTermScores 统一回退缓存） */
  private static async getTermScoresInner(realTermId: string): Promise<TermScore[]> {
    const parts: string[] = realTermId.split('-');
    const xnm: string = parts[0];
    const xqm: string = JwApi.xqmOf(realTermId);
    const res: HttpResult = await HttpClient.postForm('/jwglxt/cjcx/cjcx_cxDgXscj.html',
      { 'doType': 'query', 'xnm': xnm, 'xqm': xqm, 'queryModel.showCount': '100' });
    const root: ESObject = JSON.parse(res.body);
    const items: ESObject[] = (root['items'] as ESObject[]) ?? [];
    const scores: ScoreItem[] = [];
    for (let i = 0; i < items.length; i++) {
      scores.push(JwApi.mapScore(items[i], realTermId));
    }
    let gpaW: number = 0;
    let creditSum: number = 0;
    let scoreSum: number = 0;
    let scoreCount: number = 0;
    for (const s of scores) {
      gpaW += s.gradePoint * s.credit;
      creditSum += s.credit;
      if (s.score > 0) {
        scoreSum += s.score;
        scoreCount++;
      }
    }
    // 查询学期 label（用 JwApi.terms 映射，未找到时回退为 id）
    const termLabel: string = JwApi.term.id === realTermId ? JwApi.term.label : realTermId;
    const ts: TermScore = {
      termId: realTermId,
      termLabel: termLabel,
      gpa: creditSum > 0 ? gpaW / creditSum : 0,
      avgScore: scoreCount > 0 ? scoreSum / scoreCount : 0,
      totalCredit: creditSum,
      earnedCredit: creditSum,
      rank: 0, // 学校不允许查看排名
      classSize: 0,
      items: scores
    };
    const result: TermScore[] = [ts];
    // 仅缓存当前学期成绩，避免把其他学期的成绩覆盖掉
    if (realTermId === JwApi.term.id) {
      DataStore.cacheJSON(DataStore.KEY_TERM_SCORES, JSON.stringify(result));
    }
    LogStore.logNet(T('成绩'), '获取', T('成功'),
      { method: 'POST', url: '/jwglxt/cjcx/cjcx_cxDgXscj.html', status: `${res.code}`,
        detail: `${scores.length}条 GPA=${ts.gpa.toFixed(2)} ${termLabel}` });
    return result;
  }

  /** 消息/通知（真实接口：POST /jwglxt/xtgl/index_cxDbsy.html?doType=query
   *  Form: sfyy=0(全部)/1(已阅)/2(待阅) + queryModel.sortName=cjsj+(末尾空格) -> JSON items[]
   *  状态字段是 clzt：0=已处理(已读)、2=未处理(未读)；xxbt=标题、xxnr=正文、cjsj=创建时间。
   *  注：sfyy 不是分页，是读未读筛选；totalResult 在 items 内是字符串。 */
  static async getNotices(): Promise<NoticeItem[]> {
    if (JwApi.USE_MOCK) {
      const list: NoticeItem[] = MockData.notices();
      // 演示数据不写真实缓存（避免污染真实登录后的消息列表）
      return JwApi.delay(list, 400);
    }
    // 并发单飞：refreshAll 与首页 loadData 常同时请求通知，去重后只发一次网络请求
    if (JwApi.noticesInflight !== null) {
      return JwApi.noticesInflight;
    }
    const task: Promise<NoticeItem[]> = JwApi.getNoticesInner();
    JwApi.noticesInflight = task;
    try {
      return await task;
    } finally {
      JwApi.noticesInflight = null;
    }
  }

  /** 通知真实拉取（内部） */
  private static async getNoticesInner(): Promise<NoticeItem[]> {
    // 真实拉取（POST 表单，sfyy=0 拉全部消息，按创建时间倒序）。
    // 注意：缓存秒开由页面层 loadCachedNotices 负责，这里始终拉最新，避免旧缓存一直显示。
    try {
      const res: HttpResult = await HttpClient.postForm(
        '/jwglxt/xtgl/index_cxDbsy.html?doType=query',
        {
          'sfyy': '0',
          'flag': '',
          '_search': 'false',
          'nd': `${Date.now()}`,
          'queryModel.showCount': '50',
          'queryModel.currentPage': '1',
          'queryModel.sortName': 'cjsj ',
          'queryModel.sortOrder': 'desc',
          'time': '1'
        });
      const root: ESObject = JSON.parse(res.body);
      const items: ESObject[] = (root['items'] as ESObject[]) ?? [];
      const list: NoticeItem[] = [];
      let index: number = 0;
      for (let i = 0; i < items.length; i++) {
        const it: ESObject = items[i];
        const title: string = (it['xxbt'] as string) ?? '';
        const content: string = (it['xxnr'] as string) ?? '';
        if (title.length < 2 && content.length < 2) {
          continue;
        }
        const cjsj: string = (it['cjsj'] as string) ?? '';
        const date: string = cjsj.length >= 19 ? cjsj.substring(0, 19) : cjsj;
        // clzt：0=已处理(已读)、2=未处理(未读)
        const read: boolean = `${it['clzt']}` !== '2';
        index += 1;
        list.push({
          id: `n${index}-${date}`,
          title: title.length > 0 ? title : content,
          // jsmc 是角色名（"学生"），无展示意义；消息来源统一标"教务处"
          source: '教务处',
          date: date,
          tag: T('通知'),
          isTop: false,
          read: read,
          summary: content,
          content: content.length > 0 ? content : title,
          url: ''
        });
      }
      DataStore.cacheJSON(DataStore.KEY_NOTICES, JSON.stringify(list));
      LogStore.logNet(T('通知'), '加载', T('成功'),
        { method: 'POST', url: '/jwglxt/xtgl/index_cxDbsy.html', status: `${res.code}`, detail: `${list.length}条` });
      return list;
    } catch (e) {
      LogStore.log('通知', '加载', '失败', LogStore.errorOf(e as Object));
      // 失败回退上次成功缓存（有缓存返回缓存，无缓存才返回空数组）
      const cached: NoticeItem[] = JwApi.loadCachedNotices();
      if (cached.length > 0) {
        LogStore.log('通知', '加载', '失败回退缓存', `缓存${cached.length}条`);
        return cached;
      }
      return [];
    }
  }

  /**
   * 教务处官网「学期校历」通知：GET Const.JWC_LIST_URL（/jxrl_3318/list.htm）取最新两条文章。
   * mock：MockData.jwcNotices()；真实：解析列表页 li.news 取前两条并缓存（KEY_NOTICES_JWC）。
   */
  static async getJwcNotices(): Promise<NoticeItem[]> {
    if (JwApi.USE_MOCK) {
      return JwApi.delay(MockData.jwcNotices(), 300);
    }
    const cached: string = DataStore.loadJSON(DataStore.KEY_NOTICES_JWC);
    if (cached.length > 0) {
      try {
        const cl: NoticeItem[] = JSON.parse(cached) as NoticeItem[];
        LogStore.log('通知', '官网读取', '缓存命中', `${cl.length}条`);
        return cl;
      } catch (e) {
        // ignore
      }
    }
    try {
      const res: HttpResult = await HttpClient.get(Const.JWC_LIST_URL);
      const list: NoticeItem[] = JwApi.parseJwcListNotices(res.body);
      if (list.length > 0) {
        DataStore.cacheJSON(DataStore.KEY_NOTICES_JWC, JSON.stringify(list));
      }
      LogStore.logNet(T('通知'), '官网列表', T('成功'),
        { method: 'GET', url: Const.JWC_LIST_URL, status: `${res.code}`, detail: `${list.length}条` });
      return list;
    } catch (e) {
      LogStore.log('通知', '官网列表', '失败', LogStore.errorOf(e as Object));
      return [];
    }
  }

  /** 解析南医大官网「通知公告」栏目列表（www.njmu.edu.cn/607/list.htm，column-news-item DOM），取最新若干条 */
  private static parseJwcListNotices(html: string): NoticeItem[] {
    const out: NoticeItem[] = [];
    // 南医大官网列表项：<a class="... column-news-item ..." href="..." >标题<span>日期</span></a>
    const itemRegex: RegExp = /<a[^>]*class="[^"]*column-news-item[^"]*"[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/gi;
    let m: ESObject | null = itemRegex.exec(html);
    while (m !== null && out.length < 5) {
      const href: string = m[1];
      const body: string = m[2];
      const tMatch: ESObject | null = /<span[^>]*class="[^"]*column-news-title[^"]*"[^>]*>([\s\S]*?)<\/span>/i.exec(body);
      const dMatch: ESObject | null = /<span[^>]*class="[^"]*column-news-date[^"]*"[^>]*>([\s\S]*?)<\/span>/i.exec(body);
      const title: string = tMatch !== null ? tMatch[1].replace(/<[^>]+>/g, '').trim() : body.replace(/<[^>]+>/g, '').trim();
      if (title.length > 2) {
        const date: string = dMatch !== null ? dMatch[1].replace(/<[^>]+>/g, '').trim() : '';
        out.push({
          id: `jwc-${out.length + 1}`,
          title: title,
          source: '南京医科大学官网',
          date: date,
          tag: T('通知'),
          isTop: out.length === 0,
          read: false,
          summary: title,
          content: title,
          url: JwApi.absJwcUrl(href)
        });
      }
      m = itemRegex.exec(html);
    }
    // 兜底：官网 DOM 结构变化时，退回通用 <li>/<a> 抓取，保证不空
    if (out.length === 0) {
      const re2: RegExp = /<li[^>]*>([\s\S]{0,600}?)<\/li>/gi;
      let m2: ESObject | null = re2.exec(html);
      while (m2 !== null && out.length < 5) {
        const li: string = m2[1];
        const am: ESObject | null = /<a[^>]+href="([^"]+)"[^>]*>([\s\S]{2,150}?)<\/a>/i.exec(li);
        if (am !== null) {
          const title: string = am[2].replace(/<[^>]+>/g, '').trim();
          if (title.length > 2) {
            const dm: ESObject | null = /(\d{4}-\d{2}-\d{2})/.exec(li);
            out.push({
              id: `jwc-${out.length + 1}`,
              title: title,
              source: '南京医科大学官网',
              date: dm !== null ? dm[1] : '',
              tag: T('通知'),
              isTop: out.length === 0,
              read: false,
              summary: title,
              content: title,
              url: JwApi.absJwcUrl(am[1])
            });
          }
        }
        m2 = re2.exec(html);
      }
    }
    return out;
  }

  /** 相对链接转绝对（官网 www.njmu.edu.cn / 教学管理处 jxglc.njmu.edu.cn；已绝对地址原样返回） */
  private static absJwcUrl(href: string, baseHost: string = 'www.njmu.edu.cn'): string {
    if (href.startsWith('http')) {
      return href;
    }
    if (href.startsWith('//')) {
      return 'https:' + href;
    }
    return href.startsWith('/') ? `https://${baseHost}${href}` : `https://${baseHost}/${href}`;
  }

  /** 从校历栏目列表页取最新一条校历文章 URL（返回绝对地址，无则空串）。
   *  2026-10 实测：教学管理处「下载专区」列表 DOM 为 <li class="news n1 clearfix">
   *  <a href='/2026/0407/c20004a299333/page.htm' target='_blank' title='2026-2027学年校历'>（单引号属性）。 */
  private static firstCalendarArticle(html: string): string {
    // 优先匹配 title 含「校历」的文章链接（单引号属性）
    const re1: RegExp = /<a[^>]*href=['"]([^'"]+page\.htm)['"][^>]*title=['"]([^'"]*校历[^'"]*)['"]/gi;
    let m1: ESObject | null = re1.exec(html);
    if (m1 !== null) {
      return JwApi.absJwcUrl(String(m1[1]), 'jxglc.njmu.edu.cn');
    }
    // 兜底：匹配任意 page.htm 链接（旧 DOM / 无 title）
    const re2: RegExp = /<a[^>]+href=['"]([^'"]+page\.htm)['"][^>]*>([\s\S]{0,150}?)<\/a>/gi;
    let m2: ESObject | null = re2.exec(html);
    while (m2 !== null) {
      const title: string = String(m2[2]).replace(/<[^>]+>/g, '').trim();
      if (title.indexOf('校历') >= 0 || title.length > 0) {
        return JwApi.absJwcUrl(String(m2[1]), 'jxglc.njmu.edu.cn');
      }
      m2 = re2.exec(html);
    }
    return '';
  }

  /** 从校历文章页提取附件 URL（校历附件为 xlsx/jpg，返回绝对地址，无则空串） */
  private static async findCalendarPdfUrl(articleUrl: string): Promise<string> {
    try {
      const res: HttpResult = await HttpClient.get(articleUrl);
      // 校历附件优先 xlsx/jpg（教学管理处「下载专区」），兼容 pdf
      const pm: ESObject | null = /href=["']([^"']+\.(?:xlsx|jpg|jpeg|png|pdf)[^"']*)["']/i.exec(res.body);
      if (pm !== null) {
        return JwApi.absJwcUrl(String(pm[1]), 'jxglc.njmu.edu.cn');
      }
    } catch (e) {
      // ignore
    }
    return '';
  }

  /** 内置校历转换结果（预置的"最新校历 PDF 转换数据"，真实模式兜底） */
  static builtinCal(): TeachingCalendar | null {
    try {
      return JSON.parse(MockData.jwcCalendarJson()) as TeachingCalendar;
    } catch (e) {
      return null;
    }
  }

  /** 从缓存原始串中解出 TeachingCalendar（无则 null） */
  private static cachedCal(raw: string): TeachingCalendar | null {
    if (raw.length === 0) {
      return null;
    }
    try {
      const obj: ESObject = JSON.parse(raw);
      const data: string = (obj['data'] as string) ?? '';
      if (data.length > 0) {
        return JSON.parse(data) as TeachingCalendar;
      }
    } catch (e) {
      // ignore
    }
    return null;
  }

  /**
   * 校历（日历）：数据源为南医大教学管理处官网「下载专区」（Const.JXRL_LIST_URL / 20004/list.htm）。
   * 流程：列表 → 最新校历文章 → 文章页附件（xlsx/jpg）→ 转换结果缓存（KEY_JWC_CAL）。
   * 转换完成后的数据直接缓存；重新获取时对比最新文章 URL（来源），无变化直接用缓存，有变化才更新。
   * 说明：客户端受限于 PDF 表头为矢量图无法可靠自动转换，转换结果由预置数据（MockData.jwcCalendarJson，
   * 即沙箱内由最新校历转换生成）提供；真实模式负责抓取来源与变化检测。
   */
  static async getTeachingCalendar(): Promise<TeachingCalendar | null> {
    if (JwApi.USE_MOCK) {
      return JwApi.builtinCal();
    }
    // 1) 缓存秒开
    const cachedRaw: string = DataStore.loadJSON(DataStore.KEY_JWC_CAL);
    const cached: TeachingCalendar | null = JwApi.cachedCal(cachedRaw);
    let cachedSrc: string = '';
    if (cachedRaw.length > 0) {
      try {
        const obj: ESObject = JSON.parse(cachedRaw);
        cachedSrc = (obj['sourceArticleUrl'] as string) ?? '';
      } catch (e) {
        // ignore
      }
    }
    try {
      // 2) 拉列表，取最新校历文章 URL（教学管理处官网，桌面 UA 避免被门户拦截）
      const calHeader: Record<string, string> = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
      };
      const res: HttpResult = await HttpClient.getExtra(Const.JXRL_LIST_URL, calHeader);
      LogStore.logNet(T('校历'), '拉取', T('成功'),
        { method: 'GET', url: Const.JXRL_LIST_URL, status: `${res.code}`, detail: `本地缓存=${cached !== null ? '有' : '无'}` });
      const article: string = JwApi.firstCalendarArticle(res.body);
      if (article.length === 0) {
        LogStore.log('校历', '解析', '无文章', '列表页未匹配到校历文章');
        return cached !== null ? cached : JwApi.builtinCal();
      }
      // 3) 来源无变化 → 直接返回缓存（不更新）
      if (cached !== null && article === cachedSrc) {
        LogStore.log('校历', '更新', '来源未变', article);
        return cached;
      }
      // 4) 来源有变化 → 找 PDF、更新来源标记；转换结果以缓存/预置兜底
      const pdfUrl: string = await JwApi.findCalendarPdfUrl(article);
      const cal: TeachingCalendar | null = cached !== null ? cached : JwApi.builtinCal();
      if (cal !== null) {
        const store: JwcCalCacheStore = {
          'sourceArticleUrl': article,
          'sourcePdfUrl': pdfUrl,
          'data': JSON.stringify(cal)
        };
        DataStore.cacheJSON(DataStore.KEY_JWC_CAL, JSON.stringify(store));
      }
      LogStore.log('校历', '更新', '成功', `新来源 ${article}`);
      return cal;
    } catch (e) {
      LogStore.log('校历', '拉取', '失败', LogStore.errorOf(e as Object));
      // 网络失败也回退内置校历（官方 xlsx 数据已内置），绝不返回 null 导致日历空转
      return cached !== null ? cached : JwApi.builtinCal();
    }
  }

  /**
   * 拉取学生证件照（/jwglxt/xtgl/photo_cxXszp4.html?xh_id=&zplx=rxhzp）。
   * 返回 base64（不含 data: 前缀）；失败/未登录返回空串。
   */
  static async getPhoto(): Promise<string> {
    if (JwApi.USE_MOCK) {
      return '';
    }
    // 优先读缓存
    const cached: string = DataStore.loadJSON(DataStore.KEY_PHOTO);
    if (cached.length > 0) {
      return cached;
    }
    const sid: string = AppState.account.length > 0 ? AppState.account : (AppState.profile?.studentId ?? '');
    if (sid.length === 0) {
      return '';
    }
    try {
      const b64: string = await HttpClient.getImageBase64(`/jwglxt/xtgl/photo_cxXszp4.html?xh_id=${sid}&zplx=rxhzp&_t=${Date.now()}`);
      if (b64.length > 0) {
        DataStore.cacheJSON(DataStore.KEY_PHOTO, b64);
      }
      return b64;
    } catch (e) {
      return '';
    }
  }

  /**
   * 登录成功 / 手动刷新时：把课表、成绩、考试、学业、消息、头像全部重新拉取并写入本地缓存。
   * 界面可先用旧缓存秒开，后台静默刷新覆盖。
   *
   * ★ 单飞锁：并发调用（日志实测 3 秒内被触发 7 次）只执行一次，其余复用同一个 Promise。
   * ★ 广播前置：五接口完成后立即写缓存+广播+成功日志；头像/资料移到广播之后异步执行，
   *   绝不阻塞广播（此前广播排在最后，任一环节卡住/抛异常 → 首页回填永不触发 → 首页空白）。
   */
  static async refreshAll(): Promise<void> {
    if (JwApi.USE_MOCK) {
      return;
    }
    if (JwApi.refreshInflight !== null) {
      return JwApi.refreshInflight;
    }
    // 节流：2s 内重复触发直接忽略（日志实测曾出现每秒一次连刷 10 次，避免网络风暴与日志刷屏）
    const now: number = Date.now();
    if (now - JwApi.lastRefreshAt < 2000) {
      return;
    }
    JwApi.lastRefreshAt = now;
    const task: Promise<void> = JwApi.refreshAllInner();
    JwApi.refreshInflight = task;
    try {
      await task;
    } finally {
      JwApi.refreshInflight = null;
    }
  }

  /** refreshAll 实际执行体（由 refreshAll 单飞包裹） */
  private static async refreshAllInner(): Promise<void> {
    LogStore.log('首页', '刷新', '开始', '并行拉取课表/成绩/考试/学业/通知（失败回退缓存）');
    try {
      const term: TermInfo = JwApi.term;

      // 容错拉取：每个子任务独立 catch，失败回退上次成功缓存，单点失败不拖垮整体。
      // 返回 [数据, 是否来自缓存] 以便汇总刷新状态提示。
      // ★ 并行发起（总耗时≈最慢一个，而非串行累加），加速登录后首页数据就绪。
      const pCourses: Promise<FetchResult<CourseItem[]>> =
        JwApi.safeFetch(T('课表'), () => JwApi.getCoursesSmart(term.id, false), JwApi.loadCachedCourses());
      const pScores: Promise<FetchResult<TermScore[]>> =
        JwApi.safeFetch(T('成绩'), () => JwApi.getTermScores(), JwApi.loadCachedTermScores());
      const pExams: Promise<FetchResult<ExamItem[]>> =
        JwApi.safeFetch(T('考试'), () => JwApi.getExams(term.id), JwApi.loadCachedExams());
      const pAcademic: Promise<FetchResult<AcademicReport>> =
        JwApi.safeFetch(T('学业'), () => JwApi.getAcademic(), JwApi.loadCachedAcademic());
      const pNotices: Promise<FetchResult<NoticeItem[]>> =
        JwApi.safeFetch(T('通知'), () => JwApi.getNotices(), JwApi.loadCachedNotices());

      const coursesRes: FetchResult<CourseItem[]> = await pCourses;
      const scoresRes: FetchResult<TermScore[]> = await pScores;
      const examsRes: FetchResult<ExamItem[]> = await pExams;
      const academicRes: FetchResult<AcademicReport> = await pAcademic;
      const noticesRes: FetchResult<NoticeItem[]> = await pNotices;

      const courses: CourseItem[] = coursesRes.data;
      const scores: TermScore[] = scoresRes.data;
      const exams: ExamItem[] = examsRes.data;
      const academic: AcademicReport = academicRes.data;
      const notices: NoticeItem[] = noticesRes.data;

      DataStore.cacheJSON(DataStore.KEY_COURSES, JSON.stringify(courses));
      DataStore.cacheJSON(DataStore.KEY_TERM_SCORES, JSON.stringify(scores));
      DataStore.cacheJSON(DataStore.KEY_EXAMS, JSON.stringify(exams));
      DataStore.cacheJSON(DataStore.KEY_ACADEMIC, JSON.stringify(academic));
      DataStore.cacheJSON(DataStore.KEY_NOTICES, JSON.stringify(notices));

      // ★ 广播前置：缓存已写入，立即广播 + 成功日志（首页据此回填），不再被 profile/photo 阻塞
      const fromCacheCount: number =
        (coursesRes.fromCache ? 1 : 0) + (scoresRes.fromCache ? 1 : 0) +
        (examsRes.fromCache ? 1 : 0) + (academicRes.fromCache ? 1 : 0) + (noticesRes.fromCache ? 1 : 0);
      const status: RefreshStatus = {
        allFresh: fromCacheCount === 0,
        fromCacheCount: fromCacheCount,
        totalCount: 5,
        time: Date.now()
      };
      AppStorage.setOrCreate(JwApi.KEY_REFRESH_STATUS, status);
      // 五接口全部成功拿到真实数据 → 会话有效，清除「登录已过期」标记
      if (fromCacheCount === 0) {
        HttpClient.clearSessionExpired();
      }
      LogStore.log('首页', '刷新', '成功',
        `课表${courses.length}节 成绩${scores.length}学期 考试${exams.length}门 学业GPA=${academic.gpa} 通知${notices.length}条（${fromCacheCount}项来自缓存）`);
      DataStore.put(DataStore.KEY_CACHE_TIME, `${Date.now()}`);
    } catch (e) {
      // 全局兜底：任何未预期异常也必须广播 + 记录（否则首页回填永不触发，且问题无从排查）
      LogStore.log('首页', '刷新', '异常', LogStore.errorOf(e as Object));
      const status: RefreshStatus = {
        allFresh: false,
        fromCacheCount: 5,
        totalCount: 5,
        time: Date.now()
      };
      AppStorage.setOrCreate(JwApi.KEY_REFRESH_STATUS, status);
    }
    // 会话过期自动恢复：本轮刷新已检测到会话失效 → 后台静默重登并自动重拉（失败才提示手动重登）
    JwApi.autoRecoverIfNeeded();
    // 头像与资料：广播之后异步执行（fire-and-forget，各带 10s 超时，绝不阻塞/绝不抛出）
    JwApi.refreshProfilePhoto();
  }

  /** 清除可能被「功能浏览模式」演示数据污染的缓存（切回真实登录时调用一次）。
   *  历史版本 mock 分支会把演示课表/考试/通知/学业写入真实缓存键，
   *  导致真实登录后首页出现演示学生数据，这里统一清理。 */
  static clearMockPollutedCache(): void {
    const keys: string[] = [DataStore.KEY_COURSES, DataStore.KEY_EXAMS, DataStore.KEY_NOTICES,
      DataStore.KEY_ACADEMIC, DataStore.KEY_TERM_SCORES, DataStore.KEY_COURSES_FETCH];
    for (let i: number = 0; i < keys.length; i++) {
      DataStore.remove(keys[i]);
    }
    // 内存层必须一起清：loadCachedCourses 命中内存层时会继续返回旧/演示数据
    JwApi.coursesMem = null;
    JwApi.coursesMemStamp = '';
    JwApi.examsMem.clear();
    JwApi.examsMemStamp = '';
    DataStore.remove(DataStore.KEY_CACHE_TIME);
    LogStore.log('数据', '缓存', '清理演示数据', `已清 ${keys.length} 项缓存键（含内存层）`);
  }

  /** 重置刷新节流（网络恢复 / 手动重登 / 会话恢复成功后应立即重拉） */
  static lastRefreshReset(): void {
    JwApi.lastRefreshAt = 0;
  }

  /** 单飞锁：并发 refreshAll 去重 */
  private static refreshInflight: Promise<void> | null = null;
  /** 上次 refreshAll 触发时间（节流：2s 内重复触发忽略） */
  private static lastRefreshAt: number = 0;
  /** 会话自动恢复：进行中标记 + 本进程已尝试次数（上限 2） */
  private static recovering: boolean = false;
  private static recoverCount: number = 0;

  /** 单飞锁：通知并发请求去重（refreshAll 与首页同时拉取时只发一次） */
  private static noticesInflight: Promise<NoticeItem[]> | null = null;
  /** 课表缓存内存层（避免每次回填都读文件 + JSON.parse 116 条） */
  private static coursesMem: CourseItem[] | null = null;
  private static coursesMemStamp: string = '';
  /** 考试缓存内存层（按学期，键为 termId） */
  private static examsMem: Map<string, ExamItem[]> = new Map<string, ExamItem[]>();
  /** 考试请求单飞（按学期）：refreshAll 与考试页并发时只发一次网络请求 */
  private static examsInflight: Map<string, Promise<ExamItem[]>> = new Map<string, Promise<ExamItem[]>>();
  /** 课表单飞（按 termId+force）：冷启动时 Index/HomeView/ScheduleView 并发打同一接口 */
  private static coursesInflight: Map<string, Promise<CourseItem[]>> = new Map<string, Promise<CourseItem[]>>();
  /** 成绩单飞（按 termId） */
  private static scoresInflight: Map<string, Promise<TermScore[]>> = new Map<string, Promise<TermScore[]>>();
  private static examsMemStamp: string = '';

  /** 带超时的 Promise 竞速（超时返回 fallback，防单个请求挂起拖死链路） */
  private static withTimeout<T>(p: Promise<T>, ms: number, fallback: T): Promise<T> {
    return new Promise<T>((resolve: (v: T) => void) => {
      let done: boolean = false;
      const timer: number = setTimeout(() => {
        if (!done) {
          done = true;
          resolve(fallback);
        }
      }, ms);
      p.then((v: T) => {
        if (!done) {
          done = true;
          clearTimeout(timer);
          resolve(v);
        }
      }).catch((_e: Object) => {
        if (!done) {
          done = true;
          clearTimeout(timer);
          resolve(fallback);
        }
      });
    });
  }

  /** 异步刷新个人资料与头像（10s 超时保护，失败静默） */
  private static async refreshProfilePhoto(): Promise<void> {
    const emptyProfile: UserProfile = {
      studentId: '', name: '', college: '', major: '', className: '', grade: '', counselor: '', eduSystem: '', status: ''
    };
    try {
      const task: Promise<UserProfile> = JwApi.getProfile().catch((_e: Object): UserProfile => emptyProfile);
      const profile: UserProfile = await JwApi.withTimeout<UserProfile>(task, 10000, emptyProfile);
      if (profile.name.length > 0) {
        AppState.profile = profile;
        DataStore.cacheProfile(profile);
      }
    } catch (e) {
      // ignore
    }
    try {
      const p: string = await JwApi.withTimeout<string>(JwApi.getPhoto(), 10000, '');
      if (p.length > 0) {
        DataStore.cacheJSON(DataStore.KEY_PHOTO, p);
      }
    } catch (e) {
      // ignore
    }
  }

  /**
   * 容错拉取：优先走 fetcher 拿最新数据，失败时回退 fallback（上次成功缓存）。
   * 回退数据为空时原样返回（调用方据长度判断），不抛异常，保证 refreshAll 永不因单点失败中断。
   */
  private static async safeFetch<T>(label: string, fetcher: () => Promise<T>, fallback: T): Promise<FetchResult<T>> {
    try {
      const data: T = await fetcher();
      // 会话失效时各接口会内部回退缓存并"正常返回"，这里按全局过期标记判定数据实为缓存，
      // 使刷新状态提示（N/5 项来自缓存）准确
      return { data: data, fromCache: AppState.sessionExpired };
    } catch (e) {
      LogStore.log('刷新', label, '失败回退缓存', LogStore.errorOf(e as Object));
      return { data: fallback, fromCache: true };
    }
  }

  /** 读取缓存中的课程表（功能浏览模式不读真实缓存，避免泄露真实用户数据；无缓存返回空数组） */
  static loadCachedCourses(): CourseItem[] {
    if (JwApi.USE_MOCK) {
      return [];
    }
    // 内存层：首页刷新广播会多次回填（课表/今日课/下一节），每次都读大值文件 + 解析 116 条开销明显。
    // 用缓存时间戳做失效判断（任何 cacheJSON 写入都会更新 KEY_CACHE_TIME）。
    const stamp: string = DataStore.get(DataStore.KEY_CACHE_TIME);
    if (JwApi.coursesMem !== null && stamp === JwApi.coursesMemStamp) {
      return JwApi.coursesMem;
    }
    const raw: string = DataStore.loadJSON(DataStore.KEY_COURSES);
    if (raw.length === 0) {
      JwApi.coursesMem = [];
      JwApi.coursesMemStamp = stamp;
      return JwApi.coursesMem;
    }
    try {
      JwApi.coursesMem = JSON.parse(raw) as CourseItem[];
    } catch (e) {
      JwApi.coursesMem = [];
    }
    JwApi.coursesMemStamp = stamp;
    return JwApi.coursesMem;
  }

  /** 读取缓存中的学期成绩（功能浏览模式不读真实缓存） */
  static loadCachedTermScores(): TermScore[] {
    if (JwApi.USE_MOCK) {
      return [];
    }
    const raw: string = DataStore.loadJSON(DataStore.KEY_TERM_SCORES);
    if (raw.length === 0) {
      return [];
    }
    try {
      return JSON.parse(raw) as TermScore[];
    } catch (e) {
      return [];
    }
  }

  /** 读取缓存中的考试安排（功能浏览模式不读真实缓存） */
  static loadCachedExams(termId?: string): ExamItem[] {
    if (JwApi.USE_MOCK) {
      return [];
    }
    const tid: string = termId ?? '';
    // 内存层：缓存时间戳未变时直接返回，避免切学期/回填时反复读大值文件
    const stamp: string = DataStore.get(DataStore.KEY_CACHE_TIME);
    if (tid.length > 0 && JwApi.examsMem.has(tid) && stamp === JwApi.examsMemStamp) {
      return JwApi.examsMem.get(tid) as ExamItem[];
    }
    let raw: string = tid.length > 0 ? DataStore.loadJSON(JwApi.examCacheKey(tid)) : '';
    // 兼容旧版本单键缓存：仅当前学期可信（旧键会被不同学期互相覆盖）
    if (raw.length === 0 && (tid.length === 0 || tid === JwApi.term.id)) {
      raw = DataStore.loadJSON(DataStore.KEY_EXAMS);
    }
    if (raw.length === 0) {
      return [];
    }
    try {
      const list: ExamItem[] = JSON.parse(raw) as ExamItem[];
      if (tid.length > 0) {
        JwApi.examsMem.clear();
        JwApi.examsMem.set(tid, list);
        JwApi.examsMemStamp = stamp;
      }
      return list;
    } catch (e) {
      return [];
    }
  }

  /** 读取缓存中的学业情况（功能浏览模式不读真实缓存） */
  static loadCachedAcademic(): AcademicReport {
    if (JwApi.USE_MOCK) {
      return EMPTY_REPORT;
    }
    const raw: string = DataStore.loadJSON(DataStore.KEY_ACADEMIC);
    if (raw.length === 0) {
      return EMPTY_REPORT;
    }
    try {
      return JSON.parse(raw) as AcademicReport;
    } catch (e) {
      return EMPTY_REPORT;
    }
  }

  /** 读取缓存中的消息列表（功能浏览模式不读真实缓存） */
  static loadCachedNotices(): NoticeItem[] {
    if (JwApi.USE_MOCK) {
      return [];
    }
    const raw: string = DataStore.loadJSON(DataStore.KEY_NOTICES);
    if (raw.length === 0) {
      return [];
    }
    try {
      return JSON.parse(raw) as NoticeItem[];
    } catch (e) {
      return [];
    }
  }

  /** 读取缓存中的学生照片 base64（功能浏览模式不读真实缓存，无则空串） */
  static loadCachedPhoto(): string {
    if (JwApi.USE_MOCK) {
      return '';
    }
    return DataStore.loadJSON(DataStore.KEY_PHOTO);
  }

  /** 上次刷新时间（时间戳），0 表示从未刷新 */
  static lastRefreshTime(): number {
    const raw: string = DataStore.get(DataStore.KEY_CACHE_TIME);
    const n: number = Number(raw);
    return isNaN(n) ? 0 : n;
  }

  /**
   * 学业情况（真实接口：GET /jwglxt/xsxy/xsxyqk_cxXsxyqkIndex.html?gnmkdm=N105515
   *  -> HTML 内嵌纯文本，去 script/标签后正则解析）。不要 POST（POST 会 500/911）。
   */
  static async getAcademic(): Promise<AcademicReport> {
    if (JwApi.USE_MOCK) {
      const report: AcademicReport = MockData.academic();
      // 演示数据不写真实缓存（避免污染真实登录后的学业数据）
      return JwApi.delay(report, 550);
    }
    // 1) 优先读本地缓存
    const cached: string = DataStore.loadJSON(DataStore.KEY_ACADEMIC);
    if (cached.length > 0) {
      try {
        const r: AcademicReport = JSON.parse(cached) as AcademicReport;
        LogStore.log('学业', '读取', '缓存命中', `GPA=${r.gpa} 分类${r.categories.length}门`);
        return r;
      } catch (e) {
        // ignore
      }
    }
    // 2) 真实拉取 + 解析
    try {
      const res: HttpResult = await HttpClient.get(
        '/jwglxt/xsxy/xsxyqk_cxXsxyqkIndex.html?gnmkdm=N105515&layout=default');
      const report: AcademicReport = JwApi.parseAcademicText(res.body);
      DataStore.cacheJSON(DataStore.KEY_ACADEMIC, JSON.stringify(report));
      LogStore.logNet(T('学业'), '加载', T('成功'),
        { method: 'GET', url: '/jwglxt/xsxy/xsxyqk_cxXsxyqkIndex.html', status: `${res.code}`,
          detail: `GPA=${report.gpa} 分类${report.categories.length}门 警告${report.warnings.length}条` });
      return report;
    } catch (e) {
      LogStore.log('学业', '加载', '失败', LogStore.errorOf(e as Object));
      return EMPTY_REPORT;
    }
  }

  /**
   * 培养方案完成情况（教学执行计划 N153540 计算）。
   * 南医大无「培养方案完成情况」页面、xsxyqk 学业情况模块也未部署（404），
   * 故「计划总门数/已通过/在读/未修/计划外/应修学分」全部由
   * 67 门课程池 ∩ 成绩(课程名) ∩ 本学期课表(课程名) 自己算。
   *
   * 数据链（2026-10 抓包实测）：
   *  ① POST jxzxjhck_cxJxzxjhckIndex.html?doType=query&gnmkdm=N153540
   *     body: jg_id/njdm_id/zyh_id → jxzxjhxx_id（计划主记录）
   *  ② POST jxzxjhkcxx_cxJxzxjhkcxxIndex.html?doType=query&gnmkdm=N153540
   *     body: jxzxjhxx_id + showCount=500 → 67 门课程池（kcmc/xf/xfyqjdmc/kcxzmc）
   *  ③ GET  jxzxjhck_cxJxzxjhxdyqIndex.html?jxzxjhxx_id=... → 类别应修学分（jdkcxf）
   */
  static async getPlanProgress(): Promise<PlanProgress> {
    const empty: PlanProgress = JwApi.emptyPlanProgress();
    if (JwApi.USE_MOCK) {
      return JwApi.delay(MockData.planProgress(), 300);
    }
    // 1) 优先读缓存（培养方案课程池稳定，按学年学期缓存）
    const cached: string = DataStore.loadJSON(DataStore.KEY_PLAN_PROGRESS);
    if (cached.length > 0) {
      try {
        const r: PlanProgress = JSON.parse(cached) as PlanProgress;
        if (r.available) {
          LogStore.log('学业', '培养方案', '缓存命中', `计划${r.totalRequired}门 已过${r.totalEarned} 在读${r.studyingCount} 未修${r.unearnedCount}`);
          return r;
        }
      } catch (e) {
        // ignore
      }
    }
    try {
      // ②-前置：拿 jxzxjhxx_id（计划主记录）
      const planId: string = await JwApi.fetchPlanId();
      if (planId.length === 0) {
        LogStore.log('学业', '培养方案', '无计划', 'jxzxjhxx_id 取不到，培养方案未下发');
        return empty;
      }
      // ②：拿 67 门课程池
      const pool: PlanCourse[] = await JwApi.fetchPlanPoolCourses(planId);
      if (pool.length === 0) {
        LogStore.log('学业', '培养方案', '无课程池', '课程池为空');
        return empty;
      }
      // ③：拿类别应修学分
      const cats: CreditCategory[] = await JwApi.fetchPlanCategories(planId);

      // ④：成绩（课程名集合，判定通过）+ 本学期课表（课程名集合）
      const passedNames: Set<string> = new Set();
      const failedNames: Set<string> = new Set();
      const scoreNames: Set<string> = new Set();
      const overall: OverallGrades = await JwApi.getOverallGrades();
      for (const s of overall.courses) {
        const nm: string = s.courseName.trim();
        if (nm.length === 0 || scoreNames.has(nm)) {
          continue;
        }
        scoreNames.add(nm);
        if (JwApi.isPassedScore(s)) {
          passedNames.add(nm);
        } else {
          failedNames.add(nm);
        }
      }
      const studyingNames: Set<string> = new Set();
      const curCourses: CourseItem[] = await JwApi.getCoursesSmart(JwApi.term.id, false);
      for (const c of curCourses) {
        if (c.name.trim().length > 0) {
          studyingNames.add(c.name.trim());
        }
      }

      // 手动已修白名单（用户自定义，课程名集合）：白名单课程视为"已通过"，优先于其它判定
      const whitelist: Set<string> = new Set();
      const wlList: string[] = DataStore.planPassWhitelist();
      for (const w of wlList) {
        if (w.length > 0) {
          whitelist.add(w);
        }
      }

      // ⑤：计算交集（课程名 trim 后匹配）
      let earned: number = 0;
      let failedInPlan: number = 0;
      let studying: number = 0;
      const unearnedList: string[] = [];
      const studyingList: string[] = [];
      for (const pc of pool) {
        const nm: string = pc.name;
        if (whitelist.has(nm)) {
          earned++; // 手动标记已修，计入已通过
        } else if (passedNames.has(nm)) {
          earned++;
        } else if (failedNames.has(nm)) {
          failedInPlan++;
        } else if (studyingNames.has(nm)) {
          studying++;
          studyingList.push(nm);
        } else {
          unearnedList.push(nm);
        }
      }
      const total: number = pool.length;
      const outside: number = JwApi.countOutside(scoreNames, pool);

      // ⑥：学分类别（已修学分按课程名匹配累加）
      const catMap: Map<string, CreditCategory> = new Map();
      for (const pc of pool) {
        const catName: string = pc.category.length > 0 ? pc.category : '其他';
        let cat: CreditCategory | undefined = catMap.get(catName);
        if (cat === undefined) {
          cat = { name: catName, required: 0, earned: 0 };
          catMap.set(catName, cat);
        }
        cat.required += pc.credit;
        if (whitelist.has(pc.name) || passedNames.has(pc.name)) {
          cat.earned += pc.credit;
        }
      }
      // 类别应修学分用 jdkcxf 覆盖（更准：核心80/非核心117/毕业考试2）
      for (const c of cats) {
        const cat: CreditCategory | undefined = catMap.get(c.name);
        if (cat !== undefined) {
          cat.required = c.required;
        }
      }
      const catList: CreditCategory[] = [];
      catMap.forEach((v: CreditCategory) => {
        catList.push(v);
      });

      const result: PlanProgress = {
        available: true,
        totalRequired: total,
        totalEarned: earned,
        studyingCount: studying,
        unearnedCount: unearnedList.length,
        outsideCount: outside,
        failedCount: failedInPlan,
        categories: catList,
        unearnedNames: unearnedList,
        studyingNames: studyingList
      };
      DataStore.cacheJSON(DataStore.KEY_PLAN_PROGRESS, JSON.stringify(result));
      LogStore.log('学业', '培养方案', '计算完成',
        `计划${total}门 已过${earned} 在读${studying} 未修${unearnedList.length} 计划外${outside}`);
      return result;
    } catch (e) {
      LogStore.log('学业', '培养方案', '失败', LogStore.errorOf(e as Object));
      return empty;
    }
  }

  /** 空培养方案结果（取不到计划时） */
  private static emptyPlanProgress(): PlanProgress {
    return {
      available: false, totalRequired: 0, totalEarned: 0, studyingCount: 0,
      unearnedCount: 0, outsideCount: 0, failedCount: 0, categories: [],
      unearnedNames: [], studyingNames: []
    };
  }

  /** 拿教学执行计划主记录 id（jxzxjhxx_id）。用学号→jg_id/njdm_id/zyh_id 反查，
   *  失败则用课表 xsxx 里的 ZYH_ID + 年级 NJDM_ID 兜底。 */
  private static async fetchPlanId(): Promise<string> {
    // 从课表 xsxx 拿专业号 + 年级（与抓包记录 body 的 jg_id=101/njdm_id=2024/zyh_id=0220 对应）
    const parts: string[] = JwApi.term.id.split('-');
    const xnm: string = parts[0];
    const xqm: string = JwApi.xqmOf(JwApi.term.id);
    let zyhId: string = '';
    let njdmId: string = '';
    let jgId: string = '101'; // 南医大机构代码（抓包实测固定 101）
    try {
      const res: HttpResult = await HttpClient.postForm('/jwglxt/kbcx/xskbcx_cxXsgrkb.html',
        { 'xnm': xnm, 'xqm': xqm });
      const root: ESObject = JSON.parse(res.body);
      const xs: ESObject = (root['xsxx'] as ESObject) ?? {};
      zyhId = (xs['ZYH_ID'] as string) ?? '';
      njdmId = (xs['NJDM_ID'] as string) ?? '';
      // 年级字段 NJDM_ID 是"2024"（不带"级"），直接用
    } catch (e) {
      // ignore，下面还会兜底
    }
    if (zyhId.length === 0 || njdmId.length === 0) {
      return '';
    }
    const form: Record<string, string> = {
      'jg_id': jgId,
      'njdm_id': njdmId,
      'dlbs': '',
      'zyh_id': zyhId,
      'currentPage_cx': '',
      '_search': 'false',
      'nd': `${Date.now()}`,
      'queryModel.showCount': '15',
      'queryModel.currentPage': '1',
      'queryModel.sortName': ' ',
      'queryModel.sortOrder': 'asc',
      'time': '0'
    };
    const planRes: HttpResult = await HttpClient.postFormExtra(
      '/jwglxt/jxzxjhgl/jxzxjhck_cxJxzxjhckIndex.html?doType=query&gnmkdm=N153540', form, {});
    const planRoot: ESObject = JSON.parse(planRes.body);
    const items: ESObject[] = (planRoot['items'] as ESObject[]) ?? [];
    if (items.length === 0) {
      return '';
    }
    return (items[0]['jxzxjhxx_id'] as string) ?? '';
  }

  /** 拿培养方案课程池（67 门）。showCount=500 拉全量，否则默认只回 15 条。 */
  private static async fetchPlanPoolCourses(planId: string): Promise<PlanCourse[]> {
    const form: Record<string, string> = {
      'jyxdxnm': '', 'jyxdxqm': '', 'yxxdxnm': '', 'yxxdxqm': '', 'shzt': '', 'kch': '',
      'jxzxjhxx_id': planId, 'xdlx': '',
      '_search': 'false', 'nd': `${Date.now()}`,
      'queryModel.showCount': '500', 'queryModel.currentPage': '1',
      'queryModel.sortName': 'jyxdxnm,jyxdxqm,kch ',
      'queryModel.sortOrder': 'asc', 'time': '0'
    };
    const res: HttpResult = await HttpClient.postFormExtra(
      '/jwglxt/jxzxjhgl/jxzxjhkcxx_cxJxzxjhkcxxIndex.html?doType=query&gnmkdm=N153540', form, {});
    const root: ESObject = JSON.parse(res.body);
    const items: ESObject[] = (root['items'] as ESObject[]) ?? [];
    const out: PlanCourse[] = [];
    const seen: Set<string> = new Set();
    for (let i = 0; i < items.length; i++) {
      const it: ESObject = items[i];
      const kch: string = (it['kch'] as string) ?? '';
      const name: string = ((it['kcmc'] as string) ?? '').trim();
      if (kch.length === 0 || seen.has(kch)) {
        continue;
      }
      seen.add(kch);
      out.push({
        kch: kch,
        name: name,
        credit: Number(it['xf'] ?? 0),
        category: (it['xfyqjdmc'] as string) ?? '',
        courseType: (it['kcxzmc'] as string) ?? ''
      });
    }
    return out;
  }

  /** 拿培养方案类别应修学分（jdkcxf）。接口 B 返回脚本拼 DOM 的裸 HTML，正则提取。 */
  private static async fetchPlanCategories(planId: string): Promise<CreditCategory[]> {
    const res: HttpResult = await HttpClient.get(
      `/jwglxt/jxzxjhgl/jxzxjhck_cxJxzxjhxdyqIndex.html?jxzxjhxx_id=${encodeURIComponent(planId)}&_=${Date.now()}&gnmkdm=N153540`);
    const html: string = res.body;
    const out: CreditCategory[] = [];
    // 结构：<p class='title1' yqzdxf='0' ...>非核心课程&nbsp;...课程总学分:<span>0</span>
    // 真正的应修学分在父节点属性 jdkcxf='117'；类别名在 title1 的文本。
    // 用正则配对：jdkcxf='(\d+)' 与紧随的 title1 文本。
    const re: RegExp = /jdkcxf='([\d.]+)'[\s\S]*?class='title1'[^>]*>([^<&]{2,20})&nbsp;/g;
    let m: RegExpExecArray | null = re.exec(html);
    const seen: Set<string> = new Set();
    while (m !== null) {
      const name: string = m[2].trim();
      const credit: number = Number(m[1]);
      if (name.length > 0 && !seen.has(name)) {
        seen.add(name);
        out.push({ name: name, required: credit, earned: 0 });
      }
      m = re.exec(html);
    }
    return out;
  }

  /** 计划外通过门数：成绩集合里不在课程池中的（按课程名） */
  private static countOutside(scoreNames: Set<string>, pool: PlanCourse[]): number {
    const poolNames: Set<string> = new Set();
    for (const pc of pool) {
      poolNames.add(pc.name);
    }
    let n: number = 0;
    scoreNames.forEach((nm: string) => {
      if (!poolNames.has(nm)) {
        n++;
      }
    });
    return n;
  }

  /** 判定成绩是否通过（数值 ≥60 或等级"优/良/中/及格/合格/通过/免修"） */
  private static isPassedScore(s: ScoreItem): boolean {
    const digits: string = JwApi.scoreDigitsText(s.scoreText);
    const num: number = digits.length > 0 ? Number(digits) : -1;
    const gradeText: string = s.scoreText.replace(/\s/g, '');
    if (gradeText.length === 0) {
      return false; // 无成绩（在读/未出分），不算通过
    }
    if (digits.length > 0 && num >= 0 && num < 60) {
      return false;
    }
    if (gradeText.indexOf('不及格') >= 0 || gradeText.indexOf('不合格') >= 0) {
      return false;
    }
    if (gradeText.indexOf('优') >= 0 || gradeText.indexOf('良') >= 0 ||
      gradeText.indexOf('中') >= 0 || gradeText.indexOf('及格') >= 0 ||
      gradeText.indexOf('合格') >= 0 || gradeText.indexOf('通过') >= 0 ||
      gradeText.indexOf('免修') >= 0) {
      return true;
    }
    // 纯数值且 ≥60
    return digits.length > 0 && num >= 60;
  }

  /**
   * 从学业页 HTML 提取关键数据：
   *  - GPA / 计划总课程 / 通过 / 未通过 / 未修 / 在读 / 计划外（去 script/标签后正则）
   *  - 课程分类学分（yxxf=已获得 yqzdxf=要求 + 类别名，直接从原始 HTML 正则，不去标签）
   */
  private static parseAcademicText(html: string): AcademicReport {
    let text: string = html.replace(/<script[\s\S]*?<\/script>/gi, ' ');
    text = text.replace(/<style[\s\S]*?<\/style>/gi, ' ');
    text = text.replace(/<[^>]+>/g, ' ');
    text = text.replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ');

    const gpa: number = JwApi.matchFirstNumber(text, /平均学分绩点\s*（GPA）[：:]\s*([\d.]+)/);
    const total: number = JwApi.matchFirstNumber(text, /计划总课程\s*(\d+)\s*门/);
    const passed: number = JwApi.matchFirstNumber(text, /通过\s*(\d+)\s*门/);
    const failed: number = JwApi.matchFirstNumber(text, /未通过\s*(\d+)\s*门/);
    const unearned: number = JwApi.matchFirstNumber(text, /未修\s*(\d+)\s*门/);
    const studying: number = JwApi.matchFirstNumber(text, /在读\s*(\d+)\s*门/);
    const outside: number = JwApi.matchFirstNumber(text, /计划外\s*[：:]\s*通过\s*(\d+)\s*门/);

    // ── 课程分类学分（从原始 HTML 直接正则，类别名在属性后）──
    // 结构：yxxf='已获得' yqzdxf='要求' sftg='..'>" + "类别名&nbsp;"
    // 注意：ArkTS 正则字面量不支持裸双引号，用 new RegExp 字符串构造
    const categories: CreditCategory[] = [];
    const catRe: RegExp = /yxxf='([\d.]+)'\s*yqzdxf='([\d.]+)'\s*sftg='(\d)'[^>]*>\s*"\s*\+\s*"([^"&]{2,30})&nbsp;/g;
    let cm: RegExpExecArray | null = catRe.exec(html);
    while (cm !== null) {
      const name: string = cm[4].trim();
      const earned: number = Number(cm[1]);
      const required: number = Number(cm[2]);
      // 排除顶层汇总节点（节点名 = 入学年份 + 专业名），只保留真实分类。
      // 用通用特征替代专业名硬编码（保证不同专业学生使用都正常）：
      // 汇总节点名称以 4 位年份开头且要求学分=0；真实分类（通识教育/专业基础课等）不以年份开头。
      const isSummaryNode: boolean = name.length >= 4 && (name.match(/^\d{4}/) !== null);
      if (name.length > 0 && !isSummaryNode) {
        // 只加入有"要求学分"的真实分类（要求>0），且去重
        if (!isNaN(required) && required > 0 && !JwApi.hasCategory(categories, name)) {
          categories.push({ name: name, required: required, earned: isNaN(earned) ? 0 : earned });
        }
      }
      cm = catRe.exec(html);
    }

    const warnings: string[] = [];
    if (failed > 0) {
      warnings.push(`计划内未通过课程 ${failed} 门，建议尽快补考/重修。`);
    } else {
      warnings.push('计划内课程全部通过，保持节奏即可。');
    }
    if (unearned > 0) {
      warnings.push(`还有 ${unearned} 门课程未修、${studying} 门在读。`);
    }
    if (outside > 0) {
      warnings.push(`另有计划外课程通过 ${outside} 门（跨专业/辅修等）。`);
    }

    return {
      // 计划总课程门数 / 已通过门数（含计划外），用于概览统计
      totalRequired: total > 0 ? total : 60,
      totalEarned: passed + outside,
      gpa: gpa,
      rank: 0,
      classSize: 0,
      failedCount: failed,
      unearnedCount: unearned,
      studyingCount: studying,
      outsideCount: outside,
      passRate: (total > 0 && passed > 0) ? Math.round(passed / total * 100) : 0,
      categories: categories,
      warnings: warnings,
      gpaTrend: []
    };
  }

  /** 检查分类数组里是否已有同名分类（去重） */
  private static hasCategory(list: CreditCategory[], name: string): boolean {
    for (const c of list) {
      if (c.name === name) {
        return true;
      }
    }
    return false;
  }

  // ══════════ 总体成绩（移植自参考项目 zhengfang-apk「成绩 - 总体」的读取方式）══════════

  /** 学业情况索引页（总体成绩与课程修读同一入口页面；本校未开放，返回无权限，仅作兜底） */
  private static readonly ACADEMIC_INDEX_URL: string =
    '/jwglxt/xsxy/xsxyqk_cxXsxyqkIndex.html?gnmkdm=N105515&layout=default';
  /** 课程修读（逐 xfyqjd_id 拉取课程成绩明细） */
  private static readonly ACADEMIC_PLAN_URL: string =
    '/jwglxt/xsxy/xsxyqk_cxJxzxjhxfyqKcxx.html?gnmkdm=N105515';
  /** 学业总评体检单页（学业总评成绩官方直出，无 JSON 接口，数值服务端渲染在 HTML 正文里） */
  private static readonly OVERALL_CHECKUP_URL: string =
    '/jwglxt/cjpmtj/cjpmtj_cxXsxytjdIndex.html?gnmkdm=N309175&layout=default';

  /**
   * 总体成绩（累计）：南医大真实数据来源已切换为「学业总评体检单」页
   * （/jwglxt/cjpmtj/cjpmtj_cxXsxytjdIndex.html，无 JSON 接口，数值服务端直出 HTML）。
   *
   * 流程：
   * ① GET 体检单页 → 正则提取官方「学业总评成绩 / 核心课程平均学分绩点 GPA / 必修课程平均学分绩点 / CET4 / 任选课学分 / 不及格门数」
   * ② 课程明细改用成绩接口（cjcx_cxXsgrcj 全量）补齐，用于成绩分布与核心/非核心均分兜底计算
   * ③ 官方「学业总评成绩」直出值优先；缺失时回退为 CC×70% + NC×30% 估算
   */
  static async getOverallGrades(): Promise<OverallGrades> {
    if (JwApi.USE_MOCK) {
      const mockCourses: ScoreItem[] = JwApi.mockOverallCourses();
      const mockStats: OverallGradeStats = JwApi.buildOverallStats(mockCourses, '', 0, 0);
      const mockOut: OverallGrades = { stats: mockStats, courses: mockCourses };
      return JwApi.delay(mockOut, 400);
    }
    // 单飞（single-flight）：并发重复调用（如 AcademicPage 的 p4 与 getPlanProgress 内部）
    // 共享同一次请求结果，避免同一接口被反复拉取
    if (JwApi.overallInflight !== null) {
      return JwApi.overallInflight;
    }
    const task: Promise<OverallGrades> = JwApi.fetchOverallGradesInner();
    JwApi.overallInflight = task;
    try {
      return await task;
    } finally {
      JwApi.overallInflight = null;
    }
  }

  /** getOverallGrades 实际执行体（单飞缓存内层） */
  private static async fetchOverallGradesInner(): Promise<OverallGrades> {
    // ① 官方体检单页（学业总评成绩直出）
    let official: OfficialOverall = JwApi.emptyOfficial();
    let officialOk: boolean = false;
    try {
      const res: HttpResult = await HttpClient.get(JwApi.OVERALL_CHECKUP_URL);
      const html: string = res.body;
      if (html.indexOf('slogin.html') >= 0 || html.indexOf('notLogin') >= 0
        || html.indexOf('用户登录') >= 0) {
        throw new Error('登录状态已过期，请重新登录后再试');
      }
      if (html.indexOf('无功能权限') < 0 && html.length > 500) {
        official = JwApi.parseOfficialOverall(html);
        officialOk = official.officialOverall.length > 0 || official.coreGpa >= 0;
      }
    } catch (e) {
      officialOk = false;
    }

    // ② 课程明细：优先走体检单外挂的成绩全量接口（任务C），失败再退回旧培养方案逻辑
    const courses: ScoreItem[] = [];
    let allTermOk: boolean = false;
    try {
      await JwApi.fetchAllTermScoreCourses(courses);
      allTermOk = courses.length > 0;
    } catch (e) {
      allTermOk = false;
    }
    if (!allTermOk) {
      // 兜底：旧培养方案（xsxyqk）逻辑（本校未开放，通常拿不到）
      await JwApi.fetchLegacyOverallCourses(courses);
    }

    const stats: OverallGradeStats = JwApi.buildOverallStats(courses, '', 0, 0);
    // ③ 官方直出值覆盖
    // 学校体检单页常不返回核心 GPA（-1）：用必修 GPA 兜底，保证学位预警规则仍可用
    stats.coreGpa = official.coreGpa >= 0
      ? official.coreGpa
      : (official.requiredGpa >= 0 ? official.requiredGpa : stats.coreGpa);
    stats.requiredGpa = official.requiredGpa;
    stats.officialOverall = official.officialOverall;
    stats.cet4 = official.cet4;
    stats.electiveCredit = official.electiveCredit;
    stats.failedCount = official.failedCount;
    // 官方学业总评成绩直出（如 86.72）优先于估算值
    if (official.officialOverall.length > 0) {
      const ov: number = Number(official.officialOverall);
      if (!isNaN(ov)) {
        stats.overallScore = ov;
      }
    }
    const out: OverallGrades = { stats: stats, courses: courses };
    if (courses.length > 0 || officialOk) {
      DataStore.cacheJSON(DataStore.KEY_OVERALL_GRADES, JSON.stringify(out));
    }
    LogStore.log('学业', '总体成绩', '完成',
      `课程${courses.length}门 总评${official.officialOverall || '估算'} 核心GPA=${official.coreGpa} 必修GPA=${official.requiredGpa} CET4=${official.cet4}`);
    return out;
  }

  /** 兜底：旧培养方案（xsxyqk）课程明细（本校未开放，通常返回空） */
  private static async fetchLegacyOverallCourses(courses: ScoreItem[]): Promise<void> {
    try {
      const res: HttpResult = await HttpClient.get(JwApi.ACADEMIC_INDEX_URL);
      const html: string = res.body;
      if (html.indexOf('无功能权限') >= 0 || html.indexOf('slogin.html') >= 0) {
        return;
      }
      const ids: string[] = JwApi.extractLoopIds(html);
      const xhId: string = JwApi.hiddenValue(html, 'xh_id');
      const cjlrxn: string = JwApi.hiddenValue(html, 'cjlrxn');
      const cjlrxq: string = JwApi.hiddenValue(html, 'cjlrxq');
      const bkcjlrxn: string = JwApi.hiddenValue(html, 'bkcjlrxn');
      const bkcjlrxq: string = JwApi.hiddenValue(html, 'bkcjlrxq');
      for (let i: number = 0; i < ids.length; i++) {
        await JwApi.fetchPlanCourses(ids[i], xhId, cjlrxn, cjlrxq, bkcjlrxn, bkcjlrxq, courses);
      }
    } catch (e) {
      // ignore
    }
  }

  /** 官方体检单汇总值（学业总评成绩直出） */
  private static emptyOfficial(): OfficialOverall {
    return {
      coreGpa: -1, requiredGpa: -1, officialOverall: '', cet4: -1,
      electiveCredit: -1, failedCount: -1
    };
  }

  /** 解析学业总评体检单 HTML，提取官方数值（无 JSON 接口，正则匹配固定句式） */
  private static parseOfficialOverall(html: string): OfficialOverall {
    // 去标签/脚本后压缩空白，得到纯文本便于匹配「为 X」句式
    let text: string = html.replace(/<script[\s\S]*?<\/script>/gi, ' ');
    text = text.replace(/<style[\s\S]*?<\/style>/gi, ' ');
    text = text.replace(/<[^>]+>/g, ' ');
    text = text.replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ');
    const out: OfficialOverall = JwApi.emptyOfficial();
    // 学业总评成绩为 86.72
    const ov: string = JwApi.textOf(text, '学业总评成绩为\\s*([\\d.]+)');
    if (ov.length > 0) {
      out.officialOverall = ov;
    }
    // 核心课程平均学分绩点（GPA）为 3.69
    const cg: string = JwApi.textOf(text, '核心课程平均学分绩点\\s*（GPA）为\\s*([\\d.]+)');
    if (cg.length > 0) {
      out.coreGpa = Number(cg);
    }
    // 必修课程平均学分绩点为 3.65
    const rg: string = JwApi.textOf(text, '必修课程平均学分绩点为\\s*([\\d.]+)');
    if (rg.length > 0) {
      out.requiredGpa = Number(rg);
    }
    // CET4成绩为 456.00 分
    const c4: string = JwApi.textOf(text, 'CET4成绩为\\s*([\\d.]+)');
    if (c4.length > 0) {
      out.cet4 = Number(c4);
    }
    // 已获得任选课学分共 23 分
    const ec: string = JwApi.textOf(text, '已获得任选课学分共\\s*([\\d.]+)');
    if (ec.length > 0) {
      out.electiveCredit = Number(ec);
    }
    // 不及格课程 0 门
    const fc: string = JwApi.textOf(text, '不及格课程\\s*([\\d.]+)\\s*门');
    if (fc.length > 0) {
      out.failedCount = Number(fc);
    }
    return out;
  }

  /** 读取总体成绩缓存（无返回 null） */
  static loadCachedOverallGrades(): OverallGrades | null {
    if (JwApi.USE_MOCK) {
      return null;
    }
    const raw: string = DataStore.loadJSON(DataStore.KEY_OVERALL_GRADES);
    if (raw.length === 0) {
      return null;
    }
    try {
      return JSON.parse(raw) as OverallGrades;
    } catch (e) {
      return null;
    }
  }

  /** 提取所有 xfyqjd_id（培养方案/轮次 id），两种写法都尝试 */
  private static extractLoopIds(html: string): string[] {
    const out: string[] = [];
    const pats: string[] = [
      'xfyqjd_id=["\']?(\\w{6,})',
      'name=["\']xfyqjd_id["\'][^>]*value=["\']([^"\']{6,})["\']'
    ];
    for (const p of pats) {
      const re: RegExp = new RegExp(p, 'g');
      let m: RegExpExecArray | null = re.exec(html);
      while (m !== null) {
        const v: string = m[1];
        if (v.length > 0 && out.indexOf(v) < 0) {
          out.push(v);
        }
        m = re.exec(html);
      }
    }
    return out;
  }

  /** 读取页面隐藏域值（兼容 name/value 两种书写顺序） */
  private static hiddenValue(html: string, name: string): string {
    const p1: string = 'name=["\']' + name + '["\'][^>]*value=["\']([^"\']*)["\']';
    const p2: string = 'value=["\']([^"\']*)["\'][^>]*name=["\']' + name + '["\']';
    const v1: string = JwApi.textOf(html, p1);
    if (v1.length > 0) {
      return v1;
    }
    return JwApi.textOf(html, p2);
  }

  /** 正则取第一个捕获组文本（无匹配返回空串） */
  private static textOf(text: string, pattern: string): string {
    const re: RegExp = new RegExp(pattern, 'i');
    const m: RegExpExecArray | null = re.exec(text);
    return m !== null && m[1] !== undefined ? m[1] : '';
  }

  /** 正则取第一个捕获组数字（无匹配返回 0） */
  private static numberOf(text: string, pattern: string): number {
    const v: string = JwApi.textOf(text, pattern);
    const n: number = Number(v);
    return isNaN(n) ? 0 : n;
  }

  /** 解析课程修读接口返回的课程明细（成绩/学分/绩点），兼容 {items:[...]} 与纯数组两种结构 */
  private static parseOverallItems(body: string, termId: string): ScoreItem[] {
    const list: ScoreItem[] = [];
    let root: ESObject;
    try {
      root = JSON.parse(body);
    } catch (e) {
      return list;
    }
    if (root === null || root === undefined) {
      return list;
    }
    let items: ESObject[] = [];
    if (Array.isArray(root)) {
      items = root as ESObject[];
    } else {
      const maybe: ESObject = root['items'] as ESObject;
      if (maybe !== undefined && maybe !== null && Array.isArray(maybe)) {
        items = maybe as ESObject[];
      }
    }
    for (let i: number = 0; i < items.length; i++) {
      const raw: ESObject = items[i];
      const name: string = (raw['kcmc'] as string) ?? '';
      if (name.length === 0) {
        continue;
      }
      const creditNum: number = Number(raw['xf'] ?? 0);
      const jdNum: number = Number(raw['jd'] ?? 0);
      const cjText: string = `${raw['cj'] ?? ''}`.trim();
      const cjNum: number = Number(cjText);
      const kclbmc: string = (raw['kclbmc'] as string) ?? (raw['kcxzmc'] as string) ?? '';
      const kcxzmc: string = (raw['kcxzmc'] as string) ?? '';
      const item: ScoreItem = {
        id: `${name}_${raw['jxb_id'] ?? ''}`,
        courseName: name,
        credit: isNaN(creditNum) ? 0 : creditNum,
        score: cjText.length > 0 && !isNaN(cjNum) ? cjNum : -1,
        scoreText: cjText.length > 0 ? cjText : '--',
        gradePoint: isNaN(jdNum) ? 0 : jdNum,
        courseType: kcxzmc,
        examType: (raw['ksxz'] as string) ?? '',
        teacher: (raw['jsxm'] as string) ?? '',
        termId: termId,
        kclbmc: kclbmc,
        isCore: JwApi.isCoreCourse(kclbmc, kcxzmc)
      };
      list.push(item);
    }
    return list;
  }

  /**
   * 拉取某个培养方案（xfyqjd_id）下的课程明细：**分页循环直到不足一页**。
   * 正方列表接口支持 queryModel.showCount / queryModel.currentPage；
   * 若接口忽略分页参数（一次性返回全部），则首屏即返回、不会多发请求。
   */
  private static async fetchPlanCourses(id: string, xhId: string, cjlrxn: string, cjlrxq: string,
    bkcjlrxn: string, bkcjlrxq: string, out: ScoreItem[]): Promise<void> {
    const pageSize: number = 100;
    for (let page: number = 1; page <= 20; page++) {
      const form: Record<string, string> = {};
      form['xfyqjd_id'] = id;
      form['xh_id'] = xhId;
      form['cjlrxn'] = cjlrxn;
      form['cjlrxq'] = cjlrxq;
      form['bkcjlrxn'] = bkcjlrxn;
      form['bkcjlrxq'] = bkcjlrxq;
      form['xscjcxkz'] = '0';
      form['cjcxkzzt'] = '2';
      form['cjztkz'] = '0';
      form['cjzt'] = '';
      form['queryModel.showCount'] = `${pageSize}`;
      form['queryModel.currentPage'] = `${page}`;
      try {
        const r: HttpResult = await HttpClient.postForm(JwApi.ACADEMIC_PLAN_URL, form);
        const items: ScoreItem[] = JwApi.parseOverallItems(r.body, id);
        for (const it of items) {
          if (!JwApi.hasScoreCourse(out, it.courseName)) {
            out.push(it);
          }
        }
        if (items.length < pageSize) {
          return;
        }
      } catch (e) {
        // 单个方案/页失败跳过，不阻塞整体（与参考项目一致）
        LogStore.logNet(T('学业'), T('总体成绩'), '轮次失败',
          { url: JwApi.ACADEMIC_PLAN_URL, status: '-', error: LogStore.errorOf(e as Object), detail: `id=${id} page=${page}` });
        return;
      }
    }
  }

  /** 用成绩数据补齐课程明细（同名课程保留已有项） */
  private static mergeScoreCourses(out: ScoreItem[], scores: TermScore[]): void {
    for (const t of scores) {
      for (const it of t.items) {
        if (!JwApi.hasScoreCourse(out, it.courseName)) {
          out.push(it);
        }
      }
    }
  }

  /** 明细覆盖的学期数量（用于判断是否需要补齐其它学期） */
  private static countDistinctTerms(courses: ScoreItem[]): number {
    const ids: string[] = [];
    for (const c of courses) {
      if (c.termId.length > 0 && ids.indexOf(c.termId) < 0) {
        ids.push(c.termId);
      }
    }
    return ids.length;
  }

  /** 兜底：遍历本地学期列表逐个拉取成绩补齐课程明细（覆盖全部学期） */
  private static async fetchAllTermScoreCourses(out: ScoreItem[]): Promise<void> {
    const terms: TermInfo[] = JwApi.buildLocalTerms();
    const limit: number = terms.length < 12 ? terms.length : 12;
    for (let i: number = 0; i < limit; i++) {
      try {
        const list: TermScore[] = await JwApi.getTermScores(terms[i].id);
        JwApi.mergeScoreCourses(out, list);
      } catch (e) {
        // 单个学期失败跳过
      }
    }
    LogStore.log('学业', '总体成绩', '补齐',
      `遍历 ${limit} 个学期后共 ${out.length} 门课程（覆盖 ${JwApi.countDistinctTerms(out)} 个学期）`);
  }

  /** 课程名去重判断 */
  private static hasScoreCourse(list: ScoreItem[], name: string): boolean {
    for (const it of list) {
      if (it.courseName === name) {
        return true;
      }
    }
    return false;
  }

  /** 课表课程名去重判断（合并 sjkList 时避免与 kbList 同名课程重复） */
  private static hasCourseName(list: CourseItem[], name: string): boolean {
    for (const it of list) {
      if (it.name === name) {
        return true;
      }
    }
    return false;
  }

  /** 汇总统计（对应参考项目 updateOverallStats：学分加权绩点 + 90/80/70/60 分布）
   *  并计算南医大学业总评成绩 = CC 加权均分 × 70% + NC 加权均分 × 30%（仅初修百分制课程）。 */
  private static buildOverallStats(courses: ScoreItem[], summaryGpa: string,
    summaryCredits: number, summaryCount: number): OverallGradeStats {
    let totalCredits: number = 0;
    let weightedGpa: number = 0;
    let excellent: number = 0;
    let good: number = 0;
    let medium: number = 0;
    let pass: number = 0;
    // 学业总评成绩：核心课程（CC）与非核心必修（NC）分别按学分加权（仅初修成绩）
    let coreSum: number = 0;
    let coreCredit: number = 0;
    let ncSum: number = 0;
    let ncCredit: number = 0;
    for (const c of courses) {
      totalCredits += c.credit;
      // 绩点：优先用服务端 jd 字段；缺失（gradePoint=0 但分数有效）时按南医大官方算法从分数换算
      // （依据教务处官网「课程及学分」kcjxf：95+→4.5 / 90→4 / 85→3.5 / 80→3 / 75→2.5 / 70→2 / 65→1.5 / 60→1 / <60→0）
      let gp: number = c.gradePoint;
      const score: number = JwApi.scoreDigits(c.scoreText);
      if (gp <= 0 && score >= 0 && c.credit > 0) {
        gp = JwApi.gpaOfScore(score);
      }
      weightedGpa += c.credit * gp;
      if (score >= 90) {
        excellent++;
      } else if (score >= 80) {
        good++;
      } else if (score >= 70) {
        medium++;
      } else if (score >= 60) {
        pass++;
      }
      // 学业总评：仅统计有百分制初修成绩的课程（score >= 0），补考/重修/等级制不计入
      const isRetake: boolean = c.examType.indexOf('重修') >= 0 || c.examType.indexOf('补考') >= 0;
      if (score >= 0 && !isRetake && c.credit > 0) {
        if (c.isCore) {
          coreSum += score * c.credit;
          coreCredit += c.credit;
        } else if (c.courseType === '必修' || c.kclbmc.indexOf('必修') >= 0) {
          ncSum += score * c.credit;
          ncCredit += c.credit;
        }
      }
    }
    const gpaText: string = summaryGpa.length > 0
      ? summaryGpa
      : (totalCredits > 0 ? (weightedGpa / totalCredits).toFixed(2) : '0.00');
    const creditValue: number = summaryCredits > 0 ? summaryCredits : totalCredits;
    const coreAvg: number = coreCredit > 0 ? coreSum / coreCredit : -1;
    const ncAvg: number = ncCredit > 0 ? ncSum / ncCredit : -1;
    let overallScore: number = -1;
    if (coreAvg >= 0 && ncAvg >= 0) {
      overallScore = coreAvg * 0.7 + ncAvg * 0.3;
    } else if (coreAvg >= 0) {
      overallScore = coreAvg;
    } else if (ncAvg >= 0) {
      overallScore = ncAvg;
    }
    const stats: OverallGradeStats = {
      gpa: gpaText,
      credits: creditValue.toFixed(1),
      courseCount: courses.length > 0 ? courses.length : summaryCount,
      excellent: excellent,
      good: good,
      medium: medium,
      pass: pass,
      coreAvg: coreAvg,
      ncAvg: ncAvg,
      overallScore: overallScore,
      coreGpa: -1,
      requiredGpa: -1,
      officialOverall: '',
      cet4: -1,
      electiveCredit: -1,
      failedCount: -1
    };
    return stats;
  }

  /** 从成绩文本提取分数（"90"→90；"优秀"/"通过"等非数字→-1） */
  private static scoreDigits(text: string): number {
    let digits: string = '';
    for (let i: number = 0; i < text.length; i++) {
      const ch: string = text.charAt(i);
      if (ch >= '0' && ch <= '9') {
        digits += ch;
      }
    }
    if (digits.length === 0) {
      return -1;
    }
    const n: number = Number(digits);
    return isNaN(n) ? -1 : n;
  }

  /** 南医大官方学分绩点换算（教务处官网「课程及学分」kcjxf）：
   *  95+→4.5 / 90→4 / 85→3.5 / 80→3 / 75→2.5 / 70→2 / 65→1.5 / 60→1 / <60→0 */
  private static gpaOfScore(score: number): number {
    if (score >= 95) {
      return 4.5;
    }
    if (score >= 90) {
      return 4;
    }
    if (score >= 85) {
      return 3.5;
    }
    if (score >= 80) {
      return 3;
    }
    if (score >= 75) {
      return 2.5;
    }
    if (score >= 70) {
      return 2;
    }
    if (score >= 65) {
      return 1.5;
    }
    if (score >= 60) {
      return 1;
    }
    return 0;
  }

  /** 从成绩文本提取数字字符串（"90"→"90"；"优秀"/"通过"等非数字→""）。供学业提醒等页面判断使用。 */
  static scoreDigitsText(text: string): string {
    let digits: string = '';
    for (let i: number = 0; i < text.length; i++) {
      const ch: string = text.charAt(i);
      if (ch >= '0' && ch <= '9') {
        digits += ch;
      }
    }
    return digits;
  }

  /** 功能浏览模式的总体成绩演示数据 */
  private static mockOverallCourses(): ScoreItem[] {
    const out: ScoreItem[] = [];
    const scores: TermScore[] = MockData.termScores([AppState.term]);
    for (const t of scores) {
      for (const it of t.items) {
        if (!JwApi.hasScoreCourse(out, it.courseName)) {
          out.push(it);
        }
      }
    }
    return out;
  }

  /** 正则取第一个数字（规避 RegExpMatchArray 结构类型：用 RegExpExecArray） */
  private static matchFirstNumber(text: string, re: RegExp): number {
    const m: RegExpExecArray | null = re.exec(text);
    if (m !== null && m[1] !== undefined) {
      const n: number = Number(m[1]);
      return isNaN(n) ? 0 : n;
    }
    return 0;
  }

  /**
   * 空闲教室查询条件（校区/楼号/场地类别）。
   * 真实入口：信息查询-查询空闲教室（cdjy），条件数据来自 cdjy_cxKxcdlb.html 页面 <select> 选项
   * （xqh_id 校区 / lh 楼号 / cdlb_id 场地类别一级）。解析失败返回空数组，页面降级为"全部"。
   */
  static async getEmptyRoomConditions(): Promise<EmptyRoomConditions> {
    const empty: EmptyRoomConditions = { campus: [], building: [], roomType: [] };
    if (JwApi.USE_MOCK) {
      // 功能浏览模式：返回固定校区/楼号/场地类别，便于演示
      return {
        campus: [
          { code: '1', name: '江宁校区' },
          { code: '2', name: '五台校区' }
        ],
        building: [
          { code: '01', name: '博学楼' },
          { code: '02', name: '明达楼' },
          { code: '03', name: '善志楼' },
          { code: '04', name: '逸夫楼' },
          { code: '05', name: '德馨楼' }
        ],
        roomType: [
          { code: '1', name: '普通教室' },
          { code: '2', name: '多媒体教室' },
          { code: '3', name: '实验室' },
          { code: '4', name: '机房' }
        ]
      };
    }
    try {
      const res: HttpResult = await HttpClient.get(
        `/jwglxt/cdjy/cdjy_cxKxcdlb.html?gnmkdm=N2155&layout=default&su=${AppState.account}`);
      const body: string = res.body;
      const parseSelect = (name: string): EmptyRoomCondition[] => {
        const out: EmptyRoomCondition[] = [];
        const m: RegExpExecArray | null = new RegExp(
          `<select[^>]*name="${name}"[^>]*>([\\s\\S]*?)</select>`).exec(body);
        if (m === null) {
          return out;
        }
        const optRe: RegExp = /<option[^>]*value="([^"]*)"[^>]*>([^<]*)<\/option>/g;
        let om: RegExpExecArray | null = null;
        while ((om = optRe.exec(m[1])) !== null) {
          const code: string = om[1];
          const text: string = om[2].trim();
          if (text.length > 0 && (code.length > 0 || text === '全部')) {
            out.push({ code: code, name: text });
          }
        }
        return out;
      };
      const campus: EmptyRoomCondition[] = parseSelect('xqh_id');
      const building: EmptyRoomCondition[] = parseSelect('lh');
      const roomType: EmptyRoomCondition[] = parseSelect('cdlb_id');
      return { campus: campus, building: building, roomType: roomType };
    } catch (e) {
      return empty;
    }
  }

  /**
   * 场地二级类别（选完一级类别 cdlb_id 后联动加载）。
   * 真实接口：/jwglxt/query/query_cxEjjxcdlbList.html?sscdlb_id=xxx&cdyysfkj=1
   * 返回数组项 { CDLB_ID, CDLBMC }（大写字段）。
   */
  static async getSubRoomTypes(parentId: string): Promise<EmptyRoomCondition[]> {
    if (parentId.length === 0) {
      return [];
    }
    if (JwApi.USE_MOCK) {
      const mocks: Record<string, EmptyRoomCondition[]> = {
        '1': [{ code: '11', name: '普通小教室' }, { code: '12', name: '普通大教室' }],
        '2': [{ code: '21', name: '多媒体小教室' }, { code: '22', name: '多媒体大教室' }, { code: '23', name: '智慧教室' }],
        '3': [{ code: '31', name: '医学形态学实验室' }, { code: '32', name: '机能学实验室' }, { code: '33', name: '计算机实验室' }],
        '4': [{ code: '41', name: '公共机房' }, { code: '42', name: '专业机房' }],
        '5': [{ code: '51', name: '大型报告厅' }, { code: '52', name: '中型报告厅' }]
      };
      const list: EmptyRoomCondition[] = mocks[parentId];
      return list !== undefined ? list : [];
    }
    try {
      const res: HttpResult = await HttpClient.postForm('/jwglxt/query/query_cxEjjxcdlbList.html', {
        'sscdlb_id': parentId,
        'cdyysfkj': '1'
      });
      const out: EmptyRoomCondition[] = [];
      const root: ESObject = JSON.parse(res.body);
      if (Array.isArray(root)) {
        for (let i: number = 0; i < root.length; i++) {
          const row: ESObject = root[i] as ESObject;
          const code: string = String(row['CDLB_ID'] ?? row['cdlb_id'] ?? '');
          const name: string = String(row['CDLBMC'] ?? row['cdlbmc'] ?? '');
          if (code.length > 0 && name.length > 0) {
            out.push({ code: code, name: name });
          }
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /** 功能浏览模式用的模拟空闲教室 */
  private static buildMockEmptyRooms(p: EmptyRoomQueryParams): EmptyRoomItem[] {
    const name: string = p.roomName.length > 0 ? p.roomName : '';
    const out: EmptyRoomItem[] = [];
    const buildings: string[] = ['博学楼', '明达楼', '善志楼', '逸夫楼'];
    const roomNames: string[] = ['101', '102', '201', '202', '301', '305', '401', '408', '502', '506'];
    for (let i: number = 0; i < roomNames.length; i++) {
      const b: string = buildings[i % buildings.length];
      const r: string = roomNames[i];
      out.push({
        cdbh: `${b.charAt(0)}${r}`,
        cdmc: `${b} ${r}室`,
        xqmc: '江宁校区',
        jxlmc: b,
        lch: `${1 + Math.floor(i / 3)}`,
        cdlbmc: i % 3 === 0 ? '多媒体教室' : (i % 3 === 1 ? '普通教室' : '实验室'),
        cdejlbmc: i % 3 === 0 ? '多媒体小教室' : (i % 3 === 1 ? '普通小教室' : '医学形态学实验室'),
        sjzws: `${40 + (i % 5) * 20}`,
        sybmmc: i % 2 === 0 ? '教务处' : '学院',
        sybj: '',
        bz: '',
        sfkfy: '1',
        time: JwApi.buildEmptyRoomTimeText(p)
      });
    }
    if (name.length > 0) {
      return out.filter((item) => item.cdmc.indexOf(name) >= 0 || item.cdbh.indexOf(name) >= 0);
    }
    return out;
  }


  /**
   * 空闲教室查询（网页版"查询"）：走 cdjy_cxKxcdlb.html?doType=query 分页拉 JSON。
   * 2026-10 抓包实测：本校导出方案 JW_N2155_CXKXJS 服务端异常（exportInitDcpz 返回空、
   * exportConfig 返回错误兜底页、最终导出抛"系统运行异常"），导出拿不到 xlsx。
   * 但查询接口是好的：totalResult=481，按 queryModel.showCount/currentPage 分页拉全量，
   * 本地生成表格。字段：cdbh(带\t前缀需trim)/cdmc/cdlbmc/xqmc/jxlmc/lch/zws/cdejlbmc/
   * sydxmc/sybj/bz/sfkjy。
   */
  static async queryEmptyRooms(p: EmptyRoomQueryParams): Promise<EmptyRoomResult> {
    const emptyResult: EmptyRoomResult = { rooms: [], message: '' };
    if (JwApi.USE_MOCK) {
      const mockResult: EmptyRoomResult = { rooms: JwApi.buildMockEmptyRooms(p), message: '' };
      return JwApi.delay(mockResult, 300);
    }
    // 查询接口用桌面浏览器请求头（移动端 UA 曾触发网关异常）
    const browserHeader: Record<string, string> = {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': 'application/json, text/javascript, */*; q=0.01',
      'X-Requested-With': 'XMLHttpRequest',
      'Referer': `https://jwpt.njmu.edu.cn/jwglxt/cdjy/cdjy_cxKxcdlb.html?gnmkdm=N2155&layout=default&su=${AppState.account}`
    };
    const tparts: string[] = p.termId.split('-');
    const xnm: string = tparts.length >= 3 ? tparts[0] : '';
    const xqm: string = JwApi.xqmOf(p.termId);
    const zcd: number = p.weeks.reduce((s: number, w: number) => s + Math.pow(2, Math.max(0, w - 1)), 0);
    const jcd: number = p.sections.reduce((s: number, n: number) => s + Math.pow(2, Math.max(0, n - 1)), 0);
    const out: EmptyRoomItem[] = [];
    const pageSize: number = 100;
    try {
      // 分页循环拉全量（服务端 totalResult 可能 >100，showCount 上限由服务端决定，逐页累加）
      for (let page: number = 1; page <= 60; page++) {
        const form: Record<string, string> = {
          'xqh_id': p.campus, 'xnm': xnm, 'xqm': xqm,
          'cdlb_id': p.roomType, 'cdejlb_id': p.roomSubType,
          'qszws': p.seatMin, 'jszws': p.seatMax, 'cdmc': p.roomName,
          'lh': p.building, 'jyfs': '0', 'cdjylx': '', 'sfbhkc': '',
          'zcd': `${zcd}`, 'xqj': p.weekdays.join(','), 'jcd': `${jcd}`,
          '_search': 'false', 'nd': `${Date.now()}`,
          'queryModel.showCount': `${pageSize}`,
          'queryModel.currentPage': `${page}`,
          'queryModel.sortName': 'cdbh',
          'queryModel.sortOrder': 'asc',
          'time': '0'
        };
        const res: HttpResult = await HttpClient.postFormExtra(
          '/jwglxt/cdjy/cdjy_cxKxcdlb.html?doType=query&gnmkdm=N2155', form, browserHeader);
        if (res.code !== 200) {
          emptyResult.message = `查询失败(code=${res.code})，请检查网络后重试`;
          return emptyResult;
        }
        let root: ESObject;
        try {
          root = JSON.parse(res.body);
        } catch (e) {
          // 返回非 JSON（登录失效/错误页）
          if (res.body.indexOf('login_slogin') >= 0 || res.body.indexOf('登录') >= 0) {
            emptyResult.message = '登录会话已失效，请到"我的-网页版教务系统"重新登录后再试';
          } else {
            emptyResult.message = '查询返回数据格式异常，请稍后重试';
          }
          return emptyResult;
        }
        const items: ESObject[] = (root['items'] as ESObject[]) ?? [];
        const timeText: string = JwApi.buildEmptyRoomTimeText(p);
        for (let i = 0; i < items.length; i++) {
          const row: ESObject = items[i];
          const str = (v: Object | undefined): string => (v === undefined || v === null) ? '' : String(v);
          out.push({
            cdbh: str(row['cdbh']).replace(/^\s+/, ''),
            cdmc: str(row['cdmc']),
            xqmc: str(row['xqmc']),
            jxlmc: str(row['jxlmc']),
            lch: str(row['lch']),
            cdlbmc: str(row['cdlbmc']),
            cdejlbmc: str(row['cdejlbmc']),
            sjzws: str(row['zws']),
            sybmmc: str(row['sydxmc']),
            sybj: str(row['sybj']),
            bz: str(row['bz']),
            sfkfy: str(row['sfkjy']),
            time: timeText
          });
        }
        // 本页不足一页 → 已拉完
        if (items.length < pageSize) {
          break;
        }
      }
      if (out.length === 0) {
        emptyResult.message = '该条件下暂无可用的空闲教室，可尝试调整条件';
        return emptyResult;
      }
      emptyResult.rooms = out;
      LogStore.logNet('空教室', '查询', T('成功'),
        { method: 'POST', url: '/jwglxt/cdjy/cdjy_cxKxcdlb.html?doType=query', status: '200', detail: `${out.length}间` });
      return emptyResult;
    } catch (e) {
      emptyResult.message = '查询异常，请检查网络后重试';
      return emptyResult;
    }
  }

  /**
   * 空闲教室导出（网页版"导出Excel"）：一次拉取全量数据（不受每页条数限制）。
   * 流程与 kxcdlb.js 对齐：先初始化导出配置（dcclbh=JW_N2155_CXKXJS），
   * 再 POST cdjy_cxDcKxcdlb.html 拿标准 xlsx（zip），解压解析后按用户选择的条件展示全部结果。
   * 导出失败返回空 rooms + message 诊断。
   */
  static async exportEmptyRooms(p: EmptyRoomQueryParams): Promise<EmptyRoomResult> {
    const emptyResult: EmptyRoomResult = { rooms: [], message: '' };
    if (JwApi.USE_MOCK) {
      const mockResult: EmptyRoomResult = { rooms: JwApi.buildMockEmptyRooms(p), message: '' };
      return JwApi.delay(mockResult, 300);
    }
    // 导出接口走正方反代网关，用桌面浏览器请求头避免被网关拒绝（移动端 UA 曾触发 502）。
    // Referer 必须指向导出来源页（kxcdlb 查询页），X-Requested-With 标识 ajax 调用，
    // 否则反代可能判为异常请求或网关层 502。
    const browserHeader: Record<string, string> = {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': `https://jwpt.njmu.edu.cn/jwglxt/cdjy/cdjy_cxKxcdlb.html?gnmkdm=N2155&layout=default&su=${AppState.account}`,
      'X-Requested-With': 'XMLHttpRequest'
    };
    const tparts: string[] = p.termId.split('-');
    const xnm: string = tparts.length >= 3 ? tparts[0] : '';
    const xqm: string = JwApi.xqmOf(p.termId);
    const zcd: number = p.weeks.reduce((s: number, w: number) => s + Math.pow(2, Math.max(0, w - 1)), 0);
    const jcd: number = p.sections.reduce((s: number, n: number) => s + Math.pow(2, Math.max(0, n - 1)), 0);
    const form: Record<string, string> = {
      'xnm': xnm, 'xqm': xqm, 'xqh_id': p.campus, 'lh': p.building,
      'cdlb_id': p.roomType, 'cdejlb_id': p.roomSubType,
      'qszws': p.seatMin, 'jszws': p.seatMax, 'cdmc': p.roomName,
      'cd_id': '', 'cdjylx': '', 'zysx': '', 'sflb': '', 'hbsl': '', 'bbsl': '',
      'sfyzz': '', 'sfjtjs': '', 'tjsl': '', 'tymbsl': '', 'yczb': '', 'zws': '',
      'sfbhkc': '', 'kszws1': '', 'jyfs': '0',
      'zcd': `${zcd}`, 'xqj': p.weekdays.join(','), 'jcd': `${jcd}`
    };
    try {
      // Step1 初始化导出配置（与 kxcdlb.js exportDialog 一致，dcclbh 是导出处类别编码）。
      // 关键：路径必须带 /jwglxt 前缀，与其它接口一致；少了前缀会被反向代理判为不存在路径并返回 502。
      const initForm: Record<string, string> = { 'dcclbh': 'JW_N2155_CXKXJS' };
      await HttpClient.postFormExtra('/jwglxt/zftal/drdc/export_exportInitDcpz.html', initForm, browserHeader);
      // Step2 导出（带查询条件 + 排序，返回标准 xlsx）
      const expForm: Record<string, string> = {};
      const formKeys: string[] = Object.keys(form);
      for (let i = 0; i < formKeys.length; i++) {
        expForm[formKeys[i]] = form[formKeys[i]];
      }
      expForm['dcclbh'] = 'JW_N2155_CXKXJS';
      expForm['xsnrbt'] = '0';
      expForm['queryModel.sortName'] = 'cdbh';
      expForm['queryModel.sortOrder'] = 'asc';
      const bin: BinaryResult =
        await HttpClient.postFormBinary('/jwglxt/cdjy/cdjy_cxDcKxcdlb.html', expForm, browserHeader);
      if (bin.data === null) {
        // 请求失败：按诊断信息区分原因
        let reason: string = '';
        if (bin.body.indexOf('login_slogin') >= 0 || bin.body.indexOf('登录') >= 0) {
          reason = '登录会话已失效，请到"我的-网页版教务系统"重新登录后再试';
        } else if (bin.body.indexOf('尚未开放') >= 0 || bin.body.indexOf('cdwkfsq') >= 0) {
          reason = '该学年学期场地预约尚未开放申请';
        } else if (bin.code === 200) {
          reason = '导出数据格式异常，请稍后重试';
        } else {
          reason = `导出请求失败(code=${bin.code})，请检查网络后重试`;
        }
        return { rooms: [], message: reason };
      }
      const rooms: EmptyRoomItem[] = await JwApi.parseXlsxRooms(bin.data, p);
      // 解析失败时把具体诊断透传给用户（解压失败/文件为空等），避免误报"该条件下暂无教室"
      if (rooms.length === 0 && JwApi.lastXlsxError.length > 0) {
        return { rooms: [], message: JwApi.lastXlsxError };
      }
      return {
        rooms: rooms,
        message: rooms.length === 0 ? '该条件下暂无可用的空闲教室，可尝试调整条件' : ''
      };
    } catch (e) {
      return { rooms: [], message: '导出异常，请检查网络后重试' };
    }
  }

  /** 最近一次导出 xlsx 解析失败的诊断（供 exportEmptyRooms 提示用户，避免误报"无数据"） */
  private static lastXlsxError: string = '';
  /** 解析导出 xlsx（zip）：写临时文件 → unzipFile 解压 → 读 sheet1.xml + sharedStrings.xml → 按表头名映射字段 */
  private static async parseXlsxRooms(bin: ArrayBuffer, p: EmptyRoomQueryParams): Promise<EmptyRoomItem[]> {
    const out: EmptyRoomItem[] = [];
    JwApi.lastXlsxError = '';
    // 0. 校验 zip 魔数（PK\x03\x04 / PK\x05\x06）：服务端在会话失效/未开放等场景会返回
    //    HTML 错误页（HTTP 200 二进制），此时直接按非 xlsx 处理，避免 unzipFile 抛异常被误报为"解析异常"。
    if (bin.byteLength < 4) {
      JwApi.lastXlsxError = '导出文件为空，请检查登录状态或查询条件后重试';
      return out;
    }
    const bytes: Uint8Array = new Uint8Array(bin);
    const isZip: boolean = (bytes[0] === 0x50 && bytes[1] === 0x4B &&
      (bytes[2] === 0x03 || bytes[2] === 0x05 || bytes[2] === 0x07));
    if (!isZip) {
      // 非 zip：可能是 HTML 错误页/登录跳转页。尝试从字节里提取特征判断原因。
      let headText: string = '';
      try {
        const headLen: number = bin.byteLength < 512 ? bin.byteLength : 512;
        const headBytes: Uint8Array = new Uint8Array(bin, 0, headLen);
        let s: string = '';
        for (let i = 0; i < headLen; i++) {
          const c: number = headBytes[i];
          s += (c >= 32 && c < 127) ? String.fromCharCode(c) : ' ';
        }
        headText = s;
      } catch (e) {
        // ignore
      }
      if (headText.indexOf('login_slogin') >= 0 || headText.indexOf('登录') >= 0) {
        JwApi.lastXlsxError = '登录会话已失效，请到"我的-网页版教务系统"重新登录后再试';
      } else if (headText.indexOf('html') >= 0 || headText.indexOf('HTML') >= 0) {
        JwApi.lastXlsxError = '服务端返回了网页而非表格文件，请稍后重试';
      } else {
        JwApi.lastXlsxError = '导出文件格式异常（非表格文件），请稍后重试';
      }
      LogStore.logNet('空教室', '解析', T('失败'),
        { method: 'POST', url: '/jwglxt/cdjy/cdjy_cxDcKxcdlb.html', status: '200', detail: `非zip 头部=${headText.substring(0, 80)}` });
      return out;
    }
    const ctx = AppState.context;
    if (ctx === null) {
      return out;
    }
    const cacheDir: string = ctx.cacheDir;
    try {
      // 1. 把 xlsx 二进制写入应用缓存目录
      const xlsxPath: string = `${cacheDir}/kxcdlb_export.xlsx`;
      const file = fileIo.openSync(xlsxPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      // writeSync 的 buffer 参数要求 ArrayBuffer | string（不能传 Uint8Array）
      fileIo.writeSync(file.fd, bin);
      fileIo.closeSync(file);
      // 2. 解压：unzipFile 要求 outFile 目录【已存在】，否则解压直接失败（SDK 文档明确）；
      //    且 rmdirSync 只能删空目录（非空抛异常）。因此每次用时间戳唯一目录并提前 mkdir，
      //    规避"目录不存在解压失败"与"旧文件残留删除失败"两个坑。
      const outDir: string = `${cacheDir}/kxcdlb_xlsx_${new Date().getTime()}`;
      fileIo.mkdirSync(outDir);
      await zlib.unzipFile(xlsxPath, outDir, {});
      // 3. 读 XML（标准 OOXML 路径；unzipFile 未按标准结构解压时递归查找兜底）
      let sheetXml: string = '';
      let sharedXml: string = '';
      try {
        sheetXml = fileIo.readTextSync(`${outDir}/xl/worksheets/sheet1.xml`);
      } catch (e) {
        sheetXml = JwApi.findXmlText(outDir, 'sheet1.xml');
      }
      try {
        sharedXml = fileIo.readTextSync(`${outDir}/xl/sharedStrings.xml`);
      } catch (e) {
        sharedXml = JwApi.findXmlText(outDir, 'sharedStrings.xml');
      }
      if (sheetXml.length === 0 || sharedXml.length === 0) {
        JwApi.lastXlsxError = '导出文件解压失败（未找到工作表数据），请稍后重试';
        LogStore.logNet('空教室', '解析', T('失败'),
          { method: 'POST', url: '/jwglxt/cdjy/cdjy_cxDcKxcdlb.html', status: '200', detail: `解压失败 sheet=${sheetXml.length} shared=${sharedXml.length}` });
        return out;
      }
      const shared: string[] = JwApi.parseSharedStrings(sharedXml);
      const rows: string[][] = JwApi.parseSheetRows(sheetXml, shared);
      if (rows.length < 2) {
        JwApi.lastXlsxError = '导出文件内容为空，该条件下暂无教室数据';
        LogStore.logNet('空教室', '解析', T('失败'),
          { method: 'POST', url: '/jwglxt/cdjy/cdjy_cxDcKxcdlb.html', status: '200', detail: `行数=${rows.length}（仅表头或无数据）` });
        return out;
      }
      // 4. 表头 → 列索引，按表头名映射字段（鲁棒，列序变化不影响）
      const header: string[] = rows[0];
      const colIdx: Record<string, number> = {};
      for (let i = 0; i < header.length; i++) {
        colIdx[header[i]] = i;
      }
      const pick = (name: string): number => {
        const idx: number = colIdx[name];
        return idx !== undefined && idx >= 0 && idx < header.length ? idx : -1;
      };
      const iCdbh: number = pick('场地编号');
      const iCdmc: number = pick('场地名称');
      const iXqmc: number = pick('校区');
      const iCdlbmc: number = pick('场地类别');
      const iZws: number = pick('座位数');
      const iJxlmc: number = pick('楼号');
      const iLch: number = pick('楼层号');
      const iBz: number = pick('场地备注信息');
      const iSybm: number = pick('使用部门');
      const iSybj: number = pick('使用班级');
      const iCdejlb: number = pick('场地二级类别');
      const iSfkjy: number = pick('是否可借用');
      const timeText: string = JwApi.buildEmptyRoomTimeText(p);
      // 日志调试：记录实际表头与关键列映射结果，用于排查"导出成功但解析无数据"（表头名不匹配时所有索引为 -1）
      LogStore.logNet('空教室', '解析', '诊断',
        { method: 'POST', url: '/jwglxt/cdjy/cdjy_cxDcKxcdlb.html', status: '200',
          detail: `行数=${rows.length} 表头=${header.join('|')} 首行=${rows.length > 1 ? rows[1].join('|') : ''} shared=${shared.length} 场地编号=${iCdbh} 场地名称=${iCdmc} 校区=${iXqmc} 类别=${iCdlbmc} 座位数=${iZws} 楼号=${iJxlmc}` });
      // 日志调试：输出 sheet1.xml 与 sharedStrings.xml 片段（确诊 V9.0 单元格格式：<v> 共享字符串 还是 <is><t> 内联字符串）
      LogStore.logNet('空教室', '解析', 'XML',
        { method: 'POST', url: '/jwglxt/cdjy/cdjy_cxDcKxcdlb.html', status: '200',
          detail: `sheet前400=${sheetXml.substring(0, 400)} shared前200=${sharedXml.substring(0, 200)}` });
      for (let r = 1; r < rows.length; r++) {
        const row: string[] = rows[r];
        const cell = (idx: number): string => (idx >= 0 && idx < row.length ? row[idx] : '');
        const item: EmptyRoomItem = {
          cdbh: cell(iCdbh),
          cdmc: cell(iCdmc),
          xqmc: cell(iXqmc),
          jxlmc: cell(iJxlmc),
          lch: cell(iLch),
          cdlbmc: cell(iCdlbmc),
          cdejlbmc: cell(iCdejlb),
          sjzws: cell(iZws),
          sybmmc: cell(iSybm),
          sybj: cell(iSybj),
          bz: cell(iBz),
          sfkfy: cell(iSfkjy),
          time: timeText
        };
        out.push(item);
      }
    } catch (e) {
      JwApi.lastXlsxError = '导出文件解析异常，请稍后重试';
      return out;
    }
    return out;
  }

  /** 在目录（含子目录）递归查找指定 xml 文件并返回其文本内容（unzipFile 解压结构兜底） */
  private static findXmlText(dir: string, fileName: string): string {
    try {
      const names: string[] = fileIo.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        const child: string = `${dir}/${names[i]}`;
        try {
          const st = fileIo.statSync(child);
          if (st.isDirectory()) {
            const sub: string = JwApi.findXmlText(child, fileName);
            if (sub.length > 0) {
              return sub;
            }
          } else if (names[i] === fileName) {
            return fileIo.readTextSync(child);
          }
        } catch (e) {
          // 单个条目 stat/read 失败跳过，继续找下一个
        }
      }
    } catch (e) {
      // 目录不存在/不可读，返回空
    }
    return '';
  }

  /** 解析 sharedStrings.xml → 字符串数组 */
  private static parseSharedStrings(xml: string): string[] {
    const out: string[] = [];
    if (xml.length === 0) {
      return out;
    }
    const siRegex = /<si>([\s\S]*?)<\/si>/gi;
    let sm: RegExpExecArray | null;
    while ((sm = siRegex.exec(xml)) !== null) {
      const tRegex = /<t[^>]*>([\s\S]*?)<\/t>/gi;
      let tm: RegExpExecArray | null;
      let txt: string = '';
      while ((tm = tRegex.exec(sm[1])) !== null) {
        txt += tm[1];
      }
      out.push(JwApi.xmlUnescape(txt));
    }
    return out;
  }

  /** 解析 sheet1.xml → 行二维数组（含表头行），兼容 <v> 共享字符串/数值 与 <is><t> 内联字符串（V9.0 两种格式都存在） */
  private static parseSheetRows(xml: string, shared: string[]): string[][] {
    const rows: string[][] = [];
    const rowRegex = /<row[^>]*>([\s\S]*?)<\/row>/gi;
    // 先按 <c ...>...</c> 块整体匹配，再在块内分别提取 <v> 或 <t>：
    //   <c r="A1" t="s"><v>0</v></c>             → 共享字符串（查 shared 表）
    //   <c r="B2" t="inlineStr"><is><t>文本</t></is></c>  → 内联字符串
    //   <c r="C3"><v>42</v></c>                  → 数字/日期
    //   <c r="D4"/>                              → 空单元格
    const cellRegex = /<c([^>]*)>([\s\S]*?)<\/c>|<c([^>]*)\/>/gi;
    // t 属性正则含双引号，用字符串构造规避 ArkTS 正则字面量坑（00305015）
    const tAttrRe = new RegExp('t="([^"]*)"', 'i');
    const vRe = /<v>([\s\S]*?)<\/v>/i;
    const tRe = /<t[^>]*>([\s\S]*?)<\/t>/i;
    let rm: RegExpExecArray | null;
    while ((rm = rowRegex.exec(xml)) !== null) {
      const cells: string[] = [];
      let cm: RegExpExecArray | null;
      while ((cm = cellRegex.exec(rm[1])) !== null) {
        const attrs: string = cm[1] !== undefined ? cm[1] : (cm[3] !== undefined ? cm[3] : '');
        const inner: string = cm[2] !== undefined ? cm[2] : '';
        const tAttrM: RegExpExecArray | null = tAttrRe.exec(attrs);
        const t: string = tAttrM !== null ? tAttrM[1] : '';
        const vM: RegExpExecArray | null = vRe.exec(inner);
        const tM: RegExpExecArray | null = tRe.exec(inner);
        let val: string = '';
        if (t === 's') {
          // 共享字符串：<v> 是 shared 表索引
          const idx: number = parseInt(vM !== null ? vM[1] : '', 10);
          val = !isNaN(idx) && idx >= 0 && idx < shared.length ? shared[idx] : '';
        } else if (t === 'inlineStr' || t.length === 0) {
          // 内联字符串 <is><t>…</t></is>（优先），无则回退 <v>
          val = tM !== null ? tM[1] : (vM !== null ? vM[1] : '');
        } else {
          // 数字/日期/布尔等：直接取 <v>
          val = vM !== null ? vM[1] : '';
        }
        cells.push(JwApi.xmlUnescape(val));
      }
      rows.push(cells);
    }
    return rows;
  }

  /** XML 实体反转义：命名实体（&amp; 等）+ 数字实体（&#NNN; 十进制 / &#xHH; 十六进制，V9.0 内联字符串中文均用数字实体） */
  private static xmlUnescape(s: string): string {
    let r: string = s.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&#10;/g, ' ');
    // XML 数字实体（先十进制后十六进制；&#10; 已在上面转为空格，避免再被转回换行符）
    r = r.replace(/&#(\d+);/g, (m: string, d: string) => {
      const n: number = parseInt(d, 10);
      return !isNaN(n) && n > 0 ? String.fromCharCode(n) : m;
    });
    r = r.replace(/&#x([0-9a-fA-F]+);/g, (m: string, h: string) => {
      const n: number = parseInt(h, 16);
      return !isNaN(n) && n > 0 ? String.fromCharCode(n) : m;
    });
    return r;
  }


  /** 构造空闲教室时间描述（多选周次/星期/节次） */
  private static buildEmptyRoomTimeText(p: EmptyRoomQueryParams): string {
    const weeksStr: string = p.weeks.length > 0 ? p.weeks.map((w: number) => `${w}`).join('、') : '-';
    const weekDaysStr: string = p.weekdays.length > 0
      ? p.weekdays.map((w: number) => Const.WEEK_LABELS[w - 1]).join('、')
      : '-';
    const sectionsStr: string = p.sections.length > 0
      ? (p.sections.length === 1
          ? `${p.sections[0]}`
          : `${Math.min(...p.sections)}-${Math.max(...p.sections)}`)
      : '-';
    return `第 ${weeksStr} 周 ${weekDaysStr} 第 ${sectionsStr} 节`;
  }
}
