import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../actions/campus_deep_link.dart';
import '../actions/pending_action_inbox.dart';
import '../logging/app_logger.dart';
import '../platform/safe_invoke.dart';

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
  late final PendingActionInbox _inbox = PendingActionInbox(
    canDeliver: () => _dispatch != null,
    deliver: (actionId) {
      // 投递发生在 post-frame 回调里，期间可能已 debugReset：为 null 时放弃。
      final dispatch = _dispatch;
      if (dispatch != null) unawaited(dispatch(actionId));
    },
  );
  Future<void> Function(String actionId)? _dispatch;

  Future<void> initialize({
    required ValueListenable<bool> navigationReady,
    required Future<void> Function(String actionId) dispatch,
  }) async {
    _inbox.navigationReady = navigationReady;
    _dispatch = dispatch;
    if (_initialized) return;
    _initialized = true;

    _channel.setMethodCallHandler(_handleMethodCall);
    _inbox.ensureListening();

    await safeInvoke<String, void>(
      _channel,
      'consumeInitialDeepLink',
      map: _queueRaw,
      missing: null,
      failed: null,
      label: '读取深链启动动作',
    );
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

    _inbox.queue(actionId);
  }

  @visibleForTesting
  void debugReset() {
    _inbox.reset();
    _channel.setMethodCallHandler(null);
    _initialized = false;
    _dispatch = null;
  }
}
