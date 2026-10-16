import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../core/academic/academic_exceptions.dart';
import '../core/auth/academic_auth_guard.dart';
import '../core/auth/auth_operation_coordinator.dart';
import '../core/auth/auth_recovery_state_store.dart';
import '../core/auth/auth_session_persistence.dart';
import '../core/auth/automatic_login.dart';
import '../core/auth/background_auth_context.dart';
import '../core/auth/background_session_gate.dart';
import '../core/auth/credential_store.dart';
import '../core/auth/unified_auth.dart';
import '../core/auth/zhengfang_auth.dart';
import '../core/logging/app_logger.dart';
import '../core/network/dio_client.dart';
import '../core/network/network_settings.dart';
import '../core/notice/notice_fetch_service.dart';
import '../core/notice/notice_sync_service.dart';
import '../core/notice/notice_sync_store.dart';
import '../core/notification/background_task_service.dart';
import '../core/semester/semester_calendar.dart';
import '../core/system_surface/campus_widget_bridge.dart';
import '../core/system_surface/widget_refresh_state.dart';
import '../core/theme/app_preferences_controller.dart';
import '../core/theme/personalization_controller.dart';
import '../features/campus_card/campus_card_service.dart';
import '../features/dorm_electricity/dorm_electricity_service.dart';
import '../features/exam/exam_service.dart';
import '../features/home/widget/campus_widget_projection.dart';
import '../features/schedule/schedule_service.dart';

const campusWidgetRefresh = 'campusWidgetRefresh';

/// app 组合层聚合各 feature，不新增 feature 依赖边。
class CampusWidgetBackground {
  CampusWidgetBackground({
    BackgroundSessionGate? gate,
    WidgetRefreshState? state,
    Future<void> Function()? restore,
    List<Future<WidgetRefreshOutcome> Function()>? refreshers,
    Future<bool> Function()? push,
    Future<bool> Function()? online,
    Future<int?> Function()? installedWidgets,
  }) : _gate = gate ?? BackgroundSessionGate.instance,
       _state = state ?? WidgetRefreshState.instance,
       _restore = restore ?? _restoreCaches,
       _refreshers =
           refreshers ?? [_refreshSchedule, _refreshExams, _refreshNotices],
       _push = push ?? _pushCaches,
       _online =
           online ??
           (() async => !(await Connectivity().checkConnectivity()).contains(
             ConnectivityResult.none,
           )),
       _installedWidgets =
           installedWidgets ??
           CampusWidgetBridge.instance.backgroundInstalledCount;
  static final instance = CampusWidgetBackground();
  final BackgroundSessionGate _gate;
  final WidgetRefreshState _state;
  final Future<void> Function() _restore;
  final List<Future<WidgetRefreshOutcome> Function()> _refreshers;
  final Future<bool> Function() _push;
  final Future<bool> Function() _online;
  final Future<int?> Function() _installedWidgets;

  Future<void> ensureScheduled() =>
      BackgroundTaskService.instance.registerPeriodicTask(
        uniqueName: campusWidgetRefresh,
        frequency: const Duration(hours: 3),
        initialDelay: const Duration(hours: 3),
        constraints: Constraints(networkType: NetworkType.connected),
      );

  /// 整轮共用申领，含 guard 与 WebVPN 嵌套 CAS 登录。缓存补推不联网。
  Future<bool> run({bool cacheOnly = false}) async {
    final startedAt = DateTime.now();
    // 桌面上一个组件都没放就不联网、不自动登录：自动登录失败会计入身份错误
    // 暂停计数，不能为看不见的组件消耗。查不到（null）按已放置处理。
    if (!cacheOnly && await _installedWidgetsOrNull() == 0) {
      AppLogger.instance.network(LogLevel.info, '桌面组件后台刷新: 未放置组件，跳过');
      return true;
    }
    final claim = await _gate.tryClaim();
    if (claim == null) {
      if (cacheOnly) return true;
      if (await _gate.isForegroundActive()) {
        await _recordSafely(WidgetRefreshOutcome.skippedForeground, startedAt);
        return true;
      }
      // 另一个后台任务正持有申领（多为几秒的缓存补推）：交给 WorkManager
      // 退避重试，不记成「前台」，也不白白丢掉这一轮。
      AppLogger.instance.network(LogLevel.info, '桌面组件后台刷新: 申领被占用，稍后重试');
      return false;
    }
    final context = BackgroundAuthContext(
      mayContinue: () async => !await _gate.shouldYield(claim),
    );
    var outcome = WidgetRefreshOutcome.error;
    var sessionTouched = false;
    final poll = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(context.allowed());
    });
    final budget = Timer(
      const Duration(seconds: 105),
      () => context.cancelToken.cancel('widget budget'),
    );
    try {
      return await context.run(() async {
        if (!await context.allowed()) {
          outcome = WidgetRefreshOutcome.skippedForeground;
          return true;
        }
        await _restore();
        final results = <WidgetRefreshOutcome>[];
        if (!cacheOnly) {
          if (!await _online()) {
            results.add(WidgetRefreshOutcome.offline);
          } else {
            for (final refresh in _refreshers) {
              if (!await context.allowed()) break;
              sessionTouched = true;
              try {
                results.add(await refresh());
              } catch (error, stack) {
                AppLogger.instance.network(
                  LogLevel.warn,
                  '桌面组件后台数据刷新失败，保留缓存',
                  error: error,
                  stackTrace: stack,
                );
                results.add(
                  error is AcademicSessionExpired ||
                          error is AcademicAuthExpiredException
                      ? WidgetRefreshOutcome.authFailed
                      : WidgetRefreshOutcome.error,
                );
              }
            }
          }
        }
        if (!await context.allowed()) {
          outcome = await _gate.isForegroundActive()
              ? WidgetRefreshOutcome.skippedForeground
              : WidgetRefreshOutcome.error;
          return true;
        }
        final pushed = await _push();
        final summary = summarizeWidgetRefresh(results);
        // 推送失败时，若刷新本身已有明确原因（登录失败 / 离线）就保留它，
        // 只有刷新成功却没推出去才记 error。
        final refreshSucceeded =
            summary == WidgetRefreshOutcome.ok ||
            summary == WidgetRefreshOutcome.partial;
        outcome = pushed || !refreshSucceeded
            ? summary
            : WidgetRefreshOutcome.error;
        return pushed;
      });
    } catch (error, stack) {
      AppLogger.instance.network(
        LogLevel.warn,
        '桌面组件后台刷新异常',
        error: error,
        stackTrace: stack,
      );
      return false;
    } finally {
      poll.cancel();
      budget.cancel();
      if (!context.cancelToken.isCancelled) {
        context.cancelToken.cancel('widget finished');
      }
      // refreshed 仅要求前台重载两域持久状态，不推断登录成功。
      await _gate.release(
        claim,
        change: sessionTouched ? BackgroundSessionChangeKind.refreshed : null,
      );
      if (!cacheOnly) await _recordSafely(outcome, startedAt);
      AppLogger.instance.network(LogLevel.info, '桌面组件后台刷新: ${outcome.name}');
    }
  }

  Future<int?> _installedWidgetsOrNull() async {
    try {
      return await _installedWidgets();
    } catch (_) {
      return null;
    }
  }

  /// 记录失败只留日志，不覆盖本轮返回值（finally 里抛出会吞掉结果）。
  Future<void> _recordSafely(
    WidgetRefreshOutcome outcome,
    DateTime startedAt,
  ) async {
    try {
      await _state.record(outcome, at: startedAt);
    } catch (error, stack) {
      AppLogger.instance.network(
        LogLevel.warn,
        '桌面组件后台刷新结果落盘失败',
        error: error,
        stackTrace: stack,
      );
    }
  }
}

WidgetRefreshOutcome summarizeWidgetRefresh(
  List<WidgetRefreshOutcome> results,
) {
  if (results.isEmpty || results.every((r) => r == WidgetRefreshOutcome.ok)) {
    return WidgetRefreshOutcome.ok;
  }
  if (results.contains(WidgetRefreshOutcome.ok)) {
    return WidgetRefreshOutcome.partial;
  }
  if (results.contains(WidgetRefreshOutcome.authFailed)) {
    return WidgetRefreshOutcome.authFailed;
  }
  if (results.contains(WidgetRefreshOutcome.offline)) {
    return WidgetRefreshOutcome.offline;
  }
  return WidgetRefreshOutcome.error;
}

bool _themeRestored = false;
Future<void> _restoreCaches() async {
  final context = BackgroundAuthContext.current!;
  context.expectedEpochs[AuthRecoveryDomain.academic.wireName] =
      (await AuthSessionPersistence.instance.read(
        CredentialSessionDomain.academic,
      )).epoch;
  context.expectedEpochs[AuthRecoveryDomain.cas.wireName] =
      (await AuthSessionPersistence.instance.read(
        CredentialSessionDomain.unified,
      )).epoch;
  context.expectedAccounts[AuthRecoveryDomain.academic.wireName] =
      (await AuthSessionPersistence.instance.read(
        CredentialSessionDomain.academic,
      )).account ??
      (await CredentialStore.instance.loadCredentials())?.$1;
  context.expectedAccounts[AuthRecoveryDomain.cas.wireName] =
      (await AuthSessionPersistence.instance.read(
        CredentialSessionDomain.unified,
      )).account ??
      (await CredentialStore.instance.loadUnifiedAuthCredentials())?.$1;
  await (await SharedPreferences.getInstance()).reload();
  await NetworkSettings.instance.ensureInitialized();
  await DioClient.instance.ensureInitialized();
  await DioClient.instance.reloadPersistedCookies();
  await ZhengfangAuth.instance.restoreSession(clearIfInactive: true);
  await UnifiedAuthService.instance.restoreSession(
    syncWebViewCookies: false,
    clearIfInactive: true,
  );
  await SemesterCalendar.instance.init();
  await PersonalizationController.instance.init();
  _themeRestored = false;
  try {
    await AppPreferencesController.instance.restore();
    _themeRestored = true;
  } catch (_) {}
  // 恢复失败就保留原生旧快照，不将尚未恢复的数据投影为空。
  await ScheduleService.instance.restoreCache();
  await ExamService.instance.restoreCache();
  await CampusCardService.instance.restoreBalance();
  await DormElectricityService.instance.restoreCache();
  await NoticeSyncStore.instance.reload();
}

Future<bool> _pushCaches() async {
  final academic = ZhengfangAuth.instance;
  final cas = UnifiedAuthService.instance;
  final revisions = (academic.sessionRevision, cas.sessionRevision);
  final envelopes = await Future.wait([
    AuthSessionPersistence.instance.read(CredentialSessionDomain.academic),
    AuthSessionPersistence.instance.read(CredentialSessionDomain.unified),
  ]);
  final expected = BackgroundAuthContext.current!.expectedEpochs;
  if (envelopes[0].epoch != expected[AuthRecoveryDomain.academic.wireName] ||
      envelopes[1].epoch != expected[AuthRecoveryDomain.cas.wireName]) {
    return false;
  }
  if (revisions != (academic.sessionRevision, cas.sessionRevision)) {
    return false;
  }
  if (envelopes[0].active != academic.isLoggedIn ||
      (academic.isLoggedIn &&
          envelopes[0].account != academic.verifiedStudentId) ||
      envelopes[1].active != cas.isLoggedIn ||
      (cas.isLoggedIn && envelopes[1].account != cas.verifiedAccount)) {
    return false;
  }
  final projection = buildCampusWidgetProjection().toMap();
  if (!_themeRestored) projection.remove('theme');
  // 复核投影期间的持久 epoch；仍不宣称跨 isolate 原子写入。
  for (var i = 0; i < envelopes.length; i++) {
    final domain = i == 0
        ? CredentialSessionDomain.academic
        : CredentialSessionDomain.unified;
    if ((await AuthSessionPersistence.instance.read(domain)).epoch !=
        envelopes[i].epoch) {
      return false;
    }
  }
  if (!await BackgroundAuthContext.current!.allowed()) return false;
  return CampusWidgetBridge.instance.pushBackgroundSnapshot(projection);
}

Future<bool> _ensureAcademic() async {
  if (ZhengfangAuth.instance.isLoggedIn) return true;
  final result = await AutomaticLoginService.instance.attemptWithReceipt(
    AuthRecoveryDomain.academic,
  );
  return result.outcome == AutomaticLoginOutcome.committed &&
      result.receipt != null;
}

Future<WidgetRefreshOutcome> _refreshSchedule() async {
  if (!await _ensureAcademic()) return WidgetRefreshOutcome.authFailed;
  final service = ScheduleService.instance;
  final result = await service.loadScheduleSnapshot(
    termContext: service.getCurrentTermContext(DateTime.now()),
    forceRefresh: true,
  );
  return result.requiresLogin
      ? WidgetRefreshOutcome.authFailed
      : result.didRefresh
      ? WidgetRefreshOutcome.ok
      : WidgetRefreshOutcome.error;
}

Future<WidgetRefreshOutcome> _refreshExams() async {
  if (!await _ensureAcademic()) return WidgetRefreshOutcome.authFailed;
  await ExamService.instance.fetchExams(forceRefresh: true);
  return WidgetRefreshOutcome.ok;
}

Future<WidgetRefreshOutcome> _refreshNotices() async {
  var result = await NoticeSyncService.instance.sync(
    trigger: NoticeSyncTrigger.background,
  );
  if (result.fetchStatus == NoticeFetchStatus.authRequired) {
    final auth = UnifiedAuthService.instance;
    final account =
        auth.currentAccount ??
        (await CredentialStore.instance.loadUnifiedAuthCredentials())?.$1;
    if (account == null ||
        await AuthOperationCoordinator.instance.automaticEligibility(
              AuthRecoveryDomain.cas,
              account: account,
            ) !=
            AuthRecoveryDecision.proceed) {
      return WidgetRefreshOutcome.authFailed;
    }
    // 资源响应已明确过期：直接复用隔离 challenge，保留旧身份直到真实提交。
    // 不先无条件撤销 epoch，否则会掩盖换号/旁路登录并破坏本轮归属。
    final attempt = await AutomaticLoginService.instance.attemptWithReceipt(
      AuthRecoveryDomain.cas,
      expectedAccount: account,
    );
    if (attempt.outcome != AutomaticLoginOutcome.committed ||
        attempt.receipt == null) {
      return WidgetRefreshOutcome.authFailed;
    }
    result = await NoticeSyncService.instance.sync(
      trigger: NoticeSyncTrigger.afterLogin,
    );
  }
  return result.skipped || result.ok
      ? WidgetRefreshOutcome.ok
      : result.fetchStatus == NoticeFetchStatus.authRequired
      ? WidgetRefreshOutcome.authFailed
      : WidgetRefreshOutcome.error;
}

/// 前台按后台变更记录重读业务缓存，确保内存不会把后台新快照覆盖回旧值。
Future<void> reloadBackgroundWidgetCaches() async {
  await (await SharedPreferences.getInstance()).reload();
  await ScheduleService.instance.restoreCache();
  await ExamService.instance.restoreCache();
  await CampusCardService.instance.restoreBalance();
  await DormElectricityService.instance.restoreCache();
}
