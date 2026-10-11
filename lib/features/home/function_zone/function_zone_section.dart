import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../core/actions/campus_action_executor.dart';
import '../../../core/config/feature_entry_catalog.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_theme_controller.dart';
import '../../../core/config/service_hub_usage_store.dart';
import '../../../shared/widgets/app_icon_badge.dart';
import '../../../shared/widgets/app_tile_surface.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../../shared/widgets/app_search_field.dart';

/// 首页单滚动页底部的「功能」锚点段落：圆润磁贴网格（有主次层级）。
///
/// 结构：标题 → 搜索框 → 「常用」分组 → 按 [FeatureEntryCategory] 固定分类。
/// 输入关键词时分组收起，只显示匹配结果（标题 / 副标题 / 别名）。
///
/// 视觉与交互参考 Win10 磁贴设计并圆润化：
/// - 主次分明（PRD §25）：仅「常用」排序 rank #1 的入口升级为唯一的 Primary（宽）磁贴，
///   其余入口都是 Compact 磁贴网格（手机 2 列 / 宽屏 3-4 列）；不再出现多个
///   宽磁贴连续，也不再因奇数项把最后一个自动升级。
/// - 淡淡圆角毛玻璃：使用现有表面机制 [AppTileSurface]（平色填充 / 半透明 tint +
///   柔和落底阴影 + squircle 圆角），零 BackdropFilter，避免每格重叠滤镜导致 GPU 开销。
/// - 非语义图标统一主题色：入口徽标统一跟随主题主色，保持沉稳内敛的视觉节奏。
class FunctionZoneSection extends StatefulWidget {
  const FunctionZoneSection({
    super.key,
    this.campusCardBalance = '--',
    this.dormElectricity = '--',
    this.padding = EdgeInsets.zero,
  });

  final String campusCardBalance;
  final String dormElectricity;
  final EdgeInsetsGeometry padding;

  @override
  State<FunctionZoneSection> createState() => _FunctionZoneSectionState();
}

class _FunctionZoneSectionState extends State<FunctionZoneSection> {
  /// 「常用」分组至少展示的数量（1 宽磁贴 + 4 小磁贴）；置顶项总会全部进入。
  static const _commonMinCount = 5;

  /// 新装 / 尚无使用记录时「常用」的兜底入口，按顺序补位。
  static const _defaultCommonIds = <String>[
    'schedule',
    'grades',
    'exam',
    'campus-card',
    'dorm-electricity',
  ];

  final _usageStore = ServiceHubUsageStore.instance;
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _usageStore.addListener(_onUsageChanged);
    unawaited(_restoreUsage());
  }

  @override
  void dispose() {
    _usageStore.removeListener(_onUsageChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onUsageChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// 离线恢复使用/置顶数据：只读 SharedPreferences，不发起任何网络请求；
  /// ServiceHubUsageStore.restore 内部自带幂等保护。
  Future<void> _restoreUsage() async {
    try {
      await _usageStore.restore();
    } catch (_) {}
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _openEntry(FeatureEntryDefinition entry) async {
    FocusScope.of(context).unfocus();
    await _usageStore.recordVisit(entry.id);
    if (!mounted) return;
    await CampusActionExecutor.instance.execute(context, entry.primaryActionId);
  }

  Future<void> _togglePinned(FeatureEntryDefinition entry) async {
    final wasPinned = _usageStore.snapshot.isPinned(entry.id);
    await _usageStore.togglePinned(entry.id);
    if (!mounted) return;
    AppFeedback.toast(
      context,
      wasPinned ? '已取消置顶 ${entry.title}' : '已置顶 ${entry.title}',
    );
  }

  void _onQueryChanged(String value) {
    setState(() => _query = value);
  }

  void _clearQuery() {
    _searchController.clear();
    setState(() => _query = '');
  }

  /// 「常用」分组：置顶优先，其次按访问频次降序（同频按目录 sortOrder），
  /// 不足 [_commonMinCount] 时用 [_defaultCommonIds] 补位。
  List<FeatureEntryDefinition> _commonEntries() {
    final snapshot = _usageStore.snapshot;
    int visitCount(String id) => snapshot.usageById[id]?.visitCount ?? 0;
    final ranked = [...AppFeaturesConfig.entries]
      ..sort((a, b) {
        final pinnedA = snapshot.isPinned(a.id) ? 1 : 0;
        final pinnedB = snapshot.isPinned(b.id) ? 1 : 0;
        if (pinnedA != pinnedB) return pinnedB - pinnedA;
        final byVisits = visitCount(b.id).compareTo(visitCount(a.id));
        if (byVisits != 0) return byVisits;
        return a.sortOrder.compareTo(b.sortOrder);
      });

    final common = <FeatureEntryDefinition>[
      for (final entry in ranked)
        if (snapshot.isPinned(entry.id)) entry,
    ];
    for (final entry in ranked) {
      if (common.length >= _commonMinCount) break;
      if (visitCount(entry.id) > 0 && !common.contains(entry)) {
        common.add(entry);
      }
    }
    for (final id in _defaultCommonIds) {
      if (common.length >= _commonMinCount) break;
      final entry = AppFeaturesConfig.entries
          .where((entry) => entry.id == id)
          .firstOrNull;
      if (entry != null && !common.contains(entry)) common.add(entry);
    }
    return common;
  }

  /// 搜索：按空白拆词，每个词都要命中标题 / 短标签 / 副标题 / 别名之一，
  /// 忽略大小写；结果按目录 sortOrder 排列。
  List<FeatureEntryDefinition> _searchResults(String query) {
    final terms = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toList();
    if (terms.isEmpty) return const [];
    final results = AppFeaturesConfig.entries.where((entry) {
      final haystack = [
        entry.title,
        _shortLabelById[entry.id] ?? '',
        entry.subtitle,
        ...entry.keywords,
      ].join('\n').toLowerCase();
      return terms.every(haystack.contains);
    }).toList()..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return results;
  }

  /// 实时统计副文案：一卡通余额 / 宿舍电费在宽磁贴中提供有用增量信息。
  String? _resolveStats(FeatureEntryDefinition entry) {
    switch (entry.id) {
      case 'campus-card':
        final balance = widget.campusCardBalance;
        return balance == '--' ? null : '余额 $balance';
      case 'dorm-electricity':
        final electricity = widget.dormElectricity;
        return electricity == '--' ? null : '剩余电量 $electricity';
      default:
        return null;
    }
  }

  Widget _buildGrid(
    List<FeatureEntryDefinition> entries, {
    required double itemWidth,
    required double gap,
  }) {
    final snapshot = _usageStore.snapshot;
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        for (final entry in entries)
          SizedBox(
            width: itemWidth,
            child: _SmallFunctionTile(
              entry: entry,
              pinned: snapshot.isPinned(entry.id),
              onTap: () => unawaited(_openEntry(entry)),
              onLongPress: () => unawaited(_togglePinned(entry)),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildGroups({required double itemWidth, required double gap}) {
    final snapshot = _usageStore.snapshot;
    final common = _commonEntries();
    final primaryEntry = common.first;

    return [
      const _FunctionGroupLabel('常用'),
      _WideFunctionTile(
        entry: primaryEntry,
        pinned: snapshot.isPinned(primaryEntry.id),
        statsText: _resolveStats(primaryEntry) ?? primaryEntry.subtitle,
        onTap: () => unawaited(_openEntry(primaryEntry)),
        onLongPress: () => unawaited(_togglePinned(primaryEntry)),
      ),
      if (common.length > 1) ...[
        SizedBox(height: gap),
        _buildGrid(common.skip(1).toList(), itemWidth: itemWidth, gap: gap),
      ],
      // 「常用」只是快捷方式：入口本体仍完整留在各自分类里。
      for (final category in FeatureEntryCategory.values)
        ..._buildCategory(
          category,
          AppFeaturesConfig.entries
              .where((entry) => entry.category == category)
              .toList(),
          itemWidth: itemWidth,
          gap: gap,
        ),
    ];
  }

  List<Widget> _buildCategory(
    FeatureEntryCategory category,
    List<FeatureEntryDefinition> entries, {
    required double itemWidth,
    required double gap,
  }) {
    if (entries.isEmpty) return const [];
    entries.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return [
      const SizedBox(height: AppSpacing.lg),
      _FunctionGroupLabel(category.label),
      _buildGrid(entries, itemWidth: itemWidth, gap: gap),
    ];
  }

  List<Widget> _buildSearchResults({
    required double itemWidth,
    required double gap,
  }) {
    final results = _searchResults(_query);
    if (results.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
          child: Center(
            child: Text('没有找到相关功能', style: context.appText.secondary),
          ),
        ),
      ];
    }
    return [
      _FunctionGroupLabel('搜索结果 · ${results.length}'),
      _buildGrid(results, itemWidth: itemWidth, gap: gap),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (AppFeaturesConfig.entries.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: widget.padding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = constraints.maxWidth;
          if (maxWidth <= 0) return const SizedBox.shrink();

          const gap = 10.0;
          final columns = maxWidth >= 840
              ? 4
              : maxWidth >= 600
              ? 3
              : 2;
          final itemWidth = math.max(
            0.0,
            (maxWidth - (columns - 1) * gap) / columns,
          );
          final searching = _query.trim().isNotEmpty;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _FunctionZoneHeader(),
              const SizedBox(height: AppSpacing.md),
              _FunctionSearchTile(
                controller: _searchController,
                onChanged: _onQueryChanged,
                onClear: _clearQuery,
              ),
              const SizedBox(height: AppSpacing.md),
              if (searching)
                ..._buildSearchResults(itemWidth: itemWidth, gap: gap)
              else
                ..._buildGroups(itemWidth: itemWidth, gap: gap),
            ],
          );
        },
      ),
    );
  }
}

/// 功能搜索框：与功能磁贴同款亚克力卡面，读作功能区第一行；
/// 聚焦时卡面描边换成 primary 色作为输入提示。
class _FunctionSearchTile extends StatefulWidget {
  const _FunctionSearchTile({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  State<_FunctionSearchTile> createState() => _FunctionSearchTileState();
}

class _FunctionSearchTileState extends State<_FunctionSearchTile> {
  /// 由本卡面持有并交给内部 `TextField` 的真实焦点节点。聚焦描边只跟随它的
  /// `hasFocus`：旧实现用外层 `Focus.onFocusChange` 的布尔值，祖先 `hasFocus`
  /// 会把卡面内其它可聚焦后代（如文本出现后的清除按钮）也算作聚焦，输入框
  /// 本身已失焦时描边仍可能残留。
  final FocusNode _focusNode = FocusNode(debugLabel: 'FunctionSearchField');

  /// 落在搜索卡面之外的指针按下位置。用来区分「点击空白处」与「以空白处起手
  /// 的功能区滚动拖拽」：只有按下/抬起位移在系统触摸 slop 内才算点击并收起
  /// 焦点，滚动拖拽不收起，避免干扰滚动。
  Offset? _outsidePointerDown;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _handleTapDownOutside(PointerDownEvent event) {
    _outsidePointerDown = event.position;
  }

  void _handleTapUpOutside(PointerUpEvent event) {
    final down = _outsidePointerDown;
    _outsidePointerDown = null;
    // 位移超过 slop：用户在滚动 / 拖拽，不算点击，保留输入焦点。
    if (down == null || (event.position - down).distance > kTouchSlop) return;
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppRadius.tileBorder.topLeft.x);
    final focused = _focusNode.hasFocus;
    return TapRegion(
      // 把整张搜索卡面当成「输入框内部」：点击卡面内的图标 / 内边距 / 清除按钮
      // 不收起焦点；点击卡面外的页面空白、其它磁贴才收起。Android 真实触摸默认
      // 不会让 TextField 失焦（只隐藏键盘），故在此本地补足——作用范围仅限功能区
      // 搜索框，不改动其它 AppSearchField 调用方。
      onTapOutside: _handleTapDownOutside,
      onTapUpOutside: _handleTapUpOutside,
      child: AnimatedContainer(
        duration: AppMotion.reduced(context)
            ? Duration.zero
            : const Duration(milliseconds: 160),
        foregroundDecoration: ShapeDecoration(
          shape: RoundedSuperellipseBorder(
            borderRadius: radius,
            side: focused
                ? BorderSide(color: cs.primary, width: 1.4)
                : BorderSide.none,
          ),
        ),
        child: AppTileSurface(
          borderRadius: radius,
          // 水平内边距与 _SmallFunctionTile 一致（徽标 / 标题左缘对齐）；
          // 垂直收窄成 48dp 细条，避免比磁贴还高显得臃肿。
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: AppSearchField(
            controller: widget.controller,
            focusNode: _focusNode,
            hintText: '搜索功能，如 成绩、电费、请假',
            onChanged: widget.onChanged,
            onClear: widget.onClear,
            borderless: true,
          ),
        ),
      ),
    );
  }
}

/// 分组标题：「常用」/ 分类名 / 搜索结果计数。
class _FunctionGroupLabel extends StatelessWidget {
  const _FunctionGroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: AppSpacing.sm),
      child: Text(text, style: context.appText.label),
    );
  }
}

/// 段落头：左「功能」，右「长按置顶」提示。
class _FunctionZoneHeader extends StatelessWidget {
  const _FunctionZoneHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          '功能',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w700, height: 1.2),
        ),
        const Spacer(),
        Text('长按置顶', style: context.appText.meta),
      ],
    );
  }
}

/// 常用短标签映射：保持磁贴标题洗练短小、不折行。
const _shortLabelById = <String, String>{
  'schedule': '课表',
  'grades': '成绩',
  'exam': '考试',
  'shuati-practice': '刷题',
  'campus-card-payment': '付款码',
};

/// 宽磁贴：Win10 宽版磁贴形态，圆润边角，含中号徽标、标题、状态说明与微箭头。
class _WideFunctionTile extends StatelessWidget {
  const _WideFunctionTile({
    required this.entry,
    required this.pinned,
    required this.statsText,
    required this.onTap,
    required this.onLongPress,
  });

  final FeatureEntryDefinition entry;
  final bool pinned;
  final String statsText;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final primaryIconColor = AppThemeController.instance.resolveIconColor(
      context,
      cs.primary,
    );
    final label = _shortLabelById[entry.id] ?? entry.title;

    return Semantics(
      button: true,
      label: label,
      hint: entry.subtitle,
      child: AppTileSurface(
        borderRadius: BorderRadius.circular(AppRadius.tileBorder.topLeft.x),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Row(
          children: [
            AppIconBadge(
              icon: entry.icon,
              accentColor: primaryIconColor,
              size: AppIconBadgeSize.medium,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.appText.rowTitle.copyWith(height: 1.2),
                        ),
                      ),
                      if (pinned) ...[
                        const SizedBox(width: 5),
                        Icon(
                          Icons.push_pin_rounded,
                          size: 12,
                          color: cs.primary,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    statsText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.appText.meta.copyWith(height: 1.25),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: cs.onSurfaceVariant.withValues(alpha: 0.45),
            ),
          ],
        ),
      ),
    );
  }
}

/// 标准磁贴：Win10 正方/横扁小磁贴圆润形态，小号徽标 + 标题垂直居中。
class _SmallFunctionTile extends StatelessWidget {
  const _SmallFunctionTile({
    required this.entry,
    required this.pinned,
    required this.onTap,
    required this.onLongPress,
  });

  final FeatureEntryDefinition entry;
  final bool pinned;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final primaryIconColor = AppThemeController.instance.resolveIconColor(
      context,
      cs.primary,
    );
    final label = _shortLabelById[entry.id] ?? entry.title;

    return Semantics(
      button: true,
      label: label,
      hint: entry.subtitle,
      child: AppTileSurface(
        borderRadius: BorderRadius.circular(AppRadius.tileBorder.topLeft.x),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Row(
          children: [
            AppIconBadge(
              icon: entry.icon,
              accentColor: primaryIconColor,
              size: AppIconBadgeSize.small,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall!
                          .copyWith(height: 1.2, color: cs.onSurface),
                    ),
                  ),
                  if (pinned) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.push_pin_rounded, size: 11, color: cs.primary),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
