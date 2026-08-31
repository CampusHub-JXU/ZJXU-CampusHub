import 'package:flutter/material.dart';

/// Design tokens for the 智能中台 UI system.
///
/// Centralizes radius / spacing / elevation / icon-badge sizing so that
/// scattered hard-coded values across features converge on a single source of
/// truth. See `docs/design.md` §5 (P0-1) for the full migration plan.
///
/// Conventions:
/// * Values are tuned to match the current visual language (Material 3 seed
///   theme + frosted glass accents).
/// * Tokens are `const` so they can be used in const widget constructors.
class AppRadius {
  AppRadius._();

  /// 内容面唯一圆角：AppCard、品牌卡（cardAlt）、功能区/服务瓦片、
  /// 输入框、事件横幅共用一档，保证跨页面圆角观感一致。
  /// （历史上 card=22 / cardAlt=18 / tile=16 / input=14 四档并存，
  /// 已按设计规范收敛为单档 16。）
  static const double card = 16;

  /// 品牌卡历史别名，现与 [card] 同值；仅保留 API 兼容。
  static const double cardAlt = card;

  /// 功能瓦片，与 [card] 同档。
  static const double tile = card;

  /// Icon badge base radius（图标底座，独立小元素档）。
  static const double badge = 12;

  /// 输入框/表单字段圆角，与内容面同档。
  static const double input = card;

  /// Chips。
  static const double chip = 10;

  /// Bottom sheet top.
  static const double sheet = 26;

  /// Floating glass dock (bottom nav bar) — rectangle-leaning radius,
  /// tighter than sheet/dialog corners but softer than tiles.
  static const double dock = 20;

  /// Dialog / floating panels (matches M3 dialog corners).
  static const double floating = 28;

  /// Small decorative icon badge (home small cards).
  static const double badgeSmall = 9;

  static BorderRadius get cardBorder => BorderRadius.circular(card);
  static BorderRadius get cardAltBorder => BorderRadius.circular(cardAlt);
  static BorderRadius get tileBorder => BorderRadius.circular(tile);
  static BorderRadius get inputBorder => BorderRadius.circular(input);
  static BorderRadius get chipBorder => BorderRadius.circular(chip);
  static BorderRadius get sheetBorder => BorderRadius.circular(sheet);
}

/// Apple-flavored continuous-corner shapes (squircle).
///
/// [RoundedSuperellipseBorder] reproduces the iOS-style "liquid" corner where
/// the corner curvature eases continuously instead of a circular arc.
class AppShape {
  AppShape._();

  static RoundedSuperellipseBorder card({BorderSide side = BorderSide.none}) =>
      RoundedSuperellipseBorder(borderRadius: AppRadius.cardBorder, side: side);

  static RoundedSuperellipseBorder cardAlt({
    BorderSide side = BorderSide.none,
  }) => RoundedSuperellipseBorder(
    borderRadius: AppRadius.cardAltBorder,
    side: side,
  );

  static RoundedSuperellipseBorder sheet() => RoundedSuperellipseBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
  );

  static BorderRadius get floatingBorder =>
      BorderRadius.circular(AppRadius.floating);
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

  /// Used by AppCard with frosted glass enabled.
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
