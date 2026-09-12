import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/logging/app_logger.dart';
import 'library_token_reader.dart';

/// 已打开的图书馆 WebView 里读到的汇图访问令牌（PRD 0.7.0 §34）。
///
/// 为什么不用隐藏 WebView：设备实测（2026-09-12）显示，隐藏 WebView 里
/// `localStorage.length == 0`——即跨 WebView 实例取不到图书馆站点的 DOM
/// storage（可见页里明明有 13 个键）。因此改为在**用户真正打开的那个**
/// 图书馆 WebView 加载完成时就地读取并缓存，借阅页直接消费缓存值。
class LibrarySession {
  LibrarySession._();

  static final LibrarySession instance = LibrarySession._();

  String? _accessToken;

  /// 当前缓存的令牌；null 表示尚未读到（未登录或还没加载完）。
  String? get accessToken => _accessToken;

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

  Future<void> _capture(InAppWebViewController controller) async {
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      final cached = _accessToken;
      if (cached != null && cached.isNotEmpty) return;
      try {
        final raw = await controller.evaluateJavascript(
          source: LibraryTokenReader.readScript,
        );
        final token = LibraryTokenReader.cleanToken(raw);
        if (token.isNotEmpty) {
          _accessToken = token;
          AppLogger.instance.webview(
            LogLevel.info,
            '图书馆令牌已缓存（长度 ${token.length}）',
          );
          return;
        }
      } catch (_) {
        // 页面可能正在导航/销毁，稍后重试。
      }
      if (attempt < _maxAttempts) {
        await Future<void>.delayed(_retryInterval);
      }
    }
    AppLogger.instance.webview(LogLevel.warn, '未从图书馆页面读到令牌（可能未登录）');
  }

  @visibleForTesting
  void debugSetAccessToken(String? value) {
    _accessToken = value;
  }

  @visibleForTesting
  void debugReset() {
    _accessToken = null;
  }
}
