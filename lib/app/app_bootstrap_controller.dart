import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/auth/unified_auth.dart';
import '../core/auth/zhengfang_auth.dart';
import '../core/logging/app_logger.dart';
import '../core/network/dio_client.dart';
import '../core/network/network_settings.dart';
import '../core/semester/semester_calendar.dart';
import '../core/theme/app_preferences_controller.dart';
import '../core/theme/personalization_controller.dart';
import '../core/update/update_checker.dart';
import '../features/campus_card/campus_card_service.dart';
import '../features/changxing_jiada/changxing_jiada_service.dart';
import '../features/dorm_electricity/dorm_electricity_service.dart';
import '../features/exam/exam_service.dart';
import '../features/grades/grades_service.dart';
import '../features/schedule/schedule_service.dart';

enum AppBootstrapPhase { idle, warming, localStateReady, completed }

class AppBootstrapController {
  AppBootstrapController._();

  static final AppBootstrapController instance = AppBootstrapController._();

  final ValueNotifier<AppBootstrapPhase> phase = ValueNotifier(
    AppBootstrapPhase.idle,
  );

  /// 导航就绪派生信号：phase 进入 localStateReady / completed 即为 true。
  /// 供 core 层（如 AppShortcutService）注入消费，避免其反向依赖 app 层。
  final ValueNotifier<bool> navigationReady = ValueNotifier(false);

  /// phase 的统一写入点，同步派生的 navigationReady。
  void _setPhase(AppBootstrapPhase value) {
    phase.value = value;
    navigationReady.value =
        value == AppBootstrapPhase.localStateReady ||
        value == AppBootstrapPhase.completed;
  }

  Future<void>? _prepareFuture;
  Future<void>? _warmUpFuture;
  bool _warmUpScheduled = false;

  Future<void> prepareForFirstFrame() async {
    final existing = _prepareFuture;
    if (existing != null) return existing;

    final future = _prepareForFirstFrame();
    _prepareFuture = future;
    await future;
  }

  Future<void> _prepareForFirstFrame() async {
    await AppPreferencesController.instance.restore();

    await Future.wait<void>([
      SemesterCalendar.instance.init(),
      PersonalizationController.instance.init(),
    ]);
  }

  void scheduleWarmUpAfterFirstFrame() {
    if (_warmUpScheduled) return;
    _warmUpScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(warmUpAfterFirstFrame());
    });
  }

  Future<void> warmUpAfterFirstFrame() async {
    final existing = _warmUpFuture;
    if (existing != null) return existing;

    final future = _runWarmUp();
    _warmUpFuture = future;
    try {
      await future;
    } catch (_) {
      if (identical(_warmUpFuture, future)) {
        _warmUpFuture = null;
      }
      rethrow;
    }
  }

  Future<void> _runWarmUp() async {
    _setPhase(AppBootstrapPhase.warming);

    await AppLogger.instance.init();
    await NetworkSettings.instance.ensureInitialized();
    await DioClient.instance.ensureInitialized();

    await Future.wait<void>([
      ZhengfangAuth.instance.restoreSession(),
      UnifiedAuthService.instance.restoreSession(syncWebViewCookies: false),
      CampusCardService.instance.restoreBalance(),
      ChangxingJiadaService.instance.restoreSession(),
      DormElectricityService.instance.restoreCache(),
      ScheduleService.instance.restoreCache(),
      ExamService.instance.restoreCache(),
      GradesService.instance.restoreCache(),
    ]);

    _setPhase(AppBootstrapPhase.localStateReady);
    await Future<void>.delayed(Duration.zero);
    _setPhase(AppBootstrapPhase.completed);
    if (UpdateChecker.instance.isUpdateEnabled) {
      unawaited(UpdateChecker.instance.check(silent: true));
    }
  }

  @visibleForTesting
  void debugReset({AppBootstrapPhase phaseValue = AppBootstrapPhase.idle}) {
    _prepareFuture = null;
    _warmUpFuture = null;
    _warmUpScheduled = false;
    _setPhase(phaseValue);
  }

  @visibleForTesting
  void debugSetPhase(AppBootstrapPhase phaseValue) {
    _setPhase(phaseValue);
  }
}
