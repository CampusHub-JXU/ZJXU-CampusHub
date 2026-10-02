import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/glass_style_controller.dart';
import '../../core/theme/surface_material.dart';
import 'app_surface_style.dart';

/// 全局亚克力质感 AppBar。
///
/// 毛玻璃层放在 flexibleSpace 内，材质细节见 [GlassAppBarSpace]。
///
/// * 亚克力开启：模糊 + 半透明平色 tint + 底部发丝线，悬浮于滚动内容之上；
/// * 亚克力关闭（[GlassStyleController.enabled]）或显式传入
///   [backgroundColor]：回退为实色表面，不创建 BackdropFilter，
///   保证低端机流畅。
class AppAppBar extends StatelessWidget implements PreferredSizeWidget {
  const AppAppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.centerTitle,
    this.bottom,
    this.titleSpacing,
    this.toolbarHeight,
    this.leadingWidth,
    this.backgroundColor,
    this.foregroundColor,
  });

  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final bool automaticallyImplyLeading;
  final bool? centerTitle;
  final PreferredSizeWidget? bottom;
  final double? titleSpacing;
  final double? toolbarHeight;
  final double? leadingWidth;

  /// 显式指定背景色时跳过玻璃层（如扫码页的纯黑顶栏）。
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Size get preferredSize => Size.fromHeight(
    (toolbarHeight ?? kToolbarHeight) + (bottom?.preferredSize.height ?? 0),
  );

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AppBar(
      title: title,
      actions: actions,
      leading: leading,
      automaticallyImplyLeading: automaticallyImplyLeading,
      centerTitle: centerTitle,
      bottom: bottom,
      titleSpacing: titleSpacing,
      toolbarHeight: toolbarHeight,
      leadingWidth: leadingWidth,
      foregroundColor: foregroundColor,
      backgroundColor: backgroundColor ?? Colors.transparent,
      // 透明背景会让 AppBar 把状态栏图标判成浅色（estimateBrightnessForColor
      // 把透明当深色）；玻璃顶栏实际是浅色表面，这里按主题亮度显式指定。
      // 显式 backgroundColor 的调用方（如扫码页纯黑顶栏）保持 AppBar 默认推导。
      systemOverlayStyle: backgroundColor == null
          ? (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
                .copyWith(statusBarColor: Colors.transparent)
          : null,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      flexibleSpace: GlassAppBarSpace(fallbackColor: backgroundColor),
    );
  }
}

/// 亚克力 AppBar 的填充层，可单独用于 [SliverAppBar.flexibleSpace]。
///
/// 材质由统一 [MaterialRecipe] 驱动（与 [GlassContainer] 同一套配方），不再
/// 自持 BackdropFilter / tint / border 常量：
/// * 亚克力 —— 裁剪后 bounded 背景模糊 + 半透明 tint + 底部发丝线；
/// * 实色 / 总开关关闭 / 显式 [fallbackColor] —— 回退实色填充，
///   不创建 BackdropFilter，保证低端机流畅。
///
/// 注意：裁剪必须放在 BackdropFilter 的祖先位置。BackdropFilter 作用于
/// 整个父层 backdrop 而非自身 bounds，不先裁剪会把整屏内容糊掉；模糊经
/// [ImageFilterConfig.blur]（bounded）限制采样范围，杜绝边缘溢色。
class GlassAppBarSpace extends StatelessWidget {
  const GlassAppBarSpace({super.key, this.fallbackColor});

  /// 亚克力关闭时的实色回退；null 时按深浅主题取 surfaceContainer 系颜色。
  final Color? fallbackColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final style = GlassStyleController.instance;

    return ValueListenableBuilder<bool>(
      valueListenable: style.enabled,
      builder: (context, _, _) {
        final recipe = MaterialRecipe.resolve(style.materialStyle);
        final baseTint = isDark
            ? cs.surfaceContainerLow
            : cs.surfaceContainerLowest;
        final tintColor = fallbackColor ?? baseTint;
        final useGlass = fallbackColor == null && recipe.usesBackdropBlur;
        final sigma = (recipe.blurSigma * 1.2).clamp(0.0, 44.0);
        final borderColor = useGlass
            ? (isDark
                  ? Colors.white.withValues(
                      alpha: (recipe.borderOpacity * 0.15).clamp(0.0, 1.0),
                    )
                  : cs.outlineVariant.withValues(
                      alpha: (recipe.borderOpacity * 0.64).clamp(0.0, 1.0),
                    ))
            : Colors.transparent;
        final fill = _AppBarFill(
          tintColor: useGlass
              ? frostedFillColor(base: tintColor, isDark: isDark, alpha: 1.0)
              : tintColor,
          // 顶栏 tint 策略：低到能看清模糊，高到标题仍满足 WCAG AA。
          tintAlpha: useGlass ? (isDark ? 0.42 : 0.50) : 1.0,
          borderColor: borderColor,
        );
        return ClipRect(
          child: useGlass
              ? BackdropFilter(
                  filterConfig: acrylicBackdropFilter(
                    recipe,
                    sigma: sigma,
                    bounded: true,
                  ),
                  child: fill,
                )
              : fill,
        );
      },
    );
  }
}

/// 平色 tint 填充 + 底部发丝线（无受光渐变，深色模式不出现顶缘亮带）。
class _AppBarFill extends StatelessWidget {
  const _AppBarFill({
    required this.tintColor,
    required this.tintAlpha,
    required this.borderColor,
  });

  final Color tintColor;
  final double tintAlpha;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tintColor.withValues(alpha: tintAlpha),
        border: Border(bottom: BorderSide(color: borderColor, width: 0.8)),
      ),
      child: const SizedBox.expand(),
    );
  }
}
