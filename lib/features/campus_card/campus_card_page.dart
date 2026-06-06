import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../app/app_bootstrap_controller.dart';
import '../../app/theme.dart';
import '../../core/logging/app_logger.dart';
import '../../core/shortcut/app_shortcut_service.dart';
import '../../shared/widgets/ship_card.dart';
import '../../shared/widgets/unified_auth_protected_webview_page.dart';
import 'campus_card_service.dart';

class CampusCardPage extends StatefulWidget {
  const CampusCardPage({super.key});

  /// Whether the auto-open logic was triggered (for testing).
  static bool debugAutoOpenTriggered = false;

  @override
  State<CampusCardPage> createState() => _CampusCardPageState();
}

class _CampusCardPageState extends State<CampusCardPage> {
  static const _serviceHallHost = 'mobilehall.zjxu.edu.cn';
  static const _statusPathKeyword = '/decision/view/form';
  static const _statusViewletKeyword = 'ykt.frm';

  @override
  void initState() {
    super.initState();
    _scheduleAutoOpenIfNeeded();
  }

  void _scheduleAutoOpenIfNeeded() {
    if (CampusCardService.instance.cachedBalance != null) return;

    final phase = AppBootstrapController.instance.phase;
    if (phase.value == AppBootstrapPhase.localStateReady ||
        phase.value == AppBootstrapPhase.completed) {
      // Warm-up already done — balance is genuinely missing.
      _autoOpenWebView();
      return;
    }

    // Wait for bootstrap warm-up to restore persisted balance first.
    void listener() {
      final p = AppBootstrapController.instance.phase.value;
      if (p == AppBootstrapPhase.localStateReady ||
          p == AppBootstrapPhase.completed) {
        AppBootstrapController.instance.phase.removeListener(listener);
        if (!mounted) return;
        if (CampusCardService.instance.cachedBalance == null) {
          _autoOpenWebView();
        }
      }
    }

    AppBootstrapController.instance.phase.addListener(listener);
  }

  void _autoOpenWebView() {
    CampusCardPage.debugAutoOpenTriggered = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _openCampusCardWebView(title: '校园卡账单', autoPop: true);
    });
  }

  bool _capturedInCurrentDetailPage = false;
  bool _autoPopAfterCapture = false;
  bool _obscured = false;

  @override
  Widget build(BuildContext context) {
    final service = CampusCardService.instance;
    final balance = service.cachedBalance;
    final lastUpdated = service.lastUpdated;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAndroid = Theme.of(context).platform == TargetPlatform.android;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            title: const Text('校园卡'),
            actions: [
              if (isAndroid)
                PopupMenuButton<_CampusCardMenuAction>(
                  tooltip: '更多操作',
                  onSelected: (action) {
                    switch (action) {
                      case _CampusCardMenuAction.addShortcut:
                        _requestPaymentShortcut();
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem<_CampusCardMenuAction>(
                      value: _CampusCardMenuAction.addShortcut,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.add_to_home_screen_outlined),
                        title: Text('添加至桌面'),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _buildBalanceCard(context, balance, lastUpdated, isDark),
                const SizedBox(height: 16),
                _buildQuickActions(context, cs, isDark),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  // ── Balance Card ────────────────────────────────────────────────────────

  Widget _buildBalanceCard(
    BuildContext context,
    double? balance,
    DateTime? lastUpdated,
    bool isDark,
  ) {
    final balanceText = balance != null ? balance.toStringAsFixed(2) : '--';
    final timeText = lastUpdated != null
        ? '${lastUpdated.month}/${lastUpdated.day} '
              '${lastUpdated.hour.toString().padLeft(2, '0')}:'
              '${lastUpdated.minute.toString().padLeft(2, '0')} 更新'
        : '暂未获取余额';

    return ShipCard(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isDark
            ? const [Color(0xFF5C2030), Color(0xFF3D1018)]
            : const [AppColors.primary, AppColors.primaryDark],
      ),
      padding: EdgeInsets.zero,
      elevation: isDark ? 0 : 4,
      child: Stack(
        children: [
          // Decorative circles
          Positioned(
            right: -30,
            top: -30,
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.04),
              ),
            ),
          ),
          Positioned(
            right: 40,
            bottom: -20,
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.03),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header row
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.credit_card,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      '校园卡余额',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                    ),
                    const Spacer(),
                    _headerIcon(
                      icon: Icons.refresh_rounded,
                      onTap: () =>
                          _openCampusCardWebView(title: '刷新余额', autoPop: true),
                      tooltip: '刷新余额',
                    ),
                    const SizedBox(width: 2),
                    _headerIcon(
                      icon: _obscured
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      onTap: () => setState(() => _obscured = !_obscured),
                      tooltip: _obscured ? '显示余额' : '隐藏余额',
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                // Balance value
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '¥',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _obscured ? '****' : balanceText,
                      style: const TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        fontFeatures: [FontFeature.tabularFigures()],
                        letterSpacing: -1,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Bottom row: time + status chip
                if (balance == null)
                  GestureDetector(
                    onTap: () =>
                        _openCampusCardWebView(title: '校园卡账单', autoPop: true),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.touch_app,
                            size: 14,
                            color: Colors.white.withValues(alpha: 0.8),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '点击查询余额',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  Row(
                    children: [
                      Icon(
                        Icons.schedule,
                        size: 13,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        timeText,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerIcon({
    required IconData icon,
    required VoidCallback onTap,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 18,
            color: Colors.white.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }

  // ── Quick Actions Row ───────────────────────────────────────────────────

  Widget _buildQuickActions(BuildContext context, ColorScheme cs, bool isDark) {
    return Row(
      children: [
        _quickActionChip(
          icon: Icons.refresh_rounded,
          label: '刷新',
          isDark: isDark,
          onTap: () => _openCampusCardWebView(title: '刷新余额', autoPop: true),
        ),
        const SizedBox(width: 8),
        _quickActionChip(
          icon: Icons.receipt_long_outlined,
          label: '账单',
          isDark: isDark,
          onTap: () => _openCampusCardWebView(title: '校园卡账单'),
        ),
        const SizedBox(width: 8),
        _quickActionChip(
          icon: Icons.add_circle_outline,
          label: '充值',
          isDark: isDark,
          onTap: _openRechargePage,
        ),
      ],
    );
  }

  Widget _quickActionChip({
    required IconData icon,
    required String label,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Material(
        color: isDark ? const Color(0xFF2D1F23) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: AppColors.primary),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── WebView ─────────────────────────────────────────────────────────────

  Future<void> _openCampusCardWebView({
    required String title,
    bool autoPop = false,
  }) async {
    _capturedInCurrentDetailPage = false;
    _autoPopAfterCapture = autoPop;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UnifiedAuthProtectedWebViewPage(
          title: title,
          url: CampusCardService.statusPageUrl,
          serviceUrl: CampusCardService.statusPageCasServiceUrl,
          loginDescription: '校园卡仅支持校园网内直连访问，请连接校园网后登录统一认证',
          onLoadStop: _captureBalanceFromDetailPage,
        ),
      ),
    );

    if (!mounted) return;
    setState(() {});
  }

  Future<void> _openRechargePage() async {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('请到微信「嘉兴大学校园卡」服务号完成充值')));
  }

  Future<void> _requestPaymentShortcut() async {
    final created = await AppShortcutService.instance
        .requestCampusCardPaymentShortcut();
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(created ? '已发起添加请求，请在系统提示中确认' : '当前设备暂不支持添加桌面快捷方式'),
      ),
    );
  }

  Future<void> _captureBalanceFromDetailPage(
    InAppWebViewController controller,
    String currentUrl,
  ) async {
    if (_capturedInCurrentDetailPage) return;

    final uri = Uri.tryParse(currentUrl);
    final path = uri?.path.toLowerCase();
    if (AppLogger.instance.config.value.webviewLifecycleEnabled) {
      AppLogger.instance.webview(LogLevel.debug, '校园卡 onLoadStop: $currentUrl');
    }
    if (uri == null || !_isCampusCardStatusPage(uri)) {
      if (AppLogger.instance.config.value.webviewLifecycleEnabled) {
        AppLogger.instance.webview(
          LogLevel.debug,
          '校园卡 跳过余额提取 (host=${uri?.host}, path=$path)',
        );
      }
      return;
    }

    final balance = await _extractBalanceWithRetry(controller);
    AppLogger.instance.webview(LogLevel.info, '校园卡余额提取结果: $balance');
    if (balance == null) return;

    CampusCardService.instance.updateCachedBalance(balance);
    _capturedInCurrentDetailPage = true;

    if (!mounted) return;
    setState(() {});
    if (_autoPopAfterCapture) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.maybeOf(context)?.maybePop();
      });
    }
  }

  Future<double?> _extractBalanceWithRetry(
    InAppWebViewController controller,
  ) async {
    const delaysInMs = [0, 700, 1400, 2200];

    for (final delayInMs in delaysInMs) {
      if (delayInMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: delayInMs));
      }

      try {
        final rawText = await controller.evaluateJavascript(
          source: '''
          (() => {
            const texts = [];
            const bodyText = document.body?.innerText;
            if (bodyText) texts.push(bodyText);
            const frames = document.querySelectorAll('iframe');
            for (const frame of frames) {
              try {
                const frameText = frame.contentDocument?.body?.innerText;
                if (frameText) texts.push(frameText);
              } catch (_) {}
            }
            return texts.join('\\n');
          })();
        ''',
        );

        final text = rawText is String ? rawText : '${rawText ?? ''}';
        if (AppLogger.instance.config.value.webviewLifecycleEnabled) {
          AppLogger.instance.webview(
            LogLevel.debug,
            '校园卡 retry[$delayInMs ms] 文本长度=${text.length}',
          );
        }
        final balance = CampusCardService.instance.parseBalanceFromPageText(
          text,
        );
        if (balance != null) return balance;
      } catch (e) {
        if (AppLogger.instance.config.value.webviewLifecycleEnabled) {
          AppLogger.instance.webview(LogLevel.debug, '校园卡 JS 提取异常: $e');
        }
        continue;
      }
    }

    return null;
  }

  bool _isCampusCardStatusPage(Uri uri) {
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    final viewlet = uri.queryParameters['viewlet']?.toLowerCase() ?? '';

    final isExpectedHost = host == _serviceHallHost;
    if (!isExpectedHost) return false;

    return path.contains(_statusPathKeyword) &&
        viewlet.contains(_statusViewletKeyword);
  }
}

// ── Campus Card Action ──────────────────────────────────────────────────────

enum _CampusCardMenuAction { addShortcut }
