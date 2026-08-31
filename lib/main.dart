import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/app_bootstrap_controller.dart';
import 'app/background_task_dispatcher.dart';
import 'app/routes.dart';
import 'core/auth/connect_mode_resolver.dart';
import 'core/logging/app_logger.dart';
import 'core/notification/app_notification_service.dart';
import 'core/notification/background_task_service.dart';
import 'core/push/push_service.dart';
import 'core/shortcut/app_shortcut_service.dart';
import 'features/second_classroom/second_classroom_subscription_service.dart';

void _handleNotificationPayload(String payload) {
  if (payload == 'dorm-electricity') {
    appRouter.goNamed('dorm-electricity');
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
          'Flutter 框架异常',
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
      unawaited(AppNotificationService.instance.initialize());
      unawaited(
        SecondClassroomSubscriptionService.instance.checkRecruitingMatches(),
      );
      unawaited(PushService.instance.initialize());
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
