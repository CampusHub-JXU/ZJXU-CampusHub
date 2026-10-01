import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../actions/campus_action.dart';
import '../actions/campus_action_registry.dart';
import '../logging/app_logger.dart';

class AppShortcutService {
  AppShortcutService._();

  static final AppShortcutService instance = AppShortcutService._();

  static const campusCardPaymentAction = 'campus-card-payment';
  static const shuatiAction = 'shuati-practice';

  static const _channel = MethodChannel('edu.zjxu.jxucampushub/shortcut');

  bool _initialized = false;
  bool _readyListenerRegistered = false;
  String? _pendingAction;
  ValueListenable<bool>? _navigationReady;
  Future<void> Function(String routeName, {Object? extra})?
  _navigateToNamedRoute;

  /// 注入导航就绪信号与路由跳转回调。
  ///
  /// 就绪前收到的快捷方式动作会挂起，[navigationReady] 变为 true 时自动补发。
  /// 就绪信号由 app 层（bootstrap 控制器）注入，本服务不再反向依赖 app 层。
  Future<void> initialize({
    required ValueListenable<bool> navigationReady,
    Future<void> Function(String routeName, {Object? extra})?
    navigateToNamedRoute,
  }) async {
    _navigationReady = navigationReady;
    _navigateToNamedRoute = navigateToNamedRoute ?? _navigateToNamedRoute;
    await _ensureInitialized();
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler(_handleMethodCall);
    if (!_readyListenerRegistered && _navigationReady != null) {
      _navigationReady!.addListener(_flushPendingAction);
      _readyListenerRegistered = true;
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

  /// 通用桌面快捷方式请求（PRD §40）：只传 Action ID 与标题，不再为每个
  /// 功能新增 `requestXxxShortcut()`。
  Future<AppShortcutRequestResult> requestPinnedShortcut(
    String actionId, {
    required String title,
  }) async {
    await _ensureInitialized();
    try {
      final result = await _channel.invokeMethod<Object>(
        'requestPinnedShortcut',
        {'actionId': actionId, 'title': title},
      );
      return AppShortcutRequestResult.fromPlatformValue(result);
    } on MissingPluginException {
      return AppShortcutRequestResult.unavailable;
    } on PlatformException catch (error) {
      AppLogger.instance.ui(
        LogLevel.error,
        '添加桌面快捷方式失败: ${error.message ?? error.code}',
      );
      return AppShortcutRequestResult.failed;
    } catch (error) {
      AppLogger.instance.ui(LogLevel.error, '添加桌面快捷方式异常: $error');
      return AppShortcutRequestResult.failed;
    }
  }

  /// 默认动态快捷方式（长按应用图标菜单）：引用稳定 Action ID。
  static const defaultDynamicShortcuts = <(String, String)>[
    ('schedule.today', '今日课表'),
    ('campus-card.payment', '校园卡付款'),
    ('electricity.open', '宿舍电费'),
    ('notice.inbox', '通知中心'),
  ];

  /// 同步动态快捷方式；native 侧按 id 去重重建。
  Future<bool> syncDynamicShortcuts(List<(String, String)> shortcuts) async {
    await _ensureInitialized();
    try {
      final synced = await _channel.invokeMethod<bool>('syncDynamicShortcuts', {
        'ids': [for (final shortcut in shortcuts) shortcut.$1],
        'titles': [for (final shortcut in shortcuts) shortcut.$2],
      });
      return synced ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      AppLogger.instance.ui(
        LogLevel.error,
        '同步动态快捷方式失败: ${error.message ?? error.code}',
      );
      return false;
    } catch (error) {
      AppLogger.instance.ui(LogLevel.error, '同步动态快捷方式异常: $error');
      return false;
    }
  }

  Future<bool> openShortcutPermissionSettings() async {
    await _ensureInitialized();

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
    await _ensureInitialized();

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
        default:
          // 动态快捷方式以 CampusAction ID 表达；Route 动作复用注入的导航回调。
          final target = CampusActionRegistry.instance.findById(action)?.target;
          final navigateToNamedRoute = _navigateToNamedRoute;
          if (target is RouteActionTarget && navigateToNamedRoute != null) {
            unawaited(
              navigateToNamedRoute(target.routeName, extra: target.extra),
            );
          }
          break;
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  bool get _isNavigationReady => _navigationReady?.value ?? false;

  @visibleForTesting
  void debugReset() {
    if (_readyListenerRegistered && _navigationReady != null) {
      _navigationReady!.removeListener(_flushPendingAction);
    }
    _channel.setMethodCallHandler(null);
    _initialized = false;
    _readyListenerRegistered = false;
    _pendingAction = null;
    _navigationReady = null;
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
    AppShortcutRequestResult.rejected =>
      'HyperOS 未允许创建桌面快捷方式，请点“去设置”后在应用权限/其他权限中开启',
    AppShortcutRequestResult.unavailable => '快捷方式组件未就绪，请重新安装或重启应用后再试',
    AppShortcutRequestResult.failed => '添加桌面快捷方式失败，请稍后重试',
  };

  bool get canOpenPermissionSettings =>
      this == AppShortcutRequestResult.unsupported ||
      this == AppShortcutRequestResult.rejected ||
      this == AppShortcutRequestResult.failed;
}
