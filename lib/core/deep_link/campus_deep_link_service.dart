import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../actions/campus_deep_link.dart';
import '../logging/app_logger.dart';

/// 深链入口（PRD 0.7.0 §8）。
///
/// 原生只透传受限的 `jxucampushub://action/<id>`（兼容旧 `//shortcut/<id>`），
/// Dart 侧经 [CampusDeepLink] 白名单解析为 Action ID，导航就绪后分发给
/// [dispatch]（app 层经 CampusActionExecutor 执行）。未注册动作一律丢弃。
class CampusDeepLinkService {
  CampusDeepLinkService._();

  static final CampusDeepLinkService instance = CampusDeepLinkService._();

  static const _channel = MethodChannel('edu.zjxu.jxucampushub/deeplink');

  bool _initialized = false;
  bool _readyListenerRegistered = false;
  String? _pendingActionId;
  ValueListenable<bool>? _navigationReady;
  Future<void> Function(String actionId)? _dispatch;

  Future<void> initialize({
    required ValueListenable<bool> navigationReady,
    required Future<void> Function(String actionId) dispatch,
  }) async {
    _navigationReady = navigationReady;
    _dispatch = dispatch;
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler(_handleMethodCall);
    if (!_readyListenerRegistered) {
      navigationReady.addListener(_flushPendingAction);
      _readyListenerRegistered = true;
    }

    try {
      final raw = await _channel.invokeMethod<String>('consumeInitialDeepLink');
      _queueRaw(raw);
    } on MissingPluginException {
      // Non-Android platforms and tests do not register the native channel.
    } on PlatformException catch (error) {
      AppLogger.instance.ui(
        LogLevel.error,
        '读取深链启动动作失败: ${error.message ?? error.code}',
      );
    } catch (error) {
      AppLogger.instance.ui(LogLevel.error, '读取深链启动动作异常: $error');
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method != 'onDeepLinkAction') return;
    _queueRaw(call.arguments as String?);
  }

  void _queueRaw(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return;

    final actionId = CampusDeepLink.parse(trimmed);
    if (actionId == null) {
      AppLogger.instance.ui(LogLevel.warn, '忽略未注册的深链动作: $trimmed');
      return;
    }

    _pendingActionId = actionId;
    _flushPendingAction();
  }

  void _flushPendingAction() {
    final actionId = _pendingActionId;
    if (actionId == null || !_isNavigationReady) return;

    final dispatch = _dispatch;
    if (dispatch == null) return;

    _pendingActionId = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(dispatch(actionId));
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
    _pendingActionId = null;
    _navigationReady = null;
    _dispatch = null;
  }
}
