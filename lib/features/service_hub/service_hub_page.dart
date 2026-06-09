import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_theme_controller.dart';
import '../../core/config/feature_entry_catalog.dart';
import 'service_hub_usage_store.dart';
import 'widgets/service_hub_header.dart';

const _surfaceRadius = 18.0;
const _iconBadgeRadius = 13.0;
const _gridGap = 14.0;

class ServiceHubPage extends StatefulWidget {
  const ServiceHubPage({super.key});

  @override
  State<ServiceHubPage> createState() => _ServiceHubPageState();
}

class _ServiceHubPageState extends State<ServiceHubPage> {
  final _usageStore = ServiceHubUsageStore.instance;
  final _searchController = TextEditingController();
  String _query = '';
  bool _restoredUsage = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _usageStore.addListener(_onUsageChanged);
    unawaited(_restoreUsage());
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _usageStore.removeListener(_onUsageChanged);
    super.dispose();
  }

  Future<void> _restoreUsage() async {
    await _usageStore.restore();
    if (!mounted) return;
    setState(() {
      _restoredUsage = true;
    });
  }

  void _onUsageChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onSearchChanged() {
    final nextQuery = _searchController.text.trim();
    if (nextQuery == _query) return;
    setState(() {
      _query = nextQuery;
    });
  }

  void _clearSearch() {
    _searchController.clear();
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

  @override
  Widget build(BuildContext context) {
    final entries = FeatureEntryCatalog.instance.entriesByPlacement(
      FeatureEntryPlacement.serviceHub,
    );
    final filteredEntries = _filterEntries(entries, _query);
    final featuredEntries = _query.isEmpty && _restoredUsage
        ? _buildFeaturedEntries(entries, _usageStore.snapshot)
        : const <FeatureEntryDefinition>[];

    return Scaffold(
      appBar: AppBar(title: const Text('功能')),
      body: SafeArea(
        top: false,
        child: entries.isEmpty
            ? Center(
                child: Text(
                  '暂无功能入口',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  final horizontalPadding = constraints.maxWidth >= 900
                      ? 24.0
                      : 16.0;
                  return ListView(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      16,
                      horizontalPadding,
                      28,
                    ),
                    children: [
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 980),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const ServiceHubHeader(),
                              const SizedBox(height: 16),
                              _ServiceHubSearchField(
                                controller: _searchController,
                                hasQuery: _query.isNotEmpty,
                                onClear: _clearSearch,
                              ),
                              const SizedBox(height: 26),
                              if (_query.isNotEmpty)
                                if (filteredEntries.isEmpty)
                                  _ServiceHubSearchEmptyState(query: _query)
                                else
                                  _ServiceHubSection(
                                    title: '搜索结果',
                                    subtitle: '${filteredEntries.length} 个匹配',
                                    entries: filteredEntries,
                                    snapshot: _usageStore.snapshot,
                                    onTap: _openEntry,
                                    onLongPress: _togglePinned,
                                  )
                              else ...[
                                if (featuredEntries.isNotEmpty) ...[
                                  _ServiceHubSection(
                                    title: '常用',
                                    subtitle: '长按入口可置顶',
                                    entries: featuredEntries,
                                    snapshot: _usageStore.snapshot,
                                    onTap: _openEntry,
                                    onLongPress: _togglePinned,
                                  ),
                                  const SizedBox(height: 30),
                                ],
                                _CategoryServiceSections(
                                  entries: entries,
                                  snapshot: _usageStore.snapshot,
                                  onTap: _openEntry,
                                  onLongPress: _togglePinned,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  List<FeatureEntryDefinition> _filterEntries(
    List<FeatureEntryDefinition> entries,
    String query,
  ) {
    if (query.isEmpty) return entries;
    final normalizedQuery = query.toLowerCase();
    return entries
        .where((entry) => _matchesEntry(entry, normalizedQuery))
        .toList();
  }

  bool _matchesEntry(FeatureEntryDefinition entry, String query) {
    final searchableText = [
      entry.title,
      entry.subtitle,
      entry.id,
      entry.routeName,
      entry.category.label,
      ...entry.keywords,
    ].join(' ').toLowerCase();
    return searchableText.contains(query);
  }

  List<FeatureEntryDefinition> _buildFeaturedEntries(
    List<FeatureEntryDefinition> entries,
    ServiceHubUsageSnapshot snapshot,
  ) {
    final byId = {for (final entry in entries) entry.id: entry};
    final featured = <FeatureEntryDefinition>[];
    for (final id in snapshot.pinnedIds) {
      final entry = byId[id];
      if (entry != null && !featured.contains(entry)) {
        featured.add(entry);
      }
      if (featured.length >= 6) return featured;
    }

    final usageEntries = snapshot.usageById.values.toList()
      ..sort((left, right) {
        final countCompare = right.visitCount.compareTo(left.visitCount);
        if (countCompare != 0) return countCompare;
        return right.lastVisitedAt.compareTo(left.lastVisitedAt);
      });
    for (final usage in usageEntries) {
      final entry = byId[usage.id];
      if (entry != null && !featured.contains(entry)) {
        featured.add(entry);
      }
      if (featured.length >= 6) break;
    }
    return featured;
  }
}

class _CategoryServiceSections extends StatelessWidget {
  const _CategoryServiceSections({
    required this.entries,
    required this.snapshot,
    required this.onTap,
    required this.onLongPress,
  });

  final List<FeatureEntryDefinition> entries;
  final ServiceHubUsageSnapshot snapshot;
  final ValueChanged<FeatureEntryDefinition> onTap;
  final ValueChanged<FeatureEntryDefinition> onLongPress;

  @override
  Widget build(BuildContext context) {
    final groupedEntries = _groupEntriesByCategory(entries);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final category in FeatureEntryCategory.values)
          if (groupedEntries[category]!.isNotEmpty) ...[
            _ServiceHubSection(
              title: category.label,
              subtitle: '${groupedEntries[category]!.length} 项',
              entries: groupedEntries[category]!,
              snapshot: snapshot,
              onTap: onTap,
              onLongPress: onLongPress,
            ),
            if (category != FeatureEntryCategory.values.last)
              const SizedBox(height: 30),
          ],
      ],
    );
  }

  Map<FeatureEntryCategory, List<FeatureEntryDefinition>>
  _groupEntriesByCategory(List<FeatureEntryDefinition> entries) {
    final grouped = {
      for (final category in FeatureEntryCategory.values)
        category: <FeatureEntryDefinition>[],
    };
    for (final entry in entries) {
      grouped[entry.category]!.add(entry);
    }
    return grouped;
  }
}

class _ServiceHubSection extends StatelessWidget {
  const _ServiceHubSection({
    required this.title,
    required this.entries,
    required this.snapshot,
    required this.onTap,
    required this.onLongPress,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final List<FeatureEntryDefinition> entries;
  final ServiceHubUsageSnapshot snapshot;
  final ValueChanged<FeatureEntryDefinition> onTap;
  final ValueChanged<FeatureEntryDefinition> onLongPress;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(title: title, subtitle: subtitle),
        const SizedBox(height: 14),
        _ServiceHubEntryGrid(
          entries: entries,
          snapshot: snapshot,
          onTap: onTap,
          onLongPress: onLongPress,
        ),
      ],
    );
  }
}

class _ServiceHubEntryGrid extends StatelessWidget {
  const _ServiceHubEntryGrid({
    required this.entries,
    required this.snapshot,
    required this.onTap,
    required this.onLongPress,
  });

  final List<FeatureEntryDefinition> entries;
  final ServiceHubUsageSnapshot snapshot;
  final ValueChanged<FeatureEntryDefinition> onTap;
  final ValueChanged<FeatureEntryDefinition> onLongPress;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = _serviceHubGridColumnCount(constraints.maxWidth);
        return GridView.builder(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: entries.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: _gridGap,
            mainAxisSpacing: _gridGap,
            mainAxisExtent: _serviceHubTileHeight(context),
          ),
          itemBuilder: (context, index) {
            final entry = entries[index];
            return _ServiceHubEntryTile(
              entry: entry,
              pinned: snapshot.isPinned(entry.id),
              onTap: () => onTap(entry),
              onLongPress: () => onLongPress(entry),
            );
          },
        );
      },
    );
  }
}

int _serviceHubGridColumnCount(double maxWidth) {
  if (maxWidth >= 900) return 4;
  if (maxWidth >= 600) return 3;
  return 2;
}

double _serviceHubTileHeight(BuildContext context) {
  final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.8);
  return (136 + (textScale - 1) * 40).clamp(136.0, 168.0).toDouble();
}

class _ServiceHubEntryTile extends StatelessWidget {
  const _ServiceHubEntryTile({
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = isDark
        ? cs.outline.withValues(alpha: 0.22)
        : cs.outlineVariant.withValues(alpha: 0.38);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_surfaceRadius),
      side: BorderSide(color: borderColor),
    );
    final detailColor = cs.onSurfaceVariant.withValues(
      alpha: isDark ? 0.68 : 0.62,
    );

    return Semantics(
      button: true,
      label: entry.title,
      hint: entry.subtitle,
      child: Material(
        color: cs.surfaceContainerHighest.withValues(
          alpha: isDark ? 0.22 : 0.3,
        ),
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _EntryIconBadge(
                      entry: entry,
                      size: 38,
                      radius: _iconBadgeRadius,
                      iconSize: 21,
                    ),
                    const Spacer(),
                    if (pinned) ...[
                      _PinnedIndicator(colorScheme: cs),
                      const SizedBox(width: 6),
                    ],
                    _EntryActionIndicator(entry: entry),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.12,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  entry.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: detailColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    height: 1.24,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PinnedIndicator extends StatelessWidget {
  const _PinnedIndicator({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: colorScheme.primary,
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.push_pin_rounded,
        size: 11,
        color: colorScheme.onPrimary,
      ),
    );
  }
}

class _EntryActionIndicator extends StatelessWidget {
  const _EntryActionIndicator({required this.entry});

  final FeatureEntryDefinition entry;

  @override
  Widget build(BuildContext context) {
    final iconColor = AppThemeController.instance.resolveIconColor(
      context,
      entry.accentColor,
    );
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: iconColor.withValues(alpha: 0.08),
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.chevron_right_rounded,
        size: 18,
        color: iconColor.withValues(alpha: 0.76),
      ),
    );
  }
}

class _ServiceHubSearchField extends StatelessWidget {
  const _ServiceHubSearchField({
    required this.controller,
    required this.hasQuery,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool hasQuery;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return TextField(
      controller: controller,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: '搜索功能',
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: hasQuery
            ? IconButton(
                onPressed: onClear,
                icon: const Icon(Icons.close_rounded),
                tooltip: '清除搜索',
              )
            : null,
        filled: true,
        fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_surfaceRadius),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_surfaceRadius),
          borderSide: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_surfaceRadius),
          borderSide: BorderSide(color: cs.primary, width: 1.4),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
    );
  }
}

class _EntryIconBadge extends StatelessWidget {
  const _EntryIconBadge({
    required this.entry,
    required this.size,
    required this.radius,
    required this.iconSize,
  });

  final FeatureEntryDefinition entry;
  final double size;
  final double radius;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final iconColor = AppThemeController.instance.resolveIconColor(
      context,
      entry.accentColor,
    );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: iconColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(entry.icon, color: iconColor, size: iconSize),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (subtitle != null) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );
  }
}

class _ServiceHubSearchEmptyState extends StatelessWidget {
  const _ServiceHubSearchEmptyState({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(_surfaceRadius),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_rounded, size: 36, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            '未找到相关功能',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '没有匹配"$query"的服务入口',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
