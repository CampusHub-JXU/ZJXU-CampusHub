import 'package:flutter/material.dart';

/// Design tokens for the 嘉兴大学 App UI system.
///
/// Centralizes radius / spacing / elevation / icon-badge sizing so that
/// scattered hard-coded values across features converge on a single source of
/// truth. See `docs/design-baseline/DESIGN.md` §4（v2 七档圆角）for the spec.
///
/// Conventions:
/// * Values are tuned to match the current visual language (Material 3 seed
///   theme + frosted glass accents).
/// * Tokens are `const` so they can be used in const widget constructors.
class AppRadius {
  AppRadius._();

  /// 6dp：行内语义小胶囊（`AppStatusTag` 非 stadium 形态、tag 背景）。
  static const double tag = 6;

  /// 9dp：课表课程块（`ScheduleCourseCell`）。网格块边长较小，保持紧凑圆角；
  /// 其余卡片 / 控件维持新版中度圆角（20 / 13）。
  static const double cell = 9;

  /// 13dp：输入框 / 搜索框 / 步进器 / 下拉胶囊 / chips。
  static const double control = 13;

  /// 短选项分段控件（`SegmentedButton`）：介于 control 与内容面之间的一档，
  /// 替代 MD3 默认的 StadiumBorder（胶囊）。
  static const double segment = 14;

  /// 14dp：图标底座（`AppIconBadge`）/ 卡内嵌块。
  static const double badge = 14;

  /// 20dp：内容面唯一圆角：AppCard、品牌卡、功能区 / 服务瓦片。
  /// （历史上 card=22 / cardAlt=18 / tile=16 / input=14 四档并存，
  /// 已按设计规范收敛为单档；2026-11 由 16 上调至 20 对齐新版系统卡片。）
  static const double card = 20;

  /// 26dp：浮动玻璃 Dock。
  static const double dock = 26;

  /// 30dp：底部弹层 / 对话框 / 浮动面板顶角。
  static const double sheet = 30;

  /// 品牌卡历史别名，现与 [card] 同值；仅保留 API 兼容。
  static const double cardAlt = card;

  /// 功能瓦片，与 [card] 同档。
  static const double tile = card;

  /// 输入框 / 表单字段圆角（= [control]），保留旧名兼容。
  static const double input = control;

  /// Chips（= [control]）。
  static const double chip = control;

  /// 对话框 / 浮动面板（= [sheet]）。
  static const double floating = sheet;

  /// 小图标底座（= [cell]）。
  static const double badgeSmall = cell;

  static BorderRadius get cardBorder => BorderRadius.circular(card);
  static BorderRadius get cardAltBorder => BorderRadius.circular(cardAlt);
  static BorderRadius get tileBorder => BorderRadius.circular(tile);
  static BorderRadius get inputBorder => BorderRadius.circular(input);
  static BorderRadius get chipBorder => BorderRadius.circular(chip);
  static BorderRadius get sheetBorder => BorderRadius.circular(sheet);
  static BorderRadius get dockBorder => BorderRadius.circular(dock);
  static BorderRadius get cellBorder => BorderRadius.circular(cell);
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

  /// 首页大区块分隔（资产行 → 校园公告这类「内容板块」切换点），
  /// 高于普通模块间距、远低于功能区锚点的 72 呼吸留白。
  static const double sectionBreak = 40;

  /// 数据页 / 表单页（C、D 型）左右留白。
  static const double pageMargin = 16;

  /// Tab 页与分组列表页（A、B 型：我的 / 设置 / 关于 / 首页功能区）左右留白。
  /// 页边距只有 [pageMargin] 与本值两档（docs/ui-unification-plan.md §4.2）。
  static const double listGutter = 24;

  /// 分组列表页的组间距。
  static const double listGroupGap = 20;

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

  /// Small badge — home small cards & list rows（v2 基准：36dp 底座 + 20dp 图标
  /// + 12dp 圆角）。
  static const double smallBox = 36;
  static const double smallIcon = 20;
  static const double smallRadius = AppRadius.badge;

  /// Medium badge — service hub tiles.
  static const double mediumBox = 38;
  static const double mediumIcon = 21;
  static const double mediumRadius = AppRadius.badge;

  /// Large badge — My page status cards.
  static const double largeBox = 40;
  static const double largeIcon = 22;
  static const double largeRadius = AppRadius.badge;
}

/// 动效节奏（Motion）单一来源。
///
/// 原则：高频、可来回切换的交互（底部分支、dock 指示器）只做短促的淡入，
/// 不加位移——反复切换时位移会叠成「晃」，看久了累；一次性的层级跳转
/// （push / pop）才保留方向感的位移。所有动效统一减速曲线收尾，并尊重
/// 系统「移除动画」（[reduced]）。
class AppMotion {
  AppMotion._();

  /// 微反馈：dock 选中指示器、图标切换。
  static const Duration quick = Duration(milliseconds: 150);

  /// 同级切换：底部分支交叉淡化。
  static const Duration switchFade = Duration(milliseconds: 180);

  /// 层级跳转：页面 push / pop（对齐 Android 14 系统 Activity 转场的 450ms，
  /// 位移曲线 [emphasized] 前段已走完大部分行程，尾段只是收尾减速）。
  static const Duration page = Duration(milliseconds: 450);

  /// 页内自动滚动（dock 主页 / 功能锚点）。
  static const Duration scroll = Duration(milliseconds: 360);

  /// 入场 / 正向：起步快、收尾慢。
  static const Curve standard = Curves.easeOutCubic;

  /// 返回 / 反向：[standard] 的镜像，倒放时仍是先快后慢。
  static const Curve standardReverse = Curves.easeInCubic;

  /// 层级跳转位移：Material 3 emphasized（Android `fast_out_extra_slow_in`）。
  static const Curve emphasized = Curves.fastEaseInToSlowEaseOut;

  /// [emphasized] 的镜像：路由倒放（pop）时同样先快后慢。
  static const Curve emphasizedReverse = FlippedCurve(emphasized);

  /// 系统是否要求移除动画（无障碍「移除动画」/ 开发者选项动画缩放为 0）。
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}
