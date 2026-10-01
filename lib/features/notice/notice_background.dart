// 教务处通知后台同步任务。
//
// 照 SecondClassroomBackground 模式：feature 侧只承载注册与后台入口，
// WorkManager 回调分发由 app/background_task_dispatcher.dart 组合接线。

import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import '../../core/auth/background_cas_recovery.dart';
import '../../core/logging/app_logger.dart';
import '../../core/notice/notice_fetch_service.dart';
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
      var outcome = await NoticeSyncService.instance.sync(
        trigger: NoticeSyncTrigger.background,
      );
      if (!outcome.skipped &&
          outcome.fetchStatus == NoticeFetchStatus.authRequired) {
        outcome = await _recoverAndRetry(outcome);
      }
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

  /// 统一认证会话过期：后台静默恢复一次并重试同步；无法恢复则发本地提醒。
  ///
  /// 前台正在使用（[BackgroundRecoveryResult.foregroundActive]）、探测不出
  /// （[BackgroundRecoveryResult.undetermined]）与没有身份
  /// （[BackgroundRecoveryResult.noIdentity]）时既不登录也不提醒——前者由
  /// 前台自己处理，后者可能只是网络抖动。
  Future<NoticeSyncOutcome> _recoverAndRetry(NoticeSyncOutcome expired) async {
    final result = await BackgroundCasRecovery.instance.recover();
    AppLogger.instance.network(LogLevel.info, '教务处通知后台会话恢复: ${result.name}');
    return handleRecoveryResult(result, expired);
  }

  /// 按恢复结果决定重试同步或发提醒。
  ///
  /// 仅「曾有身份但无法恢复」（notEligible / failed）才提醒；
  /// [BackgroundRecoveryResult.noIdentity]（从未登录 / 已主动退出）永不提醒。
  @visibleForTesting
  Future<NoticeSyncOutcome> handleRecoveryResult(
    BackgroundRecoveryResult result,
    NoticeSyncOutcome expired,
  ) async {
    switch (result) {
      case BackgroundRecoveryResult.recovered:
        return NoticeSyncService.instance.sync(
          trigger: NoticeSyncTrigger.afterLogin,
        );
      case BackgroundRecoveryResult.notEligible:
      case BackgroundRecoveryResult.failed:
        await NoticeSyncService.instance.notifyAuthExpired();
        return expired;
      case BackgroundRecoveryResult.noIdentity:
      case BackgroundRecoveryResult.foregroundActive:
      case BackgroundRecoveryResult.undetermined:
        return expired;
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
