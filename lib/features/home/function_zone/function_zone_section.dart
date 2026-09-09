import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/feature_entry_catalog.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_theme_controller.dart';
import '../../../core/wechat/wechat_launcher.dart';
import '../../../features/service_hub/service_hub_usage_store.dart';
import '../../../shared/widgets/app_icon_badge.dart';
import '../../../shared/widgets/app_tile_surface.dart';

/// 首页单滚动页底部的「功能」锚点段落：圆润磁贴网格（有主次层级）。
///
/// 视觉与交互参考 Win10 磁贴设计并圆润化：
/// - 主次分明：置顶项与高频项升级为宽磁贴（展示徽标、标题、状态/副标题与前进箭头），
///   其余入口为两两成行的标准磁贴；末行孤单项自动升级为宽磁贴以保持网格饱满。
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

    final wechatH5Url = entry.wechatH5Url;
    if (wechatH5Url != null) {
      final opened = await WechatLauncher.instance.openUrl(wechatH5Url);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              opened ? '已跳转到微信，请在微信中打开${entry.title}' : '未能打开页面，可复制链接后到微信中打开',
            ),
            action: SnackBarAction(
              label: '复制链接',
              onPressed: () {
                if (!mounted) return;
                unawaited(_copyLink(wechatH5Url));
              },
            ),
          ),
        );
      return;
    }

    await context.pushNamed(entry.routeName);
  }

  Future<void> _copyLink(String url) async {
    var copied = false;
    try {
      await Clipboard.setData(ClipboardData(text: url));
      copied = true;
    } on PlatformException {
      copied = false;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(copied ? '链接已复制' : '复制失败')));
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
    final pinnedCount = entries.where((e) => snapshot.isPinned(e.id)).length;

    // 磁贴主次分级：置顶项优先升级为宽磁贴（最多 2 个）；若无置顶项，
    // 则将排在首位的最重要入口（rank 0）作为宽磁贴焦点。
    final primaryWideCount = pinnedCount > 0
        ? (pinnedCount > 2 ? 2 : pinnedCount)
        : 1;

    final wideEntries = entries.take(primaryWideCount).toList();
    final remainingEntries = entries.skip(primaryWideCount).toList();

    // 手机端两列排布：若剩余标准磁贴数为奇数，将最后一个升级为宽磁贴，末行保持整齐。
    final hasOrphan = remainingEntries.length.isOdd;
    FeatureEntryDefinition? orphanWideEntry;
    List<FeatureEntryDefinition> standardEntries;
    if (hasOrphan) {
      orphanWideEntry = remainingEntries.last;
      standardEntries = remainingEntries.sublist(
        0,
        remainingEntries.length - 1,
      );
    } else {
      standardEntries = remainingEntries;
    }

    return Padding(
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _FunctionZoneHeader(),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 10.0;
              final isWideScreen = constraints.maxWidth >= 600;

              if (isWideScreen) {
                return _buildWideScreenLayout(
                  context,
                  entries: entries,
                  snapshot: snapshot,
                  gap: gap,
                  maxWidth: constraints.maxWidth,
                );
              }

              return _buildPhoneLayout(
                context,
                wideEntries: wideEntries,
                standardEntries: standardEntries,
                orphanWideEntry: orphanWideEntry,
                snapshot: snapshot,
                gap: gap,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPhoneLayout(
    BuildContext context, {
    required List<FeatureEntryDefinition> wideEntries,
    required List<FeatureEntryDefinition> standardEntries,
    required FeatureEntryDefinition? orphanWideEntry,
    required dynamic snapshot,
    required double gap,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in wideEntries) ...[
          _WideFunctionTile(
            entry: entry,
            pinned: snapshot.isPinned(entry.id),
            statsText: _resolveStats(entry) ?? entry.subtitle,
            onTap: () => unawaited(_openEntry(entry)),
            onLongPress: () => unawaited(_togglePinned(entry)),
          ),
          SizedBox(height: gap),
        ],
        for (var i = 0; i < standardEntries.length; i += 2) ...[
          Row(
            children: [
              Expanded(
                child: _SmallFunctionTile(
                  entry: standardEntries[i],
                  pinned: snapshot.isPinned(standardEntries[i].id),
                  onTap: () => unawaited(_openEntry(standardEntries[i])),
                  onLongPress: () =>
                      unawaited(_togglePinned(standardEntries[i])),
                ),
              ),
              SizedBox(width: gap),
              Expanded(
                child: _SmallFunctionTile(
                  entry: standardEntries[i + 1],
                  pinned: snapshot.isPinned(standardEntries[i + 1].id),
                  onTap: () => unawaited(_openEntry(standardEntries[i + 1])),
                  onLongPress: () =>
                      unawaited(_togglePinned(standardEntries[i + 1])),
                ),
              ),
            ],
          ),
          SizedBox(height: gap),
        ],
        if (orphanWideEntry != null)
          _WideFunctionTile(
            entry: orphanWideEntry,
            pinned: snapshot.isPinned(orphanWideEntry.id),
            statsText:
                _resolveStats(orphanWideEntry) ?? orphanWideEntry.subtitle,
            onTap: () => unawaited(_openEntry(orphanWideEntry)),
            onLongPress: () => unawaited(_togglePinned(orphanWideEntry)),
          ),
      ],
    );
  }

  Widget _buildWideScreenLayout(
    BuildContext context, {
    required List<FeatureEntryDefinition> entries,
    required dynamic snapshot,
    required double gap,
    required double maxWidth,
  }) {
    final unitWidth = (maxWidth - 3 * gap) / 4;
    final wideWidth = unitWidth * 2 + gap;

    final pinnedCount = entries.where((e) => snapshot.isPinned(e.id)).length;
    final wideCount = pinnedCount > 0 ? (pinnedCount > 2 ? 2 : pinnedCount) : 2;

    final wideList = entries.take(wideCount).toList();
    final smallList = entries.skip(wideCount).toList();

    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        for (final entry in wideList)
          SizedBox(
            width: wideWidth,
            child: _WideFunctionTile(
              entry: entry,
              pinned: snapshot.isPinned(entry.id),
              statsText: _resolveStats(entry) ?? entry.subtitle,
              onTap: () => unawaited(_openEntry(entry)),
              onLongPress: () => unawaited(_togglePinned(entry)),
            ),
          ),
        for (final entry in smallList)
          SizedBox(
            width: unitWidth,
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
