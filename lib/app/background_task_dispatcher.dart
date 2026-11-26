// 后台任务组合接线层（app 层）。
//
// core/notification/background_task_service.dart 架构反转后，
// WorkManager 的回调 dispatcher 与各 feature 后台任务的注册组合
// 统一在此完成：core 只提供通用调度能力，本文件负责把业务任务
// 接到调度框架上。

import 'dart:ui';

import 'package:workmanager/workmanager.dart';

import '../core/async/run_isolated.dart';
import '../core/logging/app_logger.dart';
import '../core/notice/notice_sync_service.dart';
import '../core/notice/notice_sync_store.dart';
import '../core/academic/schedule_model.dart';
import '../features/dorm_electricity/dorm_electricity_background.dart';
import '../features/dorm_electricity/dorm_usage_background.dart';
import '../features/notice/notice_background.dart';
import '../features/schedule/schedule_service.dart';
import '../features/second_classroom/second_classroom_background.dart';
import '../features/second_classroom/second_classroom_subscription_service.dart';
import 'campus_widget_background.dart';

/// 与 main.dart 同源的二课堂课程来源：供后台 isolate 绑定。
Future<List<CourseEntry>> _loadSecondClassroomCourses() async {
  await ScheduleService.instance.restoreCache();
  return ScheduleService.instance.preferredSnapshot()?.courses ?? const [];
}

// ── WorkManager callback (secondary fallback) ──────────────────────────

@pragma('vm:entry-point')
void appBackgroundTaskDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    DartPluginRegistrant.ensureInitialized();
    if (task == campusWidgetRefresh) {
      try {
        return await CampusWidgetBackground.instance.run();
      } catch (error, stackTrace) {
        AppLogger.instance.log(
          LogLevel.warn,
          LogCategory.bootstrap,
          '后台任务「桌面组件刷新」失败',
          error: error,
          stackTrace: stackTrace,
        );
        return false;
      }
    }
    if (task == dormUsageCollect) {
      return DormUsageBackground.instance.run();
    }
    Future<bool> Function()? action;
    if (task == dormElectricityCheck) {
      action = DormElectricityBackground.instance.executeBackgroundCheck;
    }
    if (task == secondClassroomRecruitingMonitor) {
      // WorkManager isolate 内重绑课程来源（前台在 main.dart 绑过的不
      // 跨 isolate 生效），保持与前台一致的课表冲突检查。
      SecondClassroomSubscriptionService.courseLoader =
          _loadSecondClassroomCourses;
      action = SecondClassroomBackground.instance.runMonitor;
    }
    if (task == jwcNoticeSyncCheck) action = NoticeBackground.instance.runCheck;
    if (action != null) {
      return runBackgroundTaskAndPush(
        action: action,
        push: () => CampusWidgetBackground.instance.run(cacheOnly: true),
      );
    }
    return true;
  });
}

/// 单项后台任务异常隔离：捕获并记录后继续，绝不让单个任务失败中断
/// 同批次其它任务的注册 / 检查。
Future<void> _runIsolated(String label, Future<void> Function() action) =>
    runIsolated(
      label,
      action,
      category: LogCategory.bootstrap,
      message: (label) => '后台任务「$label」失败，已隔离继续',
    );

/// 初始化 WorkManager 并注册各 feature 周期任务。
///
/// 初始化失败时降级返回 false，且**不再**调用 [schedule]——未初始化的
/// WorkManager 上注册会抛平台异常。本函数不向上抛出：调用方（main）的
/// 前台生命周期兜底与后续启动流程不依赖后台注册成功。
Future<bool> initializeAndScheduleBackgroundTasks({
  required Future<void> Function() initialize,
  Future<void> Function()? schedule,
}) async {
  try {
    await initialize();
  } catch (error, stackTrace) {
    AppLogger.instance.log(
      LogLevel.warn,
      LogCategory.bootstrap,
      '后台任务调度初始化失败，跳过周期任务注册',
      error: error,
      stackTrace: stackTrace,
    );
    return false;
  }
  await (schedule ?? scheduleFeatureBackgroundTasks)();
  return true;
}

/// 注册所有 feature 的周期性后台任务（app 启动时调用）。
///
/// 逐项隔离：某个 feature 注册失败（平台通道异常等）不回滚、不中断
/// 其余 feature 的注册。
Future<void> scheduleFeatureBackgroundTasks({
  Future<void> Function()? scheduleDormElectricity,
  Future<void> Function()? scheduleSecondClassroom,
  Future<void> Function()? scheduleNotice,
  Future<void> Function()? scheduleWidget,
}) async {
  await _runIsolated(
    '电费周期任务注册',
    scheduleDormElectricity ??
        DormElectricityBackground.instance.ensureScheduled,
  );
  await _runIsolated(
    '第二课堂周期任务注册',
    scheduleSecondClassroom ??
        SecondClassroomBackground.instance.ensureScheduled,
  );
  await _runIsolated(
    '教务处通知周期任务注册',
    scheduleNotice ?? NoticeBackground.instance.ensureScheduled,
  );
  await _runIsolated(
    '桌面组件周期任务注册',
    scheduleWidget ?? CampusWidgetBackground.instance.ensureScheduled,
  );
}

/// 前台兜底检查 — app resumed 时调用，等价于原
/// BackgroundTaskService.foregroundCheckAndNotify() 的完整语义。
///
/// 先无条件重载通知磁盘状态（后台 isolate 写盘后的红点正确性不依赖
/// 网络、也不受节流影响）；重载本身失败同样隔离，不阻断后续检查。
/// 二课监控 / 电费刷新 / 通知补查相互独立，在重载尝试之后并行执行，
/// 任何一项异常都不会丢掉其它项的更新。
Future<void> runForegroundBackgroundChecks({
  Future<void> Function()? reloadNoticeState,
  Future<void> Function()? runSecondClassroomMonitor,
  Future<void> Function()? checkDormElectricity,
  Future<void> Function()? syncNotice,
}) async {
  await _runIsolated(
    '通知磁盘状态重载',
    reloadNoticeState ?? NoticeSyncStore.instance.reload,
  );

  await Future.wait<void>([
    _runIsolated(
      '第二课堂招募监控',
      runSecondClassroomMonitor ??
          SecondClassroomBackground.instance.runMonitor,
    ),
    _runIsolated(
      '电费前台检查',
      checkDormElectricity ??
          DormElectricityBackground.instance.foregroundCheck,
    ),
    _runIsolated(
      '教务处通知补查',
      syncNotice ??
          () => NoticeSyncService.instance.sync(
            trigger: NoticeSyncTrigger.foregroundAuto,
          ),
    ),
  ]);
}

/// 补推失败独立记录，不改变原业务任务重试语义；业务抛错仍执行补推。
Future<bool> runBackgroundTaskAndPush({
  required Future<bool> Function() action,
  required Future<bool> Function() push,
}) async {
  try {
    return await action();
  } finally {
    await _runIsolated('后台任务组件补推', () async {
      await push();
    });
  }
}
