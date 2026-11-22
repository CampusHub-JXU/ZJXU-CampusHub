import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/actions/campus_action_executor.dart';
import '../../../core/config/feature_entry_catalog.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_theme_controller.dart';
import '../../../core/config/service_hub_usage_store.dart';
import '../../../shared/widgets/app_surface_style.dart';
import '../../../shared/widgets/app_tile_surface.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../../shared/widgets/app_search_field.dart';

/// 首页单滚动页底部的「功能」锚点段落：硬朗 Win10 马赛克磁贴网格（有主次层级）。
///
/// 结构：标题 → 搜索框 → 「常用」马赛克分组 → 按 [FeatureEntryCategory] 固定分类。
/// 输入关键词时分组收起，只显示匹配结果（标题 / 副标题 / 别名）。
///
/// 视觉与交互参考 Win10 开始屏幕马赛克设计：
/// - 主次分明（PRD §25）：仅「常用」排序 rank #1 的入口升级为唯一的 2×2 大磁贴，
///   其右侧由标准小磁贴填满两行；其余入口按 3 列（宽屏 4–5 列）基准网格
///   以 2×1 宽条（实时数据 / 置顶 / 补位）与 1×1 小方块混排，动态消除断行空洞。
/// - 高对比硬朗卡面：通过共享 [AppHardTileShell] 为 [AppTileSurface] 外套中性实底 +
///   浅色模式 `outline`/`onSurface` 1dp 细描边与轻微落底影（[AppRadius.control] 8dp squircle），
///   在 `#F3F4F6` 浅灰底上保持明确边界；零 BackdropFilter，避免重叠滤镜开销。
/// - 裸色图标：去掉圆角方块底座避免「框套框」，图标直接取主题主色（深色微提亮），
///   保持沉稳内敛的视觉节奏。
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

  /// 按 [columns] 列基准网格把 [entries] 编排为 2×1 宽条与 1×1 小方块混排：
  /// - [preferWideIds] 优先升级为 2×1；
  /// - 若末尾行存在空位则自动补升/降级 2×1 数量并局部重排，保证行满无断行空洞。
  List<({FeatureEntryDefinition entry, int span})> _planMosaicItems(
    List<FeatureEntryDefinition> entries, {
    required int columns,
    required Set<String> preferWideIds,
  }) {
    final n = entries.length;
    if (n == 0) return const [];
    if (n == 1) {
      final span = preferWideIds.contains(entries.first.id) && columns >= 2
          ? 2
          : 1;
      return [(entry: entries.first, span: span)];
    }

    final maxWidePerRow = columns ~/ 2;
    final preferredIndices = <int>[
      for (var i = 0; i < n; i++)
        if (preferWideIds.contains(entries[i].id)) i,
    ];
    final desiredWide = preferredIndices.length;

    // 寻找最接近 desiredWide 且能整除 columns（每行不超过 maxWidePerRow 个 2×1）的宽条数量。
    int? targetWide;
    var bestDiff = 1 << 30;
    for (var w = 0; w <= n; w++) {
      final totalCells = n + w;
      if (totalCells % columns != 0) continue;
      final rows = totalCells ~/ columns;
      if (w > rows * maxWidePerRow) continue;
      final diff = (w - desiredWide).abs();
      if (diff < bestDiff || (diff == bestDiff && w > (targetWide ?? -1))) {
        bestDiff = diff;
        targetWide = w;
      }
    }

    if (targetWide == null) {
      // 极少数无法整除的退化场景（例如 5 列下仅 2 项）：克制取偏好项并保序。
      var used = 0;
      return [
        for (final entry in entries)
          (
            entry: entry,
            span: preferWideIds.contains(entry.id) && used++ < maxWidePerRow
                ? 2
                : 1,
          ),
      ];
    }

    final wideIndexSet = <int>{};
    for (final idx in preferredIndices) {
      if (wideIndexSet.length >= targetWide) break;
      wideIndexSet.add(idx);
    }
    for (var i = 0; i < n && wideIndexSet.length < targetWide; i++) {
      wideIndexSet.add(i);
    }

    final queue = <({FeatureEntryDefinition entry, int span})>[
      for (var i = 0; i < n; i++)
        (entry: entries[i], span: wideIndexSet.contains(i) ? 2 : 1),
    ];

    var remWide = targetWide;
    var remSmall = n - targetWide;
    final planned = <({FeatureEntryDefinition entry, int span})>[];

    while (queue.isNotEmpty) {
      final remRows = (remSmall + 2 * remWide) ~/ columns;
      final minWideThisRow = math.max(
        0,
        remWide - (remRows - 1) * maxWidePerRow,
      );
      final maxWideThisRow = math.min(remWide, maxWidePerRow);
      final minWideBySmall = math.max(0, (columns - remSmall + 1) ~/ 2);
      final lowerWide = math.max(minWideThisRow, minWideBySmall);

      var prefixWide = 0;
      var prefixCells = 0;
      for (final item in queue) {
        if (prefixCells + item.span > columns) break;
        prefixCells += item.span;
        if (item.span == 2) prefixWide++;
      }

      final rowWide = prefixWide.clamp(lowerWide, maxWideThisRow);
      final rowSmall = columns - 2 * rowWide;

      var pickedWide = 0;
      var pickedSmall = 0;
      final remaining = <({FeatureEntryDefinition entry, int span})>[];
      for (final item in queue) {
        if (item.span == 2 && pickedWide < rowWide) {
          planned.add(item);
          pickedWide++;
        } else if (item.span == 1 && pickedSmall < rowSmall) {
          planned.add(item);
          pickedSmall++;
        } else {
          remaining.add(item);
        }
      }

      remWide -= rowWide;
      remSmall -= rowSmall;
      queue
        ..clear()
        ..addAll(remaining);
    }

    return planned;
  }

  Widget _buildMosaicTile(
    FeatureEntryDefinition entry, {
    required int span,
    required double itemWidth,
    required double unitHeight,
    required double gap,
  }) {
    final snapshot = _usageStore.snapshot;
    final pinned = snapshot.isPinned(entry.id);
    if (span == 2) {
      return SizedBox(
        width: 2 * itemWidth + gap,
        height: unitHeight,
        child: _WideFunctionTile(
          entry: entry,
          pinned: pinned,
          statsText: _resolveStats(entry),
          onTap: () => unawaited(_openEntry(entry)),
          onLongPress: () => unawaited(_togglePinned(entry)),
        ),
      );
    }
    return SizedBox(
      width: itemWidth,
      height: unitHeight,
      child: _SmallFunctionTile(
        entry: entry,
        pinned: pinned,
        onTap: () => unawaited(_openEntry(entry)),
        onLongPress: () => unawaited(_togglePinned(entry)),
      ),
    );
  }

  Widget _buildMosaicGrid(
    List<FeatureEntryDefinition> entries, {
    required int columns,
    required double itemWidth,
    required double unitHeight,
    required double gap,
    required Set<String> preferWideIds,
  }) {
    final items = _planMosaicItems(
      entries,
      columns: columns,
      preferWideIds: preferWideIds,
    );
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        for (final item in items)
          _buildMosaicTile(
            item.entry,
            span: item.span,
            itemWidth: itemWidth,
            unitHeight: unitHeight,
            gap: gap,
          ),
      ],
    );
  }

  Set<String> _defaultPreferWideIds(List<FeatureEntryDefinition> entries) {
    final snapshot = _usageStore.snapshot;
    return {
      for (final entry in entries)
        if (_resolveStats(entry) != null || snapshot.isPinned(entry.id))
          entry.id,
    };
  }

  List<Widget> _buildGroups({
    required int columns,
    required double itemWidth,
    required double unitHeight,
    required double gap,
  }) {
    final snapshot = _usageStore.snapshot;
    final common = _commonEntries();
    final primaryEntry = common.first;
    final rightColumns = math.max(1, columns - 2);
    // 右侧与 2×2 大磁贴并排的两行区容量：3 列时 2 个 1×1，4 列时 4 个，5 列时可混排至 6 格。
    final sideTargetCount = rightColumns == 1
        ? 2
        : rightColumns == 2
        ? 4
        : math.min(common.length - 1, 6);
    final sideEntries = common.skip(1).take(sideTargetCount).toList();
    final tailEntries = common.skip(1 + sideEntries.length).toList();
    final sideWidth =
        rightColumns * itemWidth + math.max(0, rightColumns - 1) * gap;
    final sidePreferWide = rightColumns >= 3 && sideEntries.length < 6
        ? _defaultPreferWideIds(sideEntries)
        : const <String>{};

    return [
      const _FunctionGroupLabel('常用'),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 2 * itemWidth + gap,
            height: 2 * unitHeight + gap,
            child: _LargeFunctionTile(
              entry: primaryEntry,
              pinned: snapshot.isPinned(primaryEntry.id),
              statsText: _resolveStats(primaryEntry) ?? primaryEntry.subtitle,
              onTap: () => unawaited(_openEntry(primaryEntry)),
              onLongPress: () => unawaited(_togglePinned(primaryEntry)),
            ),
          ),
          if (sideEntries.isNotEmpty) ...[
            SizedBox(width: gap),
            SizedBox(
              width: sideWidth,
              child: rightColumns >= 3
                  ? _buildMosaicGrid(
                      sideEntries,
                      columns: rightColumns,
                      itemWidth: itemWidth,
                      unitHeight: unitHeight,
                      gap: gap,
                      preferWideIds: sidePreferWide,
                    )
                  : Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final entry in sideEntries)
                          _buildMosaicTile(
                            entry,
                            span: 1,
                            itemWidth: itemWidth,
                            unitHeight: unitHeight,
                            gap: gap,
                          ),
                      ],
                    ),
            ),
          ],
        ],
      ),
      if (tailEntries.isNotEmpty) ...[
        SizedBox(height: gap),
        _buildMosaicGrid(
          tailEntries,
          columns: columns,
          itemWidth: itemWidth,
          unitHeight: unitHeight,
          gap: gap,
          preferWideIds: _defaultPreferWideIds(tailEntries),
        ),
      ],
      // 「常用」只是快捷方式：入口本体仍完整留在各自分类里。
      for (final category in FeatureEntryCategory.values)
        ..._buildCategory(
          category,
          AppFeaturesConfig.entries
              .where((entry) => entry.category == category)
              .toList(),
          columns: columns,
          itemWidth: itemWidth,
          unitHeight: unitHeight,
          gap: gap,
        ),
    ];
  }

  List<Widget> _buildCategory(
    FeatureEntryCategory category,
    List<FeatureEntryDefinition> entries, {
    required int columns,
    required double itemWidth,
    required double unitHeight,
    required double gap,
  }) {
    if (entries.isEmpty) return const [];
    entries.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final preferWide = {..._defaultPreferWideIds(entries), entries.first.id};
    return [
      const SizedBox(height: AppSpacing.md),
      _FunctionGroupLabel(category.label),
      _buildMosaicGrid(
        entries,
        columns: columns,
        itemWidth: itemWidth,
        unitHeight: unitHeight,
        gap: gap,
        preferWideIds: preferWide,
      ),
    ];
  }

  List<Widget> _buildSearchResults({
    required int columns,
    required double itemWidth,
    required double unitHeight,
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
      _buildMosaicGrid(
        results,
        columns: columns,
        itemWidth: itemWidth,
        unitHeight: unitHeight,
        gap: gap,
        preferWideIds: _defaultPreferWideIds(results),
      ),
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

          const gap = 6.0;
          final columns = maxWidth >= 840
              ? 5
              : maxWidth >= 600
              ? 4
              : 3;
          final itemWidth = math.max(
            0.0,
            (maxWidth - (columns - 1) * gap) / columns,
          );
          final unitHeight = math.min(
            82.0,
            math.max(itemWidth * 0.76, math.min(76.0, itemWidth)),
          );
          final searching = _query.trim().isNotEmpty;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _FunctionZoneHeader(),
              const SizedBox(height: AppSpacing.sm),
              _FunctionSearchTile(
                controller: _searchController,
                onChanged: _onQueryChanged,
                onClear: _clearQuery,
              ),
              const SizedBox(height: AppSpacing.md),
              if (searching)
                ..._buildSearchResults(
                  columns: columns,
                  itemWidth: itemWidth,
                  unitHeight: unitHeight,
                  gap: gap,
                )
              else
                ..._buildGroups(
                  columns: columns,
                  itemWidth: itemWidth,
                  unitHeight: unitHeight,
                  gap: gap,
                ),
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
    final radius = BorderRadius.circular(AppRadius.control);
    final focused = _focusNode.hasFocus;
    return TapRegion(
      // 把整张搜索卡面当成「输入框内部」：点击卡面内的图标 / 内边距 / 清除按钮
      // 不收起焦点；点击卡面外的页面空白、其它磁贴才收起。Android 真实触摸默认
      // 不会让 TextField 失焦（只隐藏键盘），故在此本地补足——作用范围仅限功能区
      // 搜索框，不改动其它 AppSearchField 调用方。
      onTapOutside: _handleTapDownOutside,
      onTapUpOutside: _handleTapUpOutside,
      child: AnimatedContainer(
        duration: AppMotion.reduced(context) ? Duration.zero : AppMotion.quick,
        foregroundDecoration: ShapeDecoration(
          shape: RoundedSuperellipseBorder(
            borderRadius: radius,
            side: focused
                ? BorderSide(color: cs.primary, width: 1.4)
                : BorderSide.none,
          ),
        ),
        child: AppHardTileShell(
          radius: AppRadius.control,
          child: AppTileSurface(
            borderRadius: radius,
            blurred: false,
            // 水平内边距与 _WideFunctionTile 一致（图标左缘对齐）；
            // 垂直收窄成细条，避免比磁贴还高显得臃肿。
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
      padding: const EdgeInsets.only(left: 2, bottom: 6),
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

/// 功能磁贴裸图标色：跟随主题主色（深色模式下微提亮 15% 以保证对比度）。
Color _resolveTileIconColor(BuildContext context, ColorScheme cs) {
  final base = AppThemeController.instance.resolveIconColor(
    context,
    cs.primary,
  );
  if (Theme.of(context).brightness == Brightness.dark) {
    return Color.lerp(base, Colors.white, 0.15) ?? base;
  }
  return base;
}

/// 2×2 大磁贴：Win10 常用主入口（rank #1），裸大号主色图标 + 底部标题与多行状态/说明。
class _LargeFunctionTile extends StatelessWidget {
  const _LargeFunctionTile({
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
    final iconColor = _resolveTileIconColor(context, cs);
    final label = _shortLabelById[entry.id] ?? entry.title;
    final radius = BorderRadius.circular(AppRadius.control);

    return Semantics(
      button: true,
      label: label,
      hint: entry.subtitle,
      child: AppHardTileShell(
        radius: AppRadius.control,
        child: AppTileSurface(
          borderRadius: radius,
          padding: const EdgeInsets.all(12),
          blurred: false,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(entry.icon, size: 34, color: iconColor),
                  const Spacer(),
                  if (pinned) ...[
                    Icon(Icons.push_pin_rounded, size: 13, color: cs.primary),
                    const SizedBox(width: 4),
                  ],
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.45),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.appText.rowTitleStrong.copyWith(height: 1.15),
              ),
              const SizedBox(height: 3),
              Text(
                statsText,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.appText.meta.copyWith(height: 1.2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 2×1 宽磁贴：Win10 宽版磁贴形态（[AppRadius.control]），裸图标 + 标题、可选实时状态与微箭头。
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
  final String? statsText;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final iconColor = _resolveTileIconColor(context, cs);
    final label = _shortLabelById[entry.id] ?? entry.title;
    final radius = BorderRadius.circular(AppRadius.control);

    return Semantics(
      button: true,
      label: label,
      hint: entry.subtitle,
      child: AppHardTileShell(
        radius: AppRadius.control,
        child: AppTileSurface(
          borderRadius: radius,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          blurred: false,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Row(
            children: [
              Icon(entry.icon, size: 26, color: iconColor),
              const SizedBox(width: 12),
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
                            style: context.appText.rowTitle.copyWith(
                              height: 1.15,
                            ),
                          ),
                        ),
                        if (pinned) ...[
                          const SizedBox(width: 4),
                          Icon(
                            Icons.push_pin_rounded,
                            size: 12,
                            color: cs.primary,
                          ),
                        ],
                      ],
                    ),
                    if (statsText != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        statsText!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.appText.meta.copyWith(height: 1.15),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: cs.onSurfaceVariant.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 1×1 标准磁贴：Win10 紧凑小方块（[AppRadius.control]），裸图标在上、标题在下居中。
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
    final iconColor = _resolveTileIconColor(context, cs);
    final label = _shortLabelById[entry.id] ?? entry.title;
    final radius = BorderRadius.circular(AppRadius.control);

    return Semantics(
      button: true,
      label: label,
      hint: entry.subtitle,
      child: AppHardTileShell(
        radius: AppRadius.control,
        child: AppTileSurface(
          borderRadius: radius,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          blurred: false,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(entry.icon, size: 26, color: iconColor),
                    const SizedBox(height: 6),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall!
                          .copyWith(height: 1.15, color: cs.onSurface),
                    ),
                  ],
                ),
              ),
              if (pinned)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Icon(
                    Icons.push_pin_rounded,
                    size: 11,
                    color: cs.primary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
