import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/logging/app_logger.dart';
import 'campus_card_service.dart';

/// 移动大厅「校园卡账单」（FineReport 决策报表）取数网关。
///
/// 页面是 `mobilehall.zjxu.edu.cn/webroot/decision/view/form?op=h5&viewlet=
/// xxkj%2Fmobile%2Fykt.frm`，数据全部由 FineReport 的 `fr_form` 系列接口
/// 按 widget 拉取（实证见 docs/dorm-electricity-epay100-api.md）。
///
/// 为什么不走 dio：校外必须经 `webvpn.zjxu.edu.cn` 的 wengine 代理，代理层
/// 用 JS 在页面上下文完成目标站 cookie 的注入/回放，dio 直连只会拿到
/// wengine 的「cookie 检查」HTML（实测 2026-11-19）。因此沿用 epay100 网关
/// 的既有做法：隐藏 WebView 保住同源会话，Dart 在页面上下文发 fetch。
class CampusCardBillGateway {
  CampusCardBillGateway._();

  static final CampusCardBillGateway instance = CampusCardBillGateway._();

  static const _originTimeout = Duration(seconds: 60);
  static const _rpcTimeout = Duration(seconds: 20);

  /// 账单页的 widget 名（FineReport 模板里固定）：四个统计格 + 近期消费表。
  static const statWidgets = <String>['ZTXF1', 'ZTXF2', 'ZTXF3', 'ZTXF4'];

  /// 近期消费表 widget（表头：消费日期 / 消费地点 / 消费金额）。
  static const recentWidget = 'REPORT0';

  /// 两个图表 widget：三餐消费饼图、近七日消费统计。
  static const chartWidgets = <String>['CHART0', 'CHART1'];

  HeadlessInAppWebView? _webview;
  InAppWebViewController? _controller;
  Future<void>? _starting;
  int _generation = 0;
  String? _proxyBase;

  @visibleForTesting
  Future<String> Function()? debugUrlPreparer;

  /// 测试/探测用：拿到就绪后的页面控制器（页面上下文可执行任意 JS）。
  @visibleForTesting
  Future<InAppWebViewController> debugReadyController() => _ensureReady();

  @visibleForTesting
  void debugReset() {
    _generation++;
    _controller = null;
    _starting = null;
    _proxyBase = null;
    final webview = _webview;
    _webview = null;
    webview?.dispose();
    debugUrlPreparer = null;
  }

  /// 抓一次账单：返回原始 widget 响应（解析在
  /// `CampusCardConsumptionSummary.parseRaw` 里，纯函数、可单测）。
  Future<CampusCardBillRawPayload> fetch() async {
    final controller = await _ensureReady();
    final base = _proxyBase;
    if (base == null) throw const CampusCardBillException('账单页面地址不可用');
    final rawPayload = await _evaluateBillFetch(controller, base);
    final firstBody = rawPayload.widgets.values.isEmpty
        ? ''
        : rawPayload.widgets.values.first;
    if (firstBody.trimLeft().startsWith('<')) {
      final preview = firstBody.replaceAll(RegExp(r'\s+'), ' ').trim();
      final snippet = preview.length > 160
          ? preview.substring(0, 160)
          : preview;
      AppLogger.instance.network(LogLevel.warn, '校园卡账单响应异常 | snippet=$snippet');
    }
    return rawPayload;
  }

  Future<CampusCardBillRawPayload> _evaluateBillFetch(
    InAppWebViewController controller,
    String base,
  ) async {
    var fallbackSid = '';
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri('$base/webroot/decision/view/form'),
      );
      for (final c in cookies) {
        if (c.name == 'sessionID' && c.value != null) {
          fallbackSid = c.value.toString();
          break;
        }
      }
    } catch (_) {}
    await controller.evaluateJavascript(
      source: _script(base, fallbackSid: fallbackSid),
    );
    final deadline = DateTime.now().add(_rpcTimeout);
    while (true) {
      if (DateTime.now().isAfter(deadline)) {
        await invalidate();
        throw const CampusCardBillException('账单数据加载超时，请稍后重试');
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
      Object? raw;
      try {
        raw = await controller
            .evaluateJavascript(source: "window.__jxuBillRpc || ''")
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        continue;
      }
      final payload = _unwrap(raw);
      if (payload.isEmpty) continue;
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) {
        throw const CampusCardBillException('账单数据格式异常');
      }
      final error = decoded['err'];
      if (error != null) {
        throw CampusCardBillException('账单数据加载失败：$error');
      }
      if (decoded['hasSid'] != true) {
        AppLogger.instance.network(
          LogLevel.warn,
          '校园卡账单未取到 sessionID | href=${decoded['href']} '
          'hasFr=${decoded['hasFr']} fallbackSid=${fallbackSid.isNotEmpty}',
        );
      }
      return CampusCardBillRawPayload.fromJson(decoded);
    }
  }

  static String _unwrap(Object? raw) {
    if (raw == null) return '';
    if (raw is Map) return jsonEncode(raw);
    var text = raw.toString().trim();
    for (var i = 0; i < 3; i++) {
      if (!text.startsWith('"') || text.length < 2) break;
      try {
        final decoded = jsonDecode(text);
        if (decoded is String) {
          text = decoded.trim();
        } else {
          return jsonEncode(decoded);
        }
      } catch (_) {
        return '';
      }
    }
    return text;
  }

  Future<InAppWebViewController> _ensureReady() async {
    final active = _starting;
    if (active != null) {
      await active;
      final controller = _controller;
      if (controller != null) return controller;
    }
    final existing = _controller;
    if (existing != null) return existing;
    final starting = _start();
    _starting = starting;
    try {
      await starting;
    } finally {
      if (identical(_starting, starting)) _starting = null;
    }
    final controller = _controller;
    if (controller == null) {
      throw const CampusCardBillException('账单页面会话不可用，请重试');
    }
    return controller;
  }

  Future<void> _start() async {
    final generation = _generation;
    final String url;
    try {
      url =
          await (debugUrlPreparer ??
              CampusCardService.instance.prepareStatusPage)();
    } on CasAuthExpiredException {
      throw const CampusCardBillAuthException();
    } on TimeoutException {
      throw const CampusCardBillException('校园卡网关暂时无法连接，请稍后重试');
    }
    final index = url.indexOf('/webroot/decision');
    _proxyBase = index <= 0 ? null : url.substring(0, index);
    // prepareStatusPage(..., syncWebViewCookies: false) 只把 CAS/mobilehall
    // 会话写进了 dio CookieJar；HeadlessWebView 加载前必须把 cookie 同步进
    // Android CookieManager，否则请求被打回登录页。
    try {
      await UnifiedAuthService.instance.syncCookiesToWebViewForUrl(url);
    } catch (_) {}
    AppLogger.instance.network(LogLevel.info, '校园卡账单：加载移动大厅页面');

    final ready = Completer<void>();
    HeadlessInAppWebView? webview;
    webview = HeadlessInAppWebView(
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        thirdPartyCookiesEnabled: true,
        transparentBackground: true,
      ),
      onWebViewCreated: (controller) {
        if (generation != _generation) return;
        _controller = controller;
      },
      onLoadStop: (controller, uri) {
        if (generation != _generation) return;
        if (!ready.isCompleted) ready.complete();
      },
    );
    if (generation != _generation) {
      throw const CampusCardBillException('账单页面会话已被新会话取代，请重试');
    }
    _webview = webview;
    try {
      await webview.run();
    } catch (_) {
      await _disposeOwned(generation);
      throw const CampusCardBillException('账单页面启动失败，请重试');
    }
    final controller = webview.webViewController;
    if (controller == null) {
      await _disposeOwned(generation);
      throw const CampusCardBillException('账单页面启动失败，请重试');
    }
    try {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
      await ready.future.timeout(_originTimeout);
    } on TimeoutException {
      await _disposeOwned(generation);
      throw const CampusCardBillException('账单页面加载超时，请稍后重试');
    }
    if (generation != _generation) {
      throw const CampusCardBillException('账单页面会话已被新会话取代，请重试');
    }
    AppLogger.instance.network(LogLevel.info, '校园卡账单：页面就绪');
  }

  Future<void> _disposeOwned(int generation) async {
    if (generation != _generation) return;
    await invalidate();
  }

  /// 丢弃当前页面会话（下次 [fetch] 重新经 CAS / WebVPN 建会话）。
  Future<void> invalidate() async {
    _generation++;
    _controller = null;
    _proxyBase = null;
    final webview = _webview;
    _webview = null;
    try {
      await webview?.dispose();
    } catch (_) {}
  }

  /// 页面上下文批量拉取：五个 widget + 两个图表，一次 evaluate 完成。
  ///
  /// `load_content_mobile` 必须带 `sessionID`（FineReport 报表会话句柄，取自
  /// 页面 `document.cookie` 的 `sessionID`），否则服务端一律回「会话超时」
  /// 错误页（实测 2026-11-19）。缺它时 fetch 能通但拿不到数据。
  static String _script(String base, {String fallbackSid = ''}) {
    final config = jsonEncode({
      'base': base,
      'fallbackSid': fallbackSid,
      'widgets': [...statWidgets, recentWidget],
      'charts': chartWidgets,
    });
    return '''
(function(){
  window.__jxuBillRpc = '';
  var cfg = $config;
  function readSid(){
    try {
      if (window.FR && FR.SessionMgr && typeof FR.SessionMgr.get === 'function') {
        var frSid = FR.SessionMgr.get();
        if (frSid) return String(frSid);
      }
      if (window.FR && FR.currentSessionID) {
        return String(FR.currentSessionID);
      }
    } catch (_) {}
    var m = /(?:^|;\\s*)sessionID=([^;]+)/.exec(document.cookie || '');
    if (m && m[1]) return m[1];
    return cfg.fallbackSid || '';
  }
  function sleep(ms){
    return new Promise(function(resolve){ setTimeout(resolve, ms); });
  }
  async function waitForSid(){
    var sid = readSid();
    for (var i = 0; i < 34 && !sid; i++) {
      await sleep(150);
      sid = readSid();
    }
    return sid;
  }
  function qs(obj){
    return Object.keys(obj).map(function(k){
      return encodeURIComponent(k) + '=' + encodeURIComponent(obj[k]);
    }).join('&');
  }
  function widgetBody(name, sid){
    return qs({
      op: 'fr_form',
      cmd: 'load_content_mobile',
      toVanCharts: 'true',
      dynamicHyperlink: 'true',
      pageIndex: '1',
      sessionID: sid,
      fine_api_v_json: '3',
      features_accept: 'progress-bar-cell-json',
      widgetNames: JSON.stringify([name]),
      widgetName: name,
      arrayJson: 'false',
    });
  }
  function text(url, init){
    return fetch(url, init || {}).then(function(r){
      return r.text();
    });
  }
  (async function(){
    try {
      var sid = await waitForSid();
      var out = {
        base: cfg.base,
        href: String(window.location && window.location.href || ''),
        hasSid: Boolean(sid),
        hasFr: Boolean(window.FR),
        widgets: {},
        charts: {},
        errors: {}
      };
      var widgetUrls = cfg.widgets.map(function(name){
        return text(cfg.base + '/webroot/decision/view/form', {
          method: 'POST',
          credentials: 'include',
          headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'},
          body: widgetBody(name, sid)
        }).then(function(t){ out.widgets[name] = t; },
                function(e){ out.errors[name] = String(e); });
      });
      await Promise.all(widgetUrls);
      for (var i = 0; i < cfg.charts.length; i++) {
        var name = cfg.charts[i];
        try {
          var src = await text(cfg.base + '/webroot/decision/view/form?' + qs({
            __chartsourcename__: name,
            __fr_locale__: 'zh_CN',
            __reportType__: 'flow',
            op: 'fr_form',
            cmd: 'form_getsource',
            sessionID: sid,
            toVanCharts: 'true',
            dynamicHyperlink: 'true'
          }), {
            method: 'POST',
            credentials: 'include',
            headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'},
            body: qs({__parameters__: '{}'})
          });
          out.charts[name] = {source: src};
          var parsed = JSON.parse(src);
          var items = (parsed && parsed.items) || [];
          if (items.length && items[0].url) {
            out.charts[name].data = await text(cfg.base + '/webroot/decision/view/form' + items[0].url);
          }
        } catch (e) {
          out.errors[name] = String(e);
        }
      }
      window.__jxuBillRpc = JSON.stringify(out);
    } catch (e) {
      window.__jxuBillRpc = JSON.stringify({err: String(e)});
    }
  })();
})();
''';
  }
}

/// 账单页会话问题必须引导重新登录（区别于普通失败）。
class CampusCardBillAuthException extends CampusCardBillException {
  const CampusCardBillAuthException([super.message = '登录已失效，请重新登录统一认证']);
}

class CampusCardBillException implements Exception {
  const CampusCardBillException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 网关抓回的原始响应集合（未解析）。
@immutable
class CampusCardBillRawPayload {
  const CampusCardBillRawPayload({
    required this.widgets,
    required this.charts,
    this.cookie = '',
  });

  factory CampusCardBillRawPayload.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> asMap(Object? value) => value is Map
        ? value.map((key, value) => MapEntry(key.toString(), value))
        : const {};
    return CampusCardBillRawPayload(
      widgets: asMap(json['widgets'])
          .map((key, value) => MapEntry(key, value?.toString() ?? '')),
      charts: asMap(json['charts']),
      cookie: json['cookie']?.toString() ?? '',
    );
  }

  /// widget 名 → 原始 `load_content_mobile` 响应文本。
  final Map<String, String> widgets;

  /// 图表名 → `{source: ..., data: ...}`。
  final Map<String, dynamic> charts;

  /// 页面 `document.cookie`（含 FineReport 的 sessionID），用于诊断。
  final String cookie;
}
