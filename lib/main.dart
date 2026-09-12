import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/app_action_dispatcher.dart';
import 'app/app_bootstrap_controller.dart';
import 'app/background_task_dispatcher.dart';
import 'app/routes.dart';
import 'core/auth/connect_mode_resolver.dart';
import 'core/deep_link/campus_deep_link_service.dart';
import 'core/logging/app_logger.dart';
import 'core/notice/notice_sync_service.dart';
import 'core/notice/notice_sync_store.dart';
import 'core/notification/app_notification_service.dart';
import 'core/notification/background_task_service.dart';
import 'core/push/push_service.dart';
import 'core/shortcut/app_shortcut_service.dart';
import 'features/second_classroom/second_classroom_subscription_service.dart';
import 'features/home/widget/campus_widget_sync.dart';

/// Release 构建下为 true；用编译期常量替代 kDebugMode，避免额外导入 foundation。
const bool _isProductBuild = bool.fromEnvironment('dart.vm.product');

void _handleNotificationPayload(String payload) {
  if (payload == 'dorm-electricity') {
    appRouter.goNamed('dorm-electricity');
    return;
  }
  if (payload == NoticeSyncService.aggregatePayload) {
    appRouter.goNamed('notification-center');
    return;
  }

  final uri = Uri.tryParse(payload);
  if (uri == null) return;
  if (uri.path == 'second-classroom') {
    final id = uri.queryParameters['id']?.trim();
    appRouter.goNamed(
      'second-classroom',
      queryParameters: id == null || id.isEmpty
          ? const <String, String>{}
          : {'id': id},
    );
  }
}

Future<void> main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await AppLogger.instance.init();

      FlutterError.onError = (details) {
        AppLogger.instance.ui(
          LogLevel.error,
          // Debug 下带上诊断详情：FlutterErrorDetails 里含
          // 「The relevant error-causing widget was: <file:line>」，
          // 定位布局/构建期断言时必须靠它（Release 保持精简）。
          _isProductBuild
              ? 'Flutter 框架异常'
              : 'Flutter 框架异常 | ${details.toString()}',
          error: details.exception,
          stackTrace: details.stack,
          force: true,
        );
        FlutterError.presentError(details);
      };

      PlatformDispatcher.instance.onError = (error, stackTrace) {
        AppLogger.instance.log(
          LogLevel.error,
          LogCategory.general,
          'PlatformDispatcher 未捕获异常',
          error: error,
          stackTrace: stackTrace,
          force: true,
        );
        return true;
      };

      await AppBootstrapController.instance.prepareForFirstFrame();
      ConnectModeResolver.instance.start();
      runApp(JXUCampusHubApp());
      unawaited(
        AppShortcutService.instance.initialize(
          navigationReady: AppBootstrapController.instance.navigationReady,
          navigateToNamedRoute: appRouter.pushNamed,
        ),
      );
      unawaited(
        AppShortcutService.instance.syncDynamicShortcuts(
          AppShortcutService.defaultDynamicShortcuts,
        ),
      );
      unawaited(
        CampusDeepLinkService.instance.initialize(
          navigationReady: AppBootstrapController.instance.navigationReady,
          dispatch: AppActionDispatcher.dispatch,
        ),
      );
      // 桌面组件：订阅全局状态变化 + 启动时推一次缓存快照（PRD §14）。
      CampusWidgetSync.instance.start();
      unawaited(CampusWidgetSync.instance.syncNow());
      unawaited(AppNotificationService.instance.initialize());
      unawaited(
        SecondClassroomSubscriptionService.instance.checkRecruitingMatches(),
      );
      unawaited(PushService.instance.initialize());
      // 教务处通知：冷启动无条件重载磁盘状态（后台 isolate 写盘后的红点
      // 正确性不依赖后续 resumed 事件），并发起一次自动补查（claim 防抖）。
      unawaited(NoticeSyncStore.instance.reload());
      unawaited(
        NoticeSyncService.instance.sync(
          trigger: NoticeSyncTrigger.foregroundAuto,
        ),
      );
      AppNotificationService.instance.onTap = (payload) {
        _handleNotificationPayload(payload);
      };
      // Handle cold-start from notification tap.
      final pending = AppNotificationService.instance.pendingPayload;
      if (pending != null) {
        AppNotificationService.instance.clearPendingPayload();
        _handleNotificationPayload(pending);
      }
      AppBootstrapController.instance.scheduleWarmUpAfterFirstFrame();
      await BackgroundTaskService.instance.initialize(
        callbackDispatcher: appBackgroundTaskDispatcher,
      );
      // 注册各 feature 的周期性后台任务（原 initialize 内置的 dorm/二课注册）。
      await scheduleFeatureBackgroundTasks();

      // Check electricity on app resume (foreground) for timely notifications.
      final lifecycleListener = AppLifecycleListener(
        onStateChange: (state) {
          if (state == AppLifecycleState.resumed) {
            unawaited(runForegroundBackgroundChecks());
            CampusWidgetSync.instance.requestSync();
          }
        },
      );
      // Keep listener alive for app lifetime.
      // ignore: unused_local_variable
      lifecycleListener;
    },
    (error, stackTrace) {
      AppLogger.instance.log(
        LogLevel.error,
        LogCategory.general,
        'runZonedGuarded 未捕获异常',
        error: error,
        stackTrace: stackTrace,
        force: true,
      );
    },
  );
}
