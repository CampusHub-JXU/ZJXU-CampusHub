// 第二课堂后台监控任务。
//
// 自 core/notification/background_task_service.dart 下沉（架构反转）：
// core 只保留通用 WorkManager 调度能力，订阅监控业务由本文件承载，
// 统一通过 BackgroundTaskService 的通用 API 注册任务。

import 'package:workmanager/workmanager.dart';

import '../../core/logging/app_logger.dart';
import '../../core/notification/background_task_service.dart';
import 'second_classroom_subscription_service.dart';

const secondClassroomRecruitingMonitor = 'secondClassroomRecruitingMonitor';

/// 第二课堂后台监控：周期检查已订阅关键词的同名招募活动并发通知。
class SecondClassroomBackground {
  SecondClassroomBackground._();
  static final instance = SecondClassroomBackground._();

  /// 后台监控入口，由 app 层 dispatcher 在 WorkManager isolate 中调用。
  Future<bool> runMonitor() async {
    try {
      final result = await SecondClassroomSubscriptionService.instance
          .checkRecruitingMatches();
      if (result.notificationCount > 0) {
        AppLogger.instance.storage(
          LogLevel.info,
          '第二课堂后台监控发现 ${result.notificationCount} 个同名招募活动',
        );
      }
      return true;
    } catch (error, stackTrace) {
      AppLogger.instance.storage(
        LogLevel.warn,
        '第二课堂后台监控失败',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// 注册第二课堂后台监控任务：1 小时周期，仅在联网时执行。
  Future<void> ensureScheduled() async {
    await BackgroundTaskService.instance.registerPeriodicTask(
      uniqueName: secondClassroomRecruitingMonitor,
      frequency: const Duration(hours: 1),
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }
}
