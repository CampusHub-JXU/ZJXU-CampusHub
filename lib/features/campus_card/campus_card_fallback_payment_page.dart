import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/auth/credential_store.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/app_feedback.dart';
import 'ecard_service.dart';

/// 旧版备用码页（自 `campus_card_payment_page.dart` 机械拆分，UI 不变）。
///
/// 安全约束：出码前本地存储的学号必须与当前统一认证登录账号一致；await
/// 边界（含轮询返回）后一律校验 auth epoch，旧会话的响应不得应用。
class CampusCardFallbackPaymentPage extends StatefulWidget {
  const CampusCardFallbackPaymentPage({super.key, required this.routeObserver});

  /// 路由观察者：由宿主页注入（feature 不得直接 import app 层）。
  /// 必填，避免默认构造静默失去 RouteAware 清码遮挡。
  /// 只观察 PageRoute——弹层/对话框路由不算遮挡出码页。
  final RouteObserver<PageRoute<dynamic>> routeObserver;

  @override
  State<CampusCardFallbackPaymentPage> createState() =>
      _CampusCardFallbackPaymentPageState();
}

class _CampusCardFallbackPaymentPageState
    extends State<CampusCardFallbackPaymentPage>
    with WidgetsBindingObserver, RouteAware {
  static const _fastPollInterval = Duration(seconds: 2);
  static const _slowPollInterval = Duration(seconds: 5);
  static const _fastPollAttempts = 15;
  static const _maxPollAttempts = 33;

  final _ecard = EcardService.instance;

  String? _qrCode;
  String? _accName;
  String? _accNum;
  String? _error;
  bool _loading = true;

  Timer? _pollTimer;
  String? _lastPaymentInfo;
  bool _showPaymentResult = false;
  bool _pollingStopped = false;
  int _pollAttempts = 0;
  int _pollSession = 0;
  int _requestGeneration = 0;
  int _authEpoch = 0;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  PageRoute<dynamic>? _route;
  bool _isRouteForeground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    UnifiedAuthService.instance.addListener(_onAuthChanged);
    _initialize();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final observer = widget.routeObserver;
    final route = ModalRoute.of(context);
    if (route is! PageRoute<dynamic> || identical(route, _route)) {
      return;
    }

    if (_route != null) {
      observer.unsubscribe(this);
    }

    _route = route;
    _isRouteForeground = route.isCurrent;
    observer.subscribe(this, route);
    _resumePollingIfNeeded();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    UnifiedAuthService.instance.removeListener(_onAuthChanged);
    if (_route != null) {
      widget.routeObserver.unsubscribe(this);
    }
    _cancelPolling();
    super.dispose();
  }

  void _clearStateAndCancel() {
    _requestGeneration++;
    _cancelPolling(resetAttempts: true);
    _qrCode = null;
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      if (_canPoll) {
        _resumePollingIfNeeded();
      } else if (_qrCode == null) {
        _initialize();
      }
    } else {
      _clearStateAndCancel();
    }
  }

  @override
  void didPush() {
    _isRouteForeground = true;
    _resumePollingIfNeeded();
  }

  @override
  void didPopNext() {
    _isRouteForeground = true;
    _qrCode == null ? _initialize() : _resumePollingIfNeeded();
  }

  @override
  void didPushNext() {
    _isRouteForeground = false;
    _clearStateAndCancel();
  }

  @override
  void didPop() {
    _isRouteForeground = false;
    _clearStateAndCancel();
  }

  bool get _canPoll =>
      _isRouteForeground && _appLifecycleState == AppLifecycleState.resumed;

  void _onAuthChanged() {
    _authEpoch++;
    _clearStateAndCancel();
    final auth = UnifiedAuthService.instance;
    final currentAccount = auth.currentAccount;
    _accName = null;
    _accNum = null;

    if (!auth.isLoggedIn || currentAccount == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '请先登录一卡通';
        });
      }
    } else if (mounted) {
      _initialize();
    }
  }

  Future<void> _initialize() async {
    final currentGen = ++_requestGeneration;
    final currentEpoch = _authEpoch;
    final requestAccount = UnifiedAuthService.instance.currentAccount;

    if (!UnifiedAuthService.instance.isLoggedIn || requestAccount == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '请先登录一卡通';
      });
      return;
    }

    final creds = await CredentialStore.instance.loadUnifiedAuthCredentials();

    // await 边界：读取凭据期间登录态 / 请求代数可能已变化，旧凭据不得继续。
    if (!mounted ||
        currentGen != _requestGeneration ||
        currentEpoch != _authEpoch) {
      return;
    }
    final currentAccount = UnifiedAuthService.instance.currentAccount;
    if (!UnifiedAuthService.instance.isLoggedIn ||
        currentAccount != requestAccount) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '请先登录一卡通';
      });
      return;
    }

    // 安全校验：本地存储的学号必须与当前登录账号一致——B 登录的会话通知
    // 先于凭据落盘，读到旧账号 A 的凭据时绝不发起出码请求。
    if (creds == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '请先登录一卡通';
      });
      return;
    }
    if (creds.$1 != requestAccount) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '登录凭据与当前账号不一致，请重新登录一卡通';
      });
      return;
    }

    final studentId = creds.$1;
    // 每个网络请求前后校验 gen/epoch/账号：QueryAccAuth 在途期间登出/
    // 切账号时，QueryAccInfoH / GetQRCode 一律不再发送。
    bool operationValid() =>
        mounted &&
        currentGen == _requestGeneration &&
        currentEpoch == _authEpoch &&
        UnifiedAuthService.instance.isLoggedIn &&
        UnifiedAuthService.instance.currentAccount == requestAccount;
    final result = await _ecard.initializeAndCreateQRCode(
      studentId,
      shouldContinue: operationValid,
    );

    if (!mounted ||
        currentGen != _requestGeneration ||
        currentEpoch != _authEpoch ||
        !_canPoll) {
      return;
    }

    final nowAccount = UnifiedAuthService.instance.currentAccount;
    if (!UnifiedAuthService.instance.isLoggedIn ||
        nowAccount != requestAccount) {
      setState(() {
        _loading = false;
        _qrCode = null;
        _error = '请先登录一卡通';
      });
      return;
    }

    if (!result.isSuccess) {
      setState(() {
        _loading = false;
        _error = result.error ?? '获取消费码失败';
      });
      return;
    }

    setState(() {
      _loading = false;
      _error = null;
      _qrCode = result.qrCode;
      _accName = result.accName;
      _accNum = result.accNum;
      _pollingStopped = false;
    });

    _startPolling(result.qrCode!);
  }

  void _startPolling(String qrCode) {
    _cancelPolling(resetAttempts: true);
    _pollingStopped = false;
    _scheduleNextPoll(qrCode);
  }

  void _cancelPolling({bool resetAttempts = false}) {
    _pollSession += 1;
    _pollTimer?.cancel();
    _pollTimer = null;
    if (resetAttempts) _pollAttempts = 0;
  }

  void _resumePollingIfNeeded() {
    final qrCode = _qrCode;
    if (qrCode == null ||
        _loading ||
        _showPaymentResult ||
        _pollingStopped ||
        !_canPoll ||
        _pollTimer != null) {
      return;
    }
    _scheduleNextPoll(qrCode);
  }

  Duration _nextPollDelay() =>
      _pollAttempts < _fastPollAttempts ? _fastPollInterval : _slowPollInterval;

  void _scheduleNextPoll(String qrCode) {
    if (!mounted || _pollingStopped || !_canPoll) return;
    if (_pollAttempts >= _maxPollAttempts) {
      _stopPollingWithHint();
      return;
    }

    final session = _pollSession;
    _pollTimer?.cancel();
    _pollTimer = Timer(
      _nextPollDelay(),
      () => unawaited(_pollOnce(qrCode, session)),
    );
  }

  Future<void> _pollOnce(String qrCode, int session) async {
    if (!mounted || session != _pollSession || _pollingStopped || !_canPoll) {
      return;
    }

    final pollEpoch = _authEpoch;
    _pollTimer = null;
    final info = await _ecard.getQRCodeInfo(qrCode);
    // await 边界：旧 auth epoch 的轮询结果一律丢弃。
    if (!mounted || session != _pollSession || pollEpoch != _authEpoch) return;

    _pollAttempts += 1;
    if (info.isUsed) {
      setState(() {
        _lastPaymentInfo = info.tradeAmt.isNotEmpty
            ? '¥${info.tradeAmt}'
            : '支付成功';
        _showPaymentResult = true;
      });
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted || session != _pollSession || pollEpoch != _authEpoch) {
        return;
      }
      await _refreshQRCode();
      return;
    }

    _scheduleNextPoll(qrCode);
  }

  void _stopPollingWithHint() {
    _cancelPolling();
    if (!mounted || _pollingStopped) return;
    setState(() => _pollingStopped = true);
    AppFeedback.toast(context, '状态轮询已暂停，请手动刷新消费码');
  }

  Future<void> _refreshQRCode() async {
    if (_accNum == null) return;
    final currentGen = ++_requestGeneration;
    final currentEpoch = _authEpoch;
    final requestAccount = UnifiedAuthService.instance.currentAccount;

    setState(() {
      _error = null;
      _loading = true;
      _showPaymentResult = false;
      _lastPaymentInfo = null;
      _pollingStopped = false;
    });

    _cancelPolling(resetAttempts: true);

    // 发送前与返回后都用同一份 gen/epoch/账号快照校验：登录态变化时
    // 不出码、不应用旧响应。
    bool refreshValid() =>
        mounted &&
        currentGen == _requestGeneration &&
        currentEpoch == _authEpoch &&
        UnifiedAuthService.instance.isLoggedIn &&
        UnifiedAuthService.instance.currentAccount == requestAccount;
    String? qrCode;
    String? connectionError;
    try {
      qrCode = await _ecard.getQRCode(_accNum!, shouldContinue: refreshValid);
    } on EcardConnectionException catch (e) {
      connectionError = e.message;
    }

    if (!mounted ||
        currentGen != _requestGeneration ||
        currentEpoch != _authEpoch ||
        !_canPoll) {
      return;
    }

    final nowAccount = UnifiedAuthService.instance.currentAccount;
    if (!UnifiedAuthService.instance.isLoggedIn ||
        nowAccount != requestAccount) {
      setState(() {
        _loading = false;
        _qrCode = null;
        _error = '请先登录一卡通';
      });
      return;
    }

    if (qrCode == null) {
      setState(() {
        _loading = false;
        _error = connectionError ?? '刷新消费码失败';
      });
      return;
    }

    setState(() {
      _loading = false;
      _qrCode = qrCode;
    });

    _startPolling(qrCode);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppAppBar(title: const Text('旧版备用码')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _buildError()
          : _buildContent(theme, colorScheme),
    );
  }

  Widget _buildError() {
    return AppErrorView(
      message: _error,
      onRetry: () {
        setState(() {
          _error = null;
          _loading = true;
        });
        _ecard.clearCache();
        _initialize();
      },
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
              if (_accNum != null && _accNum!.isNotEmpty)
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
                      Flexible(
                        child: Text(
                          _accName != null && _accName!.isNotEmpty
                              ? '$_accName · 卡号 $_accNum'
                              : '卡号 $_accNum',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              _buildQRCodeCard(theme, colorScheme),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: _loading ? null : _refreshQRCode,
                icon: _loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: const Text('刷新消费码'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQRCodeCard(ThemeData theme, ColorScheme colorScheme) {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: _showPaymentResult
            ? _buildPaymentResult(theme, colorScheme)
            : _buildQRCodeBody(theme, colorScheme),
      ),
    );
  }

  /// 与付款码页同款的白底扫码卡：16 内边距 + 圆角 16 + 弱投影。
  Widget _buildWhiteSurface(Widget child) {
    return Container(
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
      child: child,
    );
  }

  Widget _buildScanHint(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
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
        if (_pollingStopped)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '状态轮询已暂停，请手动刷新后继续使用',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildQRCodeBody(ThemeData theme, ColorScheme colorScheme) {
    final qrCode = _qrCode;
    if (qrCode == null) return const SizedBox.shrink();
    final qrData = qrCode.contains(',') ? qrCode.split(',').first : qrCode;

    return Column(
      key: const ValueKey('qrcode'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildWhiteSurface(
          QrImageView(
            key: ValueKey('fallback_qr_$qrData'),
            data: qrData,
            semanticsLabel: '付款二维码',
            version: QrVersions.auto,
            size: 240,
            backgroundColor: Colors.white,
            // 码点固定黑色：白底上的对比度与深色模式无关（onSurface 在深色
            // 模式下是浅色，会让二维码几乎不可扫）。
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
        _buildScanHint(theme, colorScheme),
      ],
    );
  }

  /// 支付结果占住与二维码相同的白底方块位，切换时卡片不跳动。
  Widget _buildPaymentResult(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      key: const ValueKey('payment'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildWhiteSurface(
          SizedBox(
            width: 240,
            height: 240,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.check_circle,
                    size: 64,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _lastPaymentInfo ?? '支付成功',
                    style: context.appText.rowValue,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _buildScanHint(theme, colorScheme),
      ],
    );
  }
}
