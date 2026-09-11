import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_bootstrap_controller.dart';
import '../../core/actions/campus_action_executor.dart';
import '../../core/config/app_config.dart';
import '../../core/logging/app_logger.dart';
import '../../core/shortcut/app_shortcut_service.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_icon_badge.dart';
import '../../shared/widgets/app_tile_surface.dart';
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
  bool _balanceLoading = false;
  bool _obscured = false;

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

  @override
  Widget build(BuildContext context) {
    final service = CampusCardService.instance;
    final balance = service.cachedBalance;
    final lastUpdated = service.lastUpdated;
    final isAndroid = Theme.of(context).platform == TargetPlatform.android;

    return Scaffold(
      appBar: AppAppBar(
        title: const Text('校园卡'),
        actions: [
          IconButton(
            tooltip: '刷新余额',
            onPressed: _balanceLoading ? null : _refreshBalance,
            icon: const Icon(Icons.refresh_rounded),
          ),
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
      body: RefreshIndicator(
        onRefresh: () => _refreshBalance(showFeedback: false),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pageMargin,
            AppSpacing.sm,
            AppSpacing.pageMargin,
            AppSpacing.xl,
          ),
          children: [
            _buildBalanceCard(context, balance, lastUpdated),
            const SizedBox(height: AppSpacing.lg),
            _buildActionTile(
              context,
              icon: Icons.receipt_long_outlined,
              title: '账单',
              subtitle: '查看校园卡消费明细',
              onTap: () => _openCampusCardWebView(title: '校园卡账单'),
            ),
            const SizedBox(height: AppSpacing.md),
            _buildActionTile(
              context,
              icon: Icons.add_card_outlined,
              title: '充值',
              subtitle: '在微信服务号内完成充值',
              onTap: _openRechargePage,
            ),
          ],
        ),
      ),
    );
  }

  // ── Balance Card ────────────────────────────────────────────────────────

  Widget _buildBalanceCard(
    BuildContext context,
    double? balance,
    DateTime? lastUpdated,
  ) {
    final cs = Theme.of(context).colorScheme;
    final balanceText = balance != null ? balance.toStringAsFixed(2) : '--';
    final timeText = lastUpdated != null
        ? '${lastUpdated.month}/${lastUpdated.day} '
              '${lastUpdated.hour.toString().padLeft(2, '0')}:'
              '${lastUpdated.minute.toString().padLeft(2, '0')} 更新'
        : '暂未获取余额';

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.credit_card_outlined, size: 18, color: cs.primary),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '校园卡余额',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
              const Spacer(),
              IconButton(
                tooltip: _obscured ? '显示余额' : '隐藏余额',
                onPressed: () => setState(() => _obscured = !_obscured),
                icon: Icon(
                  _obscured
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                ),
                iconSize: 20,
                color: cs.onSurfaceVariant,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '¥',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                _obscured ? '****' : balanceText,
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                  letterSpacing: -1,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (balance == null)
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: _balanceLoading ? null : _refreshBalance,
                icon: const Icon(Icons.touch_app_outlined, size: 18),
                label: Text(_balanceLoading ? '正在查询余额' : '点击查询余额'),
              ),
            )
          else
            Row(
              children: [
                Icon(Icons.schedule, size: 13, color: cs.onSurfaceVariant),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  timeText,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ],
            ),
        ],
      ),
    );
  }

  // ── Action Tiles ────────────────────────────────────────────────────────

  Widget _buildActionTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return AppTileSurface(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: 13,
      ),
      onTap: onTap,
      child: Row(
        children: [
          AppIconBadge(
            icon: icon,
            accentColor: cs.primary,
            size: AppIconBadgeSize.medium,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.25,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: cs.onSurfaceVariant.withValues(alpha: 0.45),
          ),
        ],
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
          loginDescription: '账号为校园一卡通号，校外网络自动通过 WebVPN 访问',
          prepareAuthenticatedUrl: CampusCardService.instance.prepareStatusPage,
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

    double? balance;
    try {
      balance = await CampusCardService.instance.fetchBalance(
        forceRefresh: true,
      );
    } catch (error, stackTrace) {
      AppLogger.instance.network(
        LogLevel.warn,
        '校园卡余额刷新异常',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      if (mounted) setState(() => _balanceLoading = false);
    }
    if (!mounted) return;

    if (!showFeedback) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          balance == null
              ? (CampusCardService.instance.cachedBalance == null
                    ? '余额查询失败，请检查网络或登录状态后重试'
                    : '刷新失败，仍显示上次余额，请切换网络后重试')
              : '校园卡余额已刷新',
        ),
      ),
    );
  }

  Future<void> _openRechargePage() async {
    if (!mounted) return;
    await CampusActionExecutor.instance.executeWechat(
      context,
      url: AppConfig.xiaofubaoRechargeUri.toString(),
      title: '一卡通充值',
      successMessage: '已跳转到微信，请在微信中完成充值',
      failureMessage: '未能打开页面，充值链接已复制，请到微信中打开',
      autoCopyOnFailure: true,
    );
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
