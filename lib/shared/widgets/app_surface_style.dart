import 'package:flutter/material.dart';

/// Apple 质感卡面配方（浅 / 深双模式，纯 tint、零 BackdropFilter）。
///
/// 把「一块平色 + 一圈均匀细线」换成三条可感知的深度线索：
///
/// 1. **定向受光描边（ring）**——1px 渐变环，顶部亮、底部收：深色模式下是
///    顶缘吃光的暗面浮起，浅色模式下是底缘压线；替代均匀 BorderSide 的
///    「铁丝框」感。
/// 2. **受光高光（sheen）**——左上 → 右下的白光衰减渐变，玻璃开启时叠加在
///    tint 之上；关闭时整层退化为实色。
/// 3. **落底投影（shadows）**——接触影 + 环境影双层（深色单环境影），把卡片
///    从环境背景上「托」起来；深浅两模式独立调参。
///
/// 使用方式：ring 层整幅渐变填充，fill 层内缩 1px 盖在上面，露出的一圈即为
/// 描边（见 `AppTileSurface` 与 `AppCard`）。玻璃参数语义与 GlassContainer
/// card tier 一致：[GlassStyleController.enabled] 关闭时走实色降级，
/// tint 不透明度由调用方按档位换算后经 `tintAlpha` 传入。
/// 描边环圆角使用外层 [AppRadius] 令牌，填充层圆角 = 外层 - 1（见
/// [appSurfaceInnerRadius]）。

/// 描边环装饰：整幅渐变填充，可见部分仅为被 fill 层覆盖后露出的一圈。
ShapeDecoration appSurfaceRingDecoration({
  required ColorScheme cs,
  required bool isDark,
  required bool glassEnabled,
  required BorderRadius borderRadius,
}) {
  final List<Color> colors;
  if (isDark) {
    // 深色：顶缘吃光（亮），向底部收束到几乎融入填充。
    colors = glassEnabled
        ? const [Color(0x33FFFFFF), Color(0x0DFFFFFF)]
        : const [Color(0x24FFFFFF), Color(0x0FFFFFFF)];
  } else {
    // 浅色：顶缘几乎融入填充，底缘压出一条明确的收边线。
    colors = [
      cs.outlineVariant.withValues(alpha: glassEnabled ? 0.30 : 0.28),
      cs.outlineVariant.withValues(alpha: glassEnabled ? 0.80 : 0.70),
    ];
  }
  return ShapeDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: colors,
    ),
    shape: RoundedSuperellipseBorder(borderRadius: borderRadius),
  );
}

/// 填充层装饰：玻璃开启时为「tint + 顶部受光高光」渐变，关闭时为实色。
///
/// [tintAlpha] 为玻璃开启时的基础 tint 不透明度（card tier 浅色原值、深色
/// ×0.86，与 GlassContainer 口径一致）。深色模式先把填充整体抬亮一档
/// （+3.5% 白），再叠 sheen——保证 sheen 收敛到 0 的底部仍有分离度。
ShapeDecoration appSurfaceFillDecoration({
  required ColorScheme cs,
  required bool isDark,
  required bool glassEnabled,
  required BorderRadius borderRadius,
  required double tintAlpha,
}) {
  final base = isDark ? cs.surfaceContainerLow : cs.surfaceContainerLowest;
  final liftedBase = isDark
      ? Color.alphaBlend(Colors.white.withValues(alpha: 0.035), base)
      : base;

  if (!glassEnabled) {
    return ShapeDecoration(
      color: liftedBase,
      shape: RoundedSuperellipseBorder(borderRadius: borderRadius),
    );
  }

  Color sheenAt(double highlightAlpha) => Color.alphaBlend(
    Colors.white.withValues(alpha: highlightAlpha),
    liftedBase.withValues(alpha: tintAlpha),
  );

  return ShapeDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [sheenAt(isDark ? 0.09 : 0.32), sheenAt(isDark ? 0.015 : 0.06)],
    ),
    shape: RoundedSuperellipseBorder(borderRadius: borderRadius),
  );
}

/// 落底投影：浅色为「接触影 + 环境影」双层，深色为单层环境影。
List<BoxShadow> appSurfaceShadows({required bool isDark}) {
  if (isDark) {
    return const [
      BoxShadow(color: Color(0x47000000), blurRadius: 16, offset: Offset(0, 6)),
    ];
  }
  return const [
    BoxShadow(color: Color(0x0F000000), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x14000000), blurRadius: 20, offset: Offset(0, 8)),
  ];
}

/// 填充层圆角：外层描边环半径 - 1px（描边厚度）。
BorderRadius appSurfaceInnerRadius(BorderRadius outer) =>
    BorderRadius.circular(outer.topLeft.x - 1);
