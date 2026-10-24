/**
 * 通知发送（系统通知）
 *
 * 能力事实：
 *  - notificationManager.publish 在"通知权限未授予"时**静默失败**（不抛异常），
 *    因此每次发送前用 isNotificationEnabledSync() 预检，失败写日志而非误以为成功；
 *  - 通知槽（Slot）需要在首次发送前创建，否则部分机型会落到默认槽（无声音/无横幅）；
 *  - 点击跳转用 wantAgent，参数与桌面卡片一致走 want.parameters.open，
 *    由 EntryAbility 透传到 AppState.openPageRequest。
 */
import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogStore } from './LogStore';
import { NotifyPayload } from '../model/NotifyModels';

export class PushNotifier {
  /** 通知槽类型：服务信息（课程/成绩这类"通知型"消息） */
  static readonly SLOT_SERVICE: notificationManager.SlotType = notificationManager.SlotType.SERVICE_INFORMATION;
  /** 通知 id 分配段：避免与代理提醒的 notificationId 冲突 */
  static readonly ID_BASE_SCORE: number = 1001;
  static readonly ID_BASE_NOTICE: number = 1101;
  static readonly ID_BASE_EXAM: number = 1201;
  static readonly ID_BASE_SESSION: number = 1301;
  static readonly ID_BASE_CLASS_ONGOING: number = 1401;

  private static slotReady: boolean = false;

  /** 创建通知槽（幂等；失败不阻断，publish 会回落默认槽） */
  static async ensureSlot(): Promise<void> {
    if (PushNotifier.slotReady) {
      return;
    }
    try {
      await notificationManager.addSlot(PushNotifier.SLOT_SERVICE);
      PushNotifier.slotReady = true;
    } catch (e) {
      LogStore.log('通知', '建槽', '失败', LogStore.errorOf(e as Object));
    }
  }

  /** 通知权限是否已授予（同步，避免 await 打乱调用节奏） */
  static enabled(): boolean {
    try {
      return notificationManager.isNotificationEnabledSync();
    } catch (e) {
      return false;
    }
  }

  /** 申请通知权限（必须在 UIAbility 上下文调用，只在设置页/前台触发） */
  static async requestPermission(context: common.UIAbilityContext): Promise<boolean> {
    if (PushNotifier.enabled()) {
      return true;
    }
    try {
      await notificationManager.requestEnableNotification(context);
      return PushNotifier.enabled();
    } catch (e) {
      LogStore.log('通知', '申请权限', '失败', LogStore.errorOf(e as Object));
      return false;
    }
  }

  /** 构造点击跳转（open = score / notice / schedule / home） */
  private static async clickAgent(open: string): Promise<WantAgent | undefined> {
    try {
      return await wantAgent.getWantAgent({
        wants: [{
          bundleName: 'com.njmu.helper',
          abilityName: 'EntryAbility',
          parameters: { 'open': open }
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
    } catch (e) {
      return undefined;
    }
  }

  /**
   * 发送一条通知。返回是否真正发出（权限关闭/异常时返回 false）。
   * 注意：不要在后台任务里申请权限，只发。
   */
  static async push(payload: NotifyPayload): Promise<boolean> {
    if (!PushNotifier.enabled()) {
      LogStore.log('通知', '发送', '跳过（未授权）', payload.group);
      return false;
    }
    await PushNotifier.ensureSlot();
    try {
      const agent: WantAgent | undefined = await PushNotifier.clickAgent(payload.open);
      const req: notificationManager.NotificationRequest = {
        id: payload.id,
        notificationSlotType: PushNotifier.SLOT_SERVICE,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: payload.title,
            text: payload.text
          }
        },
        tapDismissed: true,
        wantAgent: agent
      };
      if (payload.ongoing === true) {
        req.isOngoing = true;
        req.isUnremovable = false;
      }
      if (payload.autoDeletedTime !== undefined && payload.autoDeletedTime > 0) {
        req.autoDeletedTime = payload.autoDeletedTime;
      }
      await notificationManager.publish(req);
      LogStore.log('通知', '发送', '成功', `${payload.group}#${payload.id} ${payload.title}`);
      return true;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      LogStore.log('通知', '发送', '失败', `${err.code ?? ''} ${err.message ?? LogStore.errorOf(e as Object)}`);
      return false;
    }
  }

  /** 合并发送：同一事件多条时只发一条，避免刷屏（>max 折叠为"等 N 项"） */
  static async pushMerged(baseId: number, group: string, title: string,
    items: string[], open: string, max: number = 5): Promise<boolean> {
    if (items.length === 0) {
      return false;
    }
    let text: string = '';
    if (items.length <= max) {
      text = items.join('、');
    } else {
      text = `${items.slice(0, max).join('、')} 等 ${items.length} 项`;
    }
    return PushNotifier.push({ id: baseId, group, title, text, open });
  }

  /** 撤销某条通知 */
  static async cancel(id: number): Promise<void> {
    try {
      await notificationManager.cancel(id);
    } catch (e) {
      // 通知不存在时忽略
    }
  }

  /** 撤销某分组下的通知（按 id 段） */
  static async cancelRange(baseId: number, count: number): Promise<void> {
    for (let i: number = 0; i < count; i++) {
      await PushNotifier.cancel(baseId + i);
    }
  }
}
