import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/feature_entry_catalog.dart';

@visibleForTesting
int serviceHubGridColumnCount(double maxWidth) => maxWidth >= 600 ? 4 : 2;

@visibleForTesting
Alignment serviceHubChevronAlignment(int rowSpan) {
  return Alignment.bottomRight;
}

@visibleForTesting
double serviceHubCardMinHeight(
  FeatureEntryCardType cardType,
  double cardWidth,
) {
  final preferred = switch (cardType) {
    FeatureEntryCardType.smallSquare => cardWidth * 0.68,
    FeatureEntryCardType.tallRect => cardWidth * 1.02,
    FeatureEntryCardType.wideRect => cardWidth * 0.42,
    FeatureEntryCardType.largeSquare => cardWidth * 0.56,
  };
  final min = switch (cardType) {
    FeatureEntryCardType.smallSquare => 120.0,
    FeatureEntryCardType.tallRect => 176.0,
    FeatureEntryCardType.wideRect => 132.0,
    FeatureEntryCardType.largeSquare => 168.0,
  };
  final max = switch (cardType) {
    FeatureEntryCardType.smallSquare => 160.0,
    FeatureEntryCardType.tallRect => 220.0,
    FeatureEntryCardType.wideRect => 172.0,
    FeatureEntryCardType.largeSquare => 220.0,
  };
  return preferred.clamp(min, max);
}

@visibleForTesting
FeatureEntrySpan serviceHubActiveSpan(
  FeatureEntryDefinition entry,
  int gridColumns,
) {
  return entry.spanForGridColumns(gridColumns);
}

@visibleForTesting
FeatureEntryCardType serviceHubActiveCardType(
  FeatureEntryDefinition entry,
  int gridColumns,
) {
  return entry.cardTypeForGridColumns(gridColumns);
}

class ServiceHubPage extends StatelessWidget {
  const ServiceHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    final cards = FeatureEntryCatalog.instance.entriesByPlacement(
      FeatureEntryPlacement.serviceHub,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('功能')),
      body: SafeArea(
        top: false,
        child: cards.isEmpty
            ? Center(
                child: Text(
                  '暂无功能入口',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  final crossAxisCount = serviceHubGridColumnCount(
                    constraints.maxWidth,
                  );
                  final horizontalPadding = constraints.maxWidth >= 900
                      ? 24.0
                      : 16.0;

                  return SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      16,
                      horizontalPadding,
                      28,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '更多服务',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '首页保留高频入口，这里用更灵活的卡片排布承接低频但常用的服务。',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: 18),
                        StaggeredGrid.count(
                          crossAxisCount: crossAxisCount,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          children: [
                            for (final card in cards)
                              () {
                                final activeSpan = serviceHubActiveSpan(
                                  card,
                                  crossAxisCount,
                                );
                                return StaggeredGridTile.fit(
                                  crossAxisCellCount: activeSpan.columns,
                                  child: _ServiceHubCard(
                                    card: card,
                                    activeSpan: activeSpan,
                                    activeCardType: serviceHubActiveCardType(
                                      card,
                                      crossAxisCount,
                                    ),
                                  ),
                                );
                              }(),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _ServiceHubCard extends StatelessWidget {
  const _ServiceHubCard({
    required this.card,
    required this.activeSpan,
    required this.activeCardType,
  });

  final FeatureEntryDefinition card;
  final FeatureEntrySpan activeSpan;
  final FeatureEntryCardType activeCardType;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return LayoutBuilder(
      builder: (context, constraints) {
        final minHeight = serviceHubCardMinHeight(
          activeCardType,
          constraints.maxWidth,
        );
        final contentPadding = _paddingForCard();

        return InkWell(
          onTap: () => context.pushNamed(card.routeName),
          borderRadius: BorderRadius.circular(24),
          child: Ink(
            decoration: BoxDecoration(
              color: isDark ? cs.surfaceContainerLowest : Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: card.accentColor.withValues(alpha: isDark ? 0.26 : 0.18),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.06 : 0.05),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Stack(
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(minHeight: minHeight),
                    child: Padding(
                      padding: contentPadding,
                      child: switch (activeCardType) {
                        FeatureEntryCardType.smallSquare => _SquareCardBody(
                          card: card,
                          cardWidth: constraints.maxWidth,
                        ),
                        FeatureEntryCardType.tallRect => _TallCardBody(
                          card: card,
                          cardWidth: constraints.maxWidth,
                        ),
                        FeatureEntryCardType.wideRect => _WideCardBody(
                          card: card,
                          cardWidth: constraints.maxWidth,
                        ),
                        FeatureEntryCardType.largeSquare => _LargeCardBody(
                          card: card,
                          cardWidth: constraints.maxWidth,
                        ),
                      },
                    ),
                  ),
                  _CardChevron(card: card, rowSpan: activeSpan.rows),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  EdgeInsets _paddingForCard() {
    final base = switch (activeCardType) {
      FeatureEntryCardType.smallSquare => 15.0,
      FeatureEntryCardType.tallRect => 18.0,
      FeatureEntryCardType.wideRect => 16.0,
      FeatureEntryCardType.largeSquare => 18.0,
    };
    return EdgeInsets.fromLTRB(base, base, base + 36, base + 36);
  }
}

class _LargeCardBody extends StatelessWidget {
  const _LargeCardBody({required this.card, required this.cardWidth});

  final FeatureEntryDefinition card;
  final double cardWidth;

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(
      context,
    ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, height: 1.15);
    final subtitleStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(height: 1.4);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CardIconBadge(
          card: card,
          size: cardWidth < 280 ? 46 : 52,
          radius: 16,
          iconSize: cardWidth < 280 ? 24 : 28,
        ),
        const SizedBox(height: 18),
        Text(
          card.title,
          style: titleStyle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        Text(
          card.subtitle,
          style: subtitleStyle,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _WideCardBody extends StatelessWidget {
  const _WideCardBody({required this.card, required this.cardWidth});

  final FeatureEntryDefinition card;
  final double cardWidth;

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w800,
      height: 1.15,
    );
    final subtitleStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      height: 1.35,
      fontSize: cardWidth < 320 ? 13 : null,
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CardIconBadge(
          card: card,
          size: cardWidth < 320 ? 40 : 44,
          radius: 14,
          iconSize: cardWidth < 320 ? 20 : 22,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                card.title,
                style: titleStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                card.subtitle,
                style: subtitleStyle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TallCardBody extends StatelessWidget {
  const _TallCardBody({required this.card, required this.cardWidth});

  final FeatureEntryDefinition card;
  final double cardWidth;

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w800,
      height: 1.15,
    );
    final subtitleStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      height: 1.38,
      fontSize: cardWidth < 180 ? 13 : null,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CardIconBadge(
          card: card,
          size: cardWidth < 180 ? 40 : 44,
          radius: 14,
          iconSize: cardWidth < 180 ? 20 : 22,
        ),
        const SizedBox(height: 14),
        Text(
          card.title,
          style: titleStyle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6),
        Text(
          card.subtitle,
          style: subtitleStyle,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _SquareCardBody extends StatelessWidget {
  const _SquareCardBody({required this.card, required this.cardWidth});

  final FeatureEntryDefinition card;
  final double cardWidth;

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w800,
      fontSize: cardWidth < 180 ? 15 : null,
      height: 1.15,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CardIconBadge(
          card: card,
          size: cardWidth < 180 ? 38 : 40,
          radius: 14,
          iconSize: cardWidth < 180 ? 18 : 20,
        ),
        const SizedBox(height: 18),
        Text(
          card.title,
          style: titleStyle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _CardIconBadge extends StatelessWidget {
  const _CardIconBadge({
    required this.card,
    required this.size,
    required this.radius,
    required this.iconSize,
  });

  final FeatureEntryDefinition card;
  final double size;
  final double radius;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: card.accentColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(card.icon, color: card.accentColor, size: iconSize),
    );
  }
}

class _CardChevron extends StatelessWidget {
  const _CardChevron({required this.card, required this.rowSpan});

  final FeatureEntryDefinition card;
  final int rowSpan;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 14,
      bottom: 14,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: card.accentColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Icon(
          Icons.chevron_right_rounded,
          size: 18,
          color: card.accentColor,
        ),
      ),
    );
  }
}
