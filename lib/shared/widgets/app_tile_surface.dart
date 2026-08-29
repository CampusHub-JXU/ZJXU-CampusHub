import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/glass_style_controller.dart';
import 'app_surface_style.dart';

/// 可点卡面的统一质感容器（平色填充 + hairline 描边 + 落底投影）。
///
/// 结构：Material → Ink(配方装饰) → InkWell。涟漪绘制在 Material 上、由
/// customBorder 裁成 squircle；单层 Ink 只负责质感，零 BackdropFilter。
/// 玻璃参数实时监听 [GlassStyleController]：
/// [GlassStyleController.enabled] 关闭时走实色降级，投影保留。
class AppTileSurface extends StatelessWidget {
  const AppTileSurface({
    super.key,
    required this.child,
    this.borderRadius,
    this.padding,
    this.onTap,
    this.onLongPress,
  });

  final Widget child;

  /// 卡面圆角；空时取 [AppRadius.tileBorder]。
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final style = GlassStyleController.instance;
    final radius = borderRadius ?? AppRadius.tileBorder;

    return ValueListenableBuilder<bool>(
      valueListenable: style.enabled,
      builder: (context, glassEnabled, _) {
        return ValueListenableBuilder<double>(
          valueListenable: style.tintOpacity,
          builder: (context, tintOpacity, _) {
            return Material(
              color: Colors.transparent,
              child: Ink(
                decoration: appSurfaceDecoration(
                  cs: Theme.of(context).colorScheme,
                  isDark: isDark,
                  glassEnabled: glassEnabled,
                  borderRadius: radius,
                  tintAlpha: isDark ? tintOpacity * 0.86 : tintOpacity,
                ),
                child: InkWell(
                  onTap: onTap,
                  onLongPress: onLongPress,
                  customBorder: RoundedSuperellipseBorder(
                    borderRadius: radius,
                  ),
                  child: Padding(
                    padding: padding ?? EdgeInsets.zero,
                    child: child,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
