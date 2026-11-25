import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../core/auth/academic_auth_guard.dart';
import '../core/auth/auth_recovery_state_store.dart';
import '../core/auth/automatic_login.dart';
import '../core/auth/connect_mode_resolver.dart';
import '../core/auth/unified_auth.dart';
import '../core/auth/zhengfang_auth.dart';
import '../core/async/run_isolated.dart';
import '../core/logging/app_logger.dart';
import '../features/campus_card/campus_card_service.dart';
import '../features/dorm_electricity/dorm_electricity_service.dart';
import '../features/exam/exam_service.dart';
import '../features/grades/grades_service.dart';
import '../features/schedule/schedule_service.dart';
import 'app_bootstrap_controller.dart';

/// 主引擎前台刷新入口。业务服务负责 owner/epoch 校验、去重、TTL 与成功落盘。
/// 后台只暂停此调度，不注册 WorkManager，也不启动后台登录。
class CampusRefreshCoordinator {
  CampusRefreshCoordinator({
    this.pollInterval = const Duration(minutes: 1),
    this._refresh,
    this._ready,
  });

  static final instance = CampusRefreshCoordinator();

  final Duration pollInterval;
  final Future<void> Function()? _refresh;
  final bool Function()? _ready;
  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _network;
  bool _started = false;
  bool _foreground = true;
  bool _queued = false;
  Future<void>? _running;
  DateTime? _lastScheduleAttempt;
  int? _scheduleRevision;

  void start() {
    if (_started) return;
    _started = true;
    AppBootstrapController.instance.phase.addListener(requestRefresh);
    ZhengfangAuth.instance.addListener(requestRefresh);
    UnifiedAuthService.instance.addListener(requestRefresh);
    _network = Connectivity().onConnectivityChanged.listen(
      (states) {
        if (states.any((state) => state != ConnectivityResult.none)) {
          requestRefresh();
        }
      },
      onError: (Object error) {
        AppLogger.instance.network(LogLevel.warn, '前台刷新网络监听失败', error: error);
      },
    );
    _startTimer();
    requestRefresh();
  }

  void _startTimer() {
    _timer?.cancel();
    if (_started && _foreground) {
      _timer = Timer.periodic(pollInterval, (_) => requestRefresh());
    }
  }

  void setForeground(bool foreground) {
    if (foreground) ConnectModeResolver.instance.invalidate();
    _foreground = foreground;
    AutomaticLoginService.instance.setForeground(foreground);
    _startTimer();
    if (foreground) requestRefresh();
  }

  bool get _canRefresh =>
      _foreground &&
      (_ready?.call() ?? AppBootstrapController.instance.navigationReady.value);

  /// 登录成功发生在刷新期间时排下一轮；同一轮内各资源错误相互隔离。
  void requestRefresh() {
    if (!_canRefresh) return;
    if (_running != null) {
      _queued = true;
      return;
    }
    unawaited(refreshNow());
  }

  Future<void> refreshNow() {
    if (!_canRefresh) return Future.value();
    final pending = _running;
    if (pending != null) return pending;
    final future = _run();
    _running = future;
    return future.whenComplete(() {
      if (!identical(_running, future)) return;
      _running = null;
      if (_queued) {
        _queued = false;
        requestRefresh();
      }
    });
  }

  Future<void> _run() async {
    if (_refresh != null) return _refresh();
    // 已保存的身份暂不可用时，按持久 opt-in / cooldown 恢复。显式登出不恢复。
    await Future.wait([
      if (!UnifiedAuthService.instance.isLoggedIn)
        _isolate('统一认证恢复', () async {
          await AutomaticLoginService.instance.attempt(AuthRecoveryDomain.cas);
        }),
      if (!ZhengfangAuth.instance.isLoggedIn)
        _isolate('教务恢复', () async {
          await AutomaticLoginService.instance.attempt(
            AuthRecoveryDomain.academic,
          );
        }),
    ]);
    if (!_canRefresh) return;
    final auth = ZhengfangAuth.instance;
    final owner = auth.currentStudentId;
    final now = DateTime.now();
    final scheduleDue =
        owner != null &&
        auth.isLoggedIn &&
        (_scheduleRevision != auth.sessionRevision ||
            _lastScheduleAttempt == null ||
            now.difference(_lastScheduleAttempt!) >=
                GradesService.refreshWindow);
    await Future.wait([
      if (owner != null &&
          auth.isLoggedIn &&
          (scheduleDue ||
              auth.mode == ZhengfangMode.webVpn ||
              GradesService.instance.isStale ||
              ExamService.instance.isStale))
        _isolate('教务选路', () async {
          await AcademicAuthGuard.acquireRoute();
          if (!_canRefresh || auth.verifiedStudentId != owner) return;
          await Future.wait([
            if (GradesService.instance.isStale)
              _isolate('成绩刷新', () async {
                await GradesService.instance.fetchGrades(owner);
              }),
            if (ExamService.instance.isStale)
              _isolate('考试刷新', () async {
                await ExamService.instance.fetchExams(studentId: owner);
              }),
            if (scheduleDue)
              _isolate('课表刷新', () async {
                final revision = auth.sessionRevision;
                final result = await ScheduleService.instance
                    .loadScheduleSnapshot(
                      termContext: ScheduleService.instance
                          .getCurrentTermContext(now),
                      forceRefresh: true,
                    );
                if (result.didRefresh && auth.sessionRevision == revision) {
                  _lastScheduleAttempt = now;
                  _scheduleRevision = revision;
                }
              }),
          ]);
        }),
      if (UnifiedAuthService.instance.isLoggedIn &&
          CampusCardService.instance.isStale)
        _isolate('校园卡刷新', () async {
          await CampusCardService.instance.fetchBalance();
        }),
      if (UnifiedAuthService.instance.isLoggedIn)
        _isolate('电费刷新', () async {
          final service = DormElectricityService.instance;
          if (await service.hasRoomConfig()) await service.fetchElectricity();
        }),
    ]);
  }

  Future<void> _isolate(String label, Future<void> Function() action) =>
      runIsolated(
        label,
        action,
        category: LogCategory.network,
        message: (label) => '$label未完成，下轮重试',
      );

  @visibleForTesting
  void dispose() {
    _started = false;
    _foreground = false;
    _timer?.cancel();
    unawaited(_network?.cancel());
    AppBootstrapController.instance.phase.removeListener(requestRefresh);
    ZhengfangAuth.instance.removeListener(requestRefresh);
    UnifiedAuthService.instance.removeListener(requestRefresh);
  }
}
