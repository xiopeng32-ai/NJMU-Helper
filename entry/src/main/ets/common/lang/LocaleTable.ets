/**
 * 各语言的「地域格式」表
 *
 * 只放与排版/格式相关的数据（星期、月份缩写、日期顺序、列表分隔符），
 * 不涉及任何译文 —— 译文在 LangDict.ets / lang/LangXX.ets 里。
 *
 * 为什么单独一张表：日期格式如果写 if/else 会随语言数量膨胀，
 * 而且这些数据在运行时是只读常量，集中放一处便于新增语言。
 */

export interface LocaleInfo {
  /** 语言代码（与 I18n 的 tag 一致） */
  code: string;
  /** 是否中日韩文字：影响周次圆点取字与日期写法 */
  cjk: boolean;
  /** 周一 → 周日 的短名 */
  weekShort: string[];
  /** 周一 → 周日 的全名 */
  weekFull: string[];
  /** 周次圆点上的 1~2 字（中文取「一」，英文取「Mo」，避免与周名混淆） */
  weekInitials: string[];
  /** 1 → 12 月 的缩写（cjk 语言不用，保留占位） */
  monthShort: string[];
  /** 月日模板：{m} 月数字，{d} 日，{M} 月缩写 */
  mdTemplate: string;
  /** 年月日模板：{y} 年，{m} 月数字，{d} 日，{M} 月缩写 */
  ymdTemplate: string;
  /** 月日 + 星期模板：{D} 月日结果，{W} 星期短名 */
  mdwTemplate: string;
  /** 列表连接符（"成绩 A、B、C" / "A, B, C"） */
  listSep: string;
  /**
   * 底部标签栏 5 个短名（首页 / 课程表 / 学业 / 新闻 / 我的）。
   * 标签栏每个格只有 1/5 屏宽，长语言（Studienleistungen 之类）会截断，
   * 所以这里单独维护一组短名，不复用页面标题的译文。
   */
  tabs: string[];
}

const ZH_WEEK_SHORT: string[] = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
const ZH_WEEK_FULL: string[] = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
const ZH_WEEK_INIT: string[] = ['一', '二', '三', '四', '五', '六', '日'];

/** 中文月份缩写用不到，用数字占位，避免 undefined */
const NUM_MONTH: string[] = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11', '12'];

export const LOCALES: Record<string, LocaleInfo> = {
  'zh-Hans': {
    code: 'zh-Hans', cjk: true,
    weekShort: ZH_WEEK_SHORT,
    weekFull: ZH_WEEK_FULL,
    weekInitials: ZH_WEEK_INIT,
    monthShort: NUM_MONTH,
    mdTemplate: '{m}月{d}日',
    ymdTemplate: '{y}年{m}月{d}日',
    mdwTemplate: '{D} {W}',
    listSep: '、',
    tabs: ['首页', '课程表', '学业情况', '南医新闻', '我的'],
  },
  'zh-Hant': {
    code: 'zh-Hant', cjk: true,
    weekShort: ['週一', '週二', '週三', '週四', '週五', '週六', '週日'],
    weekFull: ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'],
    weekInitials: ZH_WEEK_INIT,
    monthShort: NUM_MONTH,
    mdTemplate: '{m}月{d}日',
    ymdTemplate: '{y}年{m}月{d}日',
    mdwTemplate: '{D} {W}',
    listSep: '、',
    tabs: ['首頁', '課程表', '學業情況', '南醫新聞', '我的'],
  },
  'en-US': {
    code: 'en-US', cjk: false,
    weekShort: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
    weekFull: ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'],
    weekInitials: ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'],
    monthShort: ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'],
    mdTemplate: '{M} {d}',
    ymdTemplate: '{M} {d}, {y}',
    mdwTemplate: '{W}, {D}',
    listSep: ', ',
    tabs: ['Home', 'Timetable', 'Academics', 'News', 'Me'],
  },
  'ja-JP': {
    code: 'ja-JP', cjk: true,
    weekShort: ['月', '火', '水', '木', '金', '土', '日'],
    weekFull: ['月曜日', '火曜日', '水曜日', '木曜日', '金曜日', '土曜日', '日曜日'],
    weekInitials: ['月', '火', '水', '木', '金', '土', '日'],
    monthShort: NUM_MONTH,
    mdTemplate: '{m}月{d}日',
    ymdTemplate: '{y}年{m}月{d}日',
    mdwTemplate: '{D}({W})',
    listSep: '、',
    tabs: ['ホーム', '時間割', '学業', 'ニュース', 'マイ'],
  },
  'ko-KR': {
    code: 'ko-KR', cjk: true,
    weekShort: ['월', '화', '수', '목', '금', '토', '일'],
    weekFull: ['월요일', '화요일', '수요일', '목요일', '금요일', '토요일', '일요일'],
    weekInitials: ['월', '화', '수', '목', '금', '토', '일'],
    monthShort: NUM_MONTH,
    mdTemplate: '{m}월 {d}일',
    ymdTemplate: '{y}년 {m}월 {d}일',
    mdwTemplate: '{D} ({W})',
    listSep: ', ',
    tabs: ['홈', '시간표', '학업', '뉴스', '내 정보'],
  },
  'fr-FR': {
    code: 'fr-FR', cjk: false,
    weekShort: ['lun.', 'mar.', 'mer.', 'jeu.', 'ven.', 'sam.', 'dim.'],
    weekFull: ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'],
    weekInitials: ['Lu', 'Ma', 'Me', 'Je', 'Ve', 'Sa', 'Di'],
    monthShort: ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin', 'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'],
    mdTemplate: '{d} {M}',
    ymdTemplate: '{d} {M} {y}',
    mdwTemplate: '{W} {D}',
    listSep: ', ',
    tabs: ['Accueil', 'Horaires', 'Scolarité', 'Actus', 'Profil'],
  },
  'de-DE': {
    code: 'de-DE', cjk: false,
    weekShort: ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'],
    weekFull: ['Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag', 'Sonntag'],
    weekInitials: ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'],
    monthShort: ['Jan.', 'Feb.', 'März', 'Apr.', 'Mai', 'Juni', 'Juli', 'Aug.', 'Sept.', 'Okt.', 'Nov.', 'Dez.'],
    mdTemplate: '{d}. {M}',
    ymdTemplate: '{d}. {M} {y}',
    mdwTemplate: '{W}, {D}',
    listSep: ', ',
    tabs: ['Start', 'Plan', 'Studium', 'News', 'Profil'],
  },
  'es-ES': {
    code: 'es-ES', cjk: false,
    weekShort: ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'],
    weekFull: ['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'],
    weekInitials: ['Lu', 'Ma', 'Mi', 'Ju', 'Vi', 'Sá', 'Do'],
    monthShort: ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sept', 'oct', 'nov', 'dic'],
    mdTemplate: '{d} {M}',
    ymdTemplate: '{d} {M} de {y}',
    mdwTemplate: '{W}, {D}',
    listSep: ', ',
    tabs: ['Inicio', 'Horario', 'Expediente', 'Noticias', 'Perfil'],
  },
  'ru-RU': {
    code: 'ru-RU', cjk: false,
    weekShort: ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'],
    weekFull: ['Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота', 'Воскресенье'],
    weekInitials: ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'],
    monthShort: ['янв.', 'февр.', 'мар.', 'апр.', 'мая', 'июн.', 'июл.', 'авг.', 'сент.', 'окт.', 'нояб.', 'дек.'],
    mdTemplate: '{d} {M}',
    ymdTemplate: '{d} {M} {y}',
    mdwTemplate: '{W}, {D}',
    listSep: ', ',
    tabs: ['Главная', 'Расписание', 'Учёба', 'Новости', 'Профиль'],
  },
  'pt-BR': {
    code: 'pt-BR', cjk: false,
    weekShort: ['seg', 'ter', 'qua', 'qui', 'sex', 'sáb', 'dom'],
    weekFull: ['segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado', 'domingo'],
    weekInitials: ['Se', 'Te', 'Qu', 'Qu', 'Se', 'Sá', 'Do'],
    monthShort: ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'],
    mdTemplate: '{d} {M}',
    ymdTemplate: '{d} {M} de {y}',
    mdwTemplate: '{W}, {D}',
    listSep: ', ',
    tabs: ['Início', 'Horário', 'Histórico', 'Notícias', 'Perfil'],
  },
  'it-IT': {
    code: 'it-IT', cjk: false,
    weekShort: ['lun', 'mar', 'mer', 'gio', 'ven', 'sab', 'dom'],
    weekFull: ['lunedì', 'martedì', 'mercoledì', 'giovedì', 'venerdì', 'sabato', 'domenica'],
    weekInitials: ['Lu', 'Ma', 'Me', 'Gi', 'Ve', 'Sa', 'Do'],
    monthShort: ['gen', 'feb', 'mar', 'apr', 'mag', 'giu', 'lug', 'ago', 'set', 'ott', 'nov', 'dic'],
    mdTemplate: '{d} {M}',
    ymdTemplate: '{d} {M} {y}',
    mdwTemplate: '{W}, {D}',
    listSep: ', ',
    tabs: ['Home', 'Orario', 'Carriera', 'Notizie', 'Profilo'],
  }
};

/** 取语言的地域格式（未收录时回落简体中文） */
export function localeOf(tag: string): LocaleInfo {
  const info: LocaleInfo | undefined = LOCALES[tag];
  return info !== undefined ? info : LOCALES['zh-Hans'];
}
