// 后台任务组合接线层（app 层）。
//
// core/notification/background_task_service.dart 架构反转后，
// WorkManager 的回调 dispatcher 与各 feature 后台任务的注册组合
// 统一在此完成：core 只提供通用调度能力，本文件负责把业务任务
// 接到调度框架上。

import 'dart:ui';

import 'package:workmanager/workmanager.dart';

import '../features/dorm_electricity/dorm_electricity_background.dart';
import '../features/second_classroom/second_classroom_background.dart';

// ── WorkManager callback (secondary fallback) ──────────────────────────

@pragma('vm:entry-point')
void appBackgroundTaskDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    DartPluginRegistrant.ensureInitialized();
    if (task == dormElectricityCheck) {
      return await DormElectricityBackground.instance.executeBackgroundCheck();
    }
    if (task == secondClassroomRecruitingMonitor) {
      return await SecondClassroomBackground.instance.runMonitor();
    }
    return true;
  });
}

/// 注册所有 feature 的周期性后台任务（app 启动时调用）。
Future<void> scheduleFeatureBackgroundTasks() async {
  await DormElectricityBackground.instance.ensureScheduled();
  await SecondClassroomBackground.instance.ensureScheduled();
}

/// 前台兜底检查 — app resumed 时调用，等价于原
/// BackgroundTaskService.foregroundCheckAndNotify() 的完整语义。
Future<void> runForegroundBackgroundChecks() async {
  await SecondClassroomBackground.instance.runMonitor();
  await DormElectricityBackground.instance.foregroundCheck();
}
