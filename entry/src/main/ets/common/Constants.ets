/**
 * 全局常量：作息时间、色板、快捷入口等
 */
import { QuickEntry } from '../model/Models';

/** 一节课的时间段 */
export interface SectionTime {
  index: number;
  start: string;
  end: string;
}

export class Const {
  /** 课表总节次（南京医科大学作息，15 节） */
  static readonly SECTION_COUNT: number = 15;

  /** 节次时间表（南京医科大学官方作息，15 节） */
  static readonly SECTIONS: SectionTime[] = [
    { index: 1, start: '08:00', end: '08:40' },
    { index: 2, start: '08:50', end: '09:30' },
    { index: 3, start: '09:40', end: '10:20' },
    { index: 4, start: '10:30', end: '11:10' },
    { index: 5, start: '11:20', end: '12:00' },
    { index: 6, start: '12:10', end: '12:20' },
    { index: 7, start: '14:00', end: '14:40' },
    { index: 8, start: '14:50', end: '15:30' },
    { index: 9, start: '15:40', end: '16:20' },
    { index: 10, start: '16:30', end: '17:10' },
    { index: 11, start: '17:20', end: '18:00' },
    { index: 12, start: '18:10', end: '18:20' },
    { index: 13, start: '19:00', end: '19:40' },
    { index: 14, start: '19:50', end: '20:30' },
    { index: 15, start: '20:40', end: '21:20' }
  ];

  /** 节次所属的时段（上午 / 下午 / 晚上） */
  static readonly SECTION_PERIODS: string[] = [
    '上午', '上午', '上午', '上午', '上午', '上午',
    '下午', '下午', '下午', '下午', '下午', '下午',
    '晚上', '晚上', '晚上'
  ];

  static readonly WEEK_LABELS: string[] = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  static readonly WEEK_SHORT: string[] = ['一', '二', '三', '四', '五', '六', '日'];

  /** 课程块背景色板 */
  static readonly COURSE_BG: Resource[] = [
    $r('app.color.course_bg_1'), $r('app.color.course_bg_2'), $r('app.color.course_bg_3'), $r('app.color.course_bg_4'),
    $r('app.color.course_bg_5'), $r('app.color.course_bg_6'), $r('app.color.course_bg_7'), $r('app.color.course_bg_8')
  ];

  /** 课程块文字色板 */
  static readonly COURSE_FG: Resource[] = [
    $r('app.color.course_fg_1'), $r('app.color.course_fg_2'), $r('app.color.course_fg_3'), $r('app.color.course_fg_4'),
    $r('app.color.course_fg_5'), $r('app.color.course_fg_6'), $r('app.color.course_fg_7'), $r('app.color.course_fg_8')
  ];

  /** 首页快捷入口（通知/校历已下放到右上角"消息"入口与日历组件） */
  static readonly QUICK_ENTRIES: QuickEntry[] = [
    { key: 'exam', title: '考试查询', icon: '考试查询', color: $r('app.color.accent_orange') },
    { key: 'score', title: '成绩查询', icon: '成绩查询', color: $r('app.color.accent_purple') },
    { key: 'room', title: '教室查询', icon: '教室查询', color: $r('app.color.accent_blue') },
    { key: 'jw', title: '教务系统', icon: '教务系统', color: $r('app.color.brand') }
  ];

  /** 页面路由名 */
  static readonly ROUTE_EXAM: string = 'ExamPage';
  static readonly ROUTE_NOTICE: string = 'NoticePage';
  static readonly ROUTE_NOTICE_DETAIL: string = 'NoticeDetailPage';
  static readonly ROUTE_ACADEMIC: string = 'AcademicPage';
  /** 成绩查询页（学业情况页内的二级入口；首页快捷入口"成绩查询"直达） */
  static readonly ROUTE_SCORE: string = 'ScorePage';
  static readonly ROUTE_PRIVACY: string = 'PrivacyPage';
  /** 用户协议页（关于页底部卡片入口） */
  static readonly ROUTE_TERMS: string = 'TermsPage';
  static readonly ROUTE_ABOUT: string = 'AboutPage';
  /** 更新日志（完整历史）页：关于应用页「查看全部更新日志」入口 */
  static readonly ROUTE_CHANGELOG: string = 'ChangelogPage';
  /** 课表原文件（原始导入识别文件）查看页：课表页底部「课表原文件」入口 */
  static readonly ROUTE_COURSE_RAW: string = 'CourseRawPage';
  /** 快捷选课（BETA）：移植自参考项目的正方选课/抢课模块，入口在「我的」学业情况下方 */
  static readonly ROUTE_QUICK_SELECT: string = 'QuickSelectPage';
  static readonly ROUTE_EMPTY_ROOM: string = 'KxjsPage';
  static readonly ROUTE_NEWS_DETAIL: string = 'NewsDetailPage';
  static readonly ROUTE_NEWS_FAV: string = 'NewsFavPage';
  static readonly ROUTE_LOG: string = 'LogPage';
  static readonly ROUTE_SEARCH: string = 'SearchResultPage';
  static readonly ROUTE_WEB_PAGE: string = 'WebViewPage';
  static readonly ROUTE_WALLPAPER: string = 'WallpaperPage';
  /** 背景裁剪页（外观设置 → 背景 → 更换背景，选图后裁剪缩放平移） */
  static readonly ROUTE_BG_CROP: string = 'BackgroundCropPage';
  /** 字体管理页（外观设置 → 字体 → 字体管理） */
  static readonly ROUTE_FONT_MANAGE: string = 'FontManagePage';
  /** 校公众号页（我的 → 校园服务 → 校公众号，展示学校各微信公众号并引导关注） */
  static readonly ROUTE_WECHAT_OA: string = 'WechatOAPage';
  /** 学院公告订阅页（南医新闻 → 官网直达 → 学院公告） */
  static readonly ROUTE_COLLEGE_NOTICE: string = 'CollegeNoticePage';
  /** 云课堂页（智教云：我的课程 / 课堂实录 / 通知） */
  static readonly ROUTE_CLOUD_CLASS: string = 'CloudClassPage';

  /** 教务系统网址（应用内 WebView 打开）。南医大教务系统域名 jwpt.njmu.edu.cn（2026-10 抓包实测，非旧 IP 202.195.176.76）。 */
  static readonly WEB_PORTAL_URL: string = 'https://jwpt.njmu.edu.cn/jwglxt/xtgl/index_initMenu.html';
  /** 教务系统登录页（应用内 WebView 打开，"网页版登录"切换到「教务系统」时使用） */
  static readonly WEB_LOGIN_URL: string = 'https://jwpt.njmu.edu.cn/jwglxt/xtgl/login_slogin.html';

  /** ── 南医大统一身份认证（authserver.njmu.edu.cn，金智 IDS） ── */
  /** 统一认证平台根域名（用于 Cookie 的 host 匹配） */
  static readonly AUTH_HOST: string = 'authserver.njmu.edu.cn';
  /** 统一认证登录页（金智 IDS，AES 加密密码） */
  static readonly CAS_LOGIN_URL: string =
    'https://authserver.njmu.edu.cn/authserver/login';
  /** 统一认证平台主页（根域） */
  static readonly AUTH_HOME_URL: string = 'https://authserver.njmu.edu.cn/';
  /** 找回密码页（南医大统一身份认证平台，应用内 WebView 打开） */
  static readonly FORGOT_PASSWORD_URL: string =
    'https://authserver.njmu.edu.cn/authserver/getBackPasswordMainPage.do';

  /** ── 教务系统 SSO 桥接 ── */
  /** 教务系统主机名（2026-10 抓包实测：jwpt.njmu.edu.cn，非旧 IP 202.195.176.76） */
  static readonly JW_HOST: string = 'jwpt.njmu.edu.cn';
  /** 教务系统根地址（HTTPS） */
  static readonly JW_BASE_URL: string = 'https://jwpt.njmu.edu.cn';
  /**
   * 教务系统 SSO 回调端点。2026-10 抓包实测：南医大教务系统真实域名是
   * jwpt.njmu.edu.cn，统一认证桥接端点是 /sso/jzlogin（非旧的 /jwglxt/sso/jziotlogin）。
   * 流程：authserver 登录拿 CASTGC → 带 service=https://jwpt.njmu.edu.cn/sso/jzlogin 换 ST(ticket)
   * → 带 ticket 访问 /sso/jzlogin → 302 到 /jwglxt/ticketlogin?uid&timestamp&verify
   * → 拿到 jwglxt 的 JSESSIONID + MOD_AUTH_CAS。
   */
  static readonly JW_SSO_BRIDGE_URL: string =
    'https://jwpt.njmu.edu.cn/sso/jzlogin';
  /**
   * 教务系统「统一身份认证登录」跳转地址（服务大厅/门户里教务应用入口的 pcAccessUrl）。
   * 与 JW_SSO_BRIDGE_URL 同端点（门户「教务系统」应用的 pcAccessUrl 即 https://jwpt.njmu.edu.cn/sso/jzlogin）。
   */
  static readonly JW_BRIDGE_FROM_HALL_URL: string =
    'https://jwpt.njmu.edu.cn/sso/jzlogin';
  /** 服务大厅首页 —— 南医大融合门户为 i.njmu.edu.cn，教务系统主页为 jwpt.njmu.edu.cn */
  static readonly SERVICE_HALL_URL: string = 'https://i.njmu.edu.cn/';
  /**
   * 智慧学工（我的页入口）：南医大暂无独立智慧学工 SSO，指向教务系统主页占位。
   */
  static readonly ZHIHUI_XUEGONG_URL: string =
    'https://jwpt.njmu.edu.cn/jwglxt/xtgl/index_initMenu.html';
  /**
   * 首页「官网通知」数据源：南医大官网「通知公告」栏目（2026-10 实测 URL）。
   */
  static readonly JWC_LIST_URL: string = 'https://www.njmu.edu.cn/607/list.htm';
  /** 教务处官网「课程及学分」：绩点计算方法（南医大暂无公开栏目，留空占位） */
  static readonly JWC_KJXF_URL: string = '';
  /**
   * 校历（日历）数据源：南医大教学管理处官网「下载专区」栏目（2026-10 实测 URL）。
   * 校历文章在此栏目发布（如「2026-2027学年校历」，含 .xlsx / .jpg 附件）。
   * 注意：不是教务处 jwc.njmu.edu.cn，也不是 www.njmu.edu.cn/607（那是通知公告）。
   */
  static readonly JXRL_LIST_URL: string = 'https://jxglc.njmu.edu.cn/20004/list.htm';

  /** ── 南医大官网直达入口（新闻页「官网直达」快捷栏） ── */
  /** 医药实验动物中心（iacuc.njmu.edu.cn，2026-10 实测） */
  static readonly ANIMAL_CENTER_URL: string = 'https://iacuc.njmu.edu.cn/';
  /** 大型仪器创新部（创新器械管理，dycx.njmu.edu.cn，2026-10 实测） */
  static readonly INSTRUMENT_URL: string = 'https://dycx.njmu.edu.cn/';

  /** ── 云课堂（智教云 TeachingCenterStudentWeb） ── */
  /** 云课堂根地址 */
  static readonly CC_BASE_URL: string = 'https://zjy.njmu.edu.cn';
  /** 云课堂教学中心学生端入口（SSO 登录起始） */
  static readonly CC_LOGIN_URL: string =
    'https://zjy.njmu.edu.cn/ssoserver/login?platformNumber=002&platformType=4&parentPlatformNum=010';
  /** 云课堂 SSO 回调（CAS service，带 platform 参数） */
  static readonly CC_SSO_SERVICE: string =
    'https://zjy.njmu.edu.cn/ssoserver/login/singleSignOnSchool?platform=002,4,010';
  /** 云课堂业务请求 Referer（网关强校验，缺即 401） */
  static readonly CC_REFERER: string =
    'https://zjy.njmu.edu.cn/TeachingCenterStudentWeb/index.html';
  /** 云课堂鉴权 API 前缀 */
  static readonly CC_API_AUTH: string = 'https://zjy.njmu.edu.cn/authoritycontrolplatformapi';
  /** 云课堂课程 API 前缀 */
  static readonly CC_API_COURSE: string = 'https://zjy.njmu.edu.cn/courseApi';
  /** 云课堂教学业务 API 前缀 */
  static readonly CC_API_TEACH: string = 'https://zjy.njmu.edu.cn/teachingApi';
}
