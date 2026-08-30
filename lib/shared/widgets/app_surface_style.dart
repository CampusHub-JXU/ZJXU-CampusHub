import 'package:flutter/material.dart';

/// Apple 风格平色卡面配方（浅 / 深双模式，零高光、零 BackdropFilter）。
///
/// 卡面深度感全部来自「平色 + 细线 + 柔影」的组合，不做任何方向性受光
/// 渐变（sheen / 受光描边环已移除——纯色背景下高光只能读出塑料感）：
///
/// 1. **平色填充**——深色 `surfaceContainerLow`、浅色
///    `surfaceContainerLowest`；玻璃开启时替换为同色半透明 tint，
///    透明度由调用方按档位换算后经 `tintAlpha` 传入。
/// 2. **均匀 hairline 描边**——1px 统一细线，参数与 GlassContainer 边框
///    完全一致，保证卡面与玻璃容器材质同族。
/// 3. **落底投影（[appSurfaceShadows]）**——浅色接触影 + 环境影双层、
///    深色单环境影，把卡片从背景上「托」起来。
///
/// 使用方式：装饰直接作用在卡面 Container 上（描边走 shape 的 side，
/// 无需 ring/fill 双层内缩，见 `AppCard` 与 `AppTileSurface`）。

/// 平色卡面装饰：flat 填充 + 均匀 hairline 描边，玻璃开启时为半透明 tint。
ShapeDecoration appSurfaceDecoration({
  required ColorScheme cs,
  required bool isDark,
  required bool glassEnabled,
  required BorderRadius borderRadius,
  required double tintAlpha,
}) {
  final base = isDark ? cs.surfaceContainerLow : cs.surfaceContainerLowest;
  return ShapeDecoration(
    color: glassEnabled ? base.withValues(alpha: tintAlpha) : base,
    shape: RoundedSuperellipseBorder(
      borderRadius: borderRadius,
      side: appSurfaceBorder(
        isDark: isDark,
        glassEnabled: glassEnabled,
        cs: cs,
      ),
    ),
  );
}

/// 卡面 hairline 描边：与 GlassContainer 的边框同参数（深色 white 低透明、
/// 浅色 outlineVariant），玻璃开启略提亮一档。
BorderSide appSurfaceBorder({
  required bool isDark,
  required bool glassEnabled,
  required ColorScheme cs,
}) {
  final borderAlpha = glassEnabled
      ? (isDark ? 0.14 : 0.70)
      : (isDark ? 0.10 : 0.55);
  return BorderSide(
    color: isDark
        ? Colors.white.withValues(alpha: borderAlpha)
        : cs.outlineVariant.withValues(alpha: borderAlpha),
    width: isDark ? 0.8 : 1.0,
  );
}

/// 落底投影：仅深色模式保留单层环境影；浅色模式零投影——白卡与中性灰
/// scaffold 的色调对比 + hairline 描边已经完成分层，弱投影只会渲染成
/// 一圈脏灰雾（Apple 分组列表同款做法）。
List<BoxShadow> appSurfaceShadows({required bool isDark}) {
  if (isDark) {
    return const [
      BoxShadow(color: Color(0x47000000), blurRadius: 16, offset: Offset(0, 6)),
    ];
  }
  return const [];
}
