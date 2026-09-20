import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/logging/app_logger.dart';
import 'auth_required_view.dart';
import 'app_error_view.dart';
import 'login_shell.dart';
import 'webview_page.dart';
import './app_app_bar.dart';

class UnifiedAuthProtectedWebViewPage extends StatefulWidget {
  const UnifiedAuthProtectedWebViewPage({
    super.key,
    required this.title,
    required this.url,
    this.serviceUrl = UnifiedAuthService.defaultServiceUrl,
    this.loginDescription = '账号为校园一卡通号',
    this.onLoadStop,
    this.onNavigationRequest,
    this.emulateDingTalkEnvironment = true,
    this.showWebViewBottomBackButton = false,
    this.onHomePressed,
    this.appBarActions = const [],
    this.autoPromptLogin = true,
    this.warmUpAsResource = false,
    this.preserveSessionOnAuthBounce = false,
    this.prepareAuthenticatedUrl,
    this.authRequiredTitle = '需要统一认证后继续',
    this.authRequiredButtonLabel = '登录统一认证',
  });

  final String title;
  final String url;
  final String serviceUrl;
  final String loginDescription;
  final WebViewLoadStopCallback? onLoadStop;
  final WebViewNavigationRequestCallback? onNavigationRequest;
  final bool emulateDingTalkEnvironment;
  final bool showWebViewBottomBackButton;
  final VoidCallback? onHomePressed;
  final List<Widget> appBarActions;
  final bool autoPromptLogin;

  /// 目标 URL 本身就是资源而非注册的 CAS 回调（博达 CMS 详情页等）。
  /// 为 true 时认证预热走 [CasAuthBroker.getResource] 逐跳建立业务
  /// Cookie，而不是把资源 URL 当 service 校验——CAS 对任意 URL 都可能
  /// 签发 ticket，但那不代表目标业务的 Cookie 已建立。
  final bool warmUpAsResource;

  /// 业务页再次落到 CAS 登录入口时保留全局统一认证会话。
  ///
  /// 默认 false：其余业务路径维持原行为（第二次 bounce 视为主会话失效，
  /// `markLoggedOut` 后弹原生登录）。图书馆这类已经过
  /// [prepareAuthenticatedUrl] 用注册 service 确认过主会话的页面，之后
  /// WebView 再被 CAS 弹回更可能是业务/网关 Cookie 未生效而非统一认证
  /// 过期；置 true 时不再清全局会话，停在原生 AuthRequiredView 等用户
  /// 显式重试，也不自动弹登录框（避免「弹窗借本地会话自动判成功 → 再
  /// 预热 → 再 bounce」的无界循环）。
  final bool preserveSessionOnAuthBounce;

  /// Establish gateway and business cookies before selecting a network URL.
  final Future<String> Function()? prepareAuthenticatedUrl;

  /// 落到 CAS 登录入口时原生 [AuthRequiredView] 的标题 / 按钮文案。
  ///
  /// 默认保持「统一认证」口径；一卡通（付款码 / 账单）等业务流程可传入
  /// 「一卡通」用词，保持同一业务内的登录提示一致。
  final String authRequiredTitle;
  final String authRequiredButtonLabel;

  @override
  State<UnifiedAuthProtectedWebViewPage> createState() =>
      UnifiedAuthProtectedWebViewPageState();
}

@visibleForTesting
class UnifiedAuthProtectedWebViewPageState
    extends State<UnifiedAuthProtectedWebViewPage> {
  late bool _authenticated;
  late bool _authResolved;
  late String _webViewUrl;
  bool _resyncing = false;
  bool _loginPromptShown = false;
  bool _loginPromptInFlight = false;
  bool _preparationFailed = false;
  Key _webViewKey = UniqueKey();
  CancelToken? _resourceWarmUpToken;
  int _resourceWarmUpGeneration = 0;

  @override
  void initState() {
    super.initState();
    _webViewUrl = widget.url;
    // 目标本身就是 CAS 登录页时不预置已登录：否则 WebView 会把 H5 登录页
    // 直接渲染给用户。登录引导走原生 AuthRequiredView/登录弹窗。
    _authenticated =
        UnifiedAuthService.instance.isLoggedIn &&
        !isWebViewCasLoginEntryUrl(widget.url);
    _authResolved = false;
    unawaited(_resolveInitialAuthentication());
  }

  @override
  void didUpdateWidget(covariant UnifiedAuthProtectedWebViewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url == widget.url &&
        oldWidget.warmUpAsResource == widget.warmUpAsResource) {
      return;
    }

    _webViewUrl = widget.url;
    _webViewKey = UniqueKey();
    if (widget.warmUpAsResource) {
      unawaited(_resolveByResourceWarmUp());
    }
  }

  @override
  void dispose() {
    _cancelResourceWarmUp();
    super.dispose();
  }

  @visibleForTesting
  CancelToken? get debugResourceWarmUpToken => _resourceWarmUpToken;

  @visibleForTesting
  int get debugResourceWarmUpGeneration => _resourceWarmUpGeneration;

  @visibleForTesting
  String get debugWebViewUrl => _webViewUrl;

  @visibleForTesting
  Future<void> debugOnCasLoginEntry(String currentUrl) {
    return _onCasLoginEntry(currentUrl);
  }

  void _cancelResourceWarmUp() {
    final token = _resourceWarmUpToken;
    _resourceWarmUpToken = null;
    _resourceWarmUpGeneration++;
    if (token != null && !token.isCancelled) {
      token.cancel('protected webview disposed or refreshed');
    }
  }

  void _onLoginSuccess() {
    if (!mounted) return;
    if (widget.prepareAuthenticatedUrl != null) {
      unawaited(_resolveInitialAuthentication());
      return;
    }
    if (widget.warmUpAsResource) {
      // 登录只恢复了 CAS 主会话；业务 Cookie 仍需逐跳预热后才能开门。
      setState(() => _authResolved = false);
      unawaited(_resolveByResourceWarmUp());
      return;
    }
    setState(() {
      _authenticated = true;
      _authResolved = true;
    });
  }

  Future<void> _presentLoginPrompt({bool force = false}) async {
    if (!mounted || _loginPromptInFlight) return;
    // 常规路径已登录就不再打扰；force 用于「已登录但目标只剩 CAS 登录页」
    // 的兜底场景（见 build 的 loginUrlBlocked）。
    if (_authenticated && !force) return;
    if (!force && _loginPromptShown) return;

    _loginPromptShown = true;
    _loginPromptInFlight = true;
    final loggedIn = await showUnifiedAuthLoginModal(
      context,
      title: '登录统一认证',
      description: widget.loginDescription,
      // 资源型目标的 URL 不是 CAS service；登录弹窗走注册服务。
      serviceUrl: widget.warmUpAsResource
          ? UnifiedAuthService.defaultServiceUrl
          : widget.serviceUrl,
    );
    _loginPromptInFlight = false;
    if (!mounted || !loggedIn) return;
    _onLoginSuccess();
  }

  void _scheduleLoginPrompt({bool force = false}) {
    if (!force &&
        (_loginPromptShown || _loginPromptInFlight || _authenticated)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_presentLoginPrompt(force: force));
    });
  }

  Future<void> _resolveInitialAuthentication() async {
    final prepare = widget.prepareAuthenticatedUrl;
    if (prepare != null) {
      setState(() {
        _authResolved = false;
        _preparationFailed = false;
      });
      try {
        final url = await prepare();
        if (!mounted) return;
        if (isWebViewCasLoginEntryUrl(url)) {
          // prepare 返回登录页说明业务 Cookie 并未真正建立：不把 CAS H5
          // 交给用户，退回原生登录引导。
          setState(() {
            _authenticated = false;
            _preparationFailed = false;
          });
        } else {
          setState(() {
            _webViewUrl = url;
            _webViewKey = UniqueKey();
            _authenticated = true;
          });
        }
      } on CasAuthExpiredException {
        if (mounted) setState(() => _authenticated = false);
      } catch (error, stackTrace) {
        AppLogger.instance.webview(
          LogLevel.warn,
          '业务页面网络准备失败',
          error: error,
          stackTrace: stackTrace,
        );
        if (mounted) setState(() => _preparationFailed = true);
      } finally {
        if (mounted) setState(() => _authResolved = true);
      }
      return;
    }
    if (widget.warmUpAsResource) {
      await _resolveByResourceWarmUp();
      return;
    }
    try {
      // CasSession.ensure 内部依次完成：恢复本地会话 → 无会话直接判未登录
      // → 有会话则对目标 service 做服务端校验。
      final status = await CasSession.ensure(widget.serviceUrl);
      if (!mounted) return;

      if (status == CasSessionStatus.active) {
        setState(() {
          _authenticated = true;
          _authResolved = true;
        });
        return;
      }

      if (status == CasSessionStatus.inactive) {
        setState(() {
          _authenticated = false;
          _authResolved = true;
        });
        // 明确失效时清除会话（validateSession 内部已标记，这里兜底清理）。
        try {
          await UnifiedAuthService.instance.markLoggedOut();
        } catch (logoutError, logoutStackTrace) {
          AppLogger.instance.auth(
            LogLevel.warn,
            '清理统一认证登录态失败',
            error: logoutError,
            stackTrace: logoutStackTrace,
          );
        }
        return;
      }

      // unknown：网络异常，无法下结论时信任本地会话，让用户继续使用。
      setState(() {
        _authenticated = true;
        _authResolved = true;
      });
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '统一认证登录态校验失败，保持当前状态',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;

      // 其他错误时，信任保存的会话
      setState(() {
        _authenticated = UnifiedAuthService.instance.isLoggedIn;
        _authResolved = true;
      });
    }
  }

  Future<void> _syncResourceCookies(String url) async {
    try {
      // WebView 打开前业务 Cookie 必须已落盘，否则详情页会再次落回 CAS
      // 登录页。有界等待：插件通道异常时不让页面无限卡住。
      await UnifiedAuthService.instance
          .syncCookiesToWebViewForUrl(url)
          .timeout(const Duration(seconds: 10));
    } catch (syncError, syncStack) {
      AppLogger.instance.webview(
        LogLevel.warn,
        '目标 URL Cookie 同步失败，交由 WebView 重同步兜底',
        error: syncError,
        stackTrace: syncStack,
      );
    }
  }

  /// 资源型目标的认证预热：逐跳跟随重定向建立业务 Cookie，收到登录
  /// 表单才判定失效。Cookie 同步失败不推翻认证结论——业务 Cookie 已在
  /// 共享 jar 中，WebView 侧缺失时由 onLoadStop 的重同步兜底。
  Future<void> _resolveByResourceWarmUp() async {
    _cancelResourceWarmUp();
    final generation = _resourceWarmUpGeneration;
    final token = CancelToken();
    _resourceWarmUpToken = token;
    if (mounted) {
      setState(() {
        _authResolved = false;
        _preparationFailed = false;
      });
    }
    try {
      await CasAuthBroker.getResource(widget.url, cancelToken: token);
      if (!mounted || generation != _resourceWarmUpGeneration) return;
      await _syncResourceCookies(widget.url);
      if (!mounted || generation != _resourceWarmUpGeneration) return;
      setState(() {
        _authenticated = true;
        _authResolved = true;
        _webViewUrl = widget.url;
        _webViewKey = UniqueKey();
      });
    } on CasAuthExpiredException {
      if (!mounted || generation != _resourceWarmUpGeneration) return;
      setState(() {
        _authenticated = false;
        _authResolved = true;
      });
    } catch (error, stackTrace) {
      if (token.isCancelled || generation != _resourceWarmUpGeneration) {
        return;
      }
      AppLogger.instance.webview(
        LogLevel.warn,
        '资源预热失败，信任本地会话继续',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      // 网络未知不是登录过期：有本地会话则开门并允许重试，无会话才引导登录。
      setState(() {
        _authenticated = UnifiedAuthService.instance.isLoggedIn;
        _authResolved = true;
        // 网络未知不是登录过期：有本地会话也先给重试，避免把离线当失效。
        _preparationFailed = true;
      });
    }
  }

  Future<void> _onCasLoginEntry(String currentUrl) async {
    AppLogger.instance.webview(
      LogLevel.warn,
      'WebView 跳转到 CAS 登录页，尝试重新同步 Cookie',
    );

    // 资源型目标：目标页/代理重复落到登录页只做局部恢复，
    // 不能仅因 CAS 入口 URL 就全局 markLoggedOut。
    if (widget.warmUpAsResource) {
      if (_resyncing) {
        AppLogger.instance.webview(
          LogLevel.warn,
          '资源页再次落到 CAS 登录入口，停止自动重试并走原生登录引导',
        );
        if (mounted) {
          setState(() {
            _authenticated = false;
            _authResolved = true;
          });
        }
        if (UnifiedAuthService.instance.isLoggedIn) {
          // 本地会话仍在却再次被 CAS 弹回：登录弹窗会被本地会话自动判成功
          // 并再次预热，形成 [预热 → CAS → 弹窗自动成功 → 预热] 的无界循环。
          // 停在原生 AuthRequiredView，等用户显式操作后再重试一次。
          _loginPromptShown = true;
          return;
        }
        await _presentLoginPrompt(force: true);
        return;
      }
      _resyncing = true;
      await _resolveByResourceWarmUp();
      return;
    }

    // 注册服务：如果已在重试中，或 native 已登出，直接标记登出
    if (_resyncing || !UnifiedAuthService.instance.isLoggedIn) {
      if (widget.preserveSessionOnAuthBounce &&
          UnifiedAuthService.instance.isLoggedIn) {
        // 业务 bounce 不推翻已由 prepare 确认的主会话：停在原生认证视图，
        // 等用户显式重试；不自动弹登录框（见字段说明）。
        AppLogger.instance.webview(
          LogLevel.warn,
          '业务页再次落到 CAS 登录入口，保留统一认证会话并等待用户重试',
        );
        if (mounted) {
          setState(() {
            _authenticated = false;
            _authResolved = true;
          });
        }
        _loginPromptShown = true;
        return;
      }
      AppLogger.instance.webview(LogLevel.warn, 'Cookie 重同步失败，标记登出');
      await UnifiedAuthService.instance.markLoggedOut();
      if (mounted) {
        setState(() {
          _authenticated = false;
          _authResolved = true;
        });
      }
      await _presentLoginPrompt(force: true);
      return;
    }

    // 第一次：重新同步 cookie 后重新加载
    _resyncing = true;
    if (widget.prepareAuthenticatedUrl != null) {
      await _resolveInitialAuthentication();
      return;
    }
    await UnifiedAuthService.instance.syncCookiesToWebView();
    if (!mounted) return;

    final retryUrl =
        extractUnifiedAuthServiceUrl(currentUrl) ??
        (currentUrl.trim().isNotEmpty ? currentUrl : widget.url);
    if (isWebViewCasLoginEntryUrl(retryUrl)) {
      // 重试地址仍是 CAS 登录页（WebVPN 代理形态，或缺少 service 参数）：
      // 不把 H5 登录页挂回 WebView，恢复业务入口并走应用内登录引导。
      AppLogger.instance.webview(LogLevel.warn, 'CAS 登录页无法还原业务地址，改为应用内登录引导');
      setState(() {
        _authenticated = false;
        _authResolved = true;
        _webViewUrl = widget.url;
        _webViewKey = UniqueKey();
      });
      await _presentLoginPrompt(force: true);
      return;
    }
    AppLogger.instance.webview(
      LogLevel.debug,
      'Cookie 重同步完成，重新加载 WebView: $retryUrl',
    );
    // 通过快捷方式快速进入时，这里的旧 controller 偶发会失效。
    // 直接重建 WebView 比继续调用旧实例更稳定。
    setState(() {
      _webViewUrl = retryUrl;
      _webViewKey = UniqueKey();
    });
  }

  Future<void> _handleLoadStop(
    InAppWebViewController controller,
    String currentUrl,
  ) async {
    if (isWebViewCasLoginEntryUrl(currentUrl)) {
      await _onCasLoginEntry(currentUrl);
      return;
    }

    // SSO 中间跳转页（oauth/forward、CAS oauth2、钉钉授权页）落地不能重置
    // bounce 计数，否则「一次自动重试」被无限重新武装。
    if (!isSsoIntermediateLandingUrl(currentUrl)) {
      _resyncing = false;
    }
    final callback = widget.onLoadStop;
    if (callback != null) {
      try {
        await callback(controller, currentUrl);
      } on MissingPluginException {
        // WebView 平台通道尚未就绪，跳过回调。
      } catch (error, stackTrace) {
        AppLogger.instance.webview(
          LogLevel.warn,
          'WebView load-stop 回调失败：$currentUrl',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  /// 导航阶段拦截 CAS 登录页：`shouldOverrideUrlLoading` 早于页面渲染，
  /// 把它交给 [_onCasLoginEntry] 做局部恢复/原生登录引导，避免 H5 登录页
  /// 在 WebView 中闪现甚至停留。
  Future<NavigationActionPolicy?> _handleNavigationRequest(
    InAppWebViewController controller,
    Uri uri,
  ) async {
    final target = uri.toString();
    if (isWebViewCasLoginEntryUrl(target)) {
      unawaited(_onCasLoginEntry(target));
      return NavigationActionPolicy.CANCEL;
    }

    final callback = widget.onNavigationRequest;
    if (callback == null) return null;
    return callback(controller, uri);
  }

  @override
  Widget build(BuildContext context) {
    if (!_authResolved) {
      return _buildScaffold(const Center(child: CircularProgressIndicator()));
    }

    // prepare/预热可能把 CAS 登录页当成可加载目标；命中时绝不挂 WebView。
    final loginUrlBlocked =
        _authenticated && isWebViewCasLoginEntryUrl(_webViewUrl);

    if (_authenticated && !loginUrlBlocked) {
      if (_preparationFailed) {
        return _buildScaffold(
          AppErrorView(
            message: '暂时无法连接服务，请切换网络后重试',
            onRetry: _resolveInitialAuthentication,
          ),
        );
      }
      return WebViewPage(
        key: _webViewKey,
        title: widget.title,
        url: _webViewUrl,
        onLoadStop: _handleLoadStop,
        onNavigationRequest: _handleNavigationRequest,
        emulateDingTalkEnvironment: widget.emulateDingTalkEnvironment,
        showWebViewBottomBackButton: widget.showWebViewBottomBackButton,
        onHomePressed: widget.onHomePressed,
        appBarActions: widget.appBarActions,
      );
    }

    if (widget.autoPromptLogin) {
      // loginUrlBlocked 下 _authenticated 仍为 true，需 force 才能弹出；
      // 已弹过一次就不再强制，避免每次重建都重新弹出。
      _scheduleLoginPrompt(force: loginUrlBlocked && !_loginPromptShown);
    }

    return _buildScaffold(
      AuthRequiredView(
        title: widget.authRequiredTitle,
        message: widget.loginDescription,
        buttonLabel: widget.authRequiredButtonLabel,
        onAction: () => _presentLoginPrompt(force: true),
        icon: Icons.account_balance_outlined,
      ),
    );
  }

  Widget _buildScaffold(Widget body) {
    return Scaffold(
      appBar: AppAppBar(
        automaticallyImplyLeading: true,
        title: Text(widget.title),
        actions: widget.appBarActions,
      ),
      body: body,
    );
  }
}
