/**
 * 防窥保护管理器
 *
 * 基于 HarmonyOS DeviceSecurityKit 的 dlpAntiPeep 模块，
 * 监听系统防窥状态变化，在检测到非机主窥屏时回调通知页面隐藏敏感内容。
 *
 * 权限说明：
 *  ohos.permission.DLP_GET_HIDE_STATUS 为受限权限，需在签名 profile 的 ACL 中配置。
 *  当前未声明该权限，API 调用失败时静默降级（不启用防窥但不影响页面正常使用）。
 *  如需启用，请在 AppGallery Connect 控制台为应用申请该权限的 ACL 授权。
 *
 * 使用前提：
 *  1. 签名 profile 已配置 ohos.permission.DLP_GET_HIDE_STATUS 的 ACL 授权
 *  2. 用户在「设置 > 隐私与安全 > 防窥保护」中为本应用开启开关
 *  3. 设备已开启人脸识别
 *
 * 典型用法：
 *   private peepMgr: AntiPeepManager = new AntiPeepManager();
 *   aboutToAppear() { this.peepMgr.start((hidden) => { this.isPeeped = hidden; }); }
 *   aboutToDisappear() { this.peepMgr.stop(); }
 */
import { dlpAntiPeep } from '@kit.DeviceSecurityKit';
import { common } from '@kit.AbilityKit';
import { LogStore } from './LogStore';

/** 防窥状态回调：true=检测到窥屏需隐藏，false=安全可显示 */
type PeepCallback = (hidden: boolean) => void;

export class AntiPeepManager {
  /** 开关状态静态缓存（多页面共享，30s 内不重复探测，减少 IPC 开销） */
  private static switchCache: boolean = false;
  private static switchCheckedAt: number = 0;
  private static readonly SWITCH_TTL: number = 30000;

  /** 当前是否处于窥屏状态 */
  private isHidden: boolean = false;
  /** 防窥开关是否已开启 */
  private switchOn: boolean = false;
  /** 状态变化回调 */
  private callback: PeepCallback | null = null;
  /** 是否已启动监听 */
  private listening: boolean = false;
  /** 保存注册的回调引用：off 不带回调会摘掉该事件的全部监听 */
  private handler: ((info: dlpAntiPeep.DlpAntiPeepStatus) => void) | null = null;

  /**
   * 启动防窥监听
   *
   * @param cb 状态变化回调（true=需隐藏敏感内容，false=可正常显示）
   */
  async start(cb: PeepCallback): Promise<void> {
    if (this.listening) {
      // 已注册：只更新回调，避免重复 on 造成多个监听
      this.callback = cb;
      return;
    }
    this.callback = cb;
    try {
      // 检查防窥开关是否已开启（30s 内复用缓存，避免页面来回切换反复 IPC）
      const now: number = Date.now();
      if (now - AntiPeepManager.switchCheckedAt < AntiPeepManager.SWITCH_TTL) {
        this.switchOn = AntiPeepManager.switchCache;
      } else {
        this.switchOn = await dlpAntiPeep.isDlpAntiPeepSwitchOn();
        AntiPeepManager.switchCache = this.switchOn;
        AntiPeepManager.switchCheckedAt = now;
      }
      LogStore.log('防窥', '开关状态', this.switchOn ? '已开启' : '未开启', '');

      if (!this.switchOn) {
        // 开关未开启，不监听，页面正常显示
        this.notify(false);
        return;
      }

      // 获取当前初始状态
      const status: dlpAntiPeep.DlpAntiPeepStatus = dlpAntiPeep.getDlpAntiPeepInfo();
      this.isHidden = status === dlpAntiPeep.DlpAntiPeepStatus.HIDE;
      this.notify(this.isHidden);

      // 注册状态变化监听
      this.listening = true;
      this.handler = (info: dlpAntiPeep.DlpAntiPeepStatus) => {
        const newHidden: boolean = info === dlpAntiPeep.DlpAntiPeepStatus.HIDE;
        if (newHidden !== this.isHidden) {
          this.isHidden = newHidden;
          this.notify(this.isHidden);
        }
      };
      dlpAntiPeep.on('dlpAntiPeep', this.handler);
    } catch (e) {
      const msg: string = `${e}`;
      // 设备/系统不支持 DLP 防窥能力属正常降级场景，不记为失败（避免误导排查）
      if (msg.indexOf('not supported') >= 0 || msg.indexOf('Capability') >= 0 || msg.indexOf('801') >= 0) {
        LogStore.log('防窥', '能力', '设备不支持（已降级）', msg);
      } else {
        LogStore.log('防窥', '启动异常', '降级运行', msg);
      }
      // 异常时不阻断页面正常使用
      this.notify(false);
    }
  }

  /** 停止监听，清理资源 */
  stop(): void {
    if (this.listening) {
      try {
        if (this.handler !== null) {
          dlpAntiPeep.off('dlpAntiPeep', this.handler);
          this.handler = null;
        }
      } catch (e) {
        // 忽略清理异常
      }
      this.listening = false;
    }
    this.callback = null;
    this.isHidden = false;
  }

  /** 获取当前窥屏状态 */
  get isPeeped(): boolean {
    return this.isHidden;
  }

  /** 获取防窥开关是否已开启 */
  get isEnabled(): boolean {
    return this.switchOn;
  }

  /** 静默查询开关状态（供设置页展示，失败返回 false 不打断） */
  static async querySwitch(): Promise<boolean> {
    try {
      const on: boolean = await dlpAntiPeep.isDlpAntiPeepSwitchOn();
      AntiPeepManager.switchCache = on;
      AntiPeepManager.switchCheckedAt = Date.now();
      return on;
    } catch (e) {
      return false;
    }
  }

  /** 拉起系统防窥设置页（静态便捷入口） */
  static async openSettings(context: common.UIAbilityContext): Promise<void> {
    try {
      await dlpAntiPeep.requestAntiPeepOptions(context);
    } catch (e) {
      LogStore.log('防窥', '拉起设置', '失败', `${e}`);
    }
  }

  /**
   * 拉起系统防窥保护设置页，引导用户开启
   *
   * @param context UIAbilityContext
   */
  async requestEnable(context: common.UIAbilityContext): Promise<void> {
    try {
      await dlpAntiPeep.requestAntiPeepOptions(context);
    } catch (e) {
      LogStore.log('防窥', '拉起设置', '失败', `${e}`);
    }
  }

  /** 通知回调 */
  private notify(hidden: boolean): void {
    if (this.callback !== null) {
      this.callback(hidden);
    }
  }
}
