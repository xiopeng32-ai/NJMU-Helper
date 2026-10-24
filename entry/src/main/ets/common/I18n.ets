/**
 * 多语言引擎（界面语言）
 *
 * 支持 11 种界面语言：
 *   简体中文 / 繁體中文 / English / 日本語 / 한국어 / Français / Deutsch /
 *   Español / Русский / Português / Italiano
 *
 * 设计要点：
 *  1. **以简体中文原文作 key**：调用处 `T('首页')`，语义自明；
 *     未收录也不会显示成空白或裸 key（逐级回落：本语言 → English → 中文原文）。
 *  2. 繁體不逐条维护译文：由「词级 + 单字级」映射即时转换（见 HantTable.ets），
 *     所以连未接英文的深层页面也是完整繁体。
 *  3. 新增语言只需三步：建 lang/LangXX.ets → 在 EXTRA_DICTS 注册 → 在 LOCALES 加格式表，
 *     界面代码零改动。
 *  4. 切换后刷新：AppStorage 写 'langRev'（自增），各页面/组件用
 *     `@StorageProp('langRev') langRev: number = 0;` 订阅即可重建。
 *
 * 性能：
 *  - 简体（默认）走零成本快路径，直接返回 key；
 *  - 其余语言首次查询后写入 Map 缓存，一次构建内不再重复查找；
 *  - 语言切换时清空缓存，避免旧语言残留。
 */
import { i18n } from '@kit.LocalizationKit';
import { DataStore } from './DataStore';
import { EN_DICT } from './LangDict';
import { JA_DICT } from './lang/LangJa';
import { KO_DICT } from './lang/LangKo';
import { FR_DICT } from './lang/LangFr';
import { DE_DICT } from './lang/LangDe';
import { ES_DICT } from './lang/LangEs';
import { RU_DICT } from './lang/LangRu';
import { PT_DICT } from './lang/LangPt';
import { IT_DICT } from './lang/LangIt';
import { LOCALES, LocaleInfo, localeOf } from './lang/LocaleTable';
import { HANT_WORDS, HANT_SRC, HANT_DST } from './HantTable';

/** 语言偏好：'system' 表示跟随系统 */
export const LANG_SYSTEM: string = 'system';
export const LANG_ZH_HANS: string = 'zh-Hans';
export const LANG_ZH_HANT: string = 'zh-Hant';
export const LANG_EN: string = 'en-US';
export const LANG_JA: string = 'ja-JP';
export const LANG_KO: string = 'ko-KR';
export const LANG_FR: string = 'fr-FR';
export const LANG_DE: string = 'de-DE';
export const LANG_ES: string = 'es-ES';
export const LANG_RU: string = 'ru-RU';
export const LANG_PT: string = 'pt-BR';
export const LANG_IT: string = 'it-IT';

/** AppStorage 广播键：语言版本号（自增，供 @StorageProp 订阅） */
export const KEY_LANG_REV: string = 'langRev';
/** AppStorage 广播键：当前生效语言 tag */
export const KEY_LANG_TAG: string = 'langTag';

/** 语言元数据（语言设置页展示用） */
export interface LangMeta {
  /** 偏好值：system / zh-Hans / … */
  id: string;
  /** 该语言的母语写法（任何界面语言下都保持不变） */
  native: string;
  /** 英文名（当前语言没有对应译文时用它兜底描述） */
  english: string;
  /** 是否归入「常用语言」分组（首批支持的四种） */
  primary: boolean;
}

/** 语言选项（渲染用，含副标题） */
export interface LangOption {
  id: string;
  native: string;
  desc: string;
}

/**
 * 语言总表。顺序即「语言设置页」的展示顺序：
 * 常用（跟随系统 + 简繁 + 英文）→ 其他语言。
 */
export const LANG_LIST: LangMeta[] = [
  { id: LANG_SYSTEM, native: '', english: '', primary: true },
  { id: LANG_ZH_HANS, native: '简体中文', english: 'Simplified Chinese', primary: true },
  { id: LANG_ZH_HANT, native: '繁體中文', english: 'Traditional Chinese', primary: true },
  { id: LANG_EN, native: 'English', english: 'English', primary: true },
  { id: LANG_JA, native: '日本語', english: 'Japanese', primary: false },
  { id: LANG_KO, native: '한국어', english: 'Korean', primary: false },
  { id: LANG_FR, native: 'Français', english: 'French', primary: false },
  { id: LANG_DE, native: 'Deutsch', english: 'German', primary: false },
  { id: LANG_ES, native: 'Español', english: 'Spanish', primary: false },
  { id: LANG_RU, native: 'Русский', english: 'Russian', primary: false },
  { id: LANG_PT, native: 'Português', english: 'Portuguese', primary: false },
  { id: LANG_IT, native: 'Italiano', english: 'Italian', primary: false }
];

/**
 * 各语言词典。key 一律是简体中文原文。
 * 注意：除 English 外，其余语言词典只收录「核心词条」，
 * 未收录时按 English → 中文原文 的顺序回落。
 */
const EXTRA_DICTS: Record<string, Record<string, string>> = {
  'en-US': EN_DICT,
  'ja-JP': JA_DICT,
  'ko-KR': KO_DICT,
  'fr-FR': FR_DICT,
  'de-DE': DE_DICT,
  'es-ES': ES_DICT,
  'ru-RU': RU_DICT,
  'pt-BR': PT_DICT,
  'it-IT': IT_DICT
};

export class I18n {
  /** DataStore 键：用户选择的语言偏好 */
  static readonly KEY_PREF: string = 'app_language';

  private static pref: string = LANG_SYSTEM;
  private static tag: string = LANG_ZH_HANS;
  private static rev: number = 0;
  /** 单项译文缓存：文案 → 当前语言下的展示文本（切换语言时清空） */
  private static cache: Map<string, string> = new Map<string, string>();
  /** 词级映射表（按长度倒序，保证「先长后短」匹配） */
  private static wordMap: Map<string, string> = new Map<string, string>();
  private static wordMax: number = 1;
  /** 单字映射：源字 → 目标字 */
  private static charMap: Map<string, string> = new Map<string, string>();
  private static ready: boolean = false;

  /** 初始化：读取用户偏好 → 解析生效语言 → 同步系统级语言（资源文件、应用名等） */
  static init(): void {
    if (!I18n.ready) {
      I18n.buildTables();
      I18n.ready = true;
    }
    const saved: string = DataStore.get(I18n.KEY_PREF);
    I18n.pref = I18n.normalize(saved.length > 0 ? saved : LANG_SYSTEM);
    I18n.applyPref(false);
  }

  /** 建立简繁映射表（首次调用时构建，避免每次转换都遍历数组） */
  private static buildTables(): void {
    for (let i = 0; i + 1 < HANT_WORDS.length; i += 2) {
      const k: string = HANT_WORDS[i];
      if (k.length > I18n.wordMax) {
        I18n.wordMax = k.length;
      }
      I18n.wordMap.set(k, HANT_WORDS[i + 1]);
    }
    for (let i = 0; i < HANT_SRC.length && i < HANT_DST.length; i++) {
      I18n.charMap.set(HANT_SRC.charAt(i), HANT_DST.charAt(i));
    }
  }

  /** 归一化语言偏好（非法值一律回落跟随系统） */
  private static normalize(pref: string): string {
    if (pref === LANG_SYSTEM) {
      return pref;
    }
    if (LOCALES[pref] !== undefined) {
      return pref;
    }
    return LANG_SYSTEM;
  }

  /** 当前偏好（'system' 表示跟随系统） */
  static getPref(): string {
    return I18n.pref;
  }

  /** 当前生效语言 tag */
  static getTag(): string {
    return I18n.tag;
  }

  /** 语言版本号（用于给「随语言变化」的缓存做失效判断） */
  static revision(): number {
    return I18n.rev;
  }

  /** 是否英文界面 */
  static isEn(): boolean {
    return I18n.tag === LANG_EN;
  }

  /** 是否繁体界面 */
  static isHant(): boolean {
    return I18n.tag === LANG_ZH_HANT;
  }

  /** 是否中日韩文字界面（日期、周名按 CJK 习惯排版） */
  static isCJK(): boolean {
    return localeOf(I18n.tag).cjk;
  }

  /** 当前语言的地域格式 */
  static locale(): LocaleInfo {
    return localeOf(I18n.tag);
  }

  /**
   * 解析系统语言。
   * 中文按「文字系统 + 地区」判定简繁：zh-Hant / 地区为 HK、TW、MO → 繁体；
   * 其余中文 → 简体。其余语言取语言码前缀匹配，未支持的一律回落英文。
   */
  static systemTag(): string {
    try {
      const lang: string = i18n.System.getSystemLanguage().toLowerCase();
      if (lang.indexOf('zh') === 0 || lang.indexOf('hans') >= 0 || lang.indexOf('hant') >= 0) {
        if (lang.indexOf('hant') >= 0 || lang.indexOf('hk') >= 0 || lang.indexOf('tw') >= 0 ||
          lang.indexOf('mo') >= 0) {
          return LANG_ZH_HANT;
        }
        return LANG_ZH_HANS;
      }
      // 前缀匹配：'ja' / 'ja-jp' / 'ja_jp' 都能命中 'ja-JP'
      const prefix: string = lang.substring(0, 2);
      for (let i = 0; i < LANG_LIST.length; i++) {
        const id: string = LANG_LIST[i].id;
        if (id !== LANG_SYSTEM && id.substring(0, 2).toLowerCase() === prefix) {
          return id;
        }
      }
      return LANG_EN;
    } catch (e) {
      return LANG_ZH_HANS;
    }
  }

  /** 偏好 → 实际语言 tag */
  private static resolveTag(pref: string): string {
    return pref === LANG_SYSTEM ? I18n.systemTag() : pref;
  }

  /**
   * 切换语言。
   * @param pref 'system' 或任一语言 tag
   * @returns 是否发生变更（相同语言不重复广播，避免界面无谓重建）
   */
  static setPref(pref: string): boolean {
    const next: string = I18n.normalize(pref);
    const nextTag: string = I18n.resolveTag(next);
    const changed: boolean = next !== I18n.pref || nextTag !== I18n.tag;
    I18n.pref = next;
    DataStore.put(I18n.KEY_PREF, next);
    I18n.applyPref(changed);
    return changed;
  }

  /**
   * 应用偏好：解析语言 → 清理缓存 → 同步系统资源语言 → 广播刷新。
   * 启动阶段（notify=false）也写一次广播值，保证订阅方拿到的初值就是正确语言；
   * 只是不自增，避免首帧多一次无谓重建。
   */
  private static applyPref(notify: boolean): void {
    I18n.tag = I18n.resolveTag(I18n.pref);
    I18n.cache.clear();
    // 同步到系统：应用名、权限说明、卡片名称等「资源文件」文案随之切换
    try {
      i18n.System.setAppPreferredLanguage(I18n.tag);
    } catch (e) {
      // 部分设备（OpenHarmony / 低版本）不支持运行时切换，仅界面文案生效，忽略即可
    }
    if (notify) {
      I18n.rev = I18n.rev + 1;
    }
    // 卡片（FormExtensionAbility）等非 UI 进程里 AppStorage 可能不可用：
    // 广播失败不影响语言本身的读写，这里必须吞掉异常，否则卡片会整体白屏。
    try {
      AppStorage.setOrCreate<string>(KEY_LANG_TAG, I18n.tag);
      AppStorage.setOrCreate<number>(KEY_LANG_REV, I18n.rev);
    } catch (e) {
    }
  }

  /**
   * 翻译一条文案。
   * @param key 简体中文原文
   * @param p0/p1/p2 可选占位参数，替换译文中的 {0} {1} {2}
   */
  static t(key: string, p0?: string | number, p1?: string | number, p2?: string | number): string {
    if (key.length === 0) {
      return key;
    }
    // 快路径：简体中文直接返回原文，无查表、无缓存开销（默认语言占绝大多数）
    if (I18n.tag === LANG_ZH_HANS) {
      return I18n.fill(key, p0, p1, p2);
    }
    const hit: string | undefined = I18n.cache.get(key);
    if (hit !== undefined) {
      return I18n.fill(hit, p0, p1, p2);
    }
    const val: string = I18n.lookup(key);
    I18n.cache.set(key, val);
    return I18n.fill(val, p0, p1, p2);
  }

  /** 占位符替换（只替换实际传入的参数，避免无谓的 replace 调用） */
  private static fill(text: string, p0?: string | number, p1?: string | number,
    p2?: string | number): string {
    if (p0 === undefined) {
      return text;
    }
    let out: string = text.replace('{0}', `${p0}`);
    if (p1 !== undefined) {
      out = out.replace('{1}', `${p1}`);
    }
    if (p2 !== undefined) {
      out = out.replace('{2}', `${p2}`);
    }
    return out;
  }

  /** 查询译文：本语言词典 → 英文词典 → 中文原文 */
  private static lookup(key: string): string {
    if (I18n.tag === LANG_ZH_HANT) {
      return I18n.toHant(key);
    }
    const dict: Record<string, string> | undefined = EXTRA_DICTS[I18n.tag];
    if (dict !== undefined) {
      const v: string | undefined = dict[key];
      if (v !== undefined) {
        return v;
      }
      // 二级回落：非英文语言没收录时用英文，避免界面中英混杂
      if (I18n.tag !== LANG_EN) {
        const en: string | undefined = EN_DICT[key];
        if (en !== undefined) {
          return en;
        }
      }
    }
    return key;
  }

  /** 简体 → 繁体：单词规则优先（解决一简对多繁），其余逐字映射 */
  static toHant(text: string): string {
    if (!I18n.ready) {
      I18n.buildTables();
      I18n.ready = true;
    }
    if (text.length === 0) {
      return text;
    }
    let out: string = '';
    let i: number = 0;
    const n: number = text.length;
    while (i < n) {
      let matched: boolean = false;
      // 词级：从最长可能长度往下试（最多 3 字，够覆盖「复制 / 后台 / 里面」这类歧义词）
      const maxLen: number = Math.min(I18n.wordMax, n - i);
      for (let len = maxLen; len >= 2; len--) {
        const piece: string = text.substring(i, i + len);
        const dst: string | undefined = I18n.wordMap.get(piece);
        if (dst !== undefined) {
          out += dst;
          i += len;
          matched = true;
          break;
        }
      }
      if (matched) {
        continue;
      }
      const ch: string = text.charAt(i);
      const mapped: string | undefined = I18n.charMap.get(ch);
      out += mapped !== undefined ? mapped : ch;
      i += 1;
    }
    return out;
  }

  /** 某语言的母语名（未收录返回空串） */
  private static nativeOf(id: string): string {
    for (let i = 0; i < LANG_LIST.length; i++) {
      if (LANG_LIST[i].id === id) {
        return LANG_LIST[i].native;
      }
    }
    return '';
  }

  /** 语言选项列表（母语名固定，说明用当前语言描述） */
  static options(primary: boolean): LangOption[] {
    const list: LangOption[] = [];
    for (let i = 0; i < LANG_LIST.length; i++) {
      const m: LangMeta = LANG_LIST[i];
      if (m.primary !== primary) {
        continue;
      }
      if (m.id === LANG_SYSTEM) {
        // 「跟随系统」不写母语名（由界面语言翻译），副标题展示系统实际语言
        list.push({ id: m.id, native: I18n.t('跟随系统'), desc: I18n.nativeOf(I18n.systemTag()) });
      } else {
        list.push({ id: m.id, native: m.native, desc: m.english });
      }
    }
    return list;
  }

  /** 当前语言的显示名（用于设置行右侧摘要） */
  static displayName(): string {
    if (I18n.pref === LANG_SYSTEM) {
      return `${I18n.t('跟随系统')} · ${I18n.nativeOf(I18n.tag)}`;
    }
    const native: string = I18n.nativeOf(I18n.pref);
    return native.length > 0 ? native : I18n.pref;
  }

  // ────────────────────────── 日期 / 星期 ──────────────────────────

  /** 列表连接符：中文「、」，其他「, 」 */
  static listSep(): string {
    return I18n.locale().listSep;
  }

  /** 周一到周日的短名（周一 / Mon / 月 …） */
  static weekShort(): string[] {
    return I18n.locale().weekShort;
  }

  /** 周一到周日的全名（星期一 / Monday / 月曜日 …） */
  static weekFull(): string[] {
    return I18n.locale().weekFull;
  }

  /** 底部标签栏短名（首页 / 课程表 / 学业 / 新闻 / 我的）：单独维护，避免长语言被截断 */
  static tabLabels(): string[] {
    return I18n.locale().tabs;
  }

  /** 周次圆点上的 1~2 字（一 / Mo / 月 …） */
  static weekInitials(): string[] {
    return I18n.locale().weekInitials;
  }

  /** 两位补零 */
  private static pad2(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  /** 月日：中文「10月24日」、英文「Oct 24」、德文「24. Okt.」 */
  static monthDay(date: Date): string {
    const loc: LocaleInfo = I18n.locale();
    return loc.mdTemplate
      .replace('{m}', `${date.getMonth() + 1}`)
      .replace('{d}', `${date.getDate()}`)
      .replace('{M}', loc.monthShort[date.getMonth()]);
  }

  /** 年月日：中文「2026年10月24日」、英文「Oct 24, 2026」 */
  static ymd(date: Date): string {
    const loc: LocaleInfo = I18n.locale();
    return loc.ymdTemplate
      .replace('{y}', `${date.getFullYear()}`)
      .replace('{m}', `${date.getMonth() + 1}`)
      .replace('{d}', `${date.getDate()}`)
      .replace('{M}', loc.monthShort[date.getMonth()]);
  }

  /** 月日 + 星期：中文「10月24日 周六」、英文「Sat, Oct 24」 */
  static monthDayWeek(date: Date): string {
    const loc: LocaleInfo = I18n.locale();
    const w: number = date.getDay() === 0 ? 7 : date.getDay();
    return loc.mdwTemplate
      .replace('{D}', I18n.monthDay(date))
      .replace('{W}', loc.weekShort[w - 1]);
  }

  /** 时分：HH:mm（各语言一致，避免 12/24 小时制造成的歧义） */
  static hm(date: Date): string {
    return `${I18n.pad2(date.getHours())}:${I18n.pad2(date.getMinutes())}`;
  }
}

/**
 * 翻译入口（调用处直接用 T('首页')）。
 * 用独立函数而非 I18n.t 是为了调用处更短，语义仍是「取当前语言的这篇文案」。
 */
export function T(key: string, p0?: string | number, p1?: string | number, p2?: string | number): string {
  return I18n.t(key, p0, p1, p2);
}
