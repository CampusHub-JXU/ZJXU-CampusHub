import 'dart:collection';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/logging/app_logger.dart';

/// epay100 网关会话不可用（未登录 / 会话失效）。
///
/// 用户在原生统一认证登录弹窗中完成登录后即可恢复。
class EpaySessionUnavailableException implements Exception {
  final String message;

  const EpaySessionUnavailableException([
    this.message = '统一认证会话不可用，请先登录统一认证后重试',
  ]);

  @override
  String toString() => message;
}

class EpayGatewayException implements Exception {
  final String message;

  const EpayGatewayException(this.message);

  @override
  String toString() => message;
}

/// epay100 电费网关：隐藏 WebView 保住登录态，Dart 在页面上下文里执行
/// fetch 发 RPC。
///
/// 为什么必须走页面上下文：epay100 网关把 access_token、浏览器指纹
/// （client_uuid）与注册环境绑成一组校验，原生 dio 直连会被
/// 「客户端识别码已失效」拒绝（详见 docs/dorm-electricity-epay100-api.md）。
/// 页面自己完成指纹注册；本类只负责驱动页面与收发结果。
abstract interface class EpayElectricityGateway {
  static final EpayElectricityGateway instance =
      HeadlessEpayElectricityGateway();

  Future<String> call(String method, Map<String, String> data);

  Future<void> invalidate();

  @visibleForTesting
  void debugReset();
}

class HeadlessEpayElectricityGateway implements EpayElectricityGateway {
  static const _rechargeUrl =
      'https://www.epay100.cn/901/6279/elecService/recharge';
  static const _uniId = '6279';
  static const _attach = '5.6.2607315';
  static const _tokenKey = 'mh901_access_token_h5_$_uniId';
  static const _clientUuidKey = 'mh901_client_uuid';

  /// token 写入时间戳（由注入脚本钩子写进 localStorage，供就绪判定读取）。
  static const _tokenTsKey = '__jxu_elec_token_ts';

  /// 「本会话已清过旧凭据」标记（存 sessionStorage，随隐藏 WebView 实例新建）。
  static const _cleanedKey = '__jxu_elec_cleaned';
  static const _readyTimeout = Duration(seconds: 30);

  /// 等待「本次会话新签发 token」的耐心窗口。页面若认为遗留 token 仍有效就
  /// 不会重写它，等满 [_readyTimeout] 只会让用户白等，超时后接受遗留凭据。
  static const _freshTokenGrace = Duration(seconds: 10);

  /// 凭据失效后最多重建会话重试几次（depth 从 0 起算）。
  static const _maxRetryDepth = 2;

  HeadlessInAppWebView? _webview;
  InAppWebViewController? _controller;
  Future<void>? _starting;
  Future<void>? _callTail;
  Future<void>? _invalidating;

  /// 会话代号：每次作废会话时递增。上一代会话的迟到回调（onWebViewCreated /
  /// onLoadStop / 启动收尾）据此丢弃，否则会覆盖新会话的 controller，或者把
  /// 新会话的 WebView 一起 dispose 掉。
  int _generation = 0;

  /// 下次启动会话时连同浏览器指纹（client_uuid）一起清除，让页面重新注册。
  /// 换过一轮 token 仍被服务端拒绝（C900903）时才升级到这一步。
  bool _needsFullReset = false;

  static const _rpcTimeout = Duration(seconds: 15);

  /// 会话失效后由外部（如原生统一认证登录完成）调用，重建隐藏会话。
  @override
  Future<void> invalidate() {
    final existing = _invalidating;
    if (existing != null) return existing;

    final future = _invalidateAfterCalls();
    _invalidating = future;
    return future.whenComplete(() {
      if (identical(_invalidating, future)) {
        _invalidating = null;
      }
    });
  }

  Future<void> _invalidateAfterCalls() async {
    final activeCalls = _callTail;
    if (activeCalls != null) await activeCalls;
    await _invalidateInternal();
    _starting = null;
  }

  Future<void> _invalidateInternal() async {
    _generation++;
    _controller = null;
    final webview = _webview;
    _webview = null;
    try {
      await webview?.dispose();
    } catch (_) {}
  }

  /// 只作废仍属于本代会话的 WebView。会话已被新的启动取代时按兵不动——
  /// 否则旧启动流程收尾时会把新会话的 WebView 一起 dispose 掉。
  Future<void> _disposeOwnedWebView(int generation) async {
    if (generation != _generation) return;
    await _invalidateInternal();
  }

  static Future<void> _safeDispose(HeadlessInAppWebView webview) async {
    try {
      await webview.dispose();
    } catch (_) {}
  }

  @visibleForTesting
  @override
  void debugReset() {
    _controller = null;
    _starting = null;
    _callTail = null;
    _invalidating = null;
    _generation++;
    _needsFullReset = false;
    final webview = _webview;
    _webview = null;
    webview?.dispose();
  }

  /// 页面上下文里执行 RPC，返回原始响应文本。
  ///
  /// 会话不可用 / 网关返回 C900903（登录态失效）时抛
  /// [EpaySessionUnavailableException]。
  @override
  Future<String> call(String method, Map<String, String> data) {
    final previous = _callTail;
    final gate = previous ?? Future<void>.value();
    final operation = gate.then<String>((_) {
      return _callInternal(method, data);
    });
    final completion = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _callTail = completion;
    unawaited(
      completion.whenComplete(() {
        if (identical(_callTail, completion)) _callTail = null;
      }),
    );
    return operation;
  }

  Future<String> _callInternal(
    String method,
    Map<String, String> data, {
    int depth = 0,
  }) async {
    final controller = await _ensureReady();
    // RPC 必须从 www.epay100.cn 页面上下文发出；页面处于 checkCas 重定向链
    // 中时 evaluate 会跑在别的 origin 上，fetch 直接跨域失败，等它回来。
    if (!await _waitOnEpayOrigin(controller)) {
      await _invalidateInternal();
      // 页面没回到 epay100 是网关侧问题（重定向卡住 / WebView 被回收），
      // 不是统一认证失效，别引导用户去重新登录。
      throw const EpayGatewayException('电费会话页面未就绪，请重试');
    }
    // Android WebView 的 evaluateJavascript 不会等待 Promise：异步 IIFE 的
    // 返回值会被序列化成 {}（同步求值却正常）。脚本因此把结果落到
    // window.__jxuRpc，这里启动脚本后用同步求值轮询取回。
    try {
      await controller
          .evaluateJavascript(source: _rpcScript(method, data))
          .timeout(_rpcTimeout);
    } on TimeoutException {
      await _invalidateInternal();
      throw const EpayGatewayException('电费网关响应超时，请稍后重试');
    }
    var payload = '';
    final rpcDeadline = DateTime.now().add(_rpcTimeout);
    while (payload.isEmpty) {
      if (DateTime.now().isAfter(rpcDeadline)) {
        await _invalidateInternal();
        throw const EpayGatewayException('电费网关响应超时，请稍后重试');
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
      Object? stored;
      try {
        stored = await controller
            .evaluateJavascript(source: "window.__jxuRpc || ''")
            .timeout(_rpcTimeout);
      } on TimeoutException {
        continue;
      } catch (_) {
        // 页面跳转瞬间 evaluate 可能失败，下一轮再取。
        continue;
      }
      payload = _unwrapStringResult(stored);
    }
    Object? json;
    try {
      json = jsonDecode(payload);
    } on FormatException {
      throw const EpaySessionUnavailableException('电费网关返回无法识别');
    }
    if (json is! Map<String, dynamic>) {
      throw const EpaySessionUnavailableException('电费网关返回无法识别');
    }
    final code = json['code']?.toString() ?? '';
    if (code == 'no-session') {
      AppLogger.instance.network(LogLevel.warn, '电费 RPC 会话丢失: $method');
      // 页面 boot 尚未写完 token / 注册完指纹，RPC 撞进这个窗口；重建会话
      // 重走一次 boot 再试，仍拿不到凭据才判定登录态真的不可用。
      await _rebuildForRetry(depth);
      await _ensureReady();
      return _callInternal(method, data, depth: depth + 1);
    }
    if (code == 'C900903') {
      AppLogger.instance.network(LogLevel.warn, '电费 RPC 登录态失效: $method');
      // 服务端把 token + client_uuid（浏览器指纹）绑成一组校验：localStorage
      // 里遗留的 token 与本次页面注册的指纹不是同一组就会被拒。C900903 的
      // 原话是「客户端识别码已失效」，指纹本身就是嫌疑对象，第一次重建就连
      // token 带 uuid 一起清掉重新注册；换过一轮仍被拒才真的需要重新登录。
      _needsFullReset = true;
      await _rebuildForRetry(depth);
      await _ensureReady();
      return _callInternal(method, data, depth: depth + 1);
    }
    if (code != '200') {
      if (code.isEmpty) {
        // 服务端返回了信封之外的内容（HTML 登录重定向 / 维护页 / 空体）。
        // 旧 token + 过期 PHPSESSID 的组合最容易触发：重建会话换新凭据，
        // 并在同一串行槽位里重试一次，仍失败才交给上层。
        final status = json['status']?.toString() ?? '';
        final head = _bodyHead(json['head']?.toString() ?? '');
        final rawHead = _bodyHead(payload, limit: 200);
        AppLogger.instance.network(
          LogLevel.warn,
          '电费 RPC 响应异常: method=$method http=$status nf=${json['nf']} '
          'body=$head raw=$rawHead',
        );
        await _rebuildForRetry(
          depth,
          giveUp: const EpayGatewayException('电费网关暂时无法响应，请稍后重试'),
        );
        await _ensureReady();
        return _callInternal(method, data, depth: depth + 1);
      }
      final message = json['msg']?.toString() ?? '';
      if (code == 'request-failed') {
        // 页面内 fetch 抛错（断网 / 跳转打断 / 12 秒中止）。原始 JS 错误
        // 文案只进日志，用户看到可读提示。
        AppLogger.instance.network(
          LogLevel.warn,
          '电费 RPC 请求失败: $method msg=$message',
        );
        throw const EpayGatewayException('电费网关网络异常，请稍后重试');
      }
      AppLogger.instance.network(
        LogLevel.warn,
        '电费 RPC 业务错误: method=$method code=$code${message.isNotEmpty ? ' msg=$message' : ''}',
      );
      throw EpayGatewayException(message.isEmpty ? '电费网关请求失败' : message);
    }
    return json['body']?.toString() ?? '';
  }

  /// 凭据失效后作废当前会话，为重试做准备。
  ///
  /// 第二次重建起连同浏览器指纹一起清掉（[_needsFullReset]），让页面连
  /// client_uuid 一起重新注册；重试预算用尽则抛 [giveUp]。
  Future<void> _rebuildForRetry(
    int depth, {
    Exception giveUp = const EpaySessionUnavailableException(),
  }) async {
    if (depth >= _maxRetryDepth) throw giveUp;
    if (depth >= 1) _needsFullReset = true;
    await _invalidateInternal();
  }

  /// RPC 前等待页面回到 epay100 origin；停在 CAS 登录页说明统一认证会话
  /// 已失效，直接给出明确错误而不是等超时。
  static const _originWaitTimeout = Duration(seconds: 6);

  Future<bool> _waitOnEpayOrigin(InAppWebViewController controller) async {
    final deadline = DateTime.now().add(_originWaitTimeout);
    while (true) {
      final Uri? current;
      try {
        final uri = await controller.getUrl();
        current = uri == null ? null : Uri.parse(uri.toString());
      } catch (_) {
        return false;
      }
      if (current?.host == 'www.epay100.cn') return true;
      if (current?.host == 'newca.zjxu.edu.cn' &&
          (current?.path ?? '').startsWith('/cas/login')) {
        throw const EpaySessionUnavailableException('统一认证已失效，请重新登录');
      }
      if (DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// 压缩空白并截断，用于诊断日志展示未知响应体开头。
  static String _bodyHead(String raw, {int limit = 120}) {
    final collapsed = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= limit) return collapsed;
    return '${collapsed.substring(0, limit)}…';
  }

  // ── 内部：会话启动 ──────────────────────────────────────────────────────

  Future<InAppWebViewController> _ensureReady() async {
    final invalidating = _invalidating;
    if (invalidating != null) await invalidating;

    final activeStart = _starting;
    if (activeStart != null) {
      try {
        await activeStart;
      } catch (e) {
        if (identical(_starting, activeStart)) _starting = null;
        rethrow;
      }
      if (identical(_starting, activeStart)) _starting = null;
      final controller = _controller;
      if (controller != null) return controller;
    }

    final existing = _controller;
    if (existing != null) return existing;
    final starting = _start();
    _starting = starting;
    try {
      await starting;
    } catch (e) {
      if (identical(_starting, starting)) _starting = null;
      rethrow;
    }
    if (identical(_starting, starting)) _starting = null;
    final controller = _controller;
    if (controller == null) {
      throw const EpaySessionUnavailableException();
    }
    return controller;
  }

  Future<void> _start() async {
    final generation = _generation;
    AppLogger.instance.network(LogLevel.info, '电费网关：启动隐藏 WebView 会话');

    // 先确认 App 侧的一卡通 CAS 会话仍然有效，再把 Cookie 同步进隐藏
    // WebView。这样 epay100 的 checkCas 只在后台走 SSO，不把认证页面带到
    // 电费原生页面上。
    try {
      final auth = UnifiedAuthService.instance;
      await auth.restoreSession(syncWebViewCookies: false);
      if (!auth.isLoggedIn) {
        throw const EpaySessionUnavailableException('请先登录统一认证后查询电费');
      }

      final sessionStatus = await CasSession.ensure(
        CasService.ydd.serviceUrl,
        restoreFromStore: false,
        syncWebViewCookies: false,
      );
      if (sessionStatus == CasSessionStatus.inactive) {
        throw const EpaySessionUnavailableException('统一认证已失效，请重新登录');
      }
      if (sessionStatus == CasSessionStatus.unknown) {
        AppLogger.instance.network(
          LogLevel.warn,
          '电费网关：统一认证校验遇到网络异常，继续尝试复用现有 Cookie',
        );
      }

      await auth.syncCookiesToWebView();
    } catch (e) {
      if (e is EpaySessionUnavailableException) rethrow;
      AppLogger.instance.network(LogLevel.warn, '电费网关：同步统一认证 Cookie 失败: $e');
      throw EpaySessionUnavailableException('统一认证会话不可用，请重新登录');
    }

    // 每次重建会话都强制页面重走一次 checkCas 换发新 token：localStorage 里
    // 遗留的 token 与本次页面注册的指纹（client_uuid）不是同一组，服务端会
    // 回 C900903「客户端识别码已失效」。清理放在 document-start（页面 boot
    // 之前）执行，不再走「先判定就绪 → 再清凭据 → reload」的旧路径：reload
    // 会让页面带着半初始化的状态重入 CAS 链，实测经常卡到 30 秒超时。
    final clearFingerprint = _needsFullReset;
    _needsFullReset = false;
    if (clearFingerprint) {
      AppLogger.instance.network(LogLevel.info, '电费网关：连同指纹重建凭据');
    }
    final sessionStart = DateTime.now().millisecondsSinceEpoch;

    final ready = Completer<void>();
    HeadlessInAppWebView? webview;
    // onLoadStop 在 webview.run() 之后才可能有事件，处理闭包晚一步挂上。
    void Function(InAppWebViewController controller, WebUri? url)?
    onLoadStopHandler;
    webview = HeadlessInAppWebView(
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        useShouldOverrideUrlLoading: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        thirdPartyCookiesEnabled: true,
        transparentBackground: true,
        applicationNameForUserAgent: ' DingTalk/7.0.0',
      ),
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          source: _dingTalkBridgeStub,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        UserScript(
          source: _freshCredentialsScript(clearFingerprint: clearFingerprint),
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      onWebViewCreated: (c) {
        // 上一代会话的迟到回调不能覆盖新会话的 controller。
        if (generation != _generation) return;
        _controller = c;
      },
      onLoadStop: (c, url) {
        final handler = onLoadStopHandler;
        if (handler != null) handler(c, url);
      },
    );

    if (generation != _generation) {
      throw const EpayGatewayException('电费会话已被新会话取代，请重试');
    }
    _webview = webview;
    try {
      await webview.run();
    } catch (_) {
      await _disposeOwnedWebView(generation);
      throw const EpayGatewayException('电费会话启动失败，请重试');
    }
    if (generation != _generation) {
      // 启动期间会话已被取代：这个 WebView 已经没人持有，就地销毁别泄漏。
      unawaited(_safeDispose(webview));
      throw const EpayGatewayException('电费会话已被新会话取代，请重试');
    }
    final controller = webview.webViewController;
    if (controller == null) {
      await _disposeOwnedWebView(generation);
      throw const EpayGatewayException('电费会话启动失败，请重试');
    }

    final freshDeadline = DateTime.now().add(_freshTokenGrace);
    var checkingToken = false;
    Future<void> checkToken() async {
      if (ready.isCompleted || checkingToken) return;
      if (generation != _generation) return;
      checkingToken = true;
      try {
        final current = await controller.getUrl();
        final host = current?.host ?? '';
        if (host == 'newca.zjxu.edu.cn' &&
            (current?.path ?? '').startsWith('/cas/login')) {
          // 静默 SSO 停在了 CAS 登录页：统一认证会话未被接受，直接报明
          // 确错误，不再等 30 秒超时。
          if (!ready.isCompleted) {
            ready.completeError(
              const EpaySessionUnavailableException('统一认证已失效，请重新登录'),
            );
          }
          return;
        }
        // 重定向链途经 open.epay100.cn / newca / mobilehall，此刻的
        // localStorage 不属于 epay100 origin，不能据此判定就绪。
        if (host != 'www.epay100.cn') return;
        // RPC 需要 token + client_uuid 同时在位；uuid 由页面 boot 时注册，
        // 只看其中一个都会抢跑。
        final probe = EpayReadyProbe.parse(
          await controller.evaluateJavascript(source: _readyProbeScript),
        );
        if (probe == null || !probe.hasToken || !probe.hasUuid) return;
        // 优先确认 token 是本次会话新签发的（旧 token 换来的 RPC 必被拒）：
        // 清理标记为 true 即可确认（清理把旧 token 删了，剩下的必然是新写入
        // 的）；时间戳作双保险。页面若认为遗留凭据仍有效就不重写，等满宽限
        // 期后接受它，别干等到 30 秒超时。
        final fresh =
            probe.credentialsCleared ||
            probe.tokenTimestamp >= sessionStart - 1000;
        if (!fresh && DateTime.now().isBefore(freshDeadline)) return;
        if (!ready.isCompleted) {
          AppLogger.instance.network(LogLevel.debug, '电费网关：凭据到位（新签发=$fresh）');
          ready.complete();
        }
      } catch (_) {
        // CAS 跳转期间 origin 会变化，继续轮询直到回到 epay100。
      } finally {
        checkingToken = false;
      }
    }

    onLoadStopHandler = (c, url) async {
      if (generation != _generation) return;
      unawaited(checkToken());
    };

    final readyTimer = Timer(_readyTimeout, () {
      if (!ready.isCompleted) {
        // 初始化超时是网关侧问题，别把它说成「请重新登录」。
        ready.completeError(const EpayGatewayException('电费网关会话初始化超时，请重试'));
      }
    });
    final tokenPoller = Timer.periodic(
      const Duration(milliseconds: 300),
      (_) => unawaited(checkToken()),
    );
    try {
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(_rechargeUrl)),
      );
      await checkToken();
      await ready.future;
      if (generation != _generation) {
        throw const EpayGatewayException('电费会话已被新会话取代，请重试');
      }
      AppLogger.instance.network(LogLevel.info, '电费网关：会话就绪');
    } on EpayGatewayException {
      await _disposeOwnedWebView(generation);
      rethrow;
    } on EpaySessionUnavailableException {
      await _disposeOwnedWebView(generation);
      rethrow;
    } catch (e) {
      await _disposeOwnedWebView(generation);
      throw EpayGatewayException('电费会话启动失败: $e');
    } finally {
      tokenPoller.cancel();
      readyTimer.cancel();
    }
  }

  /// 会话首个 epay100 文档开头清掉遗留 token，逼页面重新走 checkCas。
  ///
  /// 同时挂钩 `localStorage.setItem` 记录 token 写入时间戳，就绪判定据此区分
  /// 「本次会话新签发」与「上次会话遗留」。
  String _freshCredentialsScript({required bool clearFingerprint}) {
    return '''
(function() {
  var TOKEN = '$_tokenKey';
  var UUID = '$_clientUuidKey';
  var TS = '$_tokenTsKey';
  var CLEANED = '$_cleanedKey';
  try {
    if (location.hostname === 'www.epay100.cn' &&
        !sessionStorage.getItem(CLEANED)) {
      sessionStorage.setItem(CLEANED, '1');
      try { localStorage.removeItem(TOKEN); } catch (e) {}
      try { localStorage.removeItem(TS); } catch (e) {}
      if (${clearFingerprint ? 'true' : 'false'}) {
        try { localStorage.removeItem(UUID); } catch (e) {}
        try { sessionStorage.removeItem(UUID); } catch (e) {}
      }
    }
  } catch (e) {}
  try {
    var original = Storage.prototype.setItem;
    Storage.prototype.setItem = function(key, value) {
      try {
        if (key === TOKEN) original.call(localStorage, TS, String(Date.now()));
      } catch (e) {}
      return original.apply(this, arguments);
    };
  } catch (e) {}
})();
''';
  }

  String get _readyProbeScript =>
      '''
JSON.stringify({
  token: Boolean(localStorage.getItem('$_tokenKey')),
  uuid: Boolean(sessionStorage.getItem('$_clientUuidKey') ||
                localStorage.getItem('$_clientUuidKey')),
  cleaned: Boolean(sessionStorage.getItem('$_cleanedKey')),
  ts: Number(localStorage.getItem('$_tokenTsKey') || 0)
})
''';

  String _rpcScript(String method, Map<String, String> data) {
    final methodJson = jsonEncode(method);
    final dataJson = jsonEncode(data);
    return '''
window.__jxuRpc = '';
(async function() {
  var result = '';
  try {
    var uuid = sessionStorage.getItem('$_clientUuidKey') ||
               localStorage.getItem('$_clientUuidKey') || '';
    var token = localStorage.getItem('$_tokenKey') || '';
    if (!uuid || !token) {
      result = JSON.stringify({ ok: false, code: 'no-session' });
      window.__jxuRpc = result;
      return;
    }
    var params = new URLSearchParams();
    var method = $methodJson;
    params.set('method', method);
    params.set('uni_id', '$_uniId');
    params.set('client_uuid', uuid);
    params.set('attach', '$_attach');
    var data = $dataJson;
    for (var k in data) { params.set('data[' + k + ']', data[k]); }
    var rand = Date.now() + '-' + Math.random().toString(36).slice(2, 10);
    var url = 'https://www.epay100.cn/901/$_uniId/server/index.php'
      + '?mh901_method=' + encodeURIComponent(method)
      + '&mh901_client_uuid=' + encodeURIComponent(uuid)
      + '&mh901_rand=' + rand;
    var controller = new AbortController();
    var abortTimer = setTimeout(function() { controller.abort(); }, 12000);
    var resp = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Authorization': token,
      },
      credentials: 'include',
      body: params.toString(),
      signal: controller.signal,
    });
    clearTimeout(abortTimer);
    var text = await resp.text();
    var nf = false;
    try { nf = String(window.fetch).indexOf('native code') >= 0; } catch (e) {}
    var parsed = {};
    try { parsed = JSON.parse(text); } catch (e) {}
    result = JSON.stringify({
      ok: true,
      status: Number(resp.status),
      nf: nf,
      code: String(parsed.code || ''),
      msg: String(parsed.msg || ''),
      head: String(text).replace(/\\s+/g, ' ').trim().slice(0, 120),
      body: text
    });
  } catch (e) {
    result = JSON.stringify({
      ok: false,
      code: 'request-failed',
      msg: String(e && e.message ? e.message : e)
    });
  }
  window.__jxuRpc = result;
  return result;
})();
''';
  }

  /// evaluateJavascript 对字符串返回值可能再包一层 JSON 编码，逐层解开。
  static String _unwrapStringResult(Object? result) {
    var value = result;
    for (var i = 0; i < 3; i++) {
      if (value is! String) break;
      final trimmed = value.trim();
      if (trimmed.startsWith('{')) return trimmed;
      try {
        value = jsonDecode(trimmed);
      } catch (_) {
        return trimmed;
      }
    }
    return value == null ? '' : value.toString();
  }

  /// 与可见 WebViewPage 相同的钉钉容器仿真（epay100 页面按容器分支行为）。
  static const _dingTalkBridgeStub = '''
(function() {
  var ddMock = {
    ready: function(cb) { if (typeof cb === 'function') setTimeout(cb, 0); },
    error: function(cb) {},
    config: function() {},
    biz: {
      navigation: {
        setTitle: function() {},
        setRight: function() {},
        close: function() {}
      },
      util: {
        openLink: function(opts) {
          if (opts && opts.url) { window.location.href = opts.url; }
        }
      }
    },
    permission: {
      requestAuthCode: function(opts) {
        if (opts && typeof opts.onFail === 'function') {
          opts.onFail({ errorCode: 3, errorMessage: 'not supported' });
        }
      }
    },
    runtime: {
      permission: {
        requestAuthCode: function(opts) {
          if (opts && typeof opts.onFail === 'function') {
            opts.onFail({ errorCode: 3, errorMessage: 'not supported' });
          }
        }
      }
    },
    device: {
      notification: {
        alert: function(opts) {
          if (opts && typeof opts.onSuccess === 'function') opts.onSuccess();
        }
      }
    },
    env: { platform: 'notInDingTalk' },
    version: '7.0.0'
  };
  try {
    Object.defineProperty(window, 'dd', {
      get: function() { return ddMock; },
      set: function() {},
      configurable: true
    });
  } catch (e) {}
})();
''';
}

/// 页面凭据快照：RPC 前 token 与 client_uuid 必须同时在位。
/// [credentialsCleared] / [tokenTimestamp] 用于区分「本次会话新签发」与
/// 「上次会话遗留」。
class EpayReadyProbe {
  const EpayReadyProbe({
    required this.hasToken,
    required this.hasUuid,
    required this.credentialsCleared,
    required this.tokenTimestamp,
  });

  final bool hasToken;
  final bool hasUuid;

  /// 本会话的清理脚本已经跑过（会话首个 epay100 文档开头删过旧 token）。
  /// 为 true 时 localStorage 里存在的 token 必然是清理之后新写入的——
  /// 即使时间戳钩子失效，也能据此确认凭据是本次新签发的。
  final bool credentialsCleared;

  /// token 写入时刻（页面 `Date.now()`，与 Dart 侧同一系统时钟）。
  final int tokenTimestamp;

  /// 解析就绪探测脚本的返回值。
  ///
  /// Android 的 `evaluateJavascript` 会把脚本返回的 JSON 字符串再包一层
  /// 引号，iOS 则可能直接给 Map，两种形态都要接得住；解析不出内容返回
  /// null（当作凭据未到位，继续轮询）。
  static EpayReadyProbe? parse(Object? raw) {
    var value = raw;
    // Android 会把 JSON 字符串再编码一层，逐层解开（最多三层）。
    for (var i = 0; i < 3; i++) {
      if (value is! String) break;
      final text = value.trim();
      if (text.startsWith('{')) break;
      try {
        value = jsonDecode(text);
      } catch (_) {
        return null;
      }
    }
    if (value is String) {
      final text = value.trim();
      if (!text.startsWith('{')) return null;
      try {
        value = jsonDecode(text);
      } catch (_) {
        return null;
      }
    }
    if (value is! Map) return null;
    final map = value;
    final timestamp = map['ts'];
    return EpayReadyProbe(
      hasToken: _asBool(map['token']),
      hasUuid: _asBool(map['uuid']),
      credentialsCleared: _asBool(map['cleaned']),
      tokenTimestamp: timestamp is num
          ? timestamp.toInt()
          : int.tryParse(timestamp?.toString() ?? '') ?? 0,
    );
  }

  static bool _asBool(Object? value) {
    if (value is bool) return value;
    final text = value?.toString().trim().toLowerCase() ?? '';
    return text == 'true';
  }
}
