import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/auth/unified_auth.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/detail_readout.dart';
import '../../shared/widgets/plain_list.dart';
import '../../shared/widgets/refresh_status_line.dart';
import '../../shared/widgets/skeleton_box.dart';
import '../../shared/widgets/unified_auth_protected_webview_page.dart';
import 'campus_card_consumption.dart';
import 'campus_card_service.dart';

/// 校园卡账单原生页：卡内余额读数 + 今日/本周/本月概览 + 近期消费 +
/// 三餐占比 + 近七个消费日趋势。
///
/// 数据全部来自 [CampusCardService.fetchConsumption]（FineReport 账单快照，
/// 与官方 H5 账单同源）；「官方原页」入口打开受保护 WebView 作为兜底。
///
/// 状态机与余额页同契约（design-guidelines 4.5）：
/// * `initState` 先读 `cachedConsumption` 首帧直出；无缓存或缓存过期才发
///   `fetchConsumption()`，加载期间无缓存时用静态骨架（无循环动画）；
/// * 下拉 `forceRefresh`；无缓存失败态的「重试」先 `invalidateBillGateway`
///   再强刷；
/// * 刷新失败但已有数据：保留旧数据，`RefreshStatusLine` 显示「刷新失败」
///   + 行尾重试图标，并给一次轻提示；无数据则整页错误态 + 「去 H5 查看」。
class CampusCardBillPage extends StatefulWidget {
  const CampusCardBillPage({super.key, this.onOpenH5});

  /// 「官方原页」动作；为空时默认 push [UnifiedAuthProtectedWebViewPage]。
  /// 传入回调便于 widget 测试断言入口可达。
  final VoidCallback? onOpenH5;

  @override
  State<CampusCardBillPage> createState() => _CampusCardBillPageState();
}

class _CampusCardBillPageState extends State<CampusCardBillPage> {
  CampusCardConsumptionSummary? _summary;
  bool _loading = false;
  bool _refreshFailed = false;

  /// 近期消费日期：`yyyy-MM-dd`；解析失败的空日期由行内 subtitle 省略。
  static String _formatEntryDate(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  @override
  void initState() {
    super.initState();
    _summary = CampusCardService.instance.cachedConsumption;
    UnifiedAuthService.instance.addListener(_onAuthChanged);
    // 有缓存也要在后台补齐过期数据；无缓存则直接进入首次加载。
    if (_summary == null ||
        CampusCardService.instance.consumptionCacheIsStale) {
      unawaited(_refreshConsumption());
    }
  }

  @override
  void dispose() {
    UnifiedAuthService.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  /// 登录 / 登出 / 换号：service 已清缓存并作废在途请求，这里重新对齐
  /// 可见快照；新身份下无缓存且已登录则补拉一次。
  void _onAuthChanged() {
    if (!mounted) return;
    final loggedIn = UnifiedAuthService.instance.isLoggedIn;
    setState(() {
      _summary = loggedIn ? CampusCardService.instance.cachedConsumption : null;
      if (!loggedIn) _refreshFailed = false;
    });
    if (loggedIn && _summary == null) {
      unawaited(_refreshConsumption());
    }
  }

  /// 拉取账单快照。[resetGateway] 仅在无缓存失败态的显式重试使用——网关
  /// 会话可能已坏，先丢弃再重新建立。
  Future<void> _refreshConsumption({
    bool forceRefresh = false,
    bool resetGateway = false,
  }) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _refreshFailed = false;
    });
    if (resetGateway) {
      await CampusCardService.instance.invalidateBillGateway();
    }
    final summary = await CampusCardService.instance.fetchConsumption(
      forceRefresh: forceRefresh,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      // 失败不清已有缓存：请求被守卫丢弃（身份变化）时快照也随缓存更新。
      _summary = summary ?? CampusCardService.instance.cachedConsumption;
      _refreshFailed = summary == null;
    });
    if (summary == null && _summary != null) {
      AppFeedback.toast(context, '刷新失败，仍显示上次数据，请稍后重试');
    }
  }

  /// 无缓存失败态的重试：先丢弃账单网关会话再强刷。
  void _retryAfterFailure() {
    unawaited(_refreshConsumption(forceRefresh: true, resetGateway: true));
  }

  /// 「官方原页」：受保护 WebView 兜底（网关 + CAS 预热由
  /// [CampusCardService.prepareStatusPage] 统一负责）。
  Future<void> _openH5() async {
    final override = widget.onOpenH5;
    if (override != null) {
      override();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UnifiedAuthProtectedWebViewPage(
          title: '校园卡账单',
          url: CampusCardService.statusPageUrl,
          serviceUrl: CampusCardService.statusPageCasServiceUrl,
          loginDescription: '账号为校园一卡通号，校外网络自动通过 WebVPN 访问',
          authRequiredTitle: '需要登录一卡通后继续',
          authRequiredButtonLabel: '登录一卡通',
          prepareAuthenticatedUrl: CampusCardService.instance.prepareStatusPage,
          onHomePressed: () => GoRouter.maybeOf(context)?.goNamed('home'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    return Scaffold(
      appBar: AppAppBar(
        title: const Text('校园卡账单'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading
                ? null
                : () => unawaited(_refreshConsumption(forceRefresh: true)),
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: '官方原页',
            onPressed: () => unawaited(_openH5()),
            icon: const Icon(Icons.open_in_new_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refreshConsumption(forceRefresh: true),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 内容撑满视口高：保证任何状态下都能下拉刷新。
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.pageMargin,
                    AppSpacing.sm,
                    AppSpacing.pageMargin,
                    AppSpacing.xl,
                  ),
                  child: summary == null && !_loading
                      ? _buildFailureState(context)
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (summary == null)
                              _buildSkeleton(context)
                            else
                              _buildContent(context, summary),
                          ],
                        ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ── 失败态（完全无数据可展示）─────────────────────────────────────────

  Widget _buildFailureState(BuildContext context) {
    final loggedIn = UnifiedAuthService.instance.isLoggedIn;
    return Column(
      children: [
        const SizedBox(height: 80),
        AppErrorView(
          title: '账单获取失败',
          message: loggedIn ? '请检查网络后重试，或到官方账单页查看' : '需要登录统一认证后查看校园卡账单',
          icon: loggedIn ? Icons.cloud_off_rounded : Icons.lock_outline_rounded,
          onRetry: _retryAfterFailure,
          retryLabel: '重试',
        ),
        TextButton.icon(
          onPressed: () => unawaited(_openH5()),
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
          label: const Text('去官方页面查看'),
        ),
      ],
    );
  }

  // ── 无缓存首次加载骨架（静态，无循环动画）────────────────────────────

  Widget _buildSkeleton(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SkeletonBox(width: 72, height: 14),
        const SizedBox(height: AppSpacing.sm),
        const SkeletonBox(width: 200, height: 64, radius: 10),
        const SizedBox(height: AppSpacing.lg),
        const Row(
          children: [
            Expanded(child: SkeletonBox(height: 52)),
            SizedBox(width: AppSpacing.md),
            Expanded(child: SkeletonBox(height: 52)),
            SizedBox(width: AppSpacing.md),
            Expanded(child: SkeletonBox(height: 52)),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        const SkeletonBox(width: 96, height: 14),
        const SizedBox(height: AppSpacing.sm),
        const SkeletonBox(height: 180, radius: AppRadius.card),
        const SizedBox(height: AppSpacing.xl),
        const SkeletonBox(width: 160, height: 14),
        const SizedBox(height: AppSpacing.sm),
        const SkeletonBox(height: 120, radius: AppRadius.card),
      ],
    );
  }

  // ── 数据内容 ────────────────────────────────────────────────────────

  Widget _buildContent(
    BuildContext context,
    CampusCardConsumptionSummary summary,
  ) {
    final entries = summary.recent.take(5).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildOverview(context, summary),
        const SizedBox(height: AppSpacing.sm),
        RefreshStatusLine(
          updatedAt: summary.fetchedAt,
          refreshing: _loading,
          failed: _refreshFailed,
          onRefresh: () => unawaited(_refreshConsumption(forceRefresh: true)),
          refreshTooltip: '重试',
        ),
        if (entries.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xl),
          const PlainSectionHeader('近期消费'),
          PlainListGroup(
            children: [
              for (final entry in entries) _buildRecentRow(context, entry),
            ],
          ),
        ],
        if (summary.meals.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xl),
          const PlainSectionHeader('三餐占比 · 近七个消费日'),
          PlainListGroup(children: _buildMealRows(context, summary)),
        ],
        if (summary.dailyTrend.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xl),
          const PlainSectionHeader('消费趋势 · 近七个消费日'),
          PlainListGroup(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  kPlainListRowInset,
                  AppSpacing.md,
                  kPlainListRowInset,
                  AppSpacing.lg,
                ),
                child: _DailyTrendChart(days: summary.dailyTrend),
              ),
            ],
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        Text(
          '近七日指最近七个有消费的日期；数据来自官方校园卡账单。',
          style: context.appText.meta.copyWith(height: 1.4),
        ),
      ],
    );
  }

  /// 卡内余额读数 + 今日/本周/本月三列等宽概览（无框，数字为主角）。
  Widget _buildOverview(
    BuildContext context,
    CampusCardConsumptionSummary summary,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DetailReadout(
          label: '卡内余额',
          valueText: summary.cardBalance.toStringAsFixed(2),
          unit: '元',
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            _overviewStat(context, '今日消费', summary.todaySpend),
            const SizedBox(width: AppSpacing.md),
            _overviewStat(context, '本周消费', summary.weekSpend),
            const SizedBox(width: AppSpacing.md),
            _overviewStat(context, '本月消费', summary.monthSpend),
          ],
        ),
      ],
    );
  }

  Widget _overviewStat(BuildContext context, String label, double amount) {
    final text = context.appText;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.group,
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(amount.toStringAsFixed(2), style: text.rowValue),
                const SizedBox(width: AppSpacing.xs),
                Text('元', style: text.numUnitCompact),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 近期消费行：地点（无地点回退「消费」）+ 日期副标题；右侧等宽金额。
  Widget _buildRecentRow(
    BuildContext context,
    CampusCardConsumptionEntry entry,
  ) {
    final text = context.appText;
    final date = entry.date;
    return PlainListRow(
      title: entry.location.isEmpty ? '消费' : entry.location,
      subtitle: date == null ? null : _formatEntryDate(date),
      showChevron: false,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          // 行内金额走 O3 紧凑读数档（20 w700 等宽），比 24 行值更适合列表行。
          Text(
            entry.amount.toStringAsFixed(2),
            style: AppCompactMetricType.value,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text('元', style: text.numUnitCompact),
        ],
      ),
    );
  }

  /// 三餐占比行：餐次 + 比例条（primary/secondary/tertiary 轮换）+
  /// 右侧金额与占比。
  List<Widget> _buildMealRows(
    BuildContext context,
    CampusCardConsumptionSummary summary,
  ) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    Color barColor(int index) => switch (index % 3) {
      0 => cs.primary,
      1 => cs.secondary,
      _ => cs.tertiary,
    };
    final total = summary.meals.fold<double>(0, (sum, m) => sum + m.amount);
    return [
      for (var i = 0; i < summary.meals.length; i++)
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kPlainListRowInset,
            vertical: 10,
          ),
          child: Row(
            children: [
              Text(summary.meals[i].label, style: text.body),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: DetailLevelBar(
                  fraction: summary.mealPeak <= 0
                      ? 0
                      : summary.meals[i].amount / summary.mealPeak,
                  color: barColor(i),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${summary.meals[i].amount.toStringAsFixed(2)} 元',
                    maxLines: 1,
                    style: text.body.copyWith(
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    total <= 0
                        ? '--'
                        : '${(summary.meals[i].amount / total * 100).round()}%',
                    maxLines: 1,
                    style: text.meta.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
    ];
  }
}

/// 近七个消费日的柱状图：每日金额（顶）+ 比例柱 + 日期与笔数（底）。
/// 等宽列 + FittedBox 数值，360px 窄屏与放大多级字号下不溢出。
class _DailyTrendChart extends StatelessWidget {
  const _DailyTrendChart({required this.days});

  final List<CampusCardDaySpend> days;

  static const double _barAreaHeight = 112;
  static const double _minBarHeight = 6;

  @override
  Widget build(BuildContext context) {
    final peak = days.fold<double>(
      0,
      (max, day) => day.amount > max ? day.amount : max,
    );
    return SizedBox(
      height: _barAreaHeight + 46,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < days.length; i++) ...[
            if (i > 0) const SizedBox(width: AppSpacing.sm),
            Expanded(child: _dayColumn(context, days[i], peak)),
          ],
        ],
      ),
    );
  }

  Widget _dayColumn(BuildContext context, CampusCardDaySpend day, double peak) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final fraction = peak <= 0 ? 0.0 : day.amount / peak;
    final barHeight = day.amount <= 0
        ? _minBarHeight
        : (fraction * _barAreaHeight).clamp(_minBarHeight, _barAreaHeight);
    return Column(
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            day.amount.toStringAsFixed(2),
            maxLines: 1,
            style: text.meta.copyWith(
              color: cs.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Expanded(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: 18,
              height: barHeight.toDouble(),
              decoration: BoxDecoration(
                color: day.amount <= 0
                    ? cs.surfaceContainerHighest
                    : cs.primary,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            day.count > 0 ? '${day.label} · ${day.count}笔' : day.label,
            maxLines: 1,
            style: text.tag.copyWith(fontWeight: FontWeight.w400),
          ),
        ),
      ],
    );
  }
}
