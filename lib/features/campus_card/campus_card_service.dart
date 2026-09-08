import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:html/parser.dart' as html_parser;

import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/network/dio_client.dart';

class CampusCardService {
  CampusCardService._();

  static final CampusCardService instance = CampusCardService._();

  static const _storage = FlutterSecureStorage();
  static const _keyBalance = 'zjxu_campus_card_balance';

  double? _cachedBalance;
  DateTime? _lastUpdated;
  Future<double?>? _balanceFetchFuture;

  @visibleForTesting
  Future<double?> Function()? debugBalanceFetcher;

  double? get cachedBalance => _cachedBalance;
  DateTime? get lastUpdated => _lastUpdated;

  static const statusPageUrl =
      'https://mobilehall.zjxu.edu.cn/webroot/decision/view/form?op=h5&viewlet=xxkj%252Fmobile%252Fykt.frm#/form';

  /// CAS service URL — fragment (#/form) 不能包含在 service 参数里，
  /// 否则 ticket 验证时 service 不匹配导致认证失败。
  /// URL 注册表统一收敛在 [CasService]。
  static final statusPageCasServiceUrl = CasService.campusCardStatus.serviceUrl;

  static const paymentCodeEntryUrl =
      'https://app.xiaoyuan.ccb.com/EMTSTATIC/DZK2026032101/index2026032101.html#/cardmentkey';

  static const paymentCodeServiceHallUrl =
      'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/wfw/id=ED8D7B51A2422411E0532602010A9D8D';

  static final serviceHallCasServiceUrl =
      CasService.campusCardPayment.serviceUrl;

  static const _renderedBalanceScript = r'''
(function() {
  var chunks = [];
  if (document.body && document.body.innerText) {
    chunks.push(document.body.innerText);
  }
  var nodes = document.querySelectorAll('[title],[aria-label],input,textarea');
  for (var i = 0; i < nodes.length; i++) {
    var node = nodes[i];
    chunks.push(node.getAttribute('title') || '');
    chunks.push(node.getAttribute('aria-label') || '');
    chunks.push(node.value || '');
    chunks.push(node.textContent || '');
  }
  return chunks.join('\n');
})()
''';

  void updateCachedBalance(double? balance) {
    if (balance == null) return;
    _cachedBalance = balance;
    _lastUpdated = DateTime.now();
    _storage.write(key: _keyBalance, value: balance.toString());
  }

  double? clearCachedBalance() {
    _cachedBalance = null;
    _lastUpdated = null;
    unawaited(_storage.delete(key: _keyBalance));
    return null;
  }

  Future<void> restoreBalance() async {
    final stored = await _storage.read(key: _keyBalance);
    if (stored != null) {
      _cachedBalance = double.tryParse(stored);
    }
  }

  double? parseBalanceFromPageText(String rawText) {
    final text = rawText
        .replaceAll('\u00A0', ' ')
        .replaceAll('\u3000', ' ')
        .trim();
    if (text.isEmpty) return null;

    final lines = text
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && line != '|')
        .toList();

    String normalize(String value) => value.replaceAll(RegExp(r'\s+'), '');

    double? parseAmount(String value) {
      final cleaned = value.replaceAll(',', '');
      final match = RegExp(r'[¥￥]?\s*([0-9]+(?:\.[0-9]+)?)\s*元?')
          .firstMatch(cleaned);
      if (match == null) return null;
      return double.tryParse(match.group(1)!);
    }

    int labelIndex = -1;
    for (int i = 0; i < lines.length; i++) {
      final normalized = normalize(lines[i]);
      if (normalized.contains('卡内余额')) {
        labelIndex = i;
        break;
      }
    }

    if (labelIndex >= 0) {
      final sameLineAmount = parseAmount(lines[labelIndex]);
      if (sameLineAmount != null) return sameLineAmount;

      for (int i = labelIndex - 1; i >= 0 && i >= labelIndex - 3; i--) {
        final amount = parseAmount(lines[i]);
        if (amount != null) return amount;
      }

      for (
        int i = labelIndex + 1;
        i < lines.length && i <= labelIndex + 3;
        i++
      ) {
        final amount = parseAmount(lines[i]);
        if (amount != null) return amount;
      }
    }

    final compact = normalize(text).replaceAll(',', '');
    final inlineMatch = RegExp(r'卡内余额[^0-9¥￥]{0,12}[¥￥]?([0-9]+(?:\.[0-9]+)?)')
        .firstMatch(compact);
    if (inlineMatch != null) {
      return double.tryParse(inlineMatch.group(1)!);
    }

    return null;
  }

  double? parseBalanceFromHtml(String rawHtml) {
    if (rawHtml.trim().isEmpty) return null;

    final document = html_parser.parse(rawHtml);
    final visibleText = document.body?.text ?? document.documentElement?.text;
    final visibleBalance = parseBalanceFromPageText(visibleText ?? '');
    if (visibleBalance != null) return visibleBalance;

    // Some report responses place the rendered cell text directly in the HTML
    // source without exposing it as a normal DOM text node.
    return parseBalanceFromPageText(rawHtml);
  }

  Future<double?> fetchBalance({bool forceRefresh = false}) {
    if (!forceRefresh && _cachedBalance != null) {
      return Future<double?>.value(_cachedBalance);
    }

    final existing = _balanceFetchFuture;
    if (existing != null) return existing;

    final future = _fetchBalanceRemote();
    _balanceFetchFuture = future;
    return future.whenComplete(() {
      if (identical(_balanceFetchFuture, future)) {
        _balanceFetchFuture = null;
      }
    });
  }

  Future<double?> _fetchBalanceRemote() async {
    final testFetcher = debugBalanceFetcher;
    if (testFetcher != null) {
      final balance = await testFetcher();
      if (balance != null) updateCachedBalance(balance);
      return balance;
    }

    try {
      final targetUrl = await prepareStatusPage();
      return await _fetchBalanceFromRenderedPage(targetUrl);
    } on CasAuthExpiredException {
      return clearCachedBalance();
    } catch (error, stackTrace) {
      AppLogger.instance.network(
        LogLevel.warn,
        '校园卡余额刷新失败，保留上次余额',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// 余额与交互页面共用网关、目标 CAS 会话及 URL 选择。
  Future<String> prepareStatusPage() async {
    await DioClient.instance.ensureInitialized();
    await UnifiedAuthService.instance.restoreSession(syncWebViewCookies: false);
    if (!UnifiedAuthService.instance.isLoggedIn) {
      throw const CasAuthExpiredException();
    }
    final gateway = await ZhengfangAuth.instance
        .ensureWebVpnGatewaySessionResult(
          syncWebViewCookies: true,
          targetUrl: statusPageUrl,
        );
    if (gateway.ready == false) throw const CasAuthExpiredException();
    if (gateway.ready == null) throw TimeoutException('校园卡网关暂时无法连接');

    final sessionStatus = await CasSession.ensure(
      CasService.campusCardStatus.serviceUrl,
      syncWebViewCookies: false,
    );
    if (sessionStatus == CasSessionStatus.inactive) {
      throw const CasAuthExpiredException();
    }
    if (sessionStatus == CasSessionStatus.unknown) {
      throw TimeoutException('校园卡认证暂时无法连接');
    }
    await UnifiedAuthService.instance.syncCookiesToWebViewForUrl(statusPageUrl);
    return gateway.selectedMode == ZhengfangMode.webVpn
        ? ZhengfangAuth.instance.buildWebVpnProxyUrl(statusPageUrl)
        : statusPageUrl;
  }

  Future<double?> _fetchBalanceFromRenderedPage(String targetUrl) async {
    final completer = Completer<double?>();
    HeadlessInAppWebView? webView;
    var pollingStarted = false;
    var cancelled = false;

    Future<void> finish(double? balance) async {
      if (!completer.isCompleted) {
        completer.complete(balance);
      }
    }

    try {
      webView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(targetUrl)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          useShouldOverrideUrlLoading: true,
          mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
          thirdPartyCookiesEnabled: true,
          userAgent:
              'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36 '
              'DingTalk/7.0.0',
        ),
        onLoadStop: (controller, url) {
          if (pollingStarted || cancelled) return;
          pollingStarted = true;
          unawaited(
            _pollRenderedBalance(
              controller,
              finish,
              isCancelled: () => cancelled || completer.isCompleted,
            ),
          );
        },
        onReceivedError: (controller, request, error) {
          if (request.isForMainFrame ?? false) {
            AppLogger.instance.webview(
              LogLevel.warn,
              '校园卡余额 WebView 加载失败: ${error.type} ${error.description}',
            );
            unawaited(finish(null));
          }
        },
        onReceivedHttpError: (controller, request, response) {
          if (request.isForMainFrame ?? false) {
            AppLogger.instance.webview(
              LogLevel.warn,
              '校园卡余额 WebView HTTP 错误: ${response.statusCode}',
            );
            unawaited(finish(null));
          }
        },
      );
      await webView.run();

      final balance = await completer.future.timeout(
        const Duration(seconds: 12),
        onTimeout: () {
          cancelled = true;
          return null;
        },
      );
      if (balance == null) {
        AppLogger.instance.network(LogLevel.warn, '校园卡余额渲染后仍未找到余额字段');
        return null;
      }

      updateCachedBalance(balance);
      AppLogger.instance.network(LogLevel.info, '校园卡余额 WebView 渲染查询成功');
      return balance;
    } catch (error, stackTrace) {
      AppLogger.instance.network(
        LogLevel.warn,
        '校园卡余额 WebView 渲染查询失败',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    } finally {
      cancelled = true;
      await webView?.dispose();
    }
  }

  /// 轮询 WebView 渲染出的余额文本。
  ///
  /// [isCancelled] 以外层 completer 完成为准（命中余额 / 加载失败 / 超时
  /// 都会完成它）。外层超时后 `finally` 会 dispose WebView，而轮询总时长
  /// 与超时上限几乎相等——每次取消信号通过后到 [InAppWebViewController
  /// .evaluateJavascript] 实际执行之间仍有微小竞态窗口，因此 evaluate
  /// 还需捕获「controller 已释放」类异常兜底，绝不让它外抛。
  Future<void> _pollRenderedBalance(
    InAppWebViewController controller,
    Future<void> Function(double? balance) finish, {
    required bool Function() isCancelled,
  }) async {
    return _pollRenderedBalanceWithEvaluator(
      () async =>
          (await controller.evaluateJavascript(source: _renderedBalanceScript))
              ?.toString(),
      finish,
      isCancelled,
    );
  }

  Future<void> _pollRenderedBalanceWithEvaluator(
    Future<String?> Function() evaluate,
    Future<void> Function(double? balance) finish,
    bool Function() isCancelled,
  ) async {
    for (var attempt = 0; attempt < 24; attempt++) {
      if (isCancelled()) return;

      final String? rawText;
      try {
        rawText = await evaluate();
      } catch (error, stackTrace) {
        if (isCancelled()) return;
        AppLogger.instance.webview(
          LogLevel.warn,
          '校园卡余额轮询中断（WebView 已释放或通道异常）',
          error: error,
          stackTrace: stackTrace,
        );
        return;
      }

      final balance = parseBalanceFromPageText(rawText?.toString() ?? '');
      if (balance != null) {
        await finish(balance);
        return;
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    await finish(null);
  }

  @visibleForTesting
  Future<void> debugPollRenderedBalance({
    required Future<String?> Function() evaluate,
    required Future<void> Function(double? balance) finish,
    required bool Function() isCancelled,
  }) {
    return _pollRenderedBalanceWithEvaluator(evaluate, finish, isCancelled);
  }

  String formatBalance(double? balance) {
    if (balance == null) return '--';

    if (balance == balance.truncateToDouble()) {
      return balance.toStringAsFixed(0);
    }

    return balance
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  @visibleForTesting
  void debugSetCachedBalance(double? balance, {DateTime? updatedAt}) {
    _cachedBalance = balance;
    _lastUpdated = updatedAt;
  }

  @visibleForTesting
  void debugReset() {
    _cachedBalance = null;
    _lastUpdated = null;
    _balanceFetchFuture = null;
    debugBalanceFetcher = null;
  }
}
