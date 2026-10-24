/**
 * 后台延迟任务扩展（WorkScheduler）
 *
 * 约束（SDK 明写）：onWorkStart 有 **2 分钟**硬超时 → 这里只做：
 *   1) 初始化 DataStore
 *   2) 调 BackgroundRefresh.run()（内部每步都有超时预算）
 *   3) 立刻返回，不等待后续
 *
 * 注意：不能在这里申请通知权限（无 UI 上下文）；权限必须在设置页申请。
 */
import { WorkSchedulerExtensionAbility } from '@kit.BackgroundTasksKit';
import { workScheduler } from '@kit.BackgroundTasksKit';
import { DataStore } from '../common/DataStore';
import { LogStore } from '../common/LogStore';
import { BackgroundRefresh } from '../common/BackgroundRefresh';

export default class BackgroundWorkAbility extends WorkSchedulerExtensionAbility {
  /** 持有任务 Promise 引用，降低扩展进程在任务完成前被回收的概率（尽力而为） */
  private static inflight: Promise<void> | null = null;

  onWorkStart(work: workScheduler.WorkInfo): void {
    LogStore.log('后台', '任务启动', '开始', `workId=${work.workId}`);
    try {
      // 后台进程没有 Ability 上下文，用 this.context 初始化持久化
      DataStore.init(this.context);
    } catch (e) {
      LogStore.log('后台', '初始化', '失败', LogStore.errorOf(e as Object));
    }
    // 不 await：SDK 要求尽快返回；内部自带超时，跑完自行结束
    const t0: number = Date.now();
    BackgroundWorkAbility.inflight = BackgroundRefresh.run('bg-work').then(() => {
      LogStore.log('后台', '任务启动', '完成', `workId=${work.workId} 耗时${Date.now() - t0}ms`);
    }).catch((e: Object) => {
      LogStore.log('后台', '任务启动', '异常', LogStore.errorOf(e as Object));
    }).finally(() => {
      BackgroundWorkAbility.inflight = null;
    });
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    LogStore.log('后台', '任务停止', '完成', `workId=${work.workId}`);
  }
}
