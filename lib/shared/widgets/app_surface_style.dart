import 'package:flutter/material.dart';

/// Apple 风格平色卡面配方（浅 / 深双模式，零高光、零 BackdropFilter）。
///
/// 视觉做减法：卡面只剩「平色填充 + 深色柔影」，不做描边——重复的
/// hairline 圆角矩形框线是视觉疲劳的主要来源；分层交给色调对比与柔影
/// 完成，Dock 这类真正需要材质层次的玻璃容器另行处理：
///
/// 1. **平色填充**——深色 `surfaceContainerLow`、浅色
///    `surfaceContainerLowest`；玻璃开启时替换为同色半透明 tint，
///    透明度由调用方按档位换算后经 `tintAlpha` 传入。
/// 2. **落底投影（[appSurfaceShadows]）**——仅深色保留单层环境影，
///    浅色零投影（白卡与中性灰 scaffold 的色调对比已经完成分层）。
///
/// 使用方式：装饰直接作用在卡面 Container 上（见 `AppCard` 与
/// `AppTileSurface`）。

/// 卡面平色填充：玻璃开启时为半透明 tint，透明度由调用方按档位换算。
Color appSurfaceColor({
  required ColorScheme cs,
  required bool isDark,
  required bool glassEnabled,
  required double tintAlpha,
}) {
  final base = isDark ? cs.surfaceContainerLow : cs.surfaceContainerLowest;
  return glassEnabled ? base.withValues(alpha: tintAlpha) : base;
}

/// 平色卡面装饰：无描边的 flat 填充，玻璃开启时为半透明 tint。
ShapeDecoration appSurfaceDecoration({
  required ColorScheme cs,
  required bool isDark,
  required bool glassEnabled,
  required BorderRadius borderRadius,
  required double tintAlpha,
}) {
  return ShapeDecoration(
    color: appSurfaceColor(
      cs: cs,
      isDark: isDark,
      glassEnabled: glassEnabled,
      tintAlpha: tintAlpha,
    ),
    shape: RoundedSuperellipseBorder(borderRadius: borderRadius),
  );
}

/// 落底投影：仅深色模式保留单层环境影；浅色模式零投影——白卡与中性灰
/// scaffold 的色调对比已经完成分层，弱投影只会渲染成一圈脏灰雾
/// （Apple 分组列表同款做法）。
List<BoxShadow> appSurfaceShadows({required bool isDark}) {
  if (isDark) {
    return const [
      BoxShadow(color: Color(0x47000000), blurRadius: 16, offset: Offset(0, 6)),
    ];
  }
  return const [];
}
