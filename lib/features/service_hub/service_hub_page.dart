import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_theme_controller.dart';
import '../../core/config/feature_entry_catalog.dart';
import 'service_hub_layout.dart';
import 'service_hub_usage_store.dart';
import 'widgets/service_hub_card.dart';
import 'widgets/service_hub_header.dart';

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
                              if (featuredEntries.isNotEmpty) ...[
                                const SizedBox(height: 18),
                                _FeaturedEntriesSection(
                                  entries: featuredEntries,
                                  snapshot: _usageStore.snapshot,
                                  onTap: _openEntry,
                                  onLongPress: _togglePinned,
                                ),
                              ],
                              const SizedBox(height: 18),
                              if (filteredEntries.isEmpty)
                                _ServiceHubSearchEmptyState(query: _query)
                              else
                                _MasonryServiceGrid(
                                  entries: filteredEntries,
                                  snapshot: _usageStore.snapshot,
                                  onTap: _openEntry,
                                  onLongPress: _togglePinned,
                                ),
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

class _MasonryServiceGrid extends StatelessWidget {
  const _MasonryServiceGrid({
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
        final gridColumns = serviceHubGridColumnCount(constraints.maxWidth);
        final pinnedIds = snapshot.pinnedIds;

        final sortedEntries = List<FeatureEntryDefinition>.from(entries)
          ..sort((a, b) {
            final aPinned = pinnedIds.contains(a.id);
            final bPinned = pinnedIds.contains(b.id);
            if (aPinned && !bPinned) return -1;
            if (!aPinned && bPinned) return 1;
            return 0;
          });

        return StaggeredGrid.count(
          crossAxisCount: gridColumns,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          children: [
            for (final entry in sortedEntries)
              StaggeredGridTile.count(
                crossAxisCellCount: entry.spanForGridColumns(gridColumns).columns,
                mainAxisCellCount: entry.spanForGridColumns(gridColumns).rows,
                child: _MasonryCard(
                  entry: entry,
                  pinned: snapshot.isPinned(entry.id),
                  activeSpan: entry.spanForGridColumns(gridColumns),
                  activeCardType: entry.cardTypeForGridColumns(gridColumns),
                  onTap: () => onTap(entry),
                  onLongPress: () => onLongPress(entry),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MasonryCard extends StatelessWidget {
  const _MasonryCard({
    required this.entry,
    required this.pinned,
    required this.activeSpan,
    required this.activeCardType,
    required this.onTap,
    required this.onLongPress,
  });

  final FeatureEntryDefinition entry;
  final bool pinned;
  final FeatureEntrySpan activeSpan;
  final FeatureEntryCardType activeCardType;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ServiceHubCard(
          card: entry,
          activeSpan: activeSpan,
          activeCardType: activeCardType,
          onTap: onTap,
          onLongPress: onLongPress,
        ),
        if (pinned)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.push_pin_rounded,
                size: 12,
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            ),
          ),
      ],
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
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
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

class _FeaturedEntriesSection extends StatelessWidget {
  const _FeaturedEntriesSection({
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(title: '常用', subtitle: '长按入口可置顶'),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in entries)
              _FeaturedEntryChip(
                entry: entry,
                pinned: snapshot.isPinned(entry.id),
                onTap: () => onTap(entry),
                onLongPress: () => onLongPress(entry),
              ),
          ],
        ),
      ],
    );
  }
}

class _FeaturedEntryChip extends StatelessWidget {
  const _FeaturedEntryChip({
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
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.36)),
    );
    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.36),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _EntryIconBadge(
                entry: entry,
                size: 30,
                radius: 10,
                iconSize: 18,
              ),
              const SizedBox(width: 9),
              Flexible(
                child: Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (pinned) ...[
                const SizedBox(width: 6),
                Icon(Icons.push_pin_rounded, size: 15, color: cs.primary),
              ],
            ],
          ),
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
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
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
        borderRadius: BorderRadius.circular(18),
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
