import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../app/app_bootstrap_controller.dart';
import '../logging/app_logger.dart';

class AppShortcutService {
  AppShortcutService._();

  static final AppShortcutService instance = AppShortcutService._();

  static const campusCardPaymentAction = 'campus-card-payment';
  static const shuatiAction = 'shuati-practice';

  static const _channel = MethodChannel('edu.zjxu.jxucampushub/shortcut');

  bool _initialized = false;
  bool _phaseListenerRegistered = false;
  String? _pendingAction;
  Future<void> Function(String routeName)? _navigateToNamedRoute;

  Future<void> initialize({
    Future<void> Function(String routeName)? navigateToNamedRoute,
  }) async {
    _navigateToNamedRoute = navigateToNamedRoute ?? _navigateToNamedRoute;
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler(_handleMethodCall);
    if (!_phaseListenerRegistered) {
      AppBootstrapController.instance.phase.addListener(_flushPendingAction);
      _phaseListenerRegistered = true;
    }

    try {
      final initialAction = await _channel.invokeMethod<String>(
        'consumeInitialShortcutAction',
      );
      _queueAction(initialAction);
    } on MissingPluginException {
      // Non-Android platforms and tests do not register the native channel.
    } on PlatformException catch (error) {
      AppLogger.instance.ui(
        LogLevel.error,
        '读取快捷方式启动动作失败: ${error.message ?? error.code}',
      );
    } catch (error) {
      AppLogger.instance.ui(LogLevel.error, '读取快捷方式启动动作异常: $error');
    }
  }

  Future<bool> requestCampusCardPaymentShortcut() async {
    final result = await requestCampusCardPaymentShortcutResult();
    return result == AppShortcutRequestResult.requested;
  }

  Future<AppShortcutRequestResult> requestCampusCardPaymentShortcutResult() {
    return _requestShortcutResult(
      method: 'requestCampusCardPaymentShortcut',
      platformErrorMessage: '添加付款码快捷方式失败',
      unknownErrorMessage: '添加付款码快捷方式异常',
    );
  }

  Future<bool> requestShuatiShortcut() async {
    final result = await requestShuatiShortcutResult();
    return result == AppShortcutRequestResult.requested;
  }

  Future<AppShortcutRequestResult> requestShuatiShortcutResult() {
    return _requestShortcutResult(
      method: 'requestShuatiShortcut',
      platformErrorMessage: '添加刷题助手快捷方式失败',
      unknownErrorMessage: '添加刷题助手快捷方式异常',
    );
  }

  Future<bool> openShortcutPermissionSettings() async {
    await initialize();

    try {
      final opened = await _channel.invokeMethod<bool>(
        'openShortcutPermissionSettings',
      );
      return opened ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      AppLogger.instance.ui(
        LogLevel.error,
        '打开快捷方式权限设置失败: ${error.message ?? error.code}',
      );
      return false;
    } catch (error) {
      AppLogger.instance.ui(LogLevel.error, '打开快捷方式权限设置异常: $error');
      return false;
    }
  }

  Future<AppShortcutRequestResult> _requestShortcutResult({
    required String method,
    required String platformErrorMessage,
    required String unknownErrorMessage,
  }) async {
    await initialize();

    try {
      final result = await _channel.invokeMethod<Object>(method);
      return AppShortcutRequestResult.fromPlatformValue(result);
    } on MissingPluginException {
      return AppShortcutRequestResult.unavailable;
    } on PlatformException catch (error) {
      AppLogger.instance.ui(
        LogLevel.error,
        '$platformErrorMessage: ${error.message ?? error.code}',
      );
      return AppShortcutRequestResult.failed;
    } catch (error) {
      AppLogger.instance.ui(LogLevel.error, '$unknownErrorMessage: $error');
      return AppShortcutRequestResult.failed;
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method != 'onShortcutAction') return;
    _queueAction(call.arguments as String?);
  }

  void _queueAction(String? action) {
    final normalized = action?.trim() ?? '';
    if (normalized.isEmpty) return;

    _pendingAction = normalized;
    _flushPendingAction();
  }

  void _flushPendingAction() {
    final action = _pendingAction;
    if (action == null || !_isNavigationReady) return;

    _pendingAction = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      switch (action) {
        case campusCardPaymentAction:
          final navigateToNamedRoute = _navigateToNamedRoute;
          if (navigateToNamedRoute != null) {
            unawaited(navigateToNamedRoute('campus-card-payment'));
          }
          break;
        case shuatiAction:
          final navigateToNamedRoute = _navigateToNamedRoute;
          if (navigateToNamedRoute != null) {
            unawaited(navigateToNamedRoute('shuati-practice'));
          }
          break;
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  bool get _isNavigationReady {
    final phase = AppBootstrapController.instance.phase.value;
    return phase == AppBootstrapPhase.localStateReady ||
        phase == AppBootstrapPhase.completed;
  }

  @visibleForTesting
  void debugReset() {
    if (_phaseListenerRegistered) {
      AppBootstrapController.instance.phase.removeListener(_flushPendingAction);
    }
    _channel.setMethodCallHandler(null);
    _initialized = false;
    _phaseListenerRegistered = false;
    _pendingAction = null;
    _navigateToNamedRoute = null;
  }
}

enum AppShortcutRequestResult {
  requested,
  unsupported,
  rejected,
  unavailable,
  failed;

  static AppShortcutRequestResult fromPlatformValue(Object? value) {
    if (value == true || value == 'requested') {
      return AppShortcutRequestResult.requested;
    }
    if (value == false || value == 'unsupported') {
      return AppShortcutRequestResult.unsupported;
    }
    if (value == 'rejected') {
      return AppShortcutRequestResult.rejected;
    }
    if (value == 'unavailable') {
      return AppShortcutRequestResult.unavailable;
    }
    return AppShortcutRequestResult.failed;
  }
}

extension AppShortcutRequestResultMessage on AppShortcutRequestResult {
  String get message => switch (this) {
    AppShortcutRequestResult.requested => '已发起添加请求，请在系统提示中确认',
    AppShortcutRequestResult.unsupported => '当前桌面未开放应用内添加快捷方式，请检查创建桌面快捷方式权限',
    AppShortcutRequestResult.rejected => '系统桌面未接收添加请求，请检查创建桌面快捷方式权限',
    AppShortcutRequestResult.unavailable => '快捷方式组件未就绪，请重新安装或重启应用后再试',
    AppShortcutRequestResult.failed => '添加桌面快捷方式失败，请稍后重试',
  };

  bool get canOpenPermissionSettings =>
      this == AppShortcutRequestResult.unsupported ||
      this == AppShortcutRequestResult.rejected ||
      this == AppShortcutRequestResult.failed;
}
