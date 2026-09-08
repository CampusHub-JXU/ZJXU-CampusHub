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
    this.prepareAuthenticatedUrl,
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

  /// Establish gateway and business cookies before selecting a network URL.
  final Future<String> Function()? prepareAuthenticatedUrl;

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
    _authenticated = UnifiedAuthService.instance.isLoggedIn;
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
    if (!mounted || _loginPromptInFlight || _authenticated) return;
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
        setState(() {
          _webViewUrl = url;
          _webViewKey = UniqueKey();
          _authenticated = true;
        });
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
          '资源页再次落到 CAS 登录入口，局部恢复业务 Cookie',
        );
        if (mounted) {
          setState(() {
            _authenticated = false;
            _authResolved = true;
          });
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
    if (isUnifiedAuthLoginEntryUrl(currentUrl)) {
      await _onCasLoginEntry(currentUrl);
      return;
    }

    _resyncing = false;
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

  Widget? _buildAppBarLeading(BuildContext context) {
    if (widget.onHomePressed == null) return null;

    final canPop = Navigator.of(context).canPop();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canPop)
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        IconButton(
          icon: const Icon(Icons.home_outlined),
          tooltip: '返回主页',
          onPressed: widget.onHomePressed,
        ),
      ],
    );
  }

  double? _appBarLeadingWidth(BuildContext context) {
    if (widget.onHomePressed == null) return null;
    return Navigator.of(context).canPop() ? 96 : 48;
  }

  @override
  Widget build(BuildContext context) {
    if (!_authResolved || _preparationFailed) {
      return Scaffold(
        appBar: AppAppBar(
          automaticallyImplyLeading: widget.onHomePressed == null,
          leadingWidth: _appBarLeadingWidth(context),
          leading: _buildAppBarLeading(context),
          title: Text(widget.title),
          actions: widget.appBarActions,
        ),
        body: _preparationFailed
            ? AppErrorView(
                message: '暂时无法连接服务，请切换网络后重试',
                onRetry: _resolveInitialAuthentication,
              )
            : const Center(child: CircularProgressIndicator()),
      );
    }

    if (_authenticated) {
      return WebViewPage(
        key: _webViewKey,
        title: widget.title,
        url: _webViewUrl,
        onLoadStop: _handleLoadStop,
        onNavigationRequest: widget.onNavigationRequest,
        emulateDingTalkEnvironment: widget.emulateDingTalkEnvironment,
        showWebViewBottomBackButton: widget.showWebViewBottomBackButton,
        onHomePressed: widget.onHomePressed,
        appBarActions: widget.appBarActions,
      );
    }

    if (widget.autoPromptLogin) {
      _scheduleLoginPrompt();
    }

    return Scaffold(
      appBar: AppAppBar(
        automaticallyImplyLeading: widget.onHomePressed == null,
        leadingWidth: _appBarLeadingWidth(context),
        leading: _buildAppBarLeading(context),
        title: Text(widget.title),
        actions: widget.appBarActions,
      ),
      body: AuthRequiredView(
        title: '需要统一认证后继续',
        message: widget.loginDescription,
        buttonLabel: '登录统一认证',
        onAction: () => _presentLoginPrompt(force: true),
        icon: Icons.account_balance_outlined,
      ),
    );
  }
}
