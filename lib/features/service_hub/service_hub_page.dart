import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/foundation.dart';

import '../../core/config/feature_entry_catalog.dart';

@visibleForTesting
int serviceHubGridColumnCount(double maxWidth) => maxWidth >= 600 ? 4 : 2;

@visibleForTesting
Alignment serviceHubChevronAlignment(int rowSpan) {
  return rowSpan <= 1 ? Alignment.centerRight : Alignment.bottomRight;
}

class ServiceHubPage extends StatelessWidget {
  const ServiceHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('功能')),
      body: SafeArea(
        top: false,
        child: FutureBuilder<List<FeatureEntryDefinition>>(
          future: FeatureEntryCatalog.instance.loadByPlacement(
            FeatureEntryPlacement.serviceHub,
          ),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    '功能入口加载失败，请稍后重试',
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }

            final cards = snapshot.data;
            if (cards == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (cards.isEmpty) {
              return Center(
                child: Text(
                  '暂无功能入口',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              );
            }

            return LayoutBuilder(
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
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 18),
                      StaggeredGrid.count(
                        crossAxisCount: crossAxisCount,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        children: [
                          for (final card in cards)
                            StaggeredGridTile.count(
                              crossAxisCellCount: card.span.columns,
                              mainAxisCellCount: card.span.rows.toDouble(),
                              child: _ServiceHubCard(card: card),
                            ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _ServiceHubCard extends StatelessWidget {
  const _ServiceHubCard({required this.card});

  final FeatureEntryDefinition card;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
        child: Stack(
          children: [
            Padding(
              padding: _paddingForCard(card),
              child: switch (card.cardType) {
                FeatureEntryCardType.smallSquare => _SquareCardBody(card: card),
                FeatureEntryCardType.tallRect => _TallCardBody(card: card),
                FeatureEntryCardType.wideRect => _WideCardBody(card: card),
                FeatureEntryCardType.largeSquare => _LargeCardBody(card: card),
              },
            ),
            _CardChevron(card: card),
          ],
        ),
      ),
    );
  }

  EdgeInsets _paddingForCard(FeatureEntryDefinition card) {
    final base = switch (card.cardType) {
      FeatureEntryCardType.smallSquare => 16.0,
      FeatureEntryCardType.tallRect => 18.0,
      FeatureEntryCardType.wideRect => 18.0,
      FeatureEntryCardType.largeSquare => 20.0,
    };
    final trailingInset = card.span.rows == 1 ? 42.0 : 18.0;
    final bottomInset = card.span.rows == 1 ? base : base + 34.0;
    return EdgeInsets.fromLTRB(base, base, trailingInset, bottomInset);
  }
}

class _LargeCardBody extends StatelessWidget {
  const _LargeCardBody({required this.card});

  final FeatureEntryDefinition card;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CardIconBadge(card: card, size: 54, radius: 18, iconSize: 28),
        const Spacer(),
        Text(
          card.title,
          style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 10),
        Text(
          card.subtitle,
          style: textTheme.bodyMedium?.copyWith(height: 1.5),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _WideCardBody extends StatelessWidget {
  const _WideCardBody({required this.card});

  final FeatureEntryDefinition card;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CardIconBadge(card: card, size: 46, radius: 14, iconSize: 24),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                card.title,
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(
                card.subtitle,
                style: textTheme.bodyMedium?.copyWith(height: 1.4),
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
  const _TallCardBody({required this.card});

  final FeatureEntryDefinition card;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CardIconBadge(card: card, size: 46, radius: 14, iconSize: 24),
        const SizedBox(height: 18),
        Text(
          card.title,
          style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        Text(
          card.subtitle,
          style: textTheme.bodyMedium?.copyWith(height: 1.45),
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _SquareCardBody extends StatelessWidget {
  const _SquareCardBody({required this.card});

  final FeatureEntryDefinition card;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CardIconBadge(card: card, size: 42, radius: 14, iconSize: 22),
        const Spacer(),
        Text(
          card.title,
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
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
  const _CardChevron({required this.card});

  final FeatureEntryDefinition card;

  @override
  Widget build(BuildContext context) {
    final alignment = serviceHubChevronAlignment(card.span.rows);
    final margin = card.span.rows == 1
        ? const EdgeInsets.only(right: 14)
        : const EdgeInsets.only(right: 14, bottom: 14);

    return Align(
      alignment: alignment,
      child: Container(
        margin: margin,
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
