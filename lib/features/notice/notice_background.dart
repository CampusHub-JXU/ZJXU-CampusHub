// 教务处通知后台同步任务。
//
// 照 SecondClassroomBackground 模式：feature 侧只承载注册与后台入口，
// WorkManager 回调分发由 app/background_task_dispatcher.dart 组合接线。

import 'package:workmanager/workmanager.dart';

import '../../core/logging/app_logger.dart';
import '../../core/notice/notice_sync_service.dart';
import '../../core/notification/background_task_service.dart';

const jwcNoticeSyncCheck = 'jwcNoticeSyncCheck';

/// 教务处通知后台同步：每 2 小时检查一次（联网约束），发现新增公告后
/// 经待播报队列发聚合提醒。夜间静音与权限由状态机统一裁决。
class NoticeBackground {
  NoticeBackground._();
  static final instance = NoticeBackground._();

  /// 后台检查入口，由 app 层 dispatcher 在 WorkManager isolate 中调用。
  Future<bool> runCheck() async {
    try {
      final outcome = await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.background,
      );
      if (!outcome.skipped) {
        AppLogger.instance.network(
          LogLevel.info,
          '教务处通知后台同步: ${outcome.fetchStatus}, 新增 ${outcome.freshCount} 条, '
          '播报=${outcome.notified}',
        );
      }
      // 同步自身有 30 分钟退避（claim 判定），不依赖 WorkManager 重试。
      return true;
    } catch (error, stackTrace) {
      AppLogger.instance.network(
        LogLevel.warn,
        '教务处通知后台同步异常',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// 注册后台同步任务：2 小时周期，仅在联网时执行。不使用精确闹钟
  /// （周期后台工作不适用 alarmClock，见 PRD §4.5）。
  Future<void> ensureScheduled() async {
    await BackgroundTaskService.instance.registerPeriodicTask(
      uniqueName: jwcNoticeSyncCheck,
      frequency: const Duration(hours: 2),
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }
}
