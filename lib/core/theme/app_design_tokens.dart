import 'package:flutter/material.dart';

/// Design tokens for the 智能中台 UI system.
///
/// Centralizes radius / spacing / elevation / icon-badge sizing so that
/// scattered hard-coded values across features converge on a single source of
/// truth. See `docs/design.md` §5 (P0-1) for the full migration plan.
///
/// Conventions:
/// * Values are tuned to match the existing visual language (Material 3 seed
///   theme + standard frosted glass accents) — introducing tokens must NOT
///   change the current rendered look, only make it auditable.
/// * Tokens are `const` so they can be used in const widget constructors.
class AppRadius {
  AppRadius._();

  /// Primary content card — HomeCardContainer, GPA summary, My status cards.
  static const double card = 20;

  /// Brand / alternative card — ShipCard, Grade card, global CardTheme.
  static const double cardAlt = 16;

  /// Service Hub entry tile.
  static const double tile = 18;

  /// Icon badge base radius.
  static const double badge = 12;

  /// Search fields & form inputs.
  static const double input = 14;

  /// Chips.
  static const double chip = 8;

  /// Bottom sheet top.
  static const double sheet = 20;

  /// Small decorative icon badge (home small cards).
  static const double badgeSmall = 9;

  static BorderRadius get cardBorder => BorderRadius.circular(card);
  static BorderRadius get cardAltBorder => BorderRadius.circular(cardAlt);
  static BorderRadius get tileBorder => BorderRadius.circular(tile);
  static BorderRadius get inputBorder => BorderRadius.circular(input);
  static BorderRadius get sheetBorder => BorderRadius.circular(sheet);
}

class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 30;

  /// Home page outer horizontal margin.
  static const double pageMargin = 16;

  /// Home card internal padding.
  static const double cardPadding = 16;

  /// Service Hub grid gap.
  static const double gridGap = 14;

  /// Service Hub section vertical gap.
  static const double sectionGap = 30;
}

/// Elevation tokens. Each level encodes the blur radius, offset and alpha used
/// to build a [BoxShadow]. Keep alpha low — the app prefers subtle borders over
/// heavy shadows.
class AppElevation {
  AppElevation._();

  static const BoxShadow level1 = BoxShadow(
    color: Color(0x0A000000),
    blurRadius: 8,
    offset: Offset(0, 3),
  );

  /// Used by HomeCardContainer with frosted glass enabled.
  static const BoxShadow level2 = BoxShadow(
    color: Color(0x0F000000),
    blurRadius: 14,
    offset: Offset(0, 3),
  );

  static const BoxShadow level3 = BoxShadow(
    color: Color(0x14000000),
    blurRadius: 10,
    offset: Offset(0, 2),
  );

  /// Builds a shadow with a theme-derived color, keeping the token geometry.
  static BoxShadow withColor(BoxShadow token, Color color) {
    return BoxShadow(
      color: color.withValues(alpha: token.color.a),
      blurRadius: token.blurRadius,
      offset: token.offset,
    );
  }
}

/// Standard icon badge sizes. Collapses the four ad-hoc sizes
/// (36/38/40 + radii 9/10/12/13 + icon 20/21/22) into two tiers.
class AppBadgeSize {
  AppBadgeSize._();

  /// Small badge — home small cards & list rows.
  static const double smallBox = 36;
  static const double smallIcon = 20;
  static const double smallRadius = AppRadius.badgeSmall;

  /// Medium badge — service hub tiles.
  static const double mediumBox = 38;
  static const double mediumIcon = 21;
  static const double mediumRadius = 13;

  /// Large badge — My page status cards.
  static const double largeBox = 40;
  static const double largeIcon = 22;
  static const double largeRadius = AppRadius.badge;
}
