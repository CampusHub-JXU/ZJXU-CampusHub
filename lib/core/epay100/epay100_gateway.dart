import 'dart:collection';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../auth/cas_auth_broker.dart';
import '../auth/unified_auth.dart';
import '../logging/app_logger.dart';

part 'epay100_gateway_scripts.dart';

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

/// 门户身份需要认证/注册绑定（C900901），不是登录过期，也不是指纹失效。
///
/// 固定中文文案，不含服务端原文。调用方应引导用户去官方付款页完成绑定，
/// 不得自动注册、不得当会话失效重建。
class EpayBindingRequiredException extends EpayGatewayException {
  static const defaultMessage = '请前往官方付款页完成一卡通认证或绑定，再返回重新获取付款码';

  const EpayBindingRequiredException([super.message = defaultMessage]);
}

/// RPC 信封错误的分类结果：重建会话重试，或直接抛给调用方。
class EpayRpcErrorAction {
  const EpayRpcErrorAction.retry({required this.logLine, required this.giveUp})
    : exception = null;

  const EpayRpcErrorAction.fail(this.exception, {required this.logLine})
    : giveUp = null;

  final String logLine;
  final Exception? giveUp;
  final Exception? exception;
}

/// epay100 共享网关（电费查询、一卡通付款码等）：隐藏 WebView 保住登录态，
/// Dart 在页面上下文里执行 fetch 发 RPC。
///
/// 为什么必须走页面上下文：epay100 网关把 access_token、浏览器指纹
/// （client_uuid）与注册环境绑成一组校验，原生 dio 直连会被
/// 「客户端识别码已失效」拒绝（详见 docs/dorm-electricity-epay100-api.md）。
/// 页面自己完成指纹注册；本类只负责驱动页面与收发结果。
abstract interface class Epay100Gateway {
  static final Epay100Gateway instance = HeadlessEpay100Gateway();

  Future<String> call(String method, Map<String, String> data);

  Future<void> invalidate();

  @visibleForTesting
  void debugReset();
}

class HeadlessEpay100Gateway implements Epay100Gateway {
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

  /// 付款码等敏感 RPC 的 method 前缀：响应原文可能含支付凭证，
  /// 日志只记录 method/status/code，不记录 body/msg/raw。
  static const _sensitiveMethodPrefix = 'app.yktservice';

  /// 隐藏 WebView 设置：普通移动 H5，不追加 DingTalk UA。
  ///
  /// 实机对照（同 WebView 单变量）：`applicationNameForUserAgent: ' DingTalk/7.0.0'`
  /// 时 `/portal/register` 一直「应用加载中」、无 CAS 按钮、console
  /// `H5 OR MINI EXCEPTION`；去掉该后缀后页面正常渲染，
  /// `getOAuthUrl` / `getOAuthUuid` / `getMemberBindHas` 成功。签名 URL
  /// 后无导航另案，不能宣称去掉 UA 解决全部绑定/登录。
  @visibleForTesting
  static InAppWebViewSettings headlessWebViewSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      domStorageEnabled: true,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      thirdPartyCookiesEnabled: true,
      transparentBackground: true,
    );
  }

  /// 当前 WebView 会话绑定的统一认证账号（会话启动成功后写入）。
  String? _boundAccount;

  /// 统一认证身份纪元：每次收到统一认证 notifier 通知（登录/登出/会话恢复
  /// /切换账号）递增。同一账号 logout→login 后凭据组（token、指纹、CAS
  /// 会话）也已换新，仅比对账号相等不足以拦截旧会话的迟到结果。
  int _authEpoch = 0;

  /// 启动完成身份绑定后发生了外部登录态变化：本次 startup 不得继续。
  bool _startupAuthChanged = false;

  HeadlessEpay100Gateway() {
    // 账号绑定：统一认证登出 / 切换账号即刻作废本会话，下次启动连同
    // epay token 与 client_uuid 一起定向清理（不动全局 Cookie），
    // 确保 A 账号的凭据不会被下一账号复用。
    UnifiedAuthService.instance.addListener(_onUnifiedAuthChanged);
  }

  void _onUnifiedAuthChanged() {
    _authEpoch++;
    _handleAccountChange(UnifiedAuthService.instance.currentAccount);
  }

  void _handleAccountChange(String? currentAccount) {
    if (_starting != null && _boundAccount != null) {
      // 启动已完成身份绑定后发生外部登录态变化：作废本次启动（连同
      // full reset），防止旧 startup 以旧身份继续跑完并出码。
      _startupAuthChanged = true;
      _needsFullReset = true;
      _boundAccount = null;
      unawaited(invalidate());
      return;
    }
    if (!accountChangeInvalidatesSession(_boundAccount, currentAccount)) return;
    _needsFullReset = true;
    _boundAccount = null;
    unawaited(invalidate());
  }

  HeadlessInAppWebView? _webview;
  InAppWebViewController? _controller;
  Future<void>? _starting;
  Future<void>? _callTail;
  Future<void>? _inFlightCall;
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
    // 只等真正正在执行的 RPC，不等整个 _callTail。排队中的后续调用会在
    // _ensureReady 里等本次 invalidate，若这里再等它们就会互相等待死锁。
    final inFlight = _inFlightCall;
    if (inFlight != null) await inFlight;
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
    _inFlightCall = null;
    _invalidating = null;
    _generation++;
    _needsFullReset = false;
    _boundAccount = null;
    _startupAuthChanged = false;
    debugRpcSendCount = 0;
    debugStartupGate = null;
    final webview = _webview;
    _webview = null;
    webview?.dispose();
  }

  /// 账号变化是否需要作废会话：登出（变 null）或切换成其他账号。
  @visibleForTesting
  static bool accountChangeInvalidatesSession(
    String? boundAccount,
    String? currentAccount,
  ) => boundAccount != null && currentAccount != boundAccount;

  /// RPC 返回前确认统一认证会话身份未变：auth-epoch 不一致（登出/重登/
  /// 切账号，即使账号相同）或账号不一致时，旧会话的迟到结果一律拒绝。
  @visibleForTesting
  static void ensureSameSession(
    String? sessionAccount,
    int sessionEpoch,
    String? currentAccount,
    int currentEpoch,
  ) {
    if (sessionEpoch != currentEpoch) {
      throw const EpaySessionUnavailableException('统一认证会话已变更，请重试');
    }
    if (sessionAccount != null && currentAccount != sessionAccount) {
      throw const EpaySessionUnavailableException('统一认证账号已切换，请重试');
    }
  }

  @visibleForTesting
  String? get debugBoundAccount => _boundAccount;

  @visibleForTesting
  bool get debugNeedsFullReset => _needsFullReset;

  @visibleForTesting
  int get debugAuthEpoch => _authEpoch;

  /// 已发出的 RPC 次数（evaluateJavascript 注入前递增），用于验证
  /// 「启动等待中 auth 变化 → RPC 零发送」。
  @visibleForTesting
  int debugRpcSendCount = 0;

  /// 测试钩子：非空时 [_start] 在最前端挂起，用于模拟启动等待期间
  /// 发生登录态变化。
  @visibleForTesting
  Completer<void>? debugStartupGate;

  @visibleForTesting
  void debugBindAccount(String? account) => _boundAccount = account;

  @visibleForTesting
  void debugHandleAuthChanged() => _onUnifiedAuthChanged();

  /// 会话就绪后固定操作身份（仅一次）：入队时未登录的冷启动调用在
  /// restoreSession 正常建立身份后采样；已固定的直接跳过。
  void _establishOperationIdentity(_OperationIdentity identity) {
    if (identity.established) return;
    final auth = UnifiedAuthService.instance;
    if (!auth.isLoggedIn || auth.currentAccount == null) {
      throw const EpaySessionUnavailableException('请先登录统一认证后重试');
    }
    identity
      ..account = auth.currentAccount
      ..epoch = _authEpoch
      ..established = true;
  }

  /// 每个 await 边界（启动完成后、origin 等待后、发送前、响应处理前、
  /// 错误重试前）的统一守卫：epoch 或账号任一变化即拒绝，确保排队的
  /// RPC 不会发给新账号、旧会话的迟到结果不会被采用。
  void _ensureOperationSession(_OperationIdentity identity, String method) {
    if (!identity.established) {
      _establishOperationIdentity(identity);
      return;
    }
    ensureSameSession(
      identity.account,
      identity.epoch,
      UnifiedAuthService.instance.currentAccount,
      _authEpoch,
    );
  }

  /// 页面上下文里执行 RPC，返回原始响应文本。
  ///
  /// 会话不可用 / 网关返回 C900903（登录态失效）时抛
  /// [EpaySessionUnavailableException]。
  @override
  Future<String> call(String method, Map<String, String> data) {
    // 入队即固定本次操作的身份与 epoch：排队期间发生登出/切账号时，
    // 排队的 RPC 不会被发给新账号，也不会采用旧会话的迟到结果。
    // 入队时未登录（冷启动）的操作先标记「未固定」，待会话启动完成、
    // restoreSession 正常建立身份后采样一次，其后不再重采样。
    final auth = UnifiedAuthService.instance;
    final identity = _OperationIdentity(_authEpoch, auth.currentAccount);
    final previous = _callTail;
    final gate = previous ?? Future<void>.value();
    final operation = gate.then<String>((_) {
      final running = _callInternal(method, data, identity);
      final inFlight = running.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      _inFlightCall = inFlight;
      return running.whenComplete(() {
        if (identical(_inFlightCall, inFlight)) _inFlightCall = null;
      });
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
    Map<String, String> data,
    _OperationIdentity identity, {
    int depth = 0,
  }) async {
    final controller = await _ensureReady();
    // 会话就绪后固定操作身份（仅一次；入队时未登录的冷启动调用在
    // restoreSession 建立身份后采样，递归重试沿用同一 identity，不重采样）。
    _establishOperationIdentity(identity);
    // 发送前：排队/启动期间登录态已变化（如 A 排队后切到 B）→ 拒绝。
    _ensureOperationSession(identity, method);
    // RPC 必须从 www.epay100.cn 页面上下文发出；页面处于 checkCas 重定向链
    // 中时 evaluate 会跑在别的 origin 上，fetch 直接跨域失败，等它回来。
    if (!await _waitOnEpayOrigin(controller)) {
      await _invalidateInternal();
      // 页面没回到 epay100 是网关侧问题（重定向卡住 / WebView 被回收），
      // 不是统一认证失效，别引导用户去重新登录。
      throw const EpayGatewayException('一卡通会话页面未就绪，请重试');
    }
    // 等待 origin 是 await 边界：期间登录态变化即拒绝。
    _ensureOperationSession(identity, method);
    // Android WebView 的 evaluateJavascript 不会等待 Promise：异步 IIFE 的
    // 返回值会被序列化成 {}（同步求值却正常）。脚本因此把结果落到
    // window.__jxuRpc，这里启动脚本后用同步求值轮询取回。
    debugRpcSendCount++;
    try {
      await controller
          .evaluateJavascript(source: _rpcScript(method, data))
          .timeout(_rpcTimeout);
    } on TimeoutException {
      await _invalidateInternal();
      throw const EpayGatewayException('一卡通网关响应超时，请稍后重试');
    }
    var payload = '';
    final rpcDeadline = DateTime.now().add(_rpcTimeout);
    while (payload.isEmpty) {
      if (DateTime.now().isAfter(rpcDeadline)) {
        await _invalidateInternal();
        throw const EpayGatewayException('一卡通网关响应超时，请稍后重试');
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
    // 取到响应是 await 边界：登录态变化时旧响应一律不处理。
    _ensureOperationSession(identity, method);
    Object? json;
    try {
      json = jsonDecode(payload);
    } on FormatException {
      throw const EpaySessionUnavailableException('一卡通网关返回无法识别');
    }
    if (json is! Map<String, dynamic>) {
      throw const EpaySessionUnavailableException('一卡通网关返回无法识别');
    }
    final action = classifyRpcError(
      method: method,
      json: json,
      payload: payload,
    );
    if (action == null) return json['body']?.toString() ?? '';
    AppLogger.instance.network(LogLevel.warn, action.logLine);
    final fail = action.exception;
    if (fail != null) throw fail;
    if ((json['code']?.toString() ?? '') == 'C900903') {
      _needsFullReset = true;
    }
    await _rebuildForRetry(
      depth,
      giveUp: action.giveUp ?? const EpaySessionUnavailableException(),
    );
    await _ensureReady();
    _ensureOperationSession(identity, method);
    return _callInternal(method, data, identity, depth: depth + 1);
  }

  /// 把 RPC 信封错误分成「重建重试」或「直接失败」。
  ///
  /// C900901 = 门户身份需认证/绑定，绝不重建；C900903 / no-session / 空信封
  /// 才重建。敏感 method 日志只含 method/code，不含 msg/body。
  @visibleForTesting
  static EpayRpcErrorAction? classifyRpcError({
    required String method,
    required Map<String, dynamic> json,
    String payload = '',
  }) {
    final code = json['code']?.toString() ?? '';
    final sensitive = method.startsWith(_sensitiveMethodPrefix);
    if (code == '200') return null;
    if (code == 'C900901') {
      return EpayRpcErrorAction.fail(
        const EpayBindingRequiredException(),
        logLine: 'epay100 RPC 需要绑定: method=$method code=C900901',
      );
    }
    if (code == 'no-session') {
      return EpayRpcErrorAction.retry(
        logLine: 'epay100 RPC 会话丢失: $method',
        giveUp: const EpaySessionUnavailableException(),
      );
    }
    if (code == 'C900903') {
      return EpayRpcErrorAction.retry(
        logLine: 'epay100 RPC 登录态失效: $method',
        giveUp: const EpaySessionUnavailableException(),
      );
    }
    if (code.isEmpty) {
      final status = json['status']?.toString() ?? '';
      final logLine = sensitive
          ? 'epay100 RPC 响应异常: method=$method http=$status '
                'nf=${json['nf']} code=$code'
          : 'epay100 RPC 响应异常: method=$method http=$status nf=${json['nf']} '
                'body=${_bodyHead(json['head']?.toString() ?? '')} '
                'raw=${_bodyHead(payload, limit: 200)}';
      return EpayRpcErrorAction.retry(
        logLine: logLine,
        giveUp: const EpayGatewayException('一卡通网关暂时无法响应，请稍后重试'),
      );
    }
    final message = json['msg']?.toString() ?? '';
    if (code == 'request-failed') {
      return EpayRpcErrorAction.fail(
        const EpayGatewayException('一卡通网关网络异常，请稍后重试'),
        logLine: 'epay100 RPC 请求失败: $method msg=$message',
      );
    }
    final logLine = sensitive
        ? 'epay100 RPC 业务错误: method=$method code=$code'
        : 'epay100 RPC 业务错误: method=$method code=$code'
              '${message.isNotEmpty ? ' msg=$message' : ''}';
    return EpayRpcErrorAction.fail(
      EpayGatewayException(message.isEmpty ? '一卡通网关请求失败' : message),
      logLine: logLine,
    );
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
    _startupAuthChanged = false;
    AppLogger.instance.network(LogLevel.info, '一卡通网关：启动隐藏 WebView 会话');

    // 测试钩子：在启动最前端挂起，模拟启动等待期间发生登录态变化。
    final startupGate = debugStartupGate;
    if (startupGate != null) {
      await startupGate.future;
      if (generation != _generation) {
        throw const EpayGatewayException('一卡通会话已被新会话取代，请重试');
      }
    }

    // 先确认 App 侧的一卡通 CAS 会话仍然有效，再把 Cookie 同步进隐藏
    // WebView。这样 epay100 的 checkCas 只在后台走 SSO，不把认证页面带到
    // 业务原生页面上。
    try {
      final auth = UnifiedAuthService.instance;
      if (!auth.isLoggedIn) {
        // 仅未登录时才冷恢复（restoreSession 只在真正身份变化时通知）；
        // 已登录直接使用当前身份，避免无谓通知推进 epoch 使入队身份失配。
        await auth.restoreSession(syncWebViewCookies: false);
        if (!auth.isLoggedIn) {
          throw const EpaySessionUnavailableException('请先登录统一认证后重试');
        }
      }
      if (_startupAuthChanged) {
        // 启动等待期间发生外部登录态变化：不得把变更后的账号绑进本次会话。
        throw const EpayGatewayException('一卡通会话已被新会话取代，请重试');
      }
      _boundAccount = auth.currentAccount;

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
          '一卡通网关：统一认证校验遇到网络异常，继续尝试复用现有 Cookie',
        );
      }
      if (_startupAuthChanged) {
        throw const EpayGatewayException('一卡通会话已被新会话取代，请重试');
      }

      await auth.syncCookiesToWebView();
      if (_startupAuthChanged) {
        throw const EpayGatewayException('一卡通会话已被新会话取代，请重试');
      }
    } catch (e) {
      if (e is EpaySessionUnavailableException) rethrow;
      if (e is EpayGatewayException) rethrow;
      AppLogger.instance.network(LogLevel.warn, '一卡通网关：同步统一认证 Cookie 失败: $e');
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
      AppLogger.instance.network(LogLevel.info, '一卡通网关：连同指纹重建凭据');
    }
    final sessionStart = DateTime.now().millisecondsSinceEpoch;

    final ready = Completer<void>();
    HeadlessInAppWebView? webview;
    // onLoadStop 在 webview.run() 之后才可能有事件，处理闭包晚一步挂上。
    void Function(InAppWebViewController controller, WebUri? url)?
    onLoadStopHandler;
    webview = HeadlessInAppWebView(
      initialSettings: headlessWebViewSettings(),
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
      throw const EpayGatewayException('一卡通会话已被新会话取代，请重试');
    }
    _webview = webview;
    try {
      await webview.run();
    } catch (_) {
      await _disposeOwnedWebView(generation);
      throw const EpayGatewayException('一卡通会话启动失败，请重试');
    }
    if (generation != _generation) {
      // 启动期间会话已被取代：这个 WebView 已经没人持有，就地销毁别泄漏。
      unawaited(_safeDispose(webview));
      throw const EpayGatewayException('一卡通会话已被新会话取代，请重试');
    }
    final controller = webview.webViewController;
    if (controller == null) {
      await _disposeOwnedWebView(generation);
      throw const EpayGatewayException('一卡通会话启动失败，请重试');
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
          AppLogger.instance.network(LogLevel.debug, '一卡通网关：凭据到位（新签发=$fresh）');
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
        ready.completeError(const EpayGatewayException('一卡通网关会话初始化超时，请重试'));
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
        throw const EpayGatewayException('一卡通会话已被新会话取代，请重试');
      }
      AppLogger.instance.network(LogLevel.info, '一卡通网关：会话就绪');
    } on EpayGatewayException {
      await _disposeOwnedWebView(generation);
      rethrow;
    } on EpaySessionUnavailableException {
      await _disposeOwnedWebView(generation);
      rethrow;
    } catch (e) {
      await _disposeOwnedWebView(generation);
      throw EpayGatewayException('一卡通会话启动失败: $e');
    } finally {
      tokenPoller.cancel();
      readyTimer.cancel();
    }
  }
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

/// 一次 RPC 操作固定的会话身份。
///
/// `call()` 入队时采样（已登录 → 立即固定；未登录的冷启动调用 → 启动
/// 完成后允许固定一次）。启动、等待 origin、发送、响应处理与错误重试前
/// 都用同一份身份复核；递归重试沿用，不重采样。
class _OperationIdentity {
  _OperationIdentity(this.epoch, this.account) : established = account != null;

  String? account;
  int epoch;
  bool established;
}
