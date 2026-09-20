import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/app_route_observer.dart';
import '../../core/actions/campus_action_executor.dart';
import '../../core/actions/campus_action_ids.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/epay100/epay100_gateway.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/app_state_view_transition.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/unified_auth_protected_webview_page.dart';
import 'campus_card_fallback_payment_page.dart';
import 'epay_payment_code_service.dart';

// 旧版备用码页已机械拆分到独立文件；此处保持原导出兼容
// （import campus_card_payment_page.dart 仍可直接使用
// CampusCardFallbackPaymentPage）。
export 'campus_card_fallback_payment_page.dart';

class CampusCardPaymentPage extends StatefulWidget {
  const CampusCardPaymentPage({super.key, this.service});

  final EpayPaymentCodeService? service;

  @override
  State<CampusCardPaymentPage> createState() => _CampusCardPaymentPageState();
}

class _CampusCardPaymentPageState extends State<CampusCardPaymentPage>
    with WidgetsBindingObserver, RouteAware {
  late final EpayPaymentCodeService _service;

  EpayPaymentCode? _code;
  bool _loading = false;
  String? _error;
  bool _needsAuth = false;
  bool _bindingRequired = false;
  String? _boundAccount;
  int _requestGeneration = 0;
  int _authEpoch = 0;
  Timer? _refreshTimer;

  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  PageRoute<dynamic>? _route;
  bool _isRouteForeground = true;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? EpayPaymentCodeService();
    WidgetsBinding.instance.addObserver(this);
    UnifiedAuthService.instance.addListener(_onAuthChanged);
    _fetchCode();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && !identical(route, _route)) {
      if (_route != null) {
        appRouteObserver.unsubscribe(this);
      }
      _route = route;
      _isRouteForeground = route.isCurrent;
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    UnifiedAuthService.instance.removeListener(_onAuthChanged);
    if (_route != null) {
      appRouteObserver.unsubscribe(this);
    }
    _cancelTimer();
    // 禁止调用共享 gateway.invalidate()，避免打断电费等其它业务
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      if (_isRouteForeground && !_bindingRequired && !_needsAuth) {
        _fetchCode();
      }
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _cancelTimerAndClearCode();
    }
  }

  @override
  void didPush() => _isRouteForeground = true;

  @override
  void didPushNext() {
    _isRouteForeground = false;
    _cancelTimerAndClearCode();
  }

  @override
  void didPopNext() {
    _isRouteForeground = true;
    if (!_bindingRequired && !_needsAuth) {
      _fetchCode();
    }
  }

  @override
  void didPop() {
    _isRouteForeground = false;
    _cancelTimerAndClearCode();
  }

  void _onAuthChanged() {
    _authEpoch++;
    final auth = UnifiedAuthService.instance;
    final currentAccount = auth.currentAccount;
    final isLoggedIn = auth.isLoggedIn;

    _cancelTimerAndClearCode();

    if (!isLoggedIn || currentAccount == null || currentAccount.isEmpty) {
      _boundAccount = null;
      _bindingRequired = false;
      if (mounted) {
        setState(() {
          _loading = false;
          _needsAuth = true;
          _error = null;
        });
      }
      return;
    }

    if (currentAccount != _boundAccount) {
      // 账号真正变化：清除旧账户的待绑定状态，按既有流程为新账号重新拉取
      _bindingRequired = false;
      _boundAccount = currentAccount;
      if (mounted) {
        _fetchCode();
      }
      return;
    }

    // 同账号通知：若处于待认证/待绑定状态，无意义 notify 不恢复自动取码
    if (_bindingRequired) {
      return;
    }

    if (mounted) {
      _fetchCode();
    }
  }

  void _cancelTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  void _cancelTimerAndClearCode() {
    _cancelTimer();
    _requestGeneration++;
    _code = null;
    if (mounted) setState(() {});
  }

  Future<void> _fetchCode() async {
    // 刷新开始即清码，并递增代数作废在途响应
    _cancelTimer();
    _code = null;
    final currentGeneration = ++_requestGeneration;
    final currentEpoch = _authEpoch;

    final auth = UnifiedAuthService.instance;
    final currentAccount = auth.currentAccount;

    if (!auth.isLoggedIn || currentAccount == null || currentAccount.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
        _needsAuth = true;
        _bindingRequired = false;
      });
      return;
    }

    _boundAccount = currentAccount;
    setState(() {
      _loading = true;
      _error = null;
      _needsAuth = false;
    });

    try {
      final code = await _service.fetch();

      // generation / epoch 丢弃迟到响应；仅在前台活跃且未被遮挡时接收
      if (!mounted ||
          currentGeneration != _requestGeneration ||
          currentEpoch != _authEpoch ||
          !_isRouteForeground ||
          _appLifecycleState != AppLifecycleState.resumed) {
        return;
      }

      // 绑定获取请求的账号与登录态
      final nowAccount = UnifiedAuthService.instance.currentAccount;
      if (!UnifiedAuthService.instance.isLoggedIn ||
          nowAccount != currentAccount) {
        _cancelTimerAndClearCode();
        setState(() {
          _loading = false;
          _needsAuth = true;
          _bindingRequired = false;
          _error = null;
        });
        return;
      }

      setState(() {
        _code = code;
        _loading = false;
        _bindingRequired = false;
        _error = null;
      });

      _scheduleRefresh(code.refreshAfter);
    } on EpayBindingRequiredException {
      if (!mounted ||
          currentGeneration != _requestGeneration ||
          currentEpoch != _authEpoch) {
        return;
      }
      _cancelTimerAndClearCode();
      setState(() {
        _loading = false;
        _bindingRequired = true;
        _needsAuth = false;
        _error = null;
      });
    } on EpaySessionUnavailableException {
      if (!mounted ||
          currentGeneration != _requestGeneration ||
          currentEpoch != _authEpoch) {
        return;
      }
      _cancelTimerAndClearCode();
      setState(() {
        _loading = false;
        _needsAuth = true;
        _bindingRequired = false;
        _error = null;
      });
    } on EpayGatewayException catch (e) {
      if (!mounted ||
          currentGeneration != _requestGeneration ||
          currentEpoch != _authEpoch) {
        return;
      }
      // 失败不留码
      _cancelTimerAndClearCode();
      setState(() {
        _loading = false;
        _bindingRequired = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted ||
          currentGeneration != _requestGeneration ||
          currentEpoch != _authEpoch) {
        return;
      }
      _cancelTimerAndClearCode();
      setState(() {
        _loading = false;
        _bindingRequired = false;
        _error = '付款码获取失败，请稍后重试';
      });
    }
  }

  void _scheduleRefresh(Duration refreshAfter) {
    _cancelTimer();
    if (!_isRouteForeground ||
        _appLifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _refreshTimer = Timer(refreshAfter, () {
      if (mounted &&
          _isRouteForeground &&
          _appLifecycleState == AppLifecycleState.resumed) {
        _fetchCode();
      }
    });
  }

  void _openOfficialWebPage() {
    // 打开网页前清码
    _cancelTimerAndClearCode();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const UnifiedAuthProtectedWebViewPage(
          title: '官方付款码',
          url: EpayPaymentCodeService.officialUrl,
          warmUpAsResource: true,
          loginDescription: '登录一卡通后可直接进入官方付款码',
          authRequiredTitle: '需要登录一卡通后继续',
          authRequiredButtonLabel: '登录一卡通',
          showWebViewBottomBackButton: true,
          emulateDingTalkEnvironment: false,
        ),
      ),
    );
  }

  void _openLegacyFallbackPage() {
    _cancelTimerAndClearCode();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            CampusCardFallbackPaymentPage(routeObserver: appRouteObserver),
      ),
    );
  }

  Future<void> _handleLogin() async {
    final loggedIn = await showUnifiedAuthLoginModal(
      context,
      title: '登录一卡通',
      description: '登录一卡通后可出示付款码',
    );
    if (loggedIn && mounted) _fetchCode();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppAppBar(
        title: const Text('付款码'),
        actions: [
          TextButton(
            onPressed: _openOfficialWebPage,
            child: const Text('官方网页'),
          ),
          PopupMenuButton<String>(
            tooltip: '更多选项',
            onSelected: (v) => v == 'legacy' ? _openLegacyFallbackPage() : null,
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'legacy', child: Text('旧版备用码')),
            ],
          ),
        ],
      ),
      body: _buildBody(theme, colorScheme),
    );
  }

  Widget _buildBody(ThemeData theme, ColorScheme colorScheme) {
    if (_needsAuth) {
      return AuthRequiredView(
        title: '需要登录一卡通后继续',
        message: '登录一卡通后可出示付款码',
        buttonLabel: '登录一卡通',
        icon: Icons.account_balance_outlined,
        onAction: _handleLogin,
      );
    }
    if (_bindingRequired) {
      return _buildBindingRequiredView(theme, colorScheme);
    }
    if (_error != null) {
      return AppErrorView(message: _error, onRetry: _fetchCode);
    }
    if (_loading && _code == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_code == null) {
      return Center(
        child: OutlinedButton.icon(
          onPressed: _fetchCode,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('获取付款码'),
        ),
      );
    }
    return _buildContent(theme, colorScheme);
  }

  Widget _buildBindingRequiredView(ThemeData theme, ColorScheme colorScheme) {
    return AppStateViewTransition(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_boundAccount != null && _boundAccount!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.account_circle_outlined,
                          size: 18,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '学工号: $_boundAccount',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                AppCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 32,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          Icons.credit_card_outlined,
                          color: colorScheme.onPrimaryContainer,
                          size: 28,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        '需完成一卡通认证',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '请在官方页面完成认证或绑定，返回后重新获取。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _openOfficialWebPage,
                  icon: const Icon(Icons.open_in_browser, size: 18),
                  label: const Text('前往官方付款页'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _fetchCode,
                  icon: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  label: const Text('已完成，重新获取'),
                ),
                const SizedBox(height: 12),
                Center(
                  child: TextButton(
                    onPressed: _openLegacyFallbackPage,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: colorScheme.outline,
                    ),
                    child: const Text('遇到兼容问题？使用旧版备用码'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(ThemeData theme, ColorScheme colorScheme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_boundAccount != null && _boundAccount!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.account_circle_outlined,
                        size: 18,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '学工号: $_boundAccount',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              AppCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 24,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: QrImageView(
                        key: ValueKey('epay_qr_${_code!.qrcode}'),
                        data: _code!.qrcode,
                        semanticsLabel: '付款二维码',
                        version: QrVersions.auto,
                        size: 240,
                        backgroundColor: Colors.white,
                        eyeStyle: const QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: Colors.black,
                        ),
                        dataModuleStyle: const QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.square,
                          color: Colors.black,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.qr_code_scanner,
                          size: 16,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '请将二维码对准扫码设备',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '付款码自动定时刷新',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              AppCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 20,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '需要支付密码确认时，请使用官方付款页。此页面不显示支付结果。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _loading ? null : _fetchCode,
                      icon: _loading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 18),
                      label: const Text('手动刷新'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _openOfficialWebPage,
                      icon: const Icon(Icons.open_in_browser, size: 18),
                      label: const Text('官方付款页'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Center(
                child: TextButton(
                  onPressed: _openLegacyFallbackPage,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: colorScheme.outline,
                  ),
                  child: const Text('遇到兼容问题？使用旧版备用码'),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: TextButton(
                  onPressed: () => CampusActionExecutor.instance.execute(
                    context,
                    CampusActionIds.campusCardResetPassword,
                  ),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: colorScheme.outline,
                  ),
                  child: const Text('忘记一卡通密码？'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
