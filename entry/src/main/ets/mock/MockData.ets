/**
 * Demo 阶段的模拟数据。
 * 全部按"当前日期"动态生成，保证课表 / 考试倒计时始终是新鲜的。
 * 接入真实教务系统后，本文件可整体删除，只需保证 JwApi 返回同样的模型即可。
 */
import { DateUtil } from '../common/DateUtil';
import { T } from '../common/I18n';
import { AcademicReport, CourseItem, CreditCategory, ExamItem, LevelExamItem, LevelExamSummary, NoticeItem,
  PlanProgress, ScoreItem, TermGpa, TermInfo, TermScore, UserProfile } from '../model/Models';

function range(from: number, to: number, step: number): number[] {
  const list: number[] = [];
  for (let i = from; i <= to; i += step) {
    list.push(i);
  }
  return list;
}

export class MockData {
  /** 功能浏览模式演示档案：南京医科大学 基础医学院 基础医学专业（虚构学号/姓名，不含真实个人信息） */
  static readonly PROFILE: UserProfile = {
    studentId: '24220199',
    name: '南小医',
    college: '基础医学院',
    major: '基础医学',
    className: '24级基础1班',
    grade: '2024 级',
    counselor: '郭旭',
    eduSystem: '五年制本科',
    status: T('在读')
  };

  /** 当前学期课表（对齐南医大 15 节制作息与课程命名习惯：人体结构与功能 / 医学形态学实验 / PBL 等） */
  static courses(): CourseItem[] {
    return [
      // ── 周一 ──
      MockData.course('c01', '人体结构与功能01', '王晖', '博学楼A207', 1, 1, 2, range(1, 16, 1), '1-16周', '专业核心课', 4, 0),
      MockData.course('c02', '病原与感染性疾病', '季旻珺', '明达楼213', 1, 7, 8, range(1, 16, 1), '1-16周', '专业核心课', 3, 1),
      MockData.course('c03', '死亡教育（医文融合类）', '王健男', '博学楼A105（智慧教室）', 1, 13, 15, range(3, 14, 1), '3-14周', '通识教育课', 2, 5),
      // ── 周二 ──
      MockData.course('c04', '大学英语（三）', '陆敏', '博学楼B302', 2, 1, 2, range(1, 16, 1), '1-16周', '通识教育课', 3, 6),
      MockData.course('c05', '医用物理学（B）', '龚丽英', '逸夫楼D410', 2, 7, 8, range(1, 16, 1), '1-16周', '专业基础课', 3.5, 2),
      MockData.course('c06', '基础医学整合案例（PBL）01', '陈琳', '博学楼A205-2', 2, 9, 10, range(2, 16, 2), '2-16周(双)', '专业核心课', 1.5, 3),
      MockData.course('c07', '文献检索与导读', '徐志鹏', '博学楼A509', 2, 11, 12, range(9, 12, 1), '9-12周', '通识教育课', 1, 7),
      // ── 周三 ──
      MockData.course('c08', '医学形态学实验', '靳建亮', '善志楼205', 3, 1, 4, range(1, 15, 1), '1-15周', '实践课', 2.5, 4),
      MockData.course('c09', '思想道德与法治', '刘洋', '博学楼B203', 3, 5, 6, range(1, 14, 1), '1-14周', '通识教育课', 3, 5),
      MockData.course('c10', '运动促进健康研究实践', '杜军', '操场', 3, 13, 14, range(3, 12, 1), '3-12周', '实践课', 1, 6),
      // ── 周四 ──
      MockData.course('c11', '人体结构与功能02', '陈芳', '博学楼A306', 4, 3, 5, range(1, 16, 1), '1-16周', '专业核心课', 4, 0),
      MockData.course('c12', '大学体育（三）', '赵磊', '西区田径场', 4, 7, 8, range(1, 16, 1), '1-16周', '通识教育课', 1, 7),
      MockData.course('c13', '军事技能', '郭旭', '操场', 4, 9, 10, range(1, 4, 1), '1-4周', '通识教育课', 2, 6),
      // ── 周五 ──
      MockData.course('c14', '人体结构与功能01实验', '王晖', '善志楼205', 5, 1, 4, range(2, 16, 2), '2-16周(双)', '实践课', 1.5, 4),
      MockData.course('c15', '人体细胞与分子', '李正荣', '博学楼B208', 5, 7, 8, range(1, 16, 1), '1-16周', '专业核心课', 3.5, 1),
      MockData.course('c16', '大学生心理健康', '张文君', '博学楼A105', 5, 11, 12, range(4, 7, 1), '4-7周', '通识教育课', 1, 5),
      // ── 周日（验证周末列显示） ──
      MockData.course('c17', '医学人文导论', '张文君', '博学楼B208', 7, 13, 14, range(1, 8, 1), '1-8周', '通识教育课', 1.5, 3)
    ];
  }

  private static course(id: string, name: string, teacher: string, location: string, weekday: number,
    start: number, end: number, weeks: number[], weeksText: string, type: string, credit: number,
    color: number): CourseItem {
    return {
      id: id,
      name: name,
      teacher: teacher,
      location: location,
      weekday: weekday,
      startSection: start,
      endSection: end,
      weeks: weeks,
      weeksText: weeksText,
      courseType: type,
      credit: credit,
      colorIndex: color,
      noSchedule: false
    };
  }

  /** 考试安排：围绕今天动态生成（南医大考场集中在明达楼/博学楼/逸夫楼） */
  static exams(): ExamItem[] {
    const today: Date = new Date();
    return [
      MockData.exam('e01', '医学形态学实验', DateUtil.addDays(today, -3), '14:00-15:40', '善志楼205', '023', '期中考试', '靳建亮'),
      MockData.exam('e02', '病原与感染性疾病', DateUtil.addDays(today, 2), '09:00-11:00', '明达楼213', '015', '期末考试', '季旻珺'),
      MockData.exam('e03', '人体结构与功能01', DateUtil.addDays(today, 5), '14:00-16:00', '明达楼222', '032', '期末考试', '王晖'),
      MockData.exam('e04', '医用物理学（B）', DateUtil.addDays(today, 9), '09:00-11:00', '逸夫楼D410', '008', '期末考试', '龚丽英'),
      MockData.exam('e05', '人体细胞与分子', DateUtil.addDays(today, 12), '14:00-16:00', '博学楼B208', '041', '期末考试', '李正荣'),
      MockData.exam('e06', '思想道德与法治', DateUtil.addDays(today, 15), '09:00-10:40', '博学楼A207', '019', '期末考试', '刘洋'),
      MockData.exam('e07', '基础医学整合案例（PBL）01', DateUtil.addDays(today, 18), '14:00-16:00', '博学楼A205-2', '056', '结课考核', '陈琳'),
      MockData.exam('e08', '医学形态学实验（操作考核）', DateUtil.addDays(today, 21), '08:30-11:30', '善志楼205', '012', '操作考核', '靳建亮'),
      MockData.exam('e09', '大学英语（三）', DateUtil.addDays(today, 24), '09:00-11:00', '博学楼B302', '088', '期末考试', '陆敏')
    ];
  }

  private static exam(id: string, name: string, date: Date, timeRange: string, location: string, seat: string,
    type: string, teacher: string): ExamItem {
    return {
      id: id,
      courseName: name,
      date: DateUtil.format(date),
      timeRange: timeRange,
      location: location,
      seat: seat,
      examType: type,
      teacher: teacher
    };
  }

  /** 历史学期列表（含当前学期） */
  static terms(current: TermInfo): TermInfo[] {
    const parts: string[] = current.id.split('-');
    const beginYear: number = Number.parseInt(parts[0], 10);
    const index: number = Number.parseInt(parts[2], 10);
    const list: TermInfo[] = [current];
    let y: number = beginYear;
    let i: number = index;
    for (let k = 0; k < 3; k++) {
      if (i === 1) {
        y = y - 1;
        i = 2;
      } else {
        i = 1;
      }
      const startDate: string = DateUtil.defaultTermStart(`${y}-${y + 1}-${i}`);
      list.push({
        id: `${y}-${y + 1}-${i}`,
        label: `${y}-${y + 1}学年 ${i === 1 ? '第一学期' : '第二学期'}`,
        startDate: startDate,
        totalWeeks: 19
      });
    }
    return list;
  }

  /** 各学期成绩 */
  static termScores(terms: TermInfo[]): TermScore[] {
    const list: TermScore[] = [];
    // 当前学期：成绩未发布
    list.push({
      termId: terms[0].id,
      termLabel: terms[0].label,
      gpa: 0,
      avgScore: 0,
      totalCredit: 0,
      earnedCredit: 0,
      rank: 0,
      classSize: 42,
      items: []
    });
    list.push({
      termId: terms[1].id,
      termLabel: terms[1].label,
      gpa: 3.62,
      avgScore: 86.4,
      totalCredit: 25.5,
      earnedCredit: 25.5,
      rank: 6,
      classSize: 42,
      items: [
        MockData.score('s101', '人体结构与功能02', 4, 91, 4.1, '专业核心课', terms[1].id),
        MockData.score('s102', '医学形态学实验', 2.5, 88, 3.8, '实践课', terms[1].id),
        MockData.score('s103', '生物化学', 4, 82, 3.2, '专业基础课', terms[1].id),
        MockData.score('s104', '生理学', 3.5, 79, 2.9, '专业基础课', terms[1].id),
        MockData.score('s105', '大学英语（二）', 3, 85, 3.5, '通识教育课', terms[1].id),
        MockData.score('s106', '中国近现代史纲要', 2, 92, 4.2, '通识教育课', terms[1].id),
        MockData.score('s107', '大学体育（二）', 1, -1, 4.0, '通识教育课', terms[1].id),
        MockData.score('s108', '医学统计学', 2.5, 87, 3.7, '专业基础课', terms[1].id)
      ]
    });
    list.push({
      termId: terms[2].id,
      termLabel: terms[2].label,
      gpa: 3.41,
      avgScore: 83.7,
      totalCredit: 24,
      earnedCredit: 24,
      rank: 9,
      classSize: 42,
      items: [
        MockData.score('s201', '人体结构与功能01', 4, 89, 3.9, '专业核心课', terms[2].id),
        MockData.score('s202', '人体细胞与分子', 3.5, 86, 3.6, '专业核心课', terms[2].id),
        MockData.score('s203', '医用化学', 4, 78, 2.8, '专业基础课', terms[2].id),
        MockData.score('s204', '医用物理学（B）', 3.5, 83, 3.3, '专业基础课', terms[2].id),
        MockData.score('s205', '大学英语（一）', 3, 84, 3.4, '通识教育课', terms[2].id),
        MockData.score('s206', '思想道德与法治', 3, 90, 4.0, '通识教育课', terms[2].id),
        MockData.score('s207', '大学体育（一）', 1, -1, 3.7, '通识教育课', terms[2].id),
        MockData.score('s208', '军事理论', 2, 88, 3.8, '通识教育课', terms[2].id),
        MockData.score('s209', '医学导论', 1, 93, 4.3, '通识教育课', terms[2].id)
      ]
    });
    list.push({
      termId: terms[3].id,
      termLabel: terms[3].label,
      gpa: 3.28,
      avgScore: 81.2,
      totalCredit: 18,
      earnedCredit: 16,
      rank: 14,
      classSize: 42,
      items: [
        MockData.score('s301', '医用高等数学', 4, 58, 0, '专业基础课', terms[3].id),
        MockData.score('s302', '医用高等数学（补考）', 4, 62, 1.2, '专业基础课', terms[3].id, T('补考')),
        MockData.score('s303', '大学计算机基础', 3, 86, 3.6, '通识教育课', terms[3].id),
        MockData.score('s304', '医学伦理学', 2, 88, 3.8, '通识教育课', terms[3].id),
        MockData.score('s305', '形势与政策（一）', 0.5, -1, 4.0, '通识教育课', terms[3].id)
      ]
    });
    return list;
  }

  private static score(id: string, name: string, credit: number, score: number, gp: number, type: string,
    termId: string, examType: string = T('正常考试')): ScoreItem {
    let text: string = score < 0 ? '优秀' : `${score}`;
    // 任课教师：按课程名取个 hash 映射，避免手填
    let hash: number = 0;
    for (let i = 0; i < name.length; i++) {
      hash = (hash * 31 + name.charCodeAt(i)) >>> 0;
    }
    const teachers: string[] = ['王晖', '季旻珺', '陈芳', '靳建亮', '李正荣', '龚丽英', '张文君', '刘洋'];
    const teacher: string = teachers[hash % teachers.length];
    return {
      id: id,
      courseName: name,
      credit: credit,
      score: score,
      scoreText: text,
      gradePoint: gp,
      courseType: type,
      examType: examType,
      teacher: teacher,
      termId: termId,
      kclbmc: '',
      isCore: false
    };
  }

  /** 通知公告 */
  static notices(): NoticeItem[] {
    const today: Date = new Date();
    return [
      {
        id: 'n01',
        title: '关于做好本学期期末考试安排工作的通知',
        source: '教务处',
        date: DateUtil.format(DateUtil.addDays(today, -1)),
        tag: T('考试'),
        isTop: true,
        read: false,
        summary: '各学院请于本周五前完成考场编排，学生可在教务系统查询个人考试安排。',
        content: '各学院、各位同学：\n\n本学期期末考试定于第 17-19 周进行，现将有关事项通知如下：\n\n一、考试安排\n1. 各学院须于本周五 18:00 前完成考场编排并提交教务处审核。\n2. 学生可通过教务系统或本客户端"考试安排"栏目查询个人考试时间、地点及座位号。\n\n二、考试纪律\n1. 考生须携带学生证、身份证参加考试，两证缺一不得入场。\n2. 开考 15 分钟后不得入场，开考 30 分钟后方可交卷离场。\n3. 严禁携带具有存储、通讯功能的电子设备进入考场。\n\n三、缓考与补考\n因病因事无法参加考试的同学，须提前 3 个工作日提交缓考申请并附证明材料。\n\n教务处\n',
        url: '',
      },
      {
        id: 'n02',
        title: '下学期选课系统开放时间及注意事项',
        source: '教务处',
        date: DateUtil.format(DateUtil.addDays(today, -2)),
        tag: '选课',
        isTop: true,
        read: false,
        summary: '选课分三轮进行，第一轮预选于下周一 12:00 开放，请提前查看培养方案。',
        content: '各位同学：\n\n下学期选课工作即将开始，具体安排如下：\n\n第一轮（预选）：下周一 12:00 - 下周五 18:00\n第二轮（正选）：第 16 周周一 12:00 - 周三 18:00\n第三轮（补退选）：开学第 1-2 周\n\n注意事项：\n1. 选课前请仔细阅读本专业培养方案，确认已修与待修课程。\n2. 每学期修读学分原则上不超过 30 学分。\n3. 体育、公共选修课名额有限，先到先得。\n4. 选课期间系统访问量大，建议错峰操作。\n\n教务处\n',
        url: '',
      },
      {
        id: 'n03',
        title: '基础医学院关于开展学业预警工作的通知',
        source: '基础医学院',
        date: DateUtil.format(DateUtil.addDays(today, -4)),
        tag: '教学',
        isTop: false,
        read: true,
        summary: '对累计不及格学分达到 10 学分的同学进行学业预警，请及时联系辅导员。',
        content: '各位同学：\n\n为帮助同学们顺利完成学业，学院将对以下情况开展学业预警：\n\n1. 一学期不及格课程累计达 8 学分；\n2. 累计不及格课程达 15 学分；\n3. 累计获得学分低于同年级培养方案要求的 60%。\n\n被预警同学请于本周内联系辅导员，制定个人学业改进计划。家长将同步收到告知函。\n\n基础医学院\n',
        url: '',
      },
      {
        id: 'n04',
        title: '关于 2026 届毕业设计（论文）中期检查的通知',
        source: '教务处',
        date: DateUtil.format(DateUtil.addDays(today, -6)),
        tag: '教学',
        isTop: false,
        read: true,
        summary: '中期检查材料提交截止时间为本月底，请指导教师与学生共同完成。',
        content: '各学院：\n\n为保证毕业设计（论文）质量，现开展中期检查工作。\n\n检查内容包括：开题报告完成情况、外文翻译、阶段性成果、指导记录等。\n请各位同学于本月底前在系统提交中期检查表，并由指导教师签署意见。\n\n教务处\n',
        url: '',
      },
      {
        id: 'n05',
        title: '人体结构与功能01 调课通知',
        source: '基础医学院',
        date: DateUtil.format(DateUtil.addDays(today, -7)),
        tag: T('通知'),
        isTop: false,
        read: true,
        summary: '王晖老师因参加学术会议，本周一第 1-2 节课调至本周六第 1-2 节，教室不变。',
        content: '各位同学：\n\n因王晖老师外出参加学术会议，原定本周一第 1-2 节《人体结构与功能01》（博学楼A207）调整至本周六第 1-2 节，上课地点不变。\n\n请相互转告，按时上课。\n\n基础医学院教务办\n',
        url: '',
      },
      {
        id: 'n06',
        title: '关于开展本学期教学质量评价的通知',
        source: '教务处',
        date: DateUtil.format(DateUtil.addDays(today, -9)),
        tag: '教学',
        isTop: false,
        read: true,
        summary: '未完成评教的同学将无法查询本学期成绩，请在规定时间内完成。',
        content: '各位同学：\n\n本学期教学质量评价工作现已开始，请在第 15-17 周内完成全部课程的评价。\n\n温馨提示：未完成评教的同学将无法查询本学期期末成绩。评教结果匿名处理，请客观公正评价。\n\n教务处\n',
        url: '',
      },
      {
        id: 'n07',
        title: '关于国家奖学金、励志奖学金评审工作的通知',
        source: '学生工作处',
        date: DateUtil.format(DateUtil.addDays(today, -12)),
        tag: T('通知'),
        isTop: false,
        read: true,
        summary: '申请材料请于下周三前提交至学院办公室，逾期不予受理。',
        content: '各位同学：\n\n本年度国家奖学金、国家励志奖学金评审工作现已启动。\n\n申请条件：\n1. 上一学年无不及格课程；\n2. 学业成绩排名与综合测评排名均位于专业前 30%；\n3. 家庭经济困难认定（励志奖学金）。\n\n请符合条件的同学下载申请表，填写后于下周三 18:00 前提交至学院办公室。\n\n学生工作处\n',
        url: '',
      }
    ];
  }

  /** 学业情况 */
  static academic(): AcademicReport {
    const categories: CreditCategory[] = [
      { name: '公共必修课', required: 42, earned: 34 },
      { name: '学科基础课', required: 38, earned: 27.5 },
      { name: '专业必修课', required: 32, earned: 12 },
      { name: '专业选修课', required: 16, earned: 6 },
      { name: '公共选修课', required: 8, earned: 5 },
      { name: '集中实践环节', required: 24, earned: 8 }
    ];
    const trend: TermGpa[] = [
      { termLabel: '大一上', gpa: 3.28 },
      { termLabel: '大一下', gpa: 3.41 },
      { termLabel: '大二上', gpa: 3.62 },
      { termLabel: '大二下', gpa: 3.55 }
    ];
    return {
      totalRequired: 160,
      totalEarned: 92.5,
      gpa: 3.47,
      rank: 8,
      classSize: 42,
      failedCount: 1,
      unearnedCount: 3,
      studyingCount: 12,
      outsideCount: 5,
      passRate: 96.8,
      categories: categories,
      warnings: [
        '《医用高等数学》首修不及格，已通过补考取得学分，绩点按补考成绩计入。',
        '专业选修课已修 6 学分，距毕业要求还差 10 学分，建议下学期至少选修 2 门医学人文类课程。'
      ],
      gpaTrend: trend
    };
  }

  /** 等级考试（功能浏览模式补齐：此前返回空结构，学业页该卡片不显示） */
  static levelExams(): LevelExamSummary {
    const items: LevelExamItem[] = [
      {
        id: 'le01', categoryCode: '05', categoryName: 'CET', name: 'CET4', score: '528.00',
        examTime: '2026-06-13 09:00', schoolYear: '2025-2026', certNo: ''
      },
      {
        id: 'le02', categoryCode: '08', categoryName: '全国计算机', name: '全国计算机等级考试二级（MS Office）',
        score: T('合格'), examTime: '2026-03-28 09:00', schoolYear: '2025-2026', certNo: '2026JSJ001234'
      }
    ];
    return {
      hasData: true,
      cet4: 528,
      cet4Passed: true,
      cet6: -1,
      cet6Passed: false,
      computerName: '全国计算机等级考试二级（MS Office）',
      computerPassed: true,
      items: items
    };
  }

  /** 培养方案进度（功能浏览模式补齐：此前返回空结构，进度卡与学分构成不显示） */
  static planProgress(): PlanProgress {
    const categories: CreditCategory[] = [
      { name: '通识教育课', required: 42, earned: 38 },
      { name: '专业基础课', required: 36, earned: 30 },
      { name: '专业核心课', required: 48, earned: 26 },
      { name: '实践课', required: 30, earned: 12 },
      { name: T('选修课'), required: 16, earned: 6 }
    ];
    return {
      available: true,
      totalRequired: 58,
      totalEarned: 21,
      studyingCount: 9,
      unearnedCount: 28,
      outsideCount: 2,
      failedCount: 1,
      categories: categories,
      unearnedNames: ['医学免疫学', '病理学', '药理学', '诊断学', '内科学', '外科学总论', '医学遗传学', '神经生物学'],
      studyingNames: ['人体结构与功能01', '人体结构与功能02', '人体细胞与分子', '医学形态学实验',
        '病原与感染性疾病', '基础医学整合案例（PBL）01', '医用物理学（B）', '思想道德与法治', '大学英语（三）']
    };
  }

  /** 教务处官网「学期校历」最新两条（通知功能数据源） */
  static jwcNotices(): NoticeItem[] {
    return [
      {
        id: 'jwc-1',
        title: '2026年秋季学期校历',
        source: '教务处官网',
        date: '2026-05-15',
        tag: T('通知'),
        isTop: true,
        read: false,
        summary: '2026-2027学年第一学期校历（2026年秋季学期）已发布。',
        content: '2026-2027学年第一学期校历（2026年秋季学期）：2026-09-07（周一）上课，第1~19周教学活动，第20周起放寒假。',
        url: 'http://www.njmu.edu.cn/2026/0515/c3318a115903/page.htm'
      },
      {
        id: 'jwc-2',
        title: '2026年春季学期校历',
        source: '教务处官网',
        date: '2025-12-31',
        tag: T('通知'),
        isTop: false,
        read: false,
        summary: '2025-2026学年第二学期校历。',
        content: '2026年春季学期校历（2025-2026学年第二学期）。',
        url: 'http://www.njmu.edu.cn/2025/1225/c3318a112583/page.htm'
      }
    ];
  }

  /** 校历转换结果（从最新校历 PDF 转换而来，作为 mock 默认缓存；真实模式下载 PDF 转换后覆盖） */
  static jwcCalendarJson(): string {
    return '{"semesterLabel":"2026-2027学年第一学期（2026年9月7日至2027年1月15日）","startDate":"2026-09-07","endDate":"2027-01-15","monthGroups":[{"label":"9月","span":4},{"label":"10月","span":4},{"label":"11月","span":5},{"label":"12月","span":4},{"label":"1月","span":2}],"weekNumbers":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19],"rows":[{"weekday":"周一","dates":["2026-09-07","2026-09-14","2026-09-21","2026-09-28","2026-10-05","2026-10-12","2026-10-19","2026-10-26","2026-11-02","2026-11-09","2026-11-16","2026-11-23","2026-11-30","2026-12-07","2026-12-14","2026-12-21","2026-12-28","2027-01-04","2027-01-11"]},{"weekday":"周二","dates":["2026-09-08","2026-09-15","2026-09-22","2026-09-29","2026-10-06","2026-10-13","2026-10-20","2026-10-27","2026-11-03","2026-11-10","2026-11-17","2026-11-24","2026-12-01","2026-12-08","2026-12-15","2026-12-22","2026-12-29","2027-01-05","2027-01-12"]},{"weekday":"周三","dates":["2026-09-09","2026-09-16","2026-09-23","2026-09-30","2026-10-07","2026-10-14","2026-10-21","2026-10-28","2026-11-04","2026-11-11","2026-11-18","2026-11-25","2026-12-02","2026-12-09","2026-12-16","2026-12-23","2026-12-30","2027-01-06","2027-01-13"]},{"weekday":"周四","dates":["2026-09-10","2026-09-17","2026-09-24","2026-10-01","2026-10-08","2026-10-15","2026-10-22","2026-10-29","2026-11-05","2026-11-12","2026-11-19","2026-11-26","2026-12-03","2026-12-10","2026-12-17","2026-12-24","2026-12-31","2027-01-07","2027-01-14"]},{"weekday":"周五","dates":["2026-09-11","2026-09-18","2026-09-25","2026-10-02","2026-10-09","2026-10-16","2026-10-23","2026-10-30","2026-11-06","2026-11-13","2026-11-20","2026-11-27","2026-12-04","2026-12-11","2026-12-18","2026-12-25","2027-01-01","2027-01-08","2027-01-15"]},{"weekday":"周六","dates":["2026-09-12","2026-09-19","2026-09-26","2026-10-03","2026-10-10","2026-10-17","2026-10-24","2026-10-31","2026-11-07","2026-11-14","2026-11-21","2026-11-28","2026-12-05","2026-12-12","2026-12-19","2026-12-26","2027-01-02","2027-01-09","2027-01-16"]},{"weekday":"周日","dates":["2026-09-13","2026-09-20","2026-09-27","2026-10-04","2026-10-11","2026-10-18","2026-10-25","2026-11-01","2026-11-08","2026-11-15","2026-11-22","2026-11-29","2026-12-06","2026-12-13","2026-12-20","2026-12-27","2027-01-03","2027-01-10","2027-01-17"]}],"todayDate":"2026-10-18"}';
  }

}
