import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/app_action_dispatcher.dart';
import 'app/app_bootstrap_controller.dart';
import 'app/background_task_dispatcher.dart';
import 'app/calendar_sync_coordinator.dart';
import 'app/campus_refresh_coordinator.dart';
import 'app/campus_widget_background.dart';
import 'app/routes.dart';
import 'core/auth/auth_session_persistence.dart';
import 'core/auth/background_session_gate.dart';
import 'core/auth/connect_mode_resolver.dart';
import 'core/auth/credential_store.dart';
import 'core/auth/unified_auth.dart';
import 'core/auth/zhengfang_auth.dart';
import 'core/calendar/calendar_reminder_settings.dart';
import 'core/deep_link/campus_deep_link_service.dart';
import 'core/logging/app_logger.dart';
import 'core/network/dio_client.dart';
import 'core/network/webview_direct_route.dart';
import 'core/notice/notice_sync_service.dart';
import 'core/notice/notice_sync_store.dart';
import 'core/theme/glass_refraction.dart';
import 'core/notification/app_notification_service.dart';
import 'core/notification/background_task_service.dart';
import 'core/shortcut/app_shortcut_service.dart';
import 'features/dorm_electricity/dorm_electricity_background.dart';
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

/// 生命周期代际：每次生命周期状态变化递增。`_onAppResumed` 要等最多 5 秒的
/// 后台对账，期间应用可能又退到后台；旧任务醒来时代际已变，必须放弃，不得再把
/// 前台刷新 / 自动登录重新打开。
int _lifecycleGeneration = 0;

/// 回到前台：先向后台会话恢复让位并对账其留下的变更，再启动前台刷新。
///
/// 对账失败只记日志，绝不阻断前台恢复。[generation] 是触发本次恢复时的
/// [_lifecycleGeneration]，任一 await 之后它若已变化就不再启动前台工作。
Future<void> _onAppResumed(int generation) async {
  try {
    final change = await BackgroundSessionGate.instance.enterForeground();
    if (change != null) {
      final auth = UnifiedAuthService.instance;
      switch (change.kind) {
        case BackgroundSessionChangeKind.refreshed:
          await DioClient.instance.reloadPersistedCookies();
          await auth.restoreSession(clearIfInactive: true);
          await ZhengfangAuth.instance.restoreSession(clearIfInactive: true);
          await reloadBackgroundWidgetCaches();
        case BackgroundSessionChangeKind.committed:
          // 后台已重登并把 Cookie 写盘：丢弃前台过期的内存镜像，重读磁盘，
          // 再把新 Cookie 同步进 WebView。
          await DioClient.instance.reloadPersistedCookies();
          await auth.restoreSession();
        case BackgroundSessionChangeKind.revoked:
          // 后台探测到服务端会话过期并持久登出、且未能重登：前台内存身份对账，
          // 随后由前台刷新协调器按既有逻辑（opt-in / 冷却）自动恢复。
          // 记录可能迟到：只在前台当前账号与持久 epoch 仍是被撤销的那一个时
          // 才登出，否则用户已在此期间重新登录，不得踢掉新会话。
          if (auth.isLoggedIn) {
            final currentEpoch = await AuthSessionPersistence.instance
                .readEpoch(CredentialSessionDomain.unified);
            if (change.revokedStillApplies(
              currentAccount: auth.currentAccount,
              currentEpoch: currentEpoch,
            )) {
              await auth.markLoggedOut();
            }
          }
      }
    }
  } catch (error, stackTrace) {
    AppLogger.instance.auth(
      LogLevel.warn,
      '回到前台时对账后台会话变更失败',
      error: error,
      stackTrace: stackTrace,
    );
  }
  if (generation != _lifecycleGeneration) return;
  CampusRefreshCoordinator.instance.setForeground(true);
  CalendarSyncCoordinator.instance.onAppResumed();
  unawaited(runForegroundBackgroundChecks());
  CampusWidgetSync.instance.requestSync();
}

Future<void> main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      // Dock 的液态玻璃折射 shader：预载失败会静默退回普通磨砂，不阻塞启动。
      unawaited(LiquidGlass.preload());
      await AppLogger.instance.init();
      // 冷启动：先建立前台心跳与变更基线，后台会话恢复见此即让位；冷启动的
      // CookieJar 本来就从磁盘读取，不需要对账历史变更。
      await BackgroundSessionGate.instance.enterForeground(coldStart: true);

      FlutterError.onError = (details) {
        AppLogger.instance.ui(
          LogLevel.error,
          // Debug 下带上完整诊断树：toDiagnosticsNode().toStringDeep() 含
          // informationCollector 输出（「The relevant error-causing widget was:
          // <file:line>」），定位布局/构建期断言必须靠它；details.toString()
          // 在该 Flutter 版本不含这一段（Release 保持精简）。
          _isProductBuild
              ? 'Flutter 框架异常'
              : 'Flutter 框架异常 | ${details.toDiagnosticsNode().toStringDeep()}',
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
      // 全局 WebView 直连：与 Dart 的 ignoreSystemProxy 保持一致（默认开启），
      // 即使系统开了代理，本 App 的 WebView 也直连。
      WebViewDirectRoute.instance.startGlobal();
      runApp(JXUCampusHubApp());
      // 课表系统日历同步：仅主引擎前台协调器，监听必须早于暖启动数据变化，
      // 以便身份/课表恢复后立即评估；不注册后台引擎、不触发自动登录。
      // 先恢复持久化的提醒提前量，保证首轮投影即用用户选择的值（默认 20）。
      await CalendarReminderSettings.instance.load();
      CalendarSyncCoordinator.instance.start();
      CampusRefreshCoordinator.instance.start();
      // 寝室电费身份对账：仅主引擎前台安装统一认证监听，登出 / 换号 /
      // 同号重登时串行取消残留的每日提醒与周期任务；监听同样早于认证暖
      // 启动。不注册后台引擎、不在 WorkManager isolate 调用。
      DormElectricityBackground.instance.start();
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
        SecondClassroomSubscriptionService.instance.checkRecruitingMatches(
          automatic: true,
        ),
      );
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

      // 前台生命周期兜底必须先于后台初始化安装：后台初始化 / 注册失败
      // 时仍能在 resumed 时执行前台检查。
      final lifecycleListener = AppLifecycleListener(
        onStateChange: (state) {
          final generation = ++_lifecycleGeneration;
          if (state == AppLifecycleState.resumed) {
            unawaited(_onAppResumed(generation));
          } else if (state == AppLifecycleState.inactive ||
              state == AppLifecycleState.paused ||
              state == AppLifecycleState.hidden) {
            // 退到后台/失焦：禁止启动新的日历写入（在途轮次在下一个 await
            // 边界失效）。
            CalendarSyncCoordinator.instance.onAppInactive();
            CampusRefreshCoordinator.instance.setForeground(false);
            // 只有真正退到后台才放开后台会话恢复；inactive（通知栏 / 系统
            // 弹窗）期间应用仍可见，心跳继续。
            if (state != AppLifecycleState.inactive) {
              unawaited(BackgroundSessionGate.instance.leaveForeground());
            }
          }
        },
      );
      // Keep listener alive for app lifetime.
      // ignore: unused_local_variable
      lifecycleListener;

      // 初始化失败时 helper 降级返回 false，不会在未初始化的 WorkManager
      // 上继续注册，也不会向上抛出破坏启动；各 feature 注册项内部逐项
      // 隔离异常。
      await initializeAndScheduleBackgroundTasks(
        initialize: () => BackgroundTaskService.instance.initialize(
          callbackDispatcher: appBackgroundTaskDispatcher,
        ),
      );
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
