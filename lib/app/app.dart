import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:material_ui/material_ui.dart';

import 'package:go_router/go_router.dart';

import '../core/logging/app_logger.dart';
import '../core/network/proxy_mode.dart';
import '../core/theme/app_preferences_controller.dart';
import '../features/welcome/welcome_page.dart';
import 'app_messenger.dart';
import 'routes.dart';
import '../core/theme/text_scale_controller.dart';
import 'theme.dart';

typedef SystemProxyDetector = Future<String?> Function({String testUrl});
typedef ConnectivityChecker = Future<List<ConnectivityResult>> Function();

class JXUCampusHubApp extends StatefulWidget {
  JXUCampusHubApp({
    super.key,
    RouterConfig<Object>? routerConfig,
    SystemProxyDetector? systemProxyDetector,
    ConnectivityChecker? connectivityChecker,
    this.startupProxyWarningDuration = const Duration(seconds: 4),
    this.onStartupProxyWarningShown,
    Future<void> Function(NavigatorState rootNavigator)? welcomeGate,
  }) : routerConfig = routerConfig ?? appRouter,
       systemProxyDetector = systemProxyDetector ?? detectSystemProxy,
       connectivityChecker = connectivityChecker ?? _defaultConnectivityChecker,
       welcomeGate = welcomeGate ?? _defaultWelcomeGate;

  final RouterConfig<Object> routerConfig;
  final SystemProxyDetector systemProxyDetector;
  final ConnectivityChecker connectivityChecker;
  final Duration startupProxyWarningDuration;
  final VoidCallback? onStartupProxyWarningShown;

  /// 首启欢迎向导闸门；测试注入以禁用（避免遮罩挡住被测页面）。
  final Future<void> Function(NavigatorState rootNavigator) welcomeGate;

  static Future<void> _defaultWelcomeGate(NavigatorState rootNavigator) async {
    if (!await WelcomeFlow.shouldShow()) return;
    if (!rootNavigator.mounted) return;
    await WelcomeFlow.showOnNavigator(
      rootNavigator,
      onLoginShortcut: (_) => appRouter.goNamed('my'),
      onNotificationsShortcut: (_) => appRouter.pushNamed('desktop-background'),
      onCalendarShortcut: (_) => appRouter.pushNamed('settings'),
      onAiShortcut: (_) => unawaited(appRouter.pushNamed('ai-settings')),
    );
  }

  static Future<List<ConnectivityResult>> _defaultConnectivityChecker() {
    return Connectivity().checkConnectivity();
  }

  @override
  State<JXUCampusHubApp> createState() => _JXUCampusHubAppState();
}

class _JXUCampusHubAppState extends State<JXUCampusHubApp> {
  static const _startupProxyWarningMessage =
      '检测到系统代理或 VPN/TUN；若校务功能异常，请排除本 App 或将 *.zjxu.edu.cn 设为 DIRECT';

  final _preferencesController = AppPreferencesController.instance;
  bool _shouldShowStartupProxyWarning = false;
  bool _startupProxyWarningShown = false;
  bool _startupProxyWarningScheduled = false;
  bool _welcomeGateRequested = false;

  @override
  void initState() {
    super.initState();
    _preferencesController.addListener(_onPreferencesChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkStartupGuards());
      unawaited(_requestWelcomeGate());
    });
  }

  @override
  void dispose() {
    _preferencesController.removeListener(_onPreferencesChanged);
    super.dispose();
  }

  void _onPreferencesChanged() => setState(() {});

  /// 首启欢迎向导：第一帧之后检查 `welcome_completed` 标记，未完成的以
  /// 全屏路由盖在 shell 之上。延迟一帧重试——注入的 router 首帧时
  /// navigatorKey 可能还没就位（如路由解析尚未完成）。
  int _welcomeGateRetries = 0;

  Future<void> _requestWelcomeGate() async {
    if (_welcomeGateRequested) return;
    _welcomeGateRequested = true;

    final delegate = widget.routerConfig.routerDelegate;
    final rootNavigator = delegate is GoRouterDelegate
        ? delegate.navigatorKey.currentState
        : null;
    if (rootNavigator == null) {
      _welcomeGateRequested = false;
      if (_welcomeGateRetries++ < 5 && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(_requestWelcomeGate());
        });
      }
      return;
    }
    if (!mounted) return;
    await widget.welcomeGate(rootNavigator);
  }

  Future<void> _checkStartupGuards() async {
    if (_shouldShowStartupProxyWarning || _startupProxyWarningShown) return;

    var shouldShowWarning = false;
    final proxyRule = await widget.systemProxyDetector();
    if (proxyRule != null) {
      AppLogger.instance.network(LogLevel.warn, '检测到系统 HTTP 代理: $proxyRule');
      shouldShowWarning = true;
    }

    final connectivityResults = await widget.connectivityChecker();
    final hasVpn = connectivityResults.contains(ConnectivityResult.vpn);
    if (hasVpn) {
      AppLogger.instance.network(
        LogLevel.warn,
        '检测到 VPN 网络环境: $connectivityResults',
      );
      shouldShowWarning = true;
    }

    if (!mounted || !shouldShowWarning) return;

    setState(() {
      _shouldShowStartupProxyWarning = true;
    });
    _scheduleStartupProxyWarning();
  }

  void _scheduleStartupProxyWarning() {
    if (!_shouldShowStartupProxyWarning ||
        _startupProxyWarningShown ||
        _startupProxyWarningScheduled) {
      return;
    }

    _startupProxyWarningScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startupProxyWarningScheduled = false;
      if (!mounted ||
          !_shouldShowStartupProxyWarning ||
          _startupProxyWarningShown) {
        return;
      }

      final messenger = rootScaffoldMessengerKey.currentState;
      if (messenger == null) {
        _scheduleStartupProxyWarning();
        return;
      }

      messenger.showSnackBar(
        SnackBar(
          content: const Text(_startupProxyWarningMessage),
          duration: widget.startupProxyWarningDuration,
          showCloseIcon: false,
        ),
      );
      widget.onStartupProxyWarningShown?.call();
      setState(() {
        _startupProxyWarningShown = true;
        _shouldShowStartupProxyWarning = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_shouldShowStartupProxyWarning) {
      _scheduleStartupProxyWarning();
    }
    final prefs = _preferencesController.state;
    return MaterialApp.router(
      title: '嘉兴大学',
      theme: AppTheme.lightThemeFor(prefs.seedColor),
      darkTheme: AppTheme.darkThemeFor(
        prefs.seedColor,
        pureBlack: prefs.pureBlack,
      ),
      themeMode: prefs.materialThemeMode,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      // Disable the built-in AnimatedTheme transition — it forces every
      // Theme.of(context) dependent to rebuild on every animation frame,
      // causing visible jank during light/dark toggle.
      themeAnimationDuration: Duration.zero,
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        // Relative to the ambient system textScaler: AppTextScaleScope
        // multiplies the system scale by the user factor and passes the
        // system scale through untouched at the default factor (0.9).
        // ignore: deprecated_member_use -- 包方标 deprecated 的临时迁移桥接，过渡期内保留
        return MaterialUiCompatibilityBridge(
          child: AppTextScaleScope(scaleFactor: prefs.textScale, child: child),
        );
      },
      routerConfig: widget.routerConfig,
      debugShowCheckedModeBanner: false,
    );
  }
}
