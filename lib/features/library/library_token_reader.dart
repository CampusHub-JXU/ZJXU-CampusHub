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
  static const Duration timeout = Duration(seconds: 15);

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
          try {
            final raw = await controller.evaluateJavascript(source: _readScript);
            final token = _cleanToken(raw);
            finish(token.isEmpty ? null : token);
          } catch (error) {
            AppLogger.instance.storage(
              LogLevel.warn,
              '图书馆令牌读取失败',
              error: error,
            );
            finish(null);
          }
        },
      );
      await webview.run();
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          AppLogger.instance.storage(LogLevel.warn, '图书馆令牌读取超时');
          return null;
        },
      );
    } catch (error) {
      AppLogger.instance.storage(LogLevel.warn, '图书馆令牌读取异常', error: error);
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
  static String _cleanToken(Object? raw) {
    var text = raw?.toString().trim() ?? '';
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      text = text.substring(1, text.length - 1);
    }
    if (text == 'null') return '';
    return text;
  }

  /// 只读 localStorage，不写、不打印令牌内容。
  static const String _readScript = r'''
(function () {
  try {
    var key = null;
    for (var i = 0; i < localStorage.length; i++) {
      var k = localStorage.key(i);
      if (/^__\d+_lrnw_AS_Parse\/lab4\/currentUser$/.test(k)) { key = k; break; }
    }
    if (!key) return '';
    var raw = localStorage.getItem(key);
    if (!raw) return '';
    var user = JSON.parse(raw);
    var token = user && (user.access_token || user.accessToken || '');
    return typeof token === 'string' ? token : '';
  } catch (e) {
    return '';
  }
})();
''';
}
