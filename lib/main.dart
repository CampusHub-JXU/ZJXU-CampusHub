import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/app_bootstrap_controller.dart';
import 'core/logging/app_logger.dart';
import 'core/notification/app_notification_service.dart';
import 'core/notification/background_task_service.dart';
import 'core/shortcut/app_shortcut_service.dart';
import 'app/routes.dart';

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
      await AppShortcutService.instance.initialize(
        navigateToNamedRoute: appRouter.pushNamed,
      );
      await AppNotificationService.instance.initialize();
      runApp(JXUCampusHubApp());
      AppNotificationService.instance.onTap = (payload) {
        if (payload == 'dorm-electricity') {
          appRouter.goNamed('dorm-electricity');
        }
      };
      // Handle cold-start from notification tap.
      final pending = AppNotificationService.instance.pendingPayload;
      if (pending != null) {
        AppNotificationService.instance.clearPendingPayload();
        if (pending == 'dorm-electricity') {
          appRouter.goNamed('dorm-electricity');
        }
      }
      AppBootstrapController.instance.scheduleWarmUpAfterFirstFrame();
      await BackgroundTaskService.instance.initialize();
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
