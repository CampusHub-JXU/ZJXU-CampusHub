import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/auth/unified_auth.dart';
import '../../core/logging/app_logger.dart';
import 'library_token_reader.dart';

/// 统一认证身份已变化：旧令牌与在途结果不得继续使用。
class LibrarySessionChangedException implements Exception {
  const LibrarySessionChangedException([this.message = '统一认证会话已变化，请重试']);

  final String message;

  @override
  String toString() => message;
}

/// 一次令牌读取 / 借阅请求开始时固定的统一认证身份（账号 + 纪元）。
///
/// 复用 epay100 / 体测的 auth-epoch 模式：任何一次统一认证通知（登录 /
/// 登出 / 切号 / 会话恢复）都会推进纪元，旧纪元固定下来的异步操作在
/// 每个 await 边界被拒绝，避免把上个账号的令牌或借阅结果交给新账号。
class LibrarySessionGuard {
  const LibrarySessionGuard(this.account, this.epoch);

  final String? account;
  final int epoch;
}

/// 已打开的图书馆 WebView 里读到的汇图访问令牌（PRD 0.7.0 §34）。
///
/// 为什么不用隐藏 WebView：设备实测（2026-09-12）显示，隐藏 WebView 里
/// `localStorage.length == 0`——即跨 WebView 实例取不到图书馆站点的 DOM
/// storage（可见页里明明有 13 个键）。因此改为在**用户真正打开的那个**
/// 图书馆 WebView 加载完成时就地读取并缓存，借阅页直接消费缓存值。
///
/// 令牌绑定统一认证账号 + auth-epoch：登出 / 切号 / 同账号重登后缓存立即
/// 失效（图书馆 localStorage 可能与旧账号并存），旧账号的令牌绝不交给
/// 新账号使用。
class LibrarySession {
  LibrarySession._() {
    UnifiedAuthService.instance.addListener(_onUnifiedAuthChanged);
  }

  static final LibrarySession instance = LibrarySession._();

  String? _accessToken;

  /// 令牌绑定时的统一认证账号；与当前账号不一致即失效。
  String? _boundAccount;

  /// 令牌绑定时的身份纪元；与当前纪元不一致即失效。
  int _boundEpoch = 0;

  /// 统一认证身份纪元：每次收到登录 / 登出 / 切号 / 会话恢复通知递增。
  int _authEpoch = 0;

  void _onUnifiedAuthChanged() {
    _authEpoch++;
    clearToken();
  }

  /// 当前缓存的令牌；null 表示尚未读到（未登录或还没加载完）或已随统一
  /// 认证身份变化失效。
  String? get accessToken {
    final token = _accessToken;
    if (token == null || token.isEmpty) return null;
    if (_boundEpoch != _authEpoch) return null;
    final auth = UnifiedAuthService.instance;
    if (!auth.isLoggedIn || auth.currentAccount != _boundAccount) return null;
    return token;
  }

  /// 就地读取并缓存令牌（[controller] 必须是图书馆页面的 WebView）。
  ///
  /// 内部已吞掉所有异常，因此可以直接作为 WebView 的 `onLoadStop` 回调：
  /// 失败/未登录一律静默，不阻塞页面，也不覆盖已缓存的旧令牌。
  ///
  /// 之所以要轮询：图书馆 SPA 在 `onLoadStop` 之后才把 Parse 用户对象落到
  /// localStorage（设备实测 2026-09-12：load stop 那一刻读为空值，稍后 CDP
  /// 能读到 88 长度的令牌）。因此做有限次重试；只在成功时记录令牌**长度**。
  Future<void> captureFrom(InAppWebViewController controller) =>
      _capture(controller);

  static const int _maxAttempts = 40;
  static const Duration _retryInterval = Duration(milliseconds: 1500);

  /// 测试替身：替代 `evaluateJavascript` 的原始返回值（为 null 走真实 WebView）。
  @visibleForTesting
  Future<String?> Function()? debugTokenReadOverride;

  /// 测试替身：重试次数 / 间隔。
  @visibleForTesting
  int debugMaxAttempts = _maxAttempts;

  @visibleForTesting
  Duration debugRetryInterval = _retryInterval;

  /// 测试入口：不依赖真实 WebView 驱动一次捕获流程。
  @visibleForTesting
  Future<void> debugCapture() => _capture(null);

  Future<void> _capture(InAppWebViewController? controller) async {
    final auth = UnifiedAuthService.instance;
    final startAccount = auth.currentAccount;
    final startEpoch = _authEpoch;
    final readOverride = debugTokenReadOverride;
    for (var attempt = 1; attempt <= debugMaxAttempts; attempt++) {
      final cached = accessToken;
      if (cached != null && cached.isNotEmpty) return;
      try {
        final raw = readOverride != null
            ? await readOverride()
            : await controller!.evaluateJavascript(
                source: LibraryTokenReader.readScript,
              );
        final token = LibraryTokenReader.cleanToken(raw);
        if (readOverride == null && attempt == 1 && token.isEmpty) {
          // 诊断：确认 evaluateJavascript 通道本身是否可用。
          final probe = await controller!.evaluateJavascript(
            source: _probeScript,
          );
          AppLogger.instance.webview(
            LogLevel.info,
            '图书馆令牌探测 ${probe?.toString() ?? 'null'}（read=${raw?.toString() ?? 'null'}）',
          );
        }
        if (token.isNotEmpty) {
          // 读取期间发生登出 / 切号：该 WebView 的令牌属于旧身份，丢弃。
          if (startEpoch != _authEpoch || startAccount != auth.currentAccount) {
            AppLogger.instance.webview(LogLevel.warn, '图书馆令牌丢弃：读取期间统一认证身份已变化');
            return;
          }
          if (!bindToken(token)) {
            AppLogger.instance.webview(LogLevel.warn, '图书馆令牌丢弃：统一认证未登录');
            return;
          }
          AppLogger.instance.webview(
            LogLevel.info,
            '图书馆令牌已缓存（长度 ${token.length}）',
          );
          return;
        }
      } catch (error) {
        if (attempt <= 3) {
          AppLogger.instance.webview(LogLevel.warn, '图书馆令牌读取抛错：$error');
        }
      }
      if (attempt < debugMaxAttempts) {
        await Future<void>.delayed(debugRetryInterval);
      }
    }
    AppLogger.instance.webview(LogLevel.warn, '未从图书馆页面读到令牌（可能未登录）');
  }

  /// 把 [token] 绑定到当前统一认证身份；未登录时拒绝（返回 false），
  /// 令牌保持不缓存，避免身份未知时被借阅页消费。
  bool bindToken(String token) {
    final trimmed = token.trim();
    final auth = UnifiedAuthService.instance;
    final account = auth.currentAccount;
    if (trimmed.isEmpty || !auth.isLoggedIn || account == null) return false;
    _accessToken = trimmed;
    _boundAccount = account;
    _boundEpoch = _authEpoch;
    return true;
  }

  /// 清空缓存令牌（401 / 令牌过期等）。
  void clearToken() {
    _accessToken = null;
    _boundAccount = null;
  }

  /// 固定当前统一认证身份，供一次异步操作的所有 await 边界校验。
  LibrarySessionGuard captureGuard() => LibrarySessionGuard(
    UnifiedAuthService.instance.currentAccount,
    _authEpoch,
  );

  /// 身份或纪元任一变化即抛 [LibrarySessionChangedException]；
  /// 只作废本次操作，不清理全局统一认证会话。
  void ensureGuard(LibrarySessionGuard guard) {
    final auth = UnifiedAuthService.instance;
    if (guard.epoch != _authEpoch || guard.account != auth.currentAccount) {
      throw const LibrarySessionChangedException();
    }
  }

  /// 诊断用：只有通道可用时才会返回非 null。
  static const String _probeScript = r'''
(function () {
  try { return localStorage.length + '|' + document.title; } catch (e) { return 'ERR:' + e; }
})();
''';

  @visibleForTesting
  void debugSetAccessToken(String? value) {
    if (value == null || value.isEmpty) {
      clearToken();
      return;
    }
    _accessToken = value;
    _boundAccount = UnifiedAuthService.instance.currentAccount;
    _boundEpoch = _authEpoch;
  }

  @visibleForTesting
  void debugHandleAuthChanged() => _onUnifiedAuthChanged();

  @visibleForTesting
  void debugReset() {
    _accessToken = null;
    _boundAccount = null;
    _boundEpoch = 0;
    _authEpoch = 0;
    debugTokenReadOverride = null;
    debugMaxAttempts = _maxAttempts;
    debugRetryInterval = _retryInterval;
  }
}
