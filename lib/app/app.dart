import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../core/logging/app_logger.dart';
import '../core/network/proxy_mode.dart';
import 'routes.dart';
import 'text_scale_controller.dart';
import 'theme.dart';
import 'theme_mode_controller.dart';

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
  }) : routerConfig = routerConfig ?? appRouter,
       systemProxyDetector = systemProxyDetector ?? detectSystemProxy,
       connectivityChecker = connectivityChecker ?? _defaultConnectivityChecker;

  final RouterConfig<Object> routerConfig;
  final SystemProxyDetector systemProxyDetector;
  final ConnectivityChecker connectivityChecker;
  final Duration startupProxyWarningDuration;
  final VoidCallback? onStartupProxyWarningShown;

  static Future<List<ConnectivityResult>> _defaultConnectivityChecker() {
    return Connectivity().checkConnectivity();
  }

  @override
  State<JXUCampusHubApp> createState() => _JXUCampusHubAppState();
}

class _JXUCampusHubAppState extends State<JXUCampusHubApp> {
  static const _startupProxyWarningMessage = '检测到系统代理或 VPN，部分校务功能可能异常';

  final _themeModeController = ThemeModeController.instance;
  final _textScaleController = TextScaleController.instance;
  final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  bool _shouldShowStartupProxyWarning = false;
  bool _startupProxyWarningShown = false;
  bool _startupProxyWarningScheduled = false;

  @override
  void initState() {
    super.initState();
    _themeModeController.themeMode.addListener(_onAppAppearanceChanged);
    _textScaleController.textScaleFactor.addListener(_onAppAppearanceChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkStartupGuards());
    });
  }

  @override
  void dispose() {
    _themeModeController.themeMode.removeListener(_onAppAppearanceChanged);
    _textScaleController.textScaleFactor.removeListener(
      _onAppAppearanceChanged,
    );
    super.dispose();
  }

  void _onAppAppearanceChanged() => setState(() {});

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

      final messenger = _scaffoldMessengerKey.currentState;
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
    return MaterialApp.router(
      title: '嘉兴大学-智能中台',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: _themeModeController.themeMode.value,
      scaffoldMessengerKey: _scaffoldMessengerKey,
      // Disable the built-in AnimatedTheme transition — it forces every
      // Theme.of(context) dependent to rebuild on every animation frame,
      // causing visible jank during light/dark toggle.
      themeAnimationDuration: Duration.zero,
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        return AppTextScaleScope(
          scaleFactor: _textScaleController.textScaleFactor.value,
          child: child,
        );
      },
      routerConfig: widget.routerConfig,
      debugShowCheckedModeBanner: false,
    );
  }
}
