import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/actions/campus_action_executor.dart';
import '../../../core/config/feature_entry_catalog.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_theme_controller.dart';
import '../../../features/service_hub/service_hub_usage_store.dart';
import '../../../shared/widgets/app_icon_badge.dart';
import '../../../shared/widgets/app_tile_surface.dart';

/// 首页单滚动页底部的「功能」锚点段落：圆润磁贴网格（有主次层级）。
///
/// 视觉与交互参考 Win10 磁贴设计并圆润化：
/// - 主次分明（PRD §25）：仅排序 rank #1 的入口升级为唯一的 Primary（宽）磁贴，
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
  final _usageStore = ServiceHubUsageStore.instance;

  @override
  void initState() {
    super.initState();
    _usageStore.addListener(_onUsageChanged);
    unawaited(_restoreUsage());
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
    await _usageStore.recordVisit(entry.id);
    if (!mounted) return;
    await CampusActionExecutor.instance.execute(context, entry.primaryActionId);
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

  /// 展示顺序：置顶优先，其余按访问频次降序、同频按目录 sortOrder。
  List<FeatureEntryDefinition> _orderedEntries() {
    final snapshot = _usageStore.snapshot;
    int visitCount(String id) => snapshot.usageById[id]?.visitCount ?? 0;
    final entries = [...AppFeaturesConfig.entries];
    entries.sort((a, b) {
      final pinnedA = snapshot.isPinned(a.id) ? 1 : 0;
      final pinnedB = snapshot.isPinned(b.id) ? 1 : 0;
      if (pinnedA != pinnedB) return pinnedB - pinnedA;
      final byVisits = visitCount(b.id).compareTo(visitCount(a.id));
      if (byVisits != 0) return byVisits;
      return a.sortOrder.compareTo(b.sortOrder);
    });
    return entries;
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

  @override
  Widget build(BuildContext context) {
    final entries = _orderedEntries();
    if (entries.isEmpty) return const SizedBox.shrink();

    final snapshot = _usageStore.snapshot;
    final primaryEntry = entries.first;
    final compactEntries = entries.skip(1).toList();

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

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _FunctionZoneHeader(),
              const SizedBox(height: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _WideFunctionTile(
                    entry: primaryEntry,
                    pinned: snapshot.isPinned(primaryEntry.id),
                    statsText:
                        _resolveStats(primaryEntry) ?? primaryEntry.subtitle,
                    onTap: () => unawaited(_openEntry(primaryEntry)),
                    onLongPress: () => unawaited(_togglePinned(primaryEntry)),
                  ),
                  if (compactEntries.isNotEmpty) ...[
                    const SizedBox(height: gap),
                    Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final entry in compactEntries)
                          SizedBox(
                            width: itemWidth,
                            child: _SmallFunctionTile(
                              entry: entry,
                              pinned: snapshot.isPinned(entry.id),
                              onTap: () => unawaited(_openEntry(entry)),
                              onLongPress: () =>
                                  unawaited(_togglePinned(entry)),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ],
          );
        },
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
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                            color: cs.onSurface,
                          ),
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
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.25,
                      color: cs.onSurfaceVariant,
                    ),
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
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                        color: cs.onSurface,
                      ),
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
