import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_design_tokens.dart';
import 'app_surface_style.dart';

/// 统一的内容卡片容器。
///
/// 收敛散落在各页面的内联 `Container + BoxDecoration` 卡片，统一圆角/边框/阴影语义。
/// 圆角默认 [AppRadius.card]。
///
/// 卡面质感由 [appSurfaceDecoration] / [appSurfaceShadows] 提供：不透明平色
/// 填充 + 落底投影，浅/深双模式独立调参（见 app_surface_style.dart）。
///
/// 卡片是内容面，**永不创建 BackdropFilter**（内容背后没有富媒体，模糊只会
/// 白耗 GPU），也不跟随全局亚克力开关；需要真实模糊的悬浮卡片请改用
/// GlassContainer。
///
/// 严禁用于底部导航、输入表单主区域、长列表承载层（遵循 design-guidelines 红线）。
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
    this.radius = AppRadius.card,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final borderRadius = BorderRadius.circular(radius);

    // 平色填充，装饰直接作用于卡面。
    final surface = Container(
      decoration: appSurfaceDecoration(
        cs: cs,
        isDark: isDark,
        glassEnabled: false,
        borderRadius: borderRadius,
        tintAlpha: 1,
      ),
      padding: padding,
      child: child,
    );

    return _withTap(
      context,
      borderRadius: borderRadius,
      shadows: appSurfaceShadows(isDark: isDark),
      child: surface,
    );
  }

  /// 投影 + 可点包装：涟漪由 InkWell 的 customBorder 裁成 squircle。
  Widget _withTap(
    BuildContext context, {
    required BorderRadius borderRadius,
    required List<BoxShadow> shadows,
    required Widget child,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: borderRadius, boxShadow: shadows),
      child: onTap == null && onLongPress == null
          ? child
          : Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                customBorder: RoundedSuperellipseBorder(
                  borderRadius: borderRadius,
                ),
                child: child,
              ),
            ),
    );
  }
}
