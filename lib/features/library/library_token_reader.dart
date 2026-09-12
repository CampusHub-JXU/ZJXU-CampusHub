import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/logging/app_logger.dart';

/// 从图书馆 WebView 的 localStorage 读取汇图（huitu）访问令牌。
///
/// 图书馆 SPA 把 Parse 用户对象存在 `__<n>_lrnw_AS_Parse/lab4/currentUser`
/// （键前缀序号随版本变化），其中的 `access_token` 正是 `/user/borrows`、
/// `/user/borrows/history`、`/book/renew` 需要的 Bearer 令牌。
///
/// localStorage 按 origin 隔离，因此这里用隐藏 WebView 打开**同一 origin**
/// 的轻量页面（WebVPN 网关根），再读键值——不必也无法脚本化登录表单
/// （该表单只认真实键盘输入，见 `LibraryPage` 的说明）。
class LibraryTokenReader {
  LibraryTokenReader._();

  static final LibraryTokenReader instance = LibraryTokenReader._();

  /// 读取超时：超时按「未登录」处理，不阻塞页面。
  static const Duration timeout = Duration(seconds: 30);

  /// `onLoadStop` 之后 SPA 才把 Parse 用户对象落到 localStorage（设备实测
  /// 2026-09-12：load stop 那一刻读为空，WebVPN 下首屏更慢），因此读空后
  /// 带退避重试若干次。
  static const int _loadStopAttempts = 10;
  static const Duration _loadStopRetryInterval = Duration(milliseconds: 1500);

  /// 测试替身。
  @visibleForTesting
  static Future<String?> Function(String libraryUrl)? debugReadOverride;

  /// 读取令牌；未登录、超时或异常一律返回 null。
  Future<String?> readAccessToken(String libraryUrl) async {
    final override = debugReadOverride;
    if (override != null) return override(libraryUrl);
    final origin = _originOf(libraryUrl);
    if (origin == null) return null;

    final completer = Completer<String?>();
    HeadlessInAppWebView? webview;
    void finish(String? token) {
      if (!completer.isCompleted) completer.complete(token);
    }

    try {
      webview = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri('$origin/')),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          thirdPartyCookiesEnabled: true,
          transparentBackground: true,
        ),
        onLoadStop: (controller, url) async {
          for (var attempt = 1; attempt <= _loadStopAttempts; attempt++) {
            if (completer.isCompleted) return;
            try {
              final raw = await controller.evaluateJavascript(
                source: readScript,
              );
              final token = cleanToken(raw);
              if (token.isNotEmpty) {
                finish(token);
                return;
              }
            } catch (error) {
              AppLogger.instance.webview(
                LogLevel.warn,
                '图书馆令牌读取失败',
                error: error,
              );
            }
            if (attempt < _loadStopAttempts) {
              await Future<void>.delayed(_loadStopRetryInterval);
            }
          }
          finish(null);
        },
      );
      await webview.run();
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          AppLogger.instance.webview(LogLevel.warn, '图书馆令牌读取超时');
          return null;
        },
      );
    } catch (error) {
      AppLogger.instance.webview(LogLevel.warn, '图书馆令牌读取异常', error: error);
      return null;
    } finally {
      final created = webview;
      if (created != null) {
        try {
          await created.dispose();
        } catch (_) {}
      }
    }
  }

  static String? _originOf(String libraryUrl) {
    final uri = Uri.tryParse(libraryUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    return '${uri.scheme}://${uri.host}';
  }

  /// `evaluateJavascript` 返回的是 JSON 编码字符串，需去掉外层引号。
  static String cleanToken(Object? raw) {
    var text = raw?.toString().trim() ?? '';
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      text = text.substring(1, text.length - 1);
    }
    if (text == 'null') return '';
    return text;
  }

  /// 只读 localStorage，不写、不打印令牌内容。
  ///
  /// 同时被 [LibrarySession] 复用（在已打开的图书馆 WebView 里就地读取），
  /// 保证只有一份读取脚本。
  ///
  /// 站点会同时残留多个 `__N_lrnw_AS_Parse/lab4/currentUser`（设备实测
  /// 2026-09-12：`__4_` 在前但 57 个字段里 `access_token` 为空，真正带令牌的
  /// 是 `__3_`），因此必须遍历所有匹配键，返回第一个非空令牌，不能取首个匹配。
  static const String readScript = r'''
(function () {
  try {
    var fallback = '';
    for (var i = 0; i < localStorage.length; i++) {
      var key = localStorage.key(i);
      if (!/^__\d+_lrnw_AS_Parse\/lab4\/currentUser$/.test(key)) continue;
      var raw = localStorage.getItem(key);
      if (!raw) continue;
      var token = '';
      try {
        var user = JSON.parse(raw);
        if (user) token = user.access_token || user.accessToken || '';
      } catch (e) {
        var matched = raw.match(/"access_?token"\s*:\s*"([^"]{20,180})"/i);
        if (matched) token = matched[1];
      }
      if (typeof token !== 'string') continue;
      if (token.length > 0) return token;
      if (!fallback) fallback = token;
    }
    return fallback;
  } catch (e) {
    return '';
  }
})();
''';
}
