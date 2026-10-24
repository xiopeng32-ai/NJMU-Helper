/**
 * ImageExport — 通用图片导出框架（成绩单 / 学业情况等共享）
 *
 * 通过对页面中已挂载、带 id 的卡片组件做快照（ComponentSnapshot.get），
 * 得到 PixelMap 后写入应用沙箱缓存目录，再通过系统"保存到相册"弹窗写入媒体库。
 *
 * 关键修正（避免"无弹出/看不到/不知道存哪"）：
 *  1. showAssetsCreationDialog 的 srcFileUris 必须是媒体库 URI，
 *     须用 fileUri.getUriFromPath(path) 转换（直接拼 file:// 字符串会导致不弹窗）；
 *  2. 弹窗授权只返回"目标媒体库 URI"，文件内容仍需自己用 fs.copyFile 写入，
 *     否则相册里是空文件/无内容；
 *  3. 保存成功后明确提示"已保存到系统相册"；用户取消/失败时给出本地路径兜底提示。
 */
import { image } from '@kit.ImageKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogStore } from './LogStore';

/** 导出结果：success 是否成功写入相册；path 为本地 PNG 绝对路径（供兜底提示/重新保存） */
export interface ExportResult {
  success: boolean;
  path: string;
  message: string;
}

export class ImageExport {
  /** 对指定 id 的组件快照并保存为 PNG，返回本地文件绝对路径（失败返回空串）。
   *  注意：仅适合高度不超过屏幕的组件；长列表请用 snapshotFromBuilder。 */
  static async snapshotToFile(context: common.UIAbilityContext,
    uiContext: UIContext, componentId: string, tag: string): Promise<string> {
    try {
      // 组件快照（组件必须已挂载在组件树，带 .id()；不可用 Visibility.Hidden，否则快照为空）
      const pm: image.PixelMap = await uiContext.getComponentSnapshot().get(componentId);
      if (pm === null || pm === undefined) {
        return '';
      }
      return ImageExport.writePixelMap(context, pm, tag);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      LogStore.log('导出图片', '快照失败', '失败', err.message ?? LogStore.errorOf(e as Object));
      return '';
    }
  }

  /** 用离屏 Builder 完整渲染并快照，适合超出屏幕高度的长内容（成绩/学业全量列表）。
   *  createFromBuilder 会把 Builder 渲染到独立完整画布，不受挂载尺寸/屏幕高度限制。 */
  static async snapshotFromBuilder(context: common.UIAbilityContext,
    uiContext: UIContext, builder: CustomBuilder, tag: string): Promise<string> {
    try {
      const pm: image.PixelMap = await uiContext.getComponentSnapshot().createFromBuilder(builder);
      if (pm === null || pm === undefined) {
        return '';
      }
      return ImageExport.writePixelMap(context, pm, tag);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      LogStore.log('导出图片', 'Builder快照失败', '失败', err.message ?? LogStore.errorOf(e as Object));
      return '';
    }
  }

  /** PixelMap 写 PNG 落盘（snapshotToFile / snapshotFromBuilder 共用） */
  private static async writePixelMap(context: common.UIAbilityContext,
    pm: image.PixelMap, tag: string): Promise<string> {
    let file: fileIo.File | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      const dir: string = `${context.cacheDir}/export_img`;
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const path: string = `${dir}/${tag}_${Date.now()}.png`;
      file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      packer = image.createImagePacker();
      const opts: image.PackingOption = { format: 'image/png', quality: 100 };
      await packer.packToFile(pm, file.fd, opts);
      fileIo.closeSync(file);
      file = null;
      await packer.release();
      packer = null;
      LogStore.log('导出图片', '快照完成', '成功', `路径=${path}`);
      return path;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      LogStore.log('导出图片', '写图失败', '失败', err.message ?? LogStore.errorOf(e as Object));
      return '';
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (e) {
          // ignore
        }
      }
      if (packer !== null) {
        try {
          await packer.release();
        } catch (e) {
          // ignore
        }
      }
      // 关键：长图快照（1080×6000+）单张可达 30MB，不释放会连续导出几次即 OOM
      try {
        await pm.release();
      } catch (e) {
        // ignore
      }
    }
  }

  /** 清理导出目录，只保留最近 max 个文件（按修改时间） */
  private static pruneExports(dir: string, max: number): void {
    try {
      const names: string[] = fileIo.listFileSync(dir);
      if (names.length <= max) {
        return;
      }
      const items: string[] = names.map((n: string) => `${dir}/${n}`);
      items.sort((a: string, b: string) => {
        try {
          return fileIo.statSync(a).mtime - fileIo.statSync(b).mtime;
        } catch (e) {
          return 0;
        }
      });
      const drop: number = items.length - max;
      for (let i: number = 0; i < drop; i++) {
        try {
          fileIo.unlinkSync(items[i]);
        } catch (e) {
          // ignore
        }
      }
      LogStore.log('导出图片', '清理旧图', '完成', `删除${drop}张 保留${max}张`);
    } catch (e) {
      // 目录不存在/读取失败时忽略
    }
  }

  /** 一键（Builder 版）：离屏完整渲染 Builder → 写 PNG → 保存相册/文档 */
  static async exportBuilder(context: common.UIAbilityContext, uiContext: UIContext,
    builder: CustomBuilder, tag: string, title: string): Promise<ExportResult> {
    const path: string = await ImageExport.snapshotFromBuilder(context, uiContext, builder, tag);
    if (path.length === 0) {
      return { success: false, path: '', message: '图片生成失败，请重试' };
    }
    return ImageExport.saveToAlbum(context, path, title);
  }

  /** 把本地 PNG 保存到系统相册（弹系统确认框），失败/超时/不支持时降级为「文档保存」选择器，返回结果。 */
  static async saveToAlbum(context: common.UIAbilityContext, localPath: string, title: string): Promise<ExportResult> {
    if (localPath.length === 0) {
      return { success: false, path: '', message: '图片生成失败，请重试' };
    }
    // 1) 沙箱路径 → 媒体库可识别的 URI（关键，直接拼 file:// 会不弹窗）
    const srcUri: string = fileUri.getUriFromPath(localPath);
    const safeTitle: string = title.replace(/[\\/:*?"<>|]/g, '');
    const cfg: photoAccessHelper.PhotoCreationConfig = {
      title: safeTitle,
      fileNameExtension: 'png',
      photoType: photoAccessHelper.PhotoType.IMAGE
    };
    // 2) 弹窗授权（10s 超时：部分设备/PC 不支持该能力，await 会永不返回导致卡"生成中"）
    try {
      const helper: photoAccessHelper.PhotoAccessHelper =
        photoAccessHelper.getPhotoAccessHelper(context);
      const dialogPromise: Promise<Array<string>> = helper.showAssetsCreationDialog([srcUri], [cfg]);
      const timeoutPromise: Promise<Array<string>> = new Promise<Array<string>>((resolve: (v: Array<string>) => void) => {
        setTimeout(() => {
          resolve(new Array<string>());
        }, 10000);
      });
      const desUris: Array<string> = await Promise.race([dialogPromise, timeoutPromise]);
      if (desUris.length > 0) {
        // 3) 把文件内容写入媒体库（弹窗只给目标 URI，内容需自己 copy）
        const srcFile: fileIo.File = fileIo.openSync(localPath, fileIo.OpenMode.READ_ONLY);
        const desFile: fileIo.File = fileIo.openSync(desUris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
        await fileIo.copyFile(srcFile.fd, desFile.fd);
        fileIo.closeSync(srcFile);
        fileIo.closeSync(desFile);
        LogStore.log('导出图片', '保存相册', '成功', `标题=${title}`);
        return { success: true, path: localPath, message: '已保存到系统相册' };
      }
      LogStore.log('导出图片', '保存相册', '跳过', '弹窗超时或取消，转文档保存');
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      LogStore.log('导出图片', '相册保存不可用', '降级', err.message ?? LogStore.errorOf(e as Object));
    }
    // 4) 降级：弹出「文档保存」选择器（所有设备都支持，用户自选保存位置，如下载目录）
    return ImageExport.saveViaDocumentPicker(localPath, title);
  }

  /** 降级方案：文档保存选择器（用户自选位置），保存成功返回 success */
  static async saveViaDocumentPicker(localPath: string, title: string): Promise<ExportResult> {
    try {
      const dp: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const opts: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      // 过滤文件名非法字符 \ / : * ? " < > | 及空白控制符
      opts.newFileNames = [`${title.replace(/[\\/:*?"<>|]/g, '')}.png`];
      const uris: Array<string> = await dp.save(opts);
      if (uris.length === 0) {
        return { success: false, path: localPath, message: '已取消保存' };
      }
      const srcFile: fileIo.File = fileIo.openSync(localPath, fileIo.OpenMode.READ_ONLY);
      const desFile: fileIo.File = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      await fileIo.copyFile(srcFile.fd, desFile.fd);
      fileIo.closeSync(srcFile);
      fileIo.closeSync(desFile);
      LogStore.log('导出图片', '文档保存', '成功', `uri=${uris[0]}`);
      return { success: true, path: localPath, message: '已保存到所选位置' };
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      LogStore.log('导出图片', '文档保存', '失败', err.message ?? LogStore.errorOf(e as Object));
      return { success: false, path: localPath, message: '保存失败' };
    }
  }

  /** 一键：快照组件 → 写 PNG → 保存相册（组合 snapshotToFile + saveToAlbum） */
  static async exportComponent(context: common.UIAbilityContext, uiContext: UIContext,
    componentId: string, tag: string, title: string): Promise<ExportResult> {
    const path: string = await ImageExport.snapshotToFile(context, uiContext, componentId, tag);
    if (path.length === 0) {
      return { success: false, path: '', message: '图片生成失败，请重试' };
    }
    return ImageExport.saveToAlbum(context, path, title);
  }
}
