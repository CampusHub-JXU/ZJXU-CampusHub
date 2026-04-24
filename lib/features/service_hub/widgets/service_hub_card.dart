import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_theme_controller.dart';
import '../../../core/config/feature_entry_catalog.dart';
import '../../home/widgets/home_card_container.dart';
import '../service_hub_layout.dart';

class ServiceHubCard extends StatelessWidget {
  const ServiceHubCard({
    super.key,
    required this.card,
    required this.activeSpan,
    required this.activeCardType,
  });

  final FeatureEntryDefinition card;
  final FeatureEntrySpan activeSpan;
  final FeatureEntryCardType activeCardType;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final minHeight = serviceHubCardMinHeight(
          activeCardType,
          constraints.maxWidth,
        );
        final contentPadding = _paddingForCard();

        return HomeCardContainer(
          padding: EdgeInsets.zero,
          onTap: () => context.pushNamed(card.routeName),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Stack(
              children: [
                Padding(
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
                _CardChevron(card: card),
              ],
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
    final iconColor = AppThemeController.instance.resolveIconColor(
      context,
      card.accentColor,
    );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: iconColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(card.icon, color: iconColor, size: iconSize),
    );
  }
}

class _CardChevron extends StatelessWidget {
  const _CardChevron({required this.card});

  final FeatureEntryDefinition card;

  @override
  Widget build(BuildContext context) {
    final iconColor = AppThemeController.instance.resolveIconColor(
      context,
      card.accentColor,
    );
    return Positioned(
      right: 14,
      bottom: 14,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Icon(Icons.chevron_right_rounded, size: 18, color: iconColor),
      ),
    );
  }
}
