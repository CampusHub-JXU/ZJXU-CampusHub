import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../core/logging/app_logger.dart';
import '../core/network/proxy_mode.dart';
import 'app_preferences_controller.dart';
import 'routes.dart';
import 'text_scale_controller.dart';
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
  static const _startupProxyWarningMessage =
      '检测到系统代理或 VPN/TUN；若校务功能异常，请排除本 App 或将 *.zjxu.edu.cn 设为 DIRECT';

  final _preferencesController = AppPreferencesController.instance;
  final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  bool _shouldShowStartupProxyWarning = false;
  bool _startupProxyWarningShown = false;
  bool _startupProxyWarningScheduled = false;

  @override
  void initState() {
    super.initState();
    _preferencesController.addListener(_onPreferencesChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkStartupGuards());
    });
  }

  @override
  void dispose() {
    _preferencesController.removeListener(_onPreferencesChanged);
    super.dispose();
  }

  void _onPreferencesChanged() => setState(() {});

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
    final prefs = _preferencesController.state;
    return MaterialApp.router(
      title: '嘉兴大学-智能中台',
      theme: AppTheme.lightThemeFor(
        prefs.seedColor,
        filledButtonSoftStyle: prefs.filledButtonSoftStyle,
      ),
      darkTheme: AppTheme.darkThemeFor(
        prefs.seedColor,
        pureBlack: prefs.pureBlack,
        filledButtonSoftStyle: prefs.filledButtonSoftStyle,
      ),
      themeMode: prefs.materialThemeMode,
      scaffoldMessengerKey: _scaffoldMessengerKey,
      // Disable the built-in AnimatedTheme transition — it forces every
      // Theme.of(context) dependent to rebuild on every animation frame,
      // causing visible jank during light/dark toggle.
      themeAnimationDuration: Duration.zero,
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        final normalizedScale = TextScaleController.normalizeScaleFactor(
          prefs.textScale,
        );
        return MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(normalizedScale)),
          child: child,
        );
      },
      routerConfig: widget.routerConfig,
      debugShowCheckedModeBanner: false,
    );
  }
}
