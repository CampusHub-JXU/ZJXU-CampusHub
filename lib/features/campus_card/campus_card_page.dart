import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_bootstrap_controller.dart';
import '../../core/shortcut/app_shortcut_service.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/ship_card.dart';
import '../../shared/widgets/unified_auth_protected_webview_page.dart';
import 'campus_card_service.dart';

class CampusCardPage extends StatefulWidget {
  const CampusCardPage({super.key});

  /// Whether the automatic balance refresh was triggered (for testing).
  static bool debugAutoRefreshTriggered = false;

  @override
  State<CampusCardPage> createState() => _CampusCardPageState();
}

class _CampusCardPageState extends State<CampusCardPage> {
  @override
  void initState() {
    super.initState();
    _scheduleAutoRefreshIfNeeded();
  }

  void _scheduleAutoRefreshIfNeeded() {
    if (CampusCardService.instance.cachedBalance != null) return;

    final phase = AppBootstrapController.instance.phase;
    if (phase.value == AppBootstrapPhase.localStateReady ||
        phase.value == AppBootstrapPhase.completed) {
      // Warm-up already done — balance is genuinely missing.
      _autoRefreshBalance();
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
          _autoRefreshBalance();
        }
      }
    }

    AppBootstrapController.instance.phase.addListener(listener);
  }

  void _autoRefreshBalance() {
    CampusCardPage.debugAutoRefreshTriggered = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshBalance(showFeedback: false);
    });
  }

  bool _balanceLoading = false;
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
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            flexibleSpace: const GlassAppBarSpace(),
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
                _buildQuickActions(context, cs),
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
    final cs = Theme.of(context).colorScheme;
    final cardForeground = _contrastOn(cs.primary);
    final gradientEnd = _shiftColor(
      cs.primary,
      lightnessDelta: isDark ? -0.18 : -0.12,
      saturationDelta: 0.04,
    );

    return ShipCard(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [cs.primary, gradientEnd],
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
                color: cardForeground.withValues(alpha: 0.04),
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
                color: cardForeground.withValues(alpha: 0.03),
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
                        color: cardForeground.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.credit_card,
                        color: cardForeground,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '校园卡余额',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: cardForeground,
                      ),
                    ),
                    const Spacer(),
                    _headerIcon(
                      icon: Icons.refresh_rounded,
                      onTap: _balanceLoading ? null : _refreshBalance,
                      tooltip: '刷新余额',
                      foreground: cardForeground,
                    ),
                    const SizedBox(width: 2),
                    _headerIcon(
                      icon: _obscured
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      onTap: () => setState(() => _obscured = !_obscured),
                      tooltip: _obscured ? '显示余额' : '隐藏余额',
                      foreground: cardForeground,
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
                        color: cardForeground.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _obscured ? '****' : balanceText,
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                        color: cardForeground,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        letterSpacing: -1,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Bottom row: time + status chip
                if (balance == null)
                  GestureDetector(
                    onTap: _balanceLoading ? null : _refreshBalance,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: cardForeground.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.touch_app,
                            size: 14,
                            color: cardForeground.withValues(alpha: 0.8),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _balanceLoading ? '正在查询余额' : '点击查询余额',
                            style: TextStyle(
                              fontSize: 12,
                              color: cardForeground.withValues(alpha: 0.8),
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
                        color: cardForeground.withValues(alpha: 0.4),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        timeText,
                        style: TextStyle(
                          fontSize: 12,
                          color: cardForeground.withValues(alpha: 0.4),
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
    required VoidCallback? onTap,
    required String tooltip,
    required Color foreground,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 18, color: foreground.withValues(alpha: 0.6)),
        ),
      ),
    );
  }

  // ── Quick Actions Row ───────────────────────────────────────────────────

  Widget _buildQuickActions(BuildContext context, ColorScheme cs) {
    return Row(
      children: [
        _quickActionChip(
          icon: Icons.refresh_rounded,
          label: '刷新',
          cs: cs,
          onTap: _balanceLoading ? null : _refreshBalance,
        ),
        const SizedBox(width: 8),
        _quickActionChip(
          icon: Icons.receipt_long_outlined,
          label: '账单',
          cs: cs,
          onTap: () => _openCampusCardWebView(title: '校园卡账单'),
        ),
        const SizedBox(width: 8),
        _quickActionChip(
          icon: Icons.add_circle_outline,
          label: '充值',
          cs: cs,
          onTap: _openRechargePage,
        ),
      ],
    );
  }

  Widget _quickActionChip({
    required IconData icon,
    required String label,
    required ColorScheme cs,
    required VoidCallback? onTap,
  }) {
    return Expanded(
      child: Material(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: cs.primary),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: cs.onSurface,
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

  Future<void> _openCampusCardWebView({required String title}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UnifiedAuthProtectedWebViewPage(
          title: title,
          url: CampusCardService.statusPageUrl,
          serviceUrl: CampusCardService.statusPageCasServiceUrl,
          loginDescription: '校园卡仅支持校园网内直连访问，请连接校园网后登录统一认证',
          onHomePressed: () => context.goNamed('home'),
        ),
      ),
    );

    if (!mounted) return;
    setState(() {});
  }

  Future<void> _refreshBalance({bool showFeedback = true}) async {
    if (_balanceLoading) return;
    setState(() => _balanceLoading = true);

    final balance = await CampusCardService.instance.fetchBalance(
      forceRefresh: true,
    );
    if (!mounted) return;

    setState(() => _balanceLoading = false);
    if (!showFeedback) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(balance == null ? '余额页面中未找到余额，请稍后重试' : '校园卡余额已刷新'),
      ),
    );
  }

  Future<void> _openRechargePage() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('请到微信「嘉兴大学校园卡」服务号完成充值')));
  }

  Future<void> _requestPaymentShortcut() async {
    final result = await AppShortcutService.instance
        .requestCampusCardPaymentShortcutResult();
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(result.message),
        action: result.canOpenPermissionSettings
            ? SnackBarAction(
                label: '去设置',
                onPressed: () {
                  AppShortcutService.instance.openShortcutPermissionSettings();
                },
              )
            : null,
      ),
    );
  }
}

// ── Campus Card Action ──────────────────────────────────────────────────────

enum _CampusCardMenuAction { addShortcut }

Color _shiftColor(
  Color color, {
  double lightnessDelta = 0,
  double saturationDelta = 0,
}) {
  final hsl = HSLColor.fromColor(color);
  return hsl
      .withLightness((hsl.lightness + lightnessDelta).clamp(0.0, 1.0))
      .withSaturation((hsl.saturation + saturationDelta).clamp(0.0, 1.0))
      .toColor();
}

Color _contrastOn(Color background) {
  return background.computeLuminance() > 0.45 ? Colors.black : Colors.white;
}
