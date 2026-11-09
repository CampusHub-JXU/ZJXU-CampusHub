// 第二课堂后台监控任务。
//
// 自 core/notification/background_task_service.dart 下沉（架构反转）：
// core 只保留通用 WorkManager 调度能力，订阅监控业务由本文件承载，
// 统一通过 BackgroundTaskService 的通用 API 注册任务。

import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import '../../core/auth/background_auth_run.dart';
import '../../core/auth/background_session_gate.dart';
import '../../core/logging/app_logger.dart';
import '../../core/notification/background_task_service.dart';
import 'second_classroom_subscription_service.dart';

const secondClassroomRecruitingMonitor = 'secondClassroomRecruitingMonitor';

/// 第二课堂后台监控：周期检查已订阅关键词的同名招募活动并发通知。
///
/// 请求经 `DioClient.unifiedAuthDio`（统一认证 `PersistCookieJar`，
/// `persistSession: true`）发出：第二课堂 `SESSION` 由前台 CAS ticket 兑换后
/// 落在该 jar，后台只读复用，不登录、不抢身份。响应的 Set-Cookie 仍会落进与
/// 前台共享的磁盘 jar——这正是后台 / 前台 jar 镜像互相覆盖的竞争面。因此在
/// WorkManager isolate 里经 [BackgroundAuthRun] 申领：
/// 前台心跳新鲜或他人持有申领时本轮**跳过**（返回 true，不报错、不退避；前台
/// resumed 时本就会自己跑一次监控，下个周期也会再查）。它不读写会话 epoch、
/// 不登录，所以无需钉住 epoch。
class SecondClassroomBackground {
  SecondClassroomBackground._({
    BackgroundSessionGate? gate,
    Future<SecondClassroomMonitorResult> Function()? check,
    Duration budget = const Duration(seconds: 60),
    Duration hardStopGrace = BackgroundAuthRun.defaultHardStopGrace,
  }) : _injectedGate = gate,
       _check = check ?? _defaultCheck,
       _monitorBudget = budget,
       _graceAfterBudget = hardStopGrace;
  static final instance = SecondClassroomBackground._();

  @visibleForTesting
  static SecondClassroomBackground debugNew({
    BackgroundSessionGate? gate,
    Future<SecondClassroomMonitorResult> Function()? check,
    Duration budget = const Duration(seconds: 60),
    Duration hardStopGrace = BackgroundAuthRun.defaultHardStopGrace,
  }) => SecondClassroomBackground._(
    gate: gate,
    check: check,
    budget: budget,
    hardStopGrace: hardStopGrace,
  );

  final BackgroundSessionGate? _injectedGate;
  final Future<SecondClassroomMonitorResult> Function() _check;
  final Duration _monitorBudget;
  final Duration _graceAfterBudget;

  static Future<SecondClassroomMonitorResult> _defaultCheck() =>
      SecondClassroomSubscriptionService.instance.checkRecruitingMatches(
        automatic: true,
      );

  /// 监控入口：WorkManager isolate 与主引擎前台（resumed 兜底）共用。
  Future<bool> runMonitor() async {
    try {
      final gate = _injectedGate ?? BackgroundSessionGate.instance;
      // 前台宿主自己就是心跳发布者，不向门申领；只有后台 isolate 需要让位。
      if (gate.isForegroundHost) {
        await _checkAndLog();
        return true;
      }
      final run = await BackgroundAuthRun.execute<void>(
        gate: gate,
        budget: _monitorBudget,
        hardStopGrace: _graceAfterBudget,
        label: '第二课堂后台监控',
        body: (_) => _checkAndLog(),
      );
      if (!run.claimed) {
        AppLogger.instance.storage(LogLevel.info, '第二课堂后台监控：前台在用或申领被占用，本轮跳过');
      } else if (run.timedOut) {
        AppLogger.instance.storage(LogLevel.warn, '第二课堂后台监控：预算耗尽，放弃本轮');
        return false;
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

  Future<void> _checkAndLog() async {
    final result = await _check();
    if (result.notificationCount > 0) {
      AppLogger.instance.storage(
        LogLevel.info,
        '第二课堂后台监控发现 ${result.notificationCount} 个同名招募活动',
      );
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
