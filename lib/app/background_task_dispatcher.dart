// 后台任务组合接线层（app 层）。
//
// core/notification/background_task_service.dart 架构反转后，
// WorkManager 的回调 dispatcher 与各 feature 后台任务的注册组合
// 统一在此完成：core 只提供通用调度能力，本文件负责把业务任务
// 接到调度框架上。

import 'dart:ui';

import 'package:workmanager/workmanager.dart';

import '../core/notice/notice_sync_service.dart';
import '../core/notice/notice_sync_store.dart';
import '../features/dorm_electricity/dorm_electricity_background.dart';
import '../features/notice/notice_background.dart';
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
    if (task == jwcNoticeSyncCheck) {
      return await NoticeBackground.instance.runCheck();
    }
    return true;
  });
}

/// 注册所有 feature 的周期性后台任务（app 启动时调用）。
Future<void> scheduleFeatureBackgroundTasks() async {
  await DormElectricityBackground.instance.ensureScheduled();
  await SecondClassroomBackground.instance.ensureScheduled();
  await NoticeBackground.instance.ensureScheduled();
}

/// 前台兜底检查 — app resumed 时调用，等价于原
/// BackgroundTaskService.foregroundCheckAndNotify() 的完整语义。
Future<void> runForegroundBackgroundChecks() async {
  await SecondClassroomBackground.instance.runMonitor();
  await DormElectricityBackground.instance.foregroundCheck();
  // 教务处通知：先无条件重载磁盘状态（后台 isolate 写盘后的红点正确性
  // 不依赖网络同步、也不受节流影响），再自动补查（资格领取自动防抖）。
  await NoticeSyncStore.instance.reload();
  await NoticeSyncService.instance.sync(
    trigger: NoticeSyncTrigger.foregroundAuto,
  );
}
