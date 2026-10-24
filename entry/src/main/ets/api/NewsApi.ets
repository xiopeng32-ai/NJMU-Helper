/**
 * 新闻 API — 解析南医大官网 www.njmu.edu.cn（栏目 URL 待接入南医大真实新闻栏目）
 */
import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { JwApi } from './JwApi';
import { AppState } from '../common/AppState';
import { LogStore } from '../common/LogStore';
import { T } from '../common/I18n';

export class NewsItem {
  title: string = '';
  url: string = '';
  date: string = '';
  thumb: string = '';
}

export class ContentBlock {
  type: string = 'text'; // 'text' | 'image'
  value: string = '';
}

export class NewsDetail {
  title: string = '';
  date: string = '';
  source: string = '';
  author: string = '';
  views: string = '';
  editor: string = '';
  blocks: ContentBlock[] = [];
}

/** 搜索结果项 */
export class SearchItem {
  title: string = '';
  url: string = '';
  date: string = '';
  category: string = '';
  source: string = '';
  thumb: string = '';
}

/** 学院（可订阅学院公告）条目 */
export interface CollegeEntry {
  name: string;
  domain: string;
}

export class NewsApi {
  static readonly BASE: string = 'https://www.njmu.edu.cn';
  /** 板块 → 列表页 URL（键 = NewsPage.tabs 标签短名；南医大官网真实栏目，2026-10 实测） */
  static readonly SECTION_URLS: Record<string, string> = {
    '要闻': 'https://www.njmu.edu.cn/606/list.htm',
    '综合': 'https://www.njmu.edu.cn/11543/list.htm',
    '科研': 'https://www.njmu.edu.cn/17575/list.htm',
    '媒体': 'https://www.njmu.edu.cn/mtny/list.htm'
  };

  /** 学院（可订阅学院公告）：名称 → 学院官网域名（2026-10 实测南医大各二级学院） */
  static readonly COLLEGES: CollegeEntry[] = [
    { name: '基础医学院', domain: 'jcyxy.njmu.edu.cn' },
    { name: '第一临床医学院', domain: 'dylc.njmu.edu.cn' },
    { name: '第二临床医学院', domain: 'erlin.njmu.edu.cn' },
    { name: '第三临床医学院', domain: 'www.njsdyyy.com.cn' },
    { name: '第四临床医学院', domain: 'silin.njmu.edu.cn' },
    { name: '公共卫生学院', domain: 'gwxy.njmu.edu.cn' },
    { name: '药学院', domain: 'yxy.njmu.edu.cn' },
    { name: '护理学院', domain: 'hlxy.njmu.edu.cn' },
    { name: '口腔医学院', domain: 'www.jsdental.cn' },
    { name: '生物医学工程与信息学院', domain: 'bmei.njmu.edu.cn' },
    { name: '康复医学院', domain: 'kfyxy.njmu.edu.cn' },
    { name: '医政学院', domain: 'yz.njmu.edu.cn' },
    { name: '医学影像学院', domain: 'yxyxxy.njmu.edu.cn' },
    { name: '外国语学院', domain: 'wgy.njmu.edu.cn' },
    { name: '儿科学院', domain: 'ekxy.njmu.edu.cn' },
    { name: '马克思主义学院', domain: 'marx.njmu.edu.cn' },
    { name: '康达学院', domain: 'kdx.njmu.edu.cn' },
    { name: '国际教育学院', domain: 'sie.njmu.edu.cn' }
  ];

  /** 学院官网首页 URL（跳转 WebView 用） */
  static collegeHome(domain: string): string {
    if (domain.startsWith('http')) {
      return domain;
    }
    return `https://${domain}/`;
  }
  /** 已下载的图片（避免重复请求）。上限 24 张，超出按插入顺序淘汰并 release */
  private static imgCache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private static readonly IMG_CACHE_MAX: number = 24;

  /** 抓指定板块列表页（pageIndex 从 1 开始，>1 请求 listN.htm）→ 并行抓每篇详情取第一张图做缩略图 */
  static async fetchPage(section: string, pageIndex: number): Promise<NewsItem[]> {
    // 功能浏览模式默认断网；隐藏调试模式（debugNetwork）开启后允许联网
    if (JwApi.USE_MOCK && !AppState.debugNetwork) {
      return [];
    }
    const base: string = NewsApi.SECTION_URLS[section] ?? NewsApi.SECTION_URLS[T('要闻')];
    let url: string = base;
    if (pageIndex > 1) {
      url = base.replace(/list\.htm$/i, `list${pageIndex}.htm`);
    }
    const t0: number = Date.now();
    const resp = await http.createHttp().request(url, { expectDataType: http.HttpDataType.STRING });
    const items: NewsItem[] = NewsApi.parseList(resp.result as string);
    LogStore.logNet('新闻', `列表[${section}]`, `${items.length}条`,
      { url: url, status: `${resp.responseCode}`, cost: `${Date.now() - t0}ms` });
    const jobs: Promise<void>[] = [];
    for (let i = 0; i < items.length; i++) {
      jobs.push(NewsApi.fillThumb(items[i]));
    }
    await Promise.all(jobs);
    return items;
  }

  private static async fillThumb(item: NewsItem): Promise<void> {
    // 外链（非本站）不抓缩略图/详情（媒体南医等外部转载）
    if (!item.url.startsWith(NewsApi.BASE)) { return; }
    try {
      const d: NewsDetail = await NewsApi.fetchDetailByUrl(item.url);
      for (const b of d.blocks) {
        if (b.type === 'image') { item.thumb = b.value; return; }
      }
    } catch (e) {
      // 单篇失败不影响列表
    }
  }

  private static parseList(html: string): NewsItem[] {
    const items: NewsItem[] = [];
    // 南医大官网真实 DOM（博达 CMS simpleList）：
    // <li class="news n1 clearfix"><span class="news_title"><a href='...' target='_blank' title='标题'>标题</a></span>
    // <span class="news_meta">2026-10-16</span></li>（注意 href/title 为单引号属性）
    const liRegex = /<li[^>]*class="news[^"]*"[^>]*>([\s\S]*?)<\/li>/gi;
    let liMatch: RegExpExecArray | null;
    while ((liMatch = liRegex.exec(html)) !== null) {
      const li: string = liMatch[1];
      // 分支一：<a href='...' title='标题'>（博达 simpleList，title 属性为纯标题）
      // 分支二：<a href='...'>内文标题</a>
      const aTitled = /<a[^>]*href=['"]([^'"]+)['"][^>]*title=['"]([^'"]*)['"][^>]*>/i.exec(li);
      const aInner = aTitled !== null ? null : /<a[^>]*href=['"]([^'"]+)['"][^>]*>([\s\S]*?)<\/a>/i.exec(li);
      const href: string = aTitled !== null ? aTitled[1] : (aInner !== null ? aInner[1] : '');
      let finalTitle: string = aTitled !== null
        ? aTitled[2].trim()
        : (aInner !== null ? aInner[2].replace(/<[^>]+>/g, '').trim() : '');
      if (href.length === 0 || finalTitle.length <= 1) { continue; }
      const dMatch = /<span[^>]*class="news_meta"[^>]*>([\s\S]*?)<\/span>/i.exec(li);
      const url: string = href.startsWith('http') ? href : NewsApi.BASE + href;
      items.push({
        title: finalTitle,
        url: url,
        date: dMatch !== null ? dMatch[1].replace(/<[^>]+>/g, '').trim() : '',
        thumb: ''
      });
    }
    // 兜底：旧版 column-news-item 结构（其他博达站点）
    if (items.length === 0) {
      const itemRegex = /<a[^>]*class="[^"]*column-news-item[^"]*"[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/gi;
      let itMatch: RegExpExecArray | null;
      while ((itMatch = itemRegex.exec(html)) !== null) {
        const href: string = itMatch[1];
        const body: string = itMatch[2];
        const tMatch = /<span[^>]*class="[^"]*column-news-title[^"]*"[^>]*>([\s\S]*?)<\/span>/i.exec(body);
        const dMatch = /<span[^>]*class="[^"]*column-news-date[^"]*"[^>]*>([\s\S]*?)<\/span>/i.exec(body);
        const url: string = href.startsWith('http') ? href : NewsApi.BASE + href;
        items.push({
          title: tMatch !== null ? tMatch[1].replace(/<[^>]+>/g, '').trim() : '',
          url: url,
          date: dMatch !== null ? dMatch[1].replace(/<[^>]+>/g, '').trim() : '',
          thumb: ''
        });
      }
    }
    return items;
  }

  static async fetchDetailByUrl(url: string): Promise<NewsDetail> {
    // 功能浏览模式默认断网（详情跟随列表，避免联网）；调试模式开启后允许
    if (JwApi.USE_MOCK && !AppState.debugNetwork) {
      return new NewsDetail();
    }
    const t0: number = Date.now();
    const resp = await http.createHttp().request(url, { expectDataType: http.HttpDataType.STRING });
    const d: NewsDetail = NewsApi.parseDetail(resp.result as string);
    LogStore.logNet('新闻', '详情', `${d.blocks.length}块`,
      { url: url, status: `${resp.responseCode}`, cost: `${Date.now() - t0}ms` });
    return d;
  }

  /** 下载图片（带防盗链请求头）→ PixelMap，带内存缓存 */
  static async fetchImage(url: string): Promise<image.PixelMap> {
    // 功能浏览模式默认断网；调试模式开启后允许
    if (JwApi.USE_MOCK && !AppState.debugNetwork) {
      throw new Error('offline');
    }
    const cached = NewsApi.imgCache.get(url);
    if (cached !== undefined) {
      return cached;
    }
    const resp = await http.createHttp().request(url, {
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      header: {
        'Referer': NewsApi.BASE + '/',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
        'Accept': 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9'
      }
    });
    const buffer: ArrayBuffer = resp.result as ArrayBuffer;
    const src: image.ImageSource = image.createImageSource(buffer);
    const pm: image.PixelMap = await src.createPixelMap();
    src.release();
    NewsApi.putImg(url, pm);
    return pm;
  }

  /** 是否本站链接（http/https 都算） */
  static isLocalUrl(url: string): boolean {
    return url.startsWith('https://www.njmu.edu.cn') || url.startsWith('http://www.njmu.edu.cn');
  }

  /** 退出应用时清理图片缓存（必须 release，Map.clear 只丢引用不回收 Native 内存） */
  static clearCache(): void {
    for (const pm of NewsApi.imgCache.values()) {
      try {
        pm.release();
      } catch (e) {
        // ignore
      }
    }
    NewsApi.imgCache.clear();
  }

  /** 写入缩略图缓存，超出上限时淘汰最早的一张并释放 */
  private static putImg(url: string, pm: image.PixelMap): void {
    if (NewsApi.imgCache.size >= NewsApi.IMG_CACHE_MAX) {
      const oldest: string | undefined = NewsApi.imgCache.keys().next().value;
      if (oldest !== undefined) {
        const old: image.PixelMap | undefined = NewsApi.imgCache.get(oldest);
        NewsApi.imgCache.delete(oldest);
        if (old !== undefined) {
          try {
            old.release();
          } catch (e) {
            // ignore
          }
        }
      }
    }
    NewsApi.imgCache.set(url, pm);
  }

  /** 站内搜索：POST 官方搜索接口，按页返回（每页 10 条左右） */
  static async search(keyword: string, pageIndex: number): Promise<SearchItem[]> {
    // 功能浏览模式默认断网；调试模式开启后允许
    if (JwApi.USE_MOCK && !AppState.debugNetwork) {
      return [];
    }
    const jsonStr: string = JSON.stringify([
      { 'field': 'pageIndex', 'value': pageIndex },
      { 'field': 'group', 'value': 0 },
      { 'field': 'searchType', 'value': 1 },
      { 'field': 'keyword', 'value': keyword },
      { 'field': 'recommend', 'value': '' },
      { 'field': 4, 'value': '' },
      { 'field': 5, 'value': '' },
      { 'field': 6, 'value': '' },
      { 'field': 7, 'value': '' }
    ]);
    const encoder: util.TextEncoder = new util.TextEncoder();
    const bytes: Uint8Array = encoder.encodeInto(jsonStr);
    const b64: util.Base64Helper = new util.Base64Helper();
    const searchInfo: string = b64.encodeToStringSync(bytes);

    const resp = await http.createHttp().request(
      'https://www.njmu.edu.cn/_web/_search/api/searchCon/create.rst?_p=YXM9NjEmdD04NjcmZD0yNzI1JnA9MSZtPVNOJg__&tt=' + Math.random(),
      {
        method: http.RequestMethod.POST,
        header: {
          'Referer': 'https://www.njmu.edu.cn/main.htm',
          'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36'
        },
        extraData: `searchInfo=${searchInfo}`,
        expectDataType: http.HttpDataType.STRING
      });
    const json: Record<string, Object> = JSON.parse(resp.result as string) as Record<string, Object>;
    const html: string = typeof json['data'] === 'string' ? json['data'] as string : '';
    return NewsApi.parseSearch(html);
  }

  /** 解析搜索结果 data HTML → SearchItem[] */
  private static parseSearch(html: string): SearchItem[] {
    const items: SearchItem[] = [];
    const itemRegex = /<div class="result_item[\s\S]*?(?=<div class="result_item|$)/gi;
    let itMatch: RegExpExecArray | null;
    while ((itMatch = itemRegex.exec(html)) !== null) {
      const block: string = itMatch[0];
      const aMatch = /<a href='([^']*)'[^>]*>([\s\S]*?)<\/a>/i.exec(block);
      if (aMatch === null) { continue; }
      const item: SearchItem = new SearchItem();
      item.url = aMatch[1];
      item.title = aMatch[2].replace(/<[^>]+>/g, '').trim();
      const dm = /发布时间:([\d-]+)/.exec(block);
      item.date = dm !== null ? dm[1] : '';
      const cm = /目录:([^<]*(?:<[^>]+>[^<]*)*)<\/span>/i.exec(block);
      item.category = cm !== null ? cm[1].replace(/<[^>]+>/g, '').trim() : '';
      const sm = /出处:([^<]*(?:<[^>]+>[^<]*)*)<\/span>/i.exec(block);
      item.source = sm !== null ? sm[1].replace(/<[^>]+>/g, '').trim() : '';
      const im = /<img[^>]*class="item_image"[^>]*src="([^"]*)"/i.exec(block);
      if (im !== null) {
        let src: string = im[1];
        if (src.startsWith('/')) { src = NewsApi.BASE + src; }
        item.thumb = src;
      }
      items.push(item);
    }
    return items;
  }

  private static parseDetail(html: string): NewsDetail {
    const d: NewsDetail = new NewsDetail();
    // 标题（兼容 arti_title 下划线（南医大官网）与 arti-title 连字符两种写法）
    const tMatch = /<h1[^>]*class=['"][^'"]*arti[_-]title[^'"]*['"][^>]*>([\s\S]*?)<\/h1>/i.exec(html);
    d.title = tMatch !== null ? tMatch[1].replace(/<[^>]+>/g, '').trim() : '';
    // 元信息（南医大官网：<p class="arti_metas"><span class="arti_publisher">发布者：xxx</span>
    // <span class="arti_update">发布时间：2026-10-16</span>…；兼容旧 arti-metas 写法）
    const mMatch = /<p[^>]*class=['"][^'"]*arti[_-]metas[^'"]*['"][^>]*>([\s\S]*?)<\/p>/i.exec(html);
    if (mMatch !== null) {
      const meta: string = mMatch[1];
      const dm = /发布时间[：:]\s*(\d{4}-\d{2}-\d{2})/.exec(meta)
        ?? /发布日期[：:]\s*(\d{4}-\d{2}-\d{2})/.exec(meta);
      d.date = dm !== null ? dm[1] : '';
      const sm = /来源[：:]\s*(.+?)(?:<\/span>|$)/i.exec(meta);
      const pm = /发布者[：:]\s*(.+?)(?:<\/span>|$)/i.exec(meta);
      d.source = (sm !== null ? sm[1] : (pm !== null ? pm[1] : '')).replace(/<[^>]+>/g, '').trim();
      const am = /作者[：:]\s*(.+?)(?:摄影|<\/span>|$)/i.exec(meta);
      d.author = am !== null ? am[1].replace(/<[^>]+>/g, '').trim() : '';
      // 浏览量：浏览次数:<span class="WP_VisitCount">1513</span>
      const vm = /浏览次数[：:]\s*(?:<[^>]+>)*\s*([\d,]+)/i.exec(meta);
      d.views = vm !== null ? vm[1].trim() : '';
    }
    // 编辑 / 审核人：<div class="read" style="float:right">编辑:xxx 审核人:yyy</div>
    const readRegex = /<div[^>]*class="[^"]*read[^"]*"[^>]*>([\s\S]*?)<\/div>/gi;
    let readMatch: RegExpExecArray | null;
    while ((readMatch = readRegex.exec(html)) !== null) {
      const txt: string = readMatch[1].replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').trim();
      if (txt.indexOf('编辑') >= 0 || txt.indexOf('审核') >= 0) {
        d.editor = txt;
        break;
      }
    }
    // 正文区：wp_articlecontent（注意该站用单引号 class！）
    const bodyMatch = /<div[^>]*class=['"][^'"]*wp_articlecontent[^'"]*['"][^>]*>([\s\S]*?)<\/div>/i.exec(html);
    const bodyHtml: string = bodyMatch !== null ? bodyMatch[1] : '';
    // 按 <p> 顺序解析
    const pRegex = /<p[^>]*>([\s\S]*?)<\/p>/gi;
    let pMatch: RegExpExecArray | null;
    while ((pMatch = pRegex.exec(bodyHtml)) !== null) {
      const inner: string = pMatch[1];
      const imgRegex = /<img[^>]*src=['"]([^'"]*)['"][^>]*>/gi;
      let hasImg = false;
      let imgMatch: RegExpExecArray | null;
      while ((imgMatch = imgRegex.exec(inner)) !== null) {
        hasImg = true;
        let src: string = imgMatch[1];
        if (src.startsWith('/')) { src = NewsApi.BASE + src; }
        const block: ContentBlock = new ContentBlock();
        block.type = 'image';
        block.value = src;
        d.blocks.push(block);
      }
      if (!hasImg) {
        const text: string = inner.replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').trim();
        if (text.length > 0) {
          const block: ContentBlock = new ContentBlock();
          block.type = 'text';
          block.value = text;
          d.blocks.push(block);
        }
      }
    }
    return d;
  }
}
