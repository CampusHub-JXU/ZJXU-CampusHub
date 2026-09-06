import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/feature_entry_catalog.dart';
import '../../../features/service_hub/service_hub_usage_store.dart';

/// 首页单滚动页底部的「功能」锚点段落：等宽小按钮网格。
///
/// 全部入口（含课表——快捷入口行已并入本段落）以「图标置顶 + 标签
/// 沉底」的无框小格子平铺（手机 4 列、宽屏 6 列），整格可点；中性灰
/// 图标、无卡面、无彩色徽标，视觉权重低于资产行与校园公告。使用/
/// 置顶数据复用 [ServiceHubUsageStore]：置顶靠前（标签后加图钉），
/// 其余按访问频次再按目录顺序；恢复过程只读本地缓存，绝不触网。
class FunctionZoneSection extends StatefulWidget {
  const FunctionZoneSection({
    super.key,
    this.padding = EdgeInsets.zero,
  });

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

  @override
  Widget build(BuildContext context) {
    final entries = _orderedEntries();
    if (entries.isEmpty) return const SizedBox.shrink();

    // 手机 4 列（每格 ~78px 宽），宽屏 6 列；等宽格子保证整格可点的
    // 命中面积（≥44 高），避免纯文字小按钮难点中。
    return Padding(
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _FunctionZoneHeader(),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 600 ? 6 : 4;
              final gap = 8.0;
              final cellWidth =
                  (constraints.maxWidth - (columns - 1) * gap) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: 4,
                children: [
                  for (final entry in entries)
                    SizedBox(
                      width: cellWidth,
                      child: _FunctionButton(
                        entry: entry,
                        pinned: _usageStore.snapshot.isPinned(entry.id),
                        onTap: () => unawaited(_openEntry(entry)),
                        onLongPress: () => unawaited(_togglePinned(entry)),
                      ),
                    ),
                ],
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

/// 功能小按钮：等宽格子内「图标置顶 + 标签沉底」垂直布局，整格可点。
///
/// 保持无框轻量（透明 Material + InkWell，无卡面、无彩色徽标），
/// 但命中区为整格（约 78×64 起），满足 ≥44 的可点击基线；置顶项在
/// 标签后加 12sp 主色图钉。
class _FunctionButton extends StatelessWidget {
  const _FunctionButton({
    required this.entry,
    required this.pinned,
    required this.onTap,
    required this.onLongPress,
  });

  final FeatureEntryDefinition entry;
  final bool pinned;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// 目录全称过长时用口语化短标签，保证一格一行放得下（与原快捷行一致）。
  static const _shortLabelById = <String, String>{
    'schedule': '课表',
    'grades': '成绩',
    'exam': '考试',
    'shuati-practice': '刷题',
    'campus-card-payment': '付款码',
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final label = _shortLabelById[entry.id] ?? entry.title;
    return Semantics(
      button: true,
      label: entry.title,
      hint: entry.subtitle,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(entry.icon, size: 24, color: cs.onSurfaceVariant),
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                    if (pinned) ...[
                      const SizedBox(width: 3),
                      Icon(Icons.push_pin_rounded, size: 11, color: cs.primary),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
