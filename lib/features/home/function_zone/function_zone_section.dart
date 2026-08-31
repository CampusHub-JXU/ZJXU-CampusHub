import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/feature_entry_catalog.dart';
import '../../../features/exam/exam_service.dart';
import '../../../features/grades/grades_service.dart';
import '../../../features/service_hub/service_hub_usage_store.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../../../shared/widgets/app_icon_badge.dart';
import '../../../shared/widgets/app_tile_surface.dart';
import 'function_zone_bento.dart';

/// 首页单滚动页底部的「功能」锚点段落：离散尺寸 Bento 网格。
///
/// 手机（2 units/行）整行瓦片只给 rank0 一名，其余 small 两两成行；
/// 宽屏（4 units/行）按 large / wide / small 三档组织（rank 制分配 +
/// 贪心打包见 function_zone_bento.dart）。使用/置顶数据复用
/// [ServiceHubUsageStore]；恢复过程只读本地缓存，绝不触网。
class FunctionZoneSection extends StatefulWidget {
  const FunctionZoneSection({
    super.key,
    required this.campusCardBalance,
    required this.dormElectricity,
    this.padding = EdgeInsets.zero,
  });

  /// 已格式化的一卡通余额（如 '¥38.20'；'--' 表示无数据，回退副标题）。
  final String campusCardBalance;

  /// 已格式化的宿舍剩余电量（如 '27.4 度'；'--' 表示无数据，回退副标题）。
  final String dormElectricity;

  final EdgeInsetsGeometry padding;

  @override
  State<FunctionZoneSection> createState() => _FunctionZoneSectionState();
}

class _FunctionZoneSectionState extends State<FunctionZoneSection> {
  final _usageStore = ServiceHubUsageStore.instance;

  @override
  void initState() {
    super.initState();
    _usageStore.addListener(_onUsageChanged);
    unawaited(_restoreOfflineData());
  }

  @override
  void dispose() {
    _usageStore.removeListener(_onUsageChanged);
    super.dispose();
  }

  void _onUsageChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// 离线恢复：使用/置顶数据 + 成绩缓存 + 考试缓存。
  ///
  /// 三者均只读 SharedPreferences，不发起任何网络请求；整体只调一次
  /// （ServiceHubUsageStore.restore 内部自带幂等保护）。完成后 setState
  /// 刷新瓦片尺寸分配与统计副文案。
  Future<void> _restoreOfflineData() async {
    try {
      await _usageStore.restore();
    } catch (_) {}
    try {
      await GradesService.instance.restoreCache();
    } catch (_) {}
    try {
      await ExamService.instance.restoreCache();
    } catch (_) {}
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _openEntry(FeatureEntryDefinition entry) async {
    await _usageStore.recordVisit(entry.id);
    if (!mounted) return;
    await context.pushNamed(entry.routeName);
  }

  Future<void> _togglePinned(FeatureEntryDefinition entry) async {
    final wasPinned = _usageStore.snapshot.isPinned(entry.id);
    await _usageStore.togglePinned(entry.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            wasPinned ? '已取消置顶 ${entry.title}' : '已置顶 ${entry.title}',
          ),
        ),
      );
  }

  /// 解析入口的统计副文案；返回 null 表示无可用统计，回退 entry.subtitle。
  String? _resolveStats(FeatureEntryDefinition entry) {
    switch (entry.id) {
      case 'grades':
        // 只读成绩缓存计算加权绩点与已修学分；无有效缓存时回退副标题。
        return formatGradeStats(GradesService.instance.cachedGrades);
      case 'exam':
        final exam = ExamService.instance.nextExam;
        if (exam == null) return null;
        return '${exam.countdownLabel} · ${exam.courseName}';
      case 'campus-card':
        final balance = widget.campusCardBalance;
        return balance == '--' ? null : balance;
      case 'dorm-electricity':
        final electricity = widget.dormElectricity;
        return electricity == '--' ? null : electricity;
      default:
        return null;
    }
  }

  BentoUsageInput _buildUsageInput() {
    final snapshot = _usageStore.snapshot;
    return BentoUsageInput(
      pinnedIds: snapshot.pinnedIds,
      visitCountById: {
        for (final usage in snapshot.usageById.values)
          usage.id: usage.visitCount,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = AppFeaturesConfig.entries;
    if (entries.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _FunctionZoneHeader(),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              return _BentoGrid(
                entries: entries,
                usage: _buildUsageInput(),
                resolveStats: _resolveStats,
                availableWidth: constraints.maxWidth,
                onTap: _openEntry,
                onLongPress: _togglePinned,
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 段落头：左「功能」，右「长按置顶」提示。
class _FunctionZoneHeader extends StatelessWidget {
  const _FunctionZoneHeader();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          '功能',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        const Spacer(),
        Text(
          '长按置顶',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Bento 网格：unit 网格布局（紧凑 2 units/行，宽屏 4 units/行）。
///
/// 瓦片尺寸由 [assignBentoTiles] 分配、占位由 [packBentoTiles] 打包后，
/// 用 Stack + Positioned 按精确像素摆放（unit 宽度由可用宽度均分，
/// unit 高度随文字缩放放大，与功能页 tile 高度策略一致）。
class _BentoGrid extends StatelessWidget {
  const _BentoGrid({
    required this.entries,
    required this.usage,
    required this.resolveStats,
    required this.availableWidth,
    required this.onTap,
    required this.onLongPress,
  });

  final List<FeatureEntryDefinition> entries;
  final BentoUsageInput usage;
  final String? Function(FeatureEntryDefinition entry) resolveStats;
  final double availableWidth;
  final Future<void> Function(FeatureEntryDefinition entry) onTap;
  final Future<void> Function(FeatureEntryDefinition entry) onLongPress;

  static const double _gap = AppSpacing.gridGap;

  /// 行高按瓦片尺寸分档：行式布局下徽标是高度驱动项——半宽 small 60
  /// （36px 徽标 + 单行标题），整行 wide 76（40px 徽标 + 标题 + 统计两行
  /// 的 hero 档）；大字号按线性系数放大并设上限防溢出。
  static const double _baseSmallHeight = 60;
  static const double _baseWideHeight = 76;

  @override
  Widget build(BuildContext context) {
    if (!availableWidth.isFinite || availableWidth <= 0) {
      return const SizedBox.shrink();
    }
    // 紧凑（宽 <600）= 2 units/行；宽 ≥600 = 4 units/行。
    final unitsPerRow = availableWidth >= 600 ? 4 : 2;
    final unitWidth = (availableWidth - (unitsPerRow - 1) * _gap) / unitsPerRow;

    // 行布局下随文字缩放的是标题+统计列（≈38px × scale），系数 30 覆盖
    // 1.8× 满档不溢出。
    final textScale = MediaQuery.textScalerOf(context)
        .scale(1)
        .clamp(1.0, 1.8)
        .toDouble();
    final scaleDelta = (textScale - 1) * 30;
    final smallHeight = (_baseSmallHeight + scaleDelta).clamp(
      _baseSmallHeight,
      92.0,
    );
    final wideHeight = (_baseWideHeight + scaleDelta).clamp(
      _baseWideHeight,
      104.0,
    );
    // large（2×2）跨两行，行高由同行 small/wide 决定，不单独驱动。
    double heightForSize(BentoTileSize size) =>
        size == BentoTileSize.wide ? wideHeight : smallHeight;

    final tiles = assignBentoTiles(
      [
        for (final entry in entries)
          BentoEntryInput(id: entry.id, sortOrder: entry.sortOrder),
      ],
      usage,
      unitsPerRow: unitsPerRow,
    );
    final placements = packBentoTiles(tiles, unitsPerRow: unitsPerRow);
    if (placements.isEmpty) return const SizedBox.shrink();

    final entryById = {for (final entry in entries) entry.id: entry};
    // 实时统计一次性解析：null 表示该入口无可用数据，瓦片回退静态描述。
    final liveStatsById = {
      for (final entry in entries) entry.id: resolveStats(entry),
    };
    var rowCount = 0;
    for (final placement in placements) {
      final bottom = placement.row + placement.rowSpan;
      if (bottom > rowCount) rowCount = bottom;
    }

    // 每行行高 = 该行单行瓦片的最高档（large 跨行不参与）。
    final rowHeights = List<double>.filled(rowCount, smallHeight);
    for (final placement in placements) {
      if (placement.rowSpan != 1) continue;
      final height = heightForSize(placement.tile.size);
      if (height > rowHeights[placement.row]) {
        rowHeights[placement.row] = height;
      }
    }
    final rowTops = <double>[];
    var accumulated = 0.0;
    for (var row = 0; row < rowCount; row++) {
      rowTops.add(accumulated);
      accumulated += rowHeights[row] + _gap;
    }
    final gridHeight = accumulated - _gap;

    double placementHeight(BentoPlacement placement) {
      if (placement.rowSpan == 1) return rowHeights[placement.row];
      var spanned = 0.0;
      for (
        var row = placement.row;
        row < placement.row + placement.rowSpan;
        row++
      ) {
        spanned += rowHeights[row];
      }
      return spanned + (placement.rowSpan - 1) * _gap;
    }

    return SizedBox(
      height: gridHeight,
      width: double.infinity,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final placement in placements)
            if (entryById[placement.tile.id] case final entry?)
              Positioned(
                left: placement.col * (unitWidth + _gap),
                top: rowTops[placement.row],
                width:
                    placement.colSpan * unitWidth +
                    (placement.colSpan - 1) * _gap,
                height: placementHeight(placement),
                child: _FunctionZoneTile(
                  entry: entry,
                  size: placement.tile.size,
                  pinned: usage.pinnedIds.contains(placement.tile.id),
                  statsText: liveStatsById[entry.id] ?? entry.subtitle,
                  liveStats: liveStatsById[entry.id] != null,
                  onTap: () => unawaited(onTap(entry)),
                  onLongPress: () => unawaited(onLongPress(entry)),
                ),
              ),
        ],
      ),
    );
  }
}

/// Bento 瓦片：AppTileSurface 平色卡面 + AppIconBadge 徽标的行式布局。
///
/// * small —— 36px 徽标 + 标题单行，垂直居中；
/// * wide  —— hero 档：40px 徽标 + 标题/统计两行 + 尾部 chevron，构成
///   段落锚点（手机上整行 rank0 与末行补丁瓦片）；
/// * large —— 平板 2×2 专属：徽标置顶、文字块沉底，统计最多两行。
/// 统计行分级强调：实时数据（绩点/倒计时/余额/电费）用 onSurface w600，
/// 无数据回退的静态描述保持 onSurfaceVariant 常规灰。
class _FunctionZoneTile extends StatelessWidget {
  const _FunctionZoneTile({
    required this.entry,
    required this.size,
    required this.pinned,
    required this.statsText,
    required this.liveStats,
    required this.onTap,
    required this.onLongPress,
  });

  final FeatureEntryDefinition entry;
  final BentoTileSize size;
  final bool pinned;
  final String statsText;

  /// [statsText] 是否为实时统计；false 表示回退的描述文案，弱化显示。
  final bool liveStats;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: entry.title,
      hint: entry.subtitle,
      child: AppTileSurface(
        borderRadius: AppRadius.tileBorder,
        // 垂直居中交给各档 body 的 Center 处理，这里只约束水平内边距。
        padding: const EdgeInsets.symmetric(horizontal: 14),
        onTap: onTap,
        onLongPress: onLongPress,
        child: switch (size) {
          BentoTileSize.large => _buildLargeBody(context),
          BentoTileSize.wide => _buildWideBody(context),
          BentoTileSize.small => _buildSmallBody(context),
        },
      ),
    );
  }

  /// small：徽标 + 标题，单行居中。Center(widthFactor: 1) 让 unit 多出的
  /// 高度上下均分，行内容始终垂直居中。
  Widget _buildSmallBody(BuildContext context) {
    return Center(
      widthFactor: 1,
      child: Row(
        children: [
          AppIconBadge(
            icon: entry.icon,
            accentColor: entry.accentColor,
            size: AppIconBadgeSize.small,
          ),
          const SizedBox(width: 10),
          Expanded(child: _buildTitleRow(context, fontSize: 15)),
        ],
      ),
    );
  }

  /// wide：hero 档 —— 40px 徽标 + 标题/统计两行 + 尾部 chevron。
  Widget _buildWideBody(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      widthFactor: 1,
      child: Row(
        children: [
          AppIconBadge(
            icon: entry.icon,
            accentColor: entry.accentColor,
            size: AppIconBadgeSize.medium,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTitleRow(context, fontSize: 16),
                const SizedBox(height: 3),
                // Flexible 防御：大字号下统计行优先被压缩省略，Column 不硬溢出。
                Flexible(child: _buildStatsText(context)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: cs.onSurfaceVariant.withValues(alpha: 0.45),
          ),
        ],
      ),
    );
  }

  /// large：badge 置顶，文字块沉底，统计最多两行。
  Widget _buildLargeBody(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppIconBadge(
          icon: entry.icon,
          accentColor: entry.accentColor,
          size: AppIconBadgeSize.medium,
        ),
        const Spacer(),
        _buildTitleRow(context, fontSize: 16),
        const SizedBox(height: 4),
        Flexible(child: _buildStatsText(context, maxLines: 2)),
      ],
    );
  }

  /// 标题行：置顶瓦片标题前加 12px 图钉（primary 色）。
  Widget _buildTitleRow(BuildContext context, {required double fontSize}) {
    return Row(
      children: [
        if (pinned) ...[
          Icon(
            Icons.push_pin_rounded,
            size: 12,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 4),
        ],
        Expanded(
          child: Text(
            entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // Apple semibold 字阶：正文级别的克制强调。
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ),
      ],
    );
  }

  /// 统计行：实时数据用 onSurface w600 强调（本段落的「活数据」价值点），
  /// 描述回退用 onSurfaceVariant 常规灰。
  Widget _buildStatsText(BuildContext context, {int maxLines = 1}) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall ?? const TextStyle();
    return Text(
      statsText,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: base.copyWith(
        fontSize: 13,
        height: 1.25,
        fontWeight: liveStats ? FontWeight.w600 : FontWeight.w400,
        color: liveStats
            ? theme.colorScheme.onSurface
            : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
