import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/feature_entry_catalog.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/glass_style_controller.dart';
import '../../../features/exam/exam_service.dart';
import '../../../features/grades/grades_service.dart';
import '../../../features/service_hub/service_hub_usage_store.dart';
import '../../../shared/widgets/app_icon_badge.dart';
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
    final entries = FeatureEntryCatalog.instance.entriesByPlacement(
      FeatureEntryPlacement.serviceHub,
    );
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
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontSize: 12,
            color: cs.onSurfaceVariant,
          ),
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

  /// 单个 grid unit 的基础高度：以 wide 瓦片（small 徽标 + 标题 + 一行
  /// 副文案）的内容高度为下限；文字放大时按线性系数放大（同功能页 tile
  /// 策略）。
  static const double _baseUnitHeight = 112;

  @override
  Widget build(BuildContext context) {
    if (!availableWidth.isFinite || availableWidth <= 0) {
      return const SizedBox.shrink();
    }
    // 紧凑（宽 <600）= 2 units/行；宽 ≥600 = 4 units/行。
    final unitsPerRow = availableWidth >= 600 ? 4 : 2;
    final unitWidth = (availableWidth - (unitsPerRow - 1) * _gap) / unitsPerRow;
    final unitHeight = _resolveUnitHeight(context);

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
    var rowCount = 0;
    for (final placement in placements) {
      final bottom = placement.row + placement.rowSpan;
      if (bottom > rowCount) rowCount = bottom;
    }
    final gridHeight = rowCount * unitHeight + (rowCount - 1) * _gap;

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
                top: placement.row * (unitHeight + _gap),
                width: placement.colSpan * unitWidth +
                    (placement.colSpan - 1) * _gap,
                height: placement.rowSpan * unitHeight +
                    (placement.rowSpan - 1) * _gap,
                child: _FunctionZoneTile(
                  entry: entry,
                  size: placement.tile.size,
                  pinned: usage.pinnedIds.contains(placement.tile.id),
                  statsText: resolveStats(entry) ?? entry.subtitle,
                  onTap: () => unawaited(onTap(entry)),
                  onLongPress: () => unawaited(onLongPress(entry)),
                ),
              ),
        ],
      ),
    );
  }

  double _resolveUnitHeight(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context)
        .scale(1)
        .clamp(1.0, 1.8)
        .toDouble();
    return (_baseUnitHeight + (textScale - 1) * 40)
        .clamp(_baseUnitHeight, 156.0)
        .toDouble();
  }
}

/// Bento 瓦片：尺寸越大信息越多（progressive disclosure）。
///
/// * small —— 小徽标 + 标题；
/// * wide  —— 追加一行统计副文案（maxLines 1）；
/// * large —— 追加两行统计（maxLines 2），文字块沉底撑满大瓦片。
class _FunctionZoneTile extends StatelessWidget {
  const _FunctionZoneTile({
    required this.entry,
    required this.size,
    required this.pinned,
    required this.statsText,
    required this.onTap,
    required this.onLongPress,
  });

  final FeatureEntryDefinition entry;
  final BentoTileSize size;
  final bool pinned;
  final String statsText;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: entry.title,
      hint: entry.subtitle,
      child: _BentoGlassSurface(
        borderRadius: AppRadius.tileBorder,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          customBorder: RoundedSuperellipseBorder(
            borderRadius: AppRadius.tileBorder,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 13),
            child: switch (size) {
              BentoTileSize.large => _buildLargeBody(context),
              BentoTileSize.wide => _buildWideBody(context),
              BentoTileSize.small => _buildSmallBody(context),
            },
          ),
        ),
      ),
    );
  }

  /// small：小徽标 + 标题。
  Widget _buildSmallBody(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppIconBadge(
          icon: entry.icon,
          accentColor: entry.accentColor,
          size: AppIconBadgeSize.small,
        ),
        const SizedBox(height: 8),
        _buildTitleRow(context),
      ],
    );
  }

  /// wide：small 的基础上追加一行统计副文案。
  Widget _buildWideBody(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppIconBadge(
          icon: entry.icon,
          accentColor: entry.accentColor,
          size: AppIconBadgeSize.small,
        ),
        const SizedBox(height: 8),
        _buildTitleRow(context),
        const SizedBox(height: 3),
        // Flexible 防御：大字号下统计行优先被压缩省略，Column 不硬溢出。
        Flexible(
          child: Text(
            statsText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _statsStyle(context),
          ),
        ),
      ],
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
        _buildTitleRow(context),
        const SizedBox(height: 4),
        Flexible(
          child: Text(
            statsText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: _statsStyle(context),
          ),
        ),
      ],
    );
  }

  /// 标题行：置顶瓦片标题前加 12px 图钉（primary 色）。
  Widget _buildTitleRow(BuildContext context) {
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
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          ),
        ),
      ],
    );
  }

  TextStyle? _statsStyle(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Theme.of(context).textTheme.bodySmall?.copyWith(
      fontSize: 13,
      color: cs.onSurfaceVariant,
      height: 1.25,
    );
  }
}

/// Bento 瓦片专用纯 tint 玻璃表面（实现思路复制自功能页
/// _ServiceHubGlassSurface）：squircle 圆角 + tint 渐变 + 高光描边，
/// 不创建 BackdropFilter。玻璃开关与 tint 参数实时读取
/// [GlassStyleController]，关闭时降级为实色表面（同 GlassContainer 降级路径）。
class _BentoGlassSurface extends StatelessWidget {
  const _BentoGlassSurface({
    required this.borderRadius,
    required this.child,
  });

  final BorderRadius borderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: GlassStyleController.instance.enabled,
      builder: (context, glassEnabled, _) {
        return ValueListenableBuilder<double>(
          valueListenable: GlassStyleController.instance.tintOpacity,
          builder: (context, _, _) {
            return Material(
              color: Colors.transparent,
              child: Ink(
                decoration: _bentoGlassShapeDecoration(
                  context,
                  borderRadius: borderRadius,
                  glassEnabled: glassEnabled,
                ),
                child: child,
              ),
            );
          },
        );
      },
    );
  }
}

/// 与 GlassContainer card tier 相同的 tint 渐变 + 高光描边，纯 tint 无模糊。
ShapeDecoration _bentoGlassShapeDecoration(
  BuildContext context, {
  required BorderRadius borderRadius,
  required bool glassEnabled,
}) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  final isDark = theme.brightness == Brightness.dark;
  final baseColor = isDark ? cs.surfaceContainerLow : cs.surfaceContainerLowest;
  final borderColor = isDark
      ? Colors.white.withValues(alpha: glassEnabled ? 0.14 : 0.10)
      : cs.outlineVariant.withValues(alpha: glassEnabled ? 0.70 : 0.55);
  final shape = RoundedSuperellipseBorder(
    borderRadius: borderRadius,
    side: BorderSide(color: borderColor, width: isDark ? 0.8 : 1.0),
  );

  if (!glassEnabled) {
    return ShapeDecoration(color: baseColor, shape: shape);
  }

  // 玻璃 tint 与边缘高光合成为单一渐变：顶部受光面提亮更多，底部回光面
  // 几乎保持 tint 本色（与 GlassContainer._buildSurface 相同的合成方式）。
  Color tintWithHighlight(double highlightAlpha) => Color.alphaBlend(
    Colors.white.withValues(alpha: highlightAlpha),
    baseColor.withValues(
      alpha:
          GlassStyleController.instance.tintOpacity.value *
          (isDark ? 0.86 : 1.0),
    ),
  );

  return ShapeDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        tintWithHighlight(isDark ? 0.10 : 0.34),
        tintWithHighlight(isDark ? 0.02 : 0.08),
      ],
    ),
    shape: shape,
  );
}
