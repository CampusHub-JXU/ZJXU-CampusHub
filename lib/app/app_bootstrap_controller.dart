import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/auth/auth_recovery_state_store.dart';
import '../core/auth/automatic_login.dart';
import '../core/auth/unified_auth.dart';
import '../core/auth/zhengfang_auth.dart';
import '../core/async/run_isolated.dart';
import '../core/logging/app_logger.dart';
import '../core/network/dio_client.dart';
import '../core/network/network_settings.dart';
import '../core/profile/user_profile_controller.dart';
import '../core/semester/semester_calendar.dart';
import '../core/theme/app_preferences_controller.dart';
import '../core/theme/glass_style_controller.dart';
import '../core/theme/personalization_controller.dart';
import '../core/update/update_checker.dart';
import '../features/campus_card/campus_card_service.dart';
import '../features/changxing_jiada/changxing_jiada_service.dart';
import '../features/dorm_electricity/dorm_electricity_service.dart';
import '../features/dorm_electricity/dorm_electricity_background.dart';
import '../features/exam/exam_service.dart';
import '../features/grades/grades_service.dart';
import '../features/schedule/schedule_service.dart';

enum AppBootstrapPhase { idle, warming, localStateReady, completed }

class AppBootstrapController {
  AppBootstrapController._();

  static final AppBootstrapController instance = AppBootstrapController._();

  /// 暖启动步骤标识（同时作为测试注入 override 的 key）。
  static const warmUpStepZhengfangAuth = '教务身份恢复';
  static const warmUpStepUnifiedAuth = '统一认证身份恢复';
  static const warmUpStepChangxingJiada = '长兴佳达会话恢复';
  static const warmUpStepDormElectricity = '电费缓存恢复';
  static const warmUpStepDormAlert = '电费前台提醒检查';
  static const warmUpStepSchedule = '课表缓存恢复';
  static const warmUpStepCampusCard = '校园卡余额缓存恢复';
  static const warmUpStepExam = '考试缓存恢复';
  static const warmUpStepGrades = '成绩缓存恢复';

  /// 测试注入：按步骤标识替换真实恢复动作（可记录顺序 / 制造失败）。
  @visibleForTesting
  final Map<String, Future<void> Function()> debugWarmUpStepOverrides = {};

  /// 测试注入：替换暖启动后的静默自动登录动作。
  @visibleForTesting
  Future<AutomaticLoginOutcome> Function(
    AuthRecoveryDomain domain, {
    String? expectedAccount,
  })?
  debugAutomaticLoginAttemptOverride;

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
      // 磨砂闪粉开关须在首帧前就位，避免开启闪粉的用户冷启动首帧缺贴图再补上。
      GlassStyleController.instance.restore(),
      SemesterCalendar.instance.init(),
      PersonalizationController.instance.init(),
      UserProfileController.instance.init(),
    ]);
    // 学号→入学年级识别依赖加密凭据读取，放暖启动阶段，失败不影响首帧。
    unawaited(UserProfileController.instance.refreshAutoEnrollmentYear());
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

    // 第一段：并行恢复两域认证身份（成绩 / 考试 / 校园卡缓存按账号隔离，
    // 必须先拿到明确身份）。长兴佳达 / 电费 / 课表恢复不依赖身份，与认证并行。
    await Future.wait<void>([
      _runWarmUpStep(
        warmUpStepZhengfangAuth,
        () => ZhengfangAuth.instance.restoreSession(),
      ),
      _runWarmUpStep(
        warmUpStepUnifiedAuth,
        () => UnifiedAuthService.instance.restoreSession(
          syncWebViewCookies: false,
        ),
      ),
      _runWarmUpStep(
        warmUpStepChangxingJiada,
        () => ChangxingJiadaService.instance.restoreSession(),
      ),
      _runWarmUpStep(
        warmUpStepDormElectricity,
        () => DormElectricityService.instance.restoreCache(),
      ),
      _runWarmUpStep(
        warmUpStepSchedule,
        () => ScheduleService.instance.restoreCache(),
      ),
    ]);

    // 身份恢复后：某域仍未登录时前台静默尝试一次自动登录。不阻塞暖启动，
    // 两域各自独立发起（互不等待），异常按域隔离。
    _maybeStartSilentAutomaticLogin();

    // 第二段：身份就绪后再恢复按 owner 隔离的缓存，避免读到别的账号数据。
    await Future.wait<void>([
      _runWarmUpStep(
        warmUpStepCampusCard,
        () => CampusCardService.instance.restoreBalance(),
      ),
      _runWarmUpStep(warmUpStepExam, () => ExamService.instance.restoreCache()),
      _runWarmUpStep(
        warmUpStepGrades,
        () => GradesService.instance.restoreCache(),
      ),
    ]);

    _setPhase(AppBootstrapPhase.localStateReady);
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      // The newly registered periodic worker has a 15-minute initial delay;
      // perform the user-visible low-balance check in the foreground after
      // owner-scoped caches and identity have been restored. This path never
      // restores credentials or initiates automatic login.
      unawaited(
        _runWarmUpStep(
          warmUpStepDormAlert,
          DormElectricityBackground.instance.foregroundCheck,
        ),
      );
    }
    await Future<void>.delayed(Duration.zero);
    _setPhase(AppBootstrapPhase.completed);
    if (UpdateChecker.instance.isUpdateEnabled) {
      unawaited(UpdateChecker.instance.check(silent: true));
    }
  }

  /// 单个暖启动步骤：失败只记日志，绝不阻断整个暖启动。
  Future<void> _runWarmUpStep(String label, Future<void> Function() action) =>
      runIsolated(
        label,
        debugWarmUpStepOverrides[label] ?? action,
        message: (label) => '$label失败，已跳过（不影响暖启动）',
      );

  /// 对每个仍未登录的认证域发起一次静默自动登录（unawaited）。
  ///
  /// 只在前台单 isolate 发起；两域并发发起但互不等待，也不阻塞暖启动。
  void _maybeStartSilentAutomaticLogin() {
    for (final domain in AuthRecoveryDomain.values) {
      if (_isDomainLoggedIn(domain)) continue;
      unawaited(_runSilentAutomaticLogin(domain));
    }
  }

  bool _isDomainLoggedIn(AuthRecoveryDomain domain) => switch (domain) {
    AuthRecoveryDomain.cas => UnifiedAuthService.instance.isLoggedIn,
    AuthRecoveryDomain.academic => ZhengfangAuth.instance.isLoggedIn,
  };

  Future<void> _runSilentAutomaticLogin(AuthRecoveryDomain domain) async {
    try {
      final override = debugAutomaticLoginAttemptOverride;
      final attempt = override ?? AutomaticLoginService.instance.attempt;
      final expectedAccount = switch (domain) {
        AuthRecoveryDomain.cas => UnifiedAuthService.instance.currentAccount,
        AuthRecoveryDomain.academic => ZhengfangAuth.instance.currentStudentId,
      };
      final outcome = await attempt(domain, expectedAccount: expectedAccount);
      AppLogger.instance.log(
        LogLevel.info,
        LogCategory.general,
        '静默自动登录（${domain.wireName}）：${outcome.name}',
      );
    } catch (error, stackTrace) {
      AppLogger.instance.log(
        LogLevel.warn,
        LogCategory.general,
        '静默自动登录（${domain.wireName}）失败，已跳过',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @visibleForTesting
  void debugReset({AppBootstrapPhase phaseValue = AppBootstrapPhase.idle}) {
    _prepareFuture = null;
    _warmUpFuture = null;
    _warmUpScheduled = false;
    debugWarmUpStepOverrides.clear();
    debugAutomaticLoginAttemptOverride = null;
    _setPhase(phaseValue);
  }

  @visibleForTesting
  void debugSetPhase(AppBootstrapPhase phaseValue) {
    _setPhase(phaseValue);
  }
}
