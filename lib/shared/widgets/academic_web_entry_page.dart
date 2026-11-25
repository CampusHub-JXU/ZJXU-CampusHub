import 'dart:async';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/auth/academic_web_entry_preparer.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/maintenance_window.dart';
import '../../core/network/webview_direct_route.dart';
import 'app_error_view.dart';
import 'app_feedback.dart';
import 'auth_required_view.dart';
import 'login_shell.dart';
import 'webview_page.dart';
import './app_app_bar.dart';

/// 教务 H5 入口页面的 UI 状态。
enum AcademicEntryPageStatus {
  /// 正在 headless 准备受信入口。
  preparing,

  /// 准备就绪，WebView 已挂载。
  ready,

  /// 需要统一认证（WebVPN 网关）会话。
  needsUnifiedLogin,

  /// 需要教务（正方）会话。
  needsAcademicLogin,

  /// 暂不可用：可手动重试。
  unavailable,

  /// 被拒绝：不可重试。
  denied,
}

/// 受信教务 H5 入口页面：用 [AcademicWebEntryPreparer] 做 headless 初始选路，
/// 命中「已证实主框架连接失败」时最多自动切换一次连接方式。
///
/// 安全不变量（与 [AcademicWebEntryPreparer] 对齐，且更严格）：
/// - 绝不修改全局 [ZhengfangAuth.mode]、绝不登出 / `markLoggedOut` /
///   `validateSession` 清会话、绝不清全局 CAS CookieJar、绝不跳过 TLS。
/// - 兜底只对**本次入口**的 GET 主框架连接失败生效，绝不重放 POST 或任意
///   失败 URL；每页面生命周期最多自动兜底一次，仅由用户显式重试重新武装。
/// - 兜底前后绑定两域身份（账号 + revision），任何 await 后复核；身份变化
///   一律静默丢弃，不驱动 UI。
class AcademicWebEntryPage extends StatefulWidget {
  const AcademicWebEntryPage({
    super.key,
    required this.title,
    this.jsdm = 'xs',
    this.loginDescription = '账号为学号',
    this.onHomePressed,
    this.autoPromptLogin = true,
    this.preparer,
    this.unifiedLoginPrompt,
    this.academicLoginPrompt,
    this.webViewDirectRoute,
  });

  final String title;

  /// 受信入口的 `jsdm`（仅 `xs` / `query`）。
  final String jsdm;
  final String loginDescription;
  final VoidCallback? onHomePressed;

  /// 需要登录时是否自动弹出原生登录弹窗（只自动弹一次）。
  final bool autoPromptLogin;

  /// 测试注入点：替换 headless 准备器；生产为 [AcademicWebEntryPreparer.instance]。
  @visibleForTesting
  final AcademicWebEntryPreparer? preparer;

  /// 测试注入点：替换统一认证登录弹窗；生产为 [showUnifiedAuthLoginModal]。
  @visibleForTesting
  final Future<bool> Function(BuildContext context)? unifiedLoginPrompt;

  /// 测试注入点：替换教务登录弹窗；生产为 [showAcademicSystemLoginModal]。
  @visibleForTesting
  final Future<bool> Function(BuildContext context)? academicLoginPrompt;

  /// 测试注入点：替换 WebView 直连覆盖；生产为 [WebViewDirectRoute.instance]。
  @visibleForTesting
  final WebViewDirectRoute? webViewDirectRoute;

  @override
  State<AcademicWebEntryPage> createState() => AcademicWebEntryPageState();
}

@visibleForTesting
class AcademicWebEntryPageState extends State<AcademicWebEntryPage> {
  /// 单次兜底准备的总预算。
  static const Duration fallbackBudget = Duration(seconds: 20);

  AcademicWebEntryPreparer get _preparer =>
      widget.preparer ?? AcademicWebEntryPreparer.instance;

  AcademicEntryPageStatus _status = AcademicEntryPageStatus.preparing;
  String _errorMessage = '';
  bool _errorRetryable = false;

  String? _readyUrl;
  Map<String, String> _readyHeaders = const <String, String>{};
  ZhengfangMode _readyMode = ZhengfangMode.direct;
  Key _webViewKey = UniqueKey();

  /// 准备 / WebView 载入代际：每次 `_prepare` 与每次 `_activateEntry` 推进。
  int _generation = 0;
  CancelToken? _prepareToken;
  CancelToken? _fallbackToken;

  bool _fallbackUsed = false;
  bool _fallbackInFlight = false;

  /// 当前入口是否被本页主动作废（重试 / 重新准备 / 重建 WebView）。
  bool _entryCancelled = false;

  /// 当前入口是否已成功 load stop（进入过页面）。
  bool _entryLoadSettled = false;

  /// 当前入口之后是否发生过交互式导航（非入口 URL）。
  bool _entryNavigationObserved = false;

  bool _loginPromptInFlight = false;
  bool _unifiedPromptAutoShown = false;
  bool _academicPromptAutoShown = false;

  /// 最近一次准备使用的选路；登录成功后按同一选路重试。
  bool _lastForceWebVpn = false;
  bool _retryDirectAfterLogin = false;

  /// 页面生命周期内持有的「WebView 直连」租约（见 [WebViewDirectRoute]）。
  ///
  /// Dart 探测走直连而 WebView 默认跟随系统代理时，教务会话（疑似绑定出口 IP）
  /// 会在 H5 内被要求重新登录；因此首次准备 / Cookie 同步 / 载入之前先 await
  /// 租约，页面销毁时释放。Dart 本身已走代理时不持有租约（路由本就一致）。
  Future<WebViewDirectLease?>? _directLeaseFuture;
  bool _directRouteHintPending = false;
  bool _directRouteHintShown = false;

  WebViewDirectRoute get _directRoute =>
      widget.webViewDirectRoute ?? WebViewDirectRoute.instance;

  @override
  void initState() {
    super.initState();
    _directLeaseFuture = _acquireDirectRoute();
    unawaited(_prepare(forceWebVpn: false));
  }

  Future<WebViewDirectLease?> _acquireDirectRoute() async {
    try {
      final lease = await _directRoute.acquireIfDartDirect();
      if (lease != null && !lease.applied) {
        // 无法绕过系统代理：不阻塞，入口就绪后给一次轻提示。
        _directRouteHintPending = true;
      }
      return lease;
    } catch (error, stackTrace) {
      AppLogger.instance.webview(
        LogLevel.warn,
        '教务 H5 入口取得 WebView 直连租约失败',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  void _releaseDirectRoute() {
    final future = _directLeaseFuture;
    _directLeaseFuture = null;
    if (future == null) return;
    unawaited(
      future.then<void>((lease) => lease?.release(), onError: (Object _) {}),
    );
  }

  void _maybeShowDirectRouteHint() {
    if (!_directRouteHintPending || _directRouteHintShown) return;
    _directRouteHintShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppFeedback.toast(
        context,
        '无法让网页绕过系统代理，若已开启代理可能需要在网页内重新登录；'
        '可关闭代理或将 jwzx.zjxu.edu.cn 设为直连',
        dedupeKey: 'academic-web-entry-proxy-hint',
        duration: const Duration(seconds: 6),
      );
    });
  }

  @override
  void deactivate() {
    _cancelInflight('academic web entry page deactivated');
    super.deactivate();
  }

  @override
  void dispose() {
    _cancelInflight('academic web entry page disposed');
    _releaseDirectRoute();
    super.dispose();
  }

  void _cancelInflight(String reason) {
    final prepare = _prepareToken;
    _prepareToken = null;
    if (prepare != null && !prepare.isCancelled) {
      prepare.cancel(reason);
    }
    final fallback = _fallbackToken;
    _fallbackToken = null;
    if (fallback != null && !fallback.isCancelled) {
      fallback.cancel(reason);
    }
  }

  Future<void> _prepare({
    required bool forceWebVpn,
    bool forceDirect = false,
  }) async {
    final generation = ++_generation;
    final previous = _prepareToken;
    if (previous != null && !previous.isCancelled) {
      previous.cancel('superseded by a new academic entry preparation');
    }
    final token = CancelToken();
    _prepareToken = token;
    _lastForceWebVpn = forceWebVpn;
    _retryDirectAfterLogin = forceDirect;
    if (_status == AcademicEntryPageStatus.ready) {
      _entryCancelled = true;
    }

    if (mounted) {
      setState(() {
        _status = AcademicEntryPageStatus.preparing;
        _errorMessage = '';
        _errorRetryable = false;
      });
    }

    // WebView 直连覆盖必须先于 Cookie 同步 / 首次载入生效。
    await _directLeaseFuture;
    if (!mounted || generation != _generation || token.isCancelled) return;

    AcademicWebEntryResult result;
    try {
      result = await _preparer.prepare(
        jsdm: widget.jsdm,
        forceWebVpn: forceWebVpn,
        forceDirect: forceDirect,
        allowReverseFallback: !_fallbackUsed,
        cancelToken: token,
      );
    } catch (error, stackTrace) {
      AppLogger.instance.webview(
        LogLevel.warn,
        '教务 H5 入口准备异常',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted || generation != _generation || token.isCancelled) return;
      _applyResult(const AcademicWebEntryUnavailable('教务入口准备失败'));
      return;
    }
    if (!mounted || generation != _generation || token.isCancelled) return;
    _applyResult(result);
  }

  void _applyResult(AcademicWebEntryResult result) {
    switch (result) {
      case final AcademicWebEntryReady ready:
        _activateEntry(ready);
      case AcademicWebEntryNeedsUnifiedLogin(:final fallbackMode):
        _rememberFallback(fallbackMode);
        _showUnifiedRequired(forceWebVpn: _lastForceWebVpn);
      case AcademicWebEntryNeedsAcademicLogin(:final fallbackMode):
        _rememberFallback(fallbackMode);
        _showAcademicRequired(forceWebVpn: _lastForceWebVpn);
      case AcademicWebEntryUnavailable(:final message):
        _showError(message, retryable: true);
      case AcademicWebEntryDenied(:final message):
        _showError(message, retryable: false);
      case AcademicWebEntryStale():
        // 身份变化 / 被取消 / 超预算：静默丢弃，UI 归属其他流程。
        return;
    }
  }

  void _rememberFallback(ZhengfangMode? mode) {
    if (mode == null) return;
    _fallbackUsed = true;
    _lastForceWebVpn = mode == ZhengfangMode.webVpn;
    _retryDirectAfterLogin = mode == ZhengfangMode.direct;
  }

  void _activateEntry(AcademicWebEntryReady ready) {
    _generation++;
    _readyUrl = ready.url;
    _readyHeaders = ready.headers;
    _readyMode = ready.selectedMode;
    _fallbackUsed |= ready.didFallback;
    _entryCancelled = false;
    _entryLoadSettled = false;
    _entryNavigationObserved = false;
    _webViewKey = UniqueKey();
    if (!mounted) return;
    setState(() {
      _status = AcademicEntryPageStatus.ready;
      _errorMessage = '';
      _errorRetryable = false;
    });
    _maybeShowDirectRouteHint();
  }

  void _showError(String message, {required bool retryable}) {
    if (!mounted) return;
    setState(() {
      _status = retryable
          ? AcademicEntryPageStatus.unavailable
          : AcademicEntryPageStatus.denied;
      _errorMessage = message;
      _errorRetryable = retryable;
    });
  }

  void _showUnifiedRequired({required bool forceWebVpn}) {
    if (!mounted) return;
    setState(() => _status = AcademicEntryPageStatus.needsUnifiedLogin);
    if (!widget.autoPromptLogin || _unifiedPromptAutoShown) return;
    _unifiedPromptAutoShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_presentUnifiedLogin(forceWebVpn: forceWebVpn));
    });
  }

  void _showAcademicRequired({required bool forceWebVpn}) {
    if (!mounted) return;
    setState(() => _status = AcademicEntryPageStatus.needsAcademicLogin);
    if (!widget.autoPromptLogin || _academicPromptAutoShown) return;
    _academicPromptAutoShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_presentAcademicLogin(forceWebVpn: forceWebVpn));
    });
  }

  Future<void> _presentUnifiedLogin({required bool forceWebVpn}) async {
    if (!mounted || _loginPromptInFlight) return;
    _loginPromptInFlight = true;
    bool loggedIn = false;
    try {
      final prompt = widget.unifiedLoginPrompt;
      loggedIn = prompt != null
          ? await prompt(context)
          : await showUnifiedAuthLoginModal(
              context,
              title: '登录统一认证',
              description: widget.loginDescription,
            );
    } catch (error, stackTrace) {
      AppLogger.instance.webview(
        LogLevel.warn,
        '统一认证登录弹窗打开失败',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _loginPromptInFlight = false;
    }
    if (!mounted || !loggedIn) return;
    await _prepare(
      forceWebVpn: forceWebVpn,
      forceDirect: _retryDirectAfterLogin,
    );
  }

  Future<void> _presentAcademicLogin({required bool forceWebVpn}) async {
    if (!mounted || _loginPromptInFlight) return;
    _loginPromptInFlight = true;
    bool loggedIn = false;
    try {
      final prompt = widget.academicLoginPrompt;
      loggedIn = prompt != null
          ? await prompt(context)
          : await showAcademicSystemLoginModal(context);
    } catch (error, stackTrace) {
      AppLogger.instance.webview(
        LogLevel.warn,
        '教务登录弹窗打开失败',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _loginPromptInFlight = false;
    }
    if (!mounted || !loggedIn) return;
    await _prepare(
      forceWebVpn: forceWebVpn,
      forceDirect: _retryDirectAfterLogin,
    );
  }

  void _onManualUnifiedLogin() {
    unawaited(_presentUnifiedLogin(forceWebVpn: _lastForceWebVpn));
  }

  void _onManualAcademicLogin() {
    unawaited(_presentAcademicLogin(forceWebVpn: _lastForceWebVpn));
  }

  /// 用户显式重试：重新武装一次性兜底，再按默认选路重新准备。
  void _onManualRetry() {
    _fallbackUsed = false;
    _fallbackInFlight = false;
    unawaited(_prepare(forceWebVpn: false));
  }

  Future<void> _handleLoadStop(
    InAppWebViewController controller,
    String currentUrl,
  ) async {
    if (currentUrl == _readyUrl) {
      _entryLoadSettled = true;
    } else {
      _entryNavigationObserved = true;
    }
  }

  Future<NavigationActionPolicy?> _handleNavigationRequest(
    InAppWebViewController controller,
    Uri uri,
  ) async {
    // 入口之后任何到别的 URL 的导航都视为交互式导航：一旦发生，本次入口不再
    // 自动兜底（安全性优先，宁可让默认错误页站着）。
    if (uri.toString() != _readyUrl) {
      _entryNavigationObserved = true;
    }
    return null;
  }

  bool _isCertOrBadUrlType(WebResourceErrorType type) {
    return type == WebResourceErrorType.FAILED_SSL_HANDSHAKE ||
        type == WebResourceErrorType.SECURE_CONNECTION_FAILED ||
        type == WebResourceErrorType.SERVER_CERTIFICATE_HAS_BAD_DATE ||
        type == WebResourceErrorType.SERVER_CERTIFICATE_UNTRUSTED ||
        type == WebResourceErrorType.SERVER_CERTIFICATE_HAS_UNKNOWN_ROOT ||
        type == WebResourceErrorType.SERVER_CERTIFICATE_NOT_YET_VALID ||
        type == WebResourceErrorType.CLIENT_CERTIFICATE_REJECTED ||
        type == WebResourceErrorType.CLIENT_CERTIFICATE_REQUIRED ||
        type ==
            WebResourceErrorType
                .APP_TRANSPORT_SECURITY_REQUIRES_SECURE_CONNECTION ||
        type == WebResourceErrorType.BAD_URL ||
        type == WebResourceErrorType.UNSUPPORTED_SCHEME;
  }

  bool _isEligibleFallback(WebViewMainFrameLoadFailure failure) {
    if (failure.isForMainFrame != true) return false;
    final method = failure.method;
    if (method == null || method.toUpperCase() != 'GET') return false;
    if (failure.url != _readyUrl) return false;
    if (_entryCancelled) return false;
    if (_entryLoadSettled) return false;
    if (_entryNavigationObserved) return false;
    if (_isCertOrBadUrlType(failure.type)) return false;
    return true;
  }

  Future<bool> _onMainFrameFailure(
    WebViewMainFrameLoadFailure failure,
    int generation,
  ) async {
    if (_status != AcademicEntryPageStatus.ready) return false;
    if (generation != _generation) return false;
    if (_fallbackUsed || _fallbackInFlight) return false;
    if (!_isEligibleFallback(failure)) return false;
    await _runFallback(generation);
    return true;
  }

  Future<void> _runFallback(int generation) async {
    _fallbackUsed = true;
    _fallbackInFlight = true;
    final useWebVpn = _readyMode == ZhengfangMode.direct;
    _lastForceWebVpn = useWebVpn;
    _retryDirectAfterLogin = !useWebVpn;
    final token = CancelToken();
    _fallbackToken = token;

    final zfRevision = ZhengfangAuth.instance.sessionRevision;
    final zfAccount = ZhengfangAuth.instance.currentStudentId?.trim() ?? '';
    final uaRevision = UnifiedAuthService.instance.sessionRevision;
    final uaAccount = UnifiedAuthService.instance.currentAccount?.trim() ?? '';

    bool identityCurrent() {
      return ZhengfangAuth.instance.sessionRevision == zfRevision &&
          (ZhengfangAuth.instance.currentStudentId?.trim() ?? '') ==
              zfAccount &&
          UnifiedAuthService.instance.sessionRevision == uaRevision &&
          (UnifiedAuthService.instance.currentAccount?.trim() ?? '') ==
              uaAccount;
    }

    bool stillCurrent() =>
        mounted &&
        generation == _generation &&
        !token.isCancelled &&
        identityCurrent();

    AcademicWebEntryResult result;
    try {
      result = await _preparer.prepare(
        jsdm: widget.jsdm,
        forceWebVpn: useWebVpn,
        forceDirect: !useWebVpn,
        allowReverseFallback: false,
        cancelToken: token,
        totalBudget: fallbackBudget,
      );
    } catch (error, stackTrace) {
      AppLogger.instance.webview(
        LogLevel.warn,
        '教务 H5 入口切换连接失败',
        error: error,
        stackTrace: stackTrace,
      );
      if (!stillCurrent()) return;
      _applyResult(const AcademicWebEntryUnavailable('教务入口切换连接失败'));
      return;
    } finally {
      if (identical(_fallbackToken, token)) _fallbackToken = null;
      _fallbackInFlight = false;
    }

    if (!stillCurrent()) return;
    _applyResult(result);
  }

  Widget _scaffold(Widget body) {
    return Scaffold(
      appBar: AppAppBar(
        automaticallyImplyLeading: true,
        title: Text(widget.title),
      ),
      body: body,
    );
  }

  @override
  Widget build(BuildContext context) {
    switch (_status) {
      case AcademicEntryPageStatus.preparing:
        return _scaffold(const Center(child: CircularProgressIndicator()));
      case AcademicEntryPageStatus.ready:
        final generation = _generation;
        return WebViewPage(
          key: _webViewKey,
          title: widget.title,
          url: _readyUrl!,
          initialHeaders: _readyHeaders,
          onLoadStop: _handleLoadStop,
          onNavigationRequest: _handleNavigationRequest,
          onMainFrameLoadFailure: (failure) =>
              _onMainFrameFailure(failure, generation),
          onHomePressed: widget.onHomePressed,
        );
      case AcademicEntryPageStatus.needsUnifiedLogin:
        return _scaffold(
          AuthRequiredView(
            title: '需要统一认证后继续',
            message: widget.loginDescription,
            buttonLabel: '登录统一认证',
            onAction: _onManualUnifiedLogin,
            icon: Icons.account_balance_outlined,
          ),
        );
      case AcademicEntryPageStatus.needsAcademicLogin:
        return _scaffold(
          AuthRequiredView(
            title: '需要登录后继续',
            message: widget.loginDescription,
            buttonLabel: '登录教务系统',
            onAction: _onManualAcademicLogin,
            icon: Icons.school_outlined,
          ),
        );
      case AcademicEntryPageStatus.unavailable:
        return _scaffold(
          AppErrorView(
            message: appendMaintenanceHint(
              _errorMessage.isEmpty ? '暂时无法连接教务系统，请稍后重试' : _errorMessage,
            ),
            onRetry: _onManualRetry,
          ),
        );
      case AcademicEntryPageStatus.denied:
        return _scaffold(
          AppErrorView(title: '无法打开教务系统', message: _errorMessage),
        );
    }
  }

  // ── 仅测试使用 ──────────────────────────────────────────────────────────

  @visibleForTesting
  AcademicEntryPageStatus get debugStatus => _status;

  @visibleForTesting
  String? get debugReadyUrl => _readyUrl;

  @visibleForTesting
  Map<String, String> get debugReadyHeaders => _readyHeaders;

  @visibleForTesting
  ZhengfangMode get debugReadyMode => _readyMode;

  @visibleForTesting
  bool get debugFallbackUsed => _fallbackUsed;

  @visibleForTesting
  bool get debugErrorRetryable => _errorRetryable;

  @visibleForTesting
  int get debugGeneration => _generation;

  @visibleForTesting
  CancelToken? get debugPrepareToken => _prepareToken;

  @visibleForTesting
  CancelToken? get debugFallbackToken => _fallbackToken;

  @visibleForTesting
  void debugMarkEntryCancelled() => _entryCancelled = true;

  @visibleForTesting
  void debugMarkEntryLoadSettled() => _entryLoadSettled = true;

  @visibleForTesting
  Future<bool> debugHandleMainFrameFailure(
    WebViewMainFrameLoadFailure failure, {
    int? generation,
  }) {
    return _onMainFrameFailure(failure, generation ?? _generation);
  }
}
