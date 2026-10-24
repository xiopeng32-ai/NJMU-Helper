/**
 * 通知生命周期清理（退出登录 / 清空数据）
 *
 * 必须成对撤销，否则会出现"退出登录后还弹旧课的提醒"、
 * "换账号后把新账号成绩当成新增刷屏"。
 *
 * 调用点（唯一）：
 *  - pages/Index.ets 的 onLogout 回调
 *  - 清空数据流程末尾
 */
import { DataStore } from './DataStore';
import { LogStore } from './LogStore';
import { ReminderGateway } from './ReminderGateway';
import { LiveViewGateway } from './LiveViewGateway';
import { NotifyScheduler } from './NotifyScheduler';
import { PushNotifier } from './PushNotifier';

export class NotifyLifecycle {
  /**
   * 彻底清理：撤提醒 → 停实况窗 → 取消后台任务 → 删快照 → 清待执行标记。
   * 幂等，可重复调用。
   */
  static async purge(reason: string): Promise<void> {
    try {
      // 先挂起：停 tick，否则撤销后 1 分钟内实况窗会按旧课表重新创建
      NotifyScheduler.suspend(reason);
      await ReminderGateway.cancelAllOurs();
      await LiveViewGateway.stopAll();
      await NotifyScheduler.cancelBackgroundWork();
      await PushNotifier.cancel(PushNotifier.ID_BASE_CLASS_ONGOING);
      await PushNotifier.cancel(PushNotifier.ID_BASE_SCORE);
      await PushNotifier.cancel(PushNotifier.ID_BASE_NOTICE);
      await PushNotifier.cancel(PushNotifier.ID_BASE_EXAM);
      DataStore.remove(DataStore.KEY_NOTIFY_SNAPSHOT);
      // 旧账号课表与实况窗 id 一并清除，防止换账号后按旧数据重排/接管
      DataStore.remove(DataStore.KEY_COURSES);
      DataStore.remove(DataStore.KEY_NOTIFY_LV_ACTIVE);
      DataStore.put(DataStore.KEY_NOTIFY_PENDING_STOP, '0');
      DataStore.put(DataStore.KEY_NOTIFY_SESSION_DATE, '');
      LogStore.log('通知', '清理', '完成', reason);
    } catch (e) {
      LogStore.log('通知', '清理', '失败', LogStore.errorOf(e as Object));
    }
  }
}
