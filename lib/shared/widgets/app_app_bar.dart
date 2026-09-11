import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/glass_style_controller.dart';
import '../../core/theme/surface_material.dart';
import 'material_noise.dart';

/// 全局玻璃质感 AppBar。
///
/// 毛玻璃层放在 flexibleSpace 内，材质细节见 [GlassAppBarSpace]。
///
/// * 玻璃开启：模糊 + 半透明平色 tint + 底部发丝线，悬浮于滚动内容之上；
/// * 玻璃关闭（[GlassStyleController.enabled]）或显式传入
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

/// 玻璃 AppBar 的填充层，可单独用于 [SliverAppBar.flexibleSpace]。
///
/// 材质由统一 [MaterialRecipe] 驱动（与 [GlassContainer] 同一套配方），不再
/// 自持 BackdropFilter / tint / border 常量：
/// * 玻璃 —— 模糊 + 半透明 tint + 底部发丝线 + 顶部高光；
/// * 亚克力 —— 更强模糊 + 更高 tint + 噪点；
/// * 云母 —— 低模糊 + 更高表面不透明度；
/// * 实色 / 总开关关闭 / 滑条归零 / 显式 [fallbackColor] —— 回退实色填充，
///   不创建 BackdropFilter，保证低端机流畅。
///
/// 注意：裁剪必须放在 BackdropFilter 的祖先位置。BackdropFilter 作用于
/// 整个父层 backdrop 而非自身 bounds，不先裁剪会把整屏内容糊掉。
class GlassAppBarSpace extends StatelessWidget {
  const GlassAppBarSpace({super.key, this.fallbackColor});

  /// 玻璃关闭时的实色回退；null 时按深浅主题取 surfaceContainer 系颜色。
  final Color? fallbackColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final tintColor =
        fallbackColor ??
        (isDark ? cs.surfaceContainerLow : cs.surfaceContainerLowest);
    final style = GlassStyleController.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([
        style.enabled,
        style.blurSigma,
        style.tintOpacity,
        style.materialStyle,
      ]),
      builder: (context, _) {
        final recipe = MaterialRecipe.resolve(
          style.materialStyle.value,
          blurBase: style.blurSigma.value,
          tintBase: style.tintOpacity.value,
        );
        final useGlass =
            fallbackColor == null && style.shouldBlur() && recipe.usesBackdropBlur;
        final sigma = recipe.style == SurfaceMaterialStyle.glass
            ? style.sigmaFor(GlassTier.nav)
            : (recipe.blurSigma * 1.2).clamp(0.0, 44.0);
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
          tintColor: tintColor,
          tintAlpha: useGlass ? _appBarTintAlpha(recipe, isDark) : 1.0,
          borderColor: borderColor,
          highlightOpacity: useGlass ? recipe.highlightOpacity : 0,
          noiseOpacity: useGlass ? recipe.noiseOpacity : 0,
          isDark: isDark,
        );
        return ClipRect(
          child: useGlass
              ? BackdropFilter(
                  filter: ImageFilter.compose(
                    outer: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                    inner: ColorFilter.matrix(
                      saturationColorMatrix(recipe.saturation),
                    ),
                  ),
                  child: fill,
                )
              : fill,
        );
      },
    );
  }

  /// 顶栏 tint 策略：低到能看清模糊，高到标题仍满足 WCAG AA。
  static double _appBarTintAlpha(MaterialRecipe recipe, bool isDark) {
    switch (recipe.style) {
      case SurfaceMaterialStyle.solid:
        return 1.0;
      case SurfaceMaterialStyle.glass:
        return isDark ? 0.34 : 0.42;
      case SurfaceMaterialStyle.acrylic:
        return isDark ? 0.42 : 0.50;
      case SurfaceMaterialStyle.mica:
        return isDark ? 0.50 : 0.58;
    }
  }
}

/// 平色 tint 填充 + 底部发丝线（无受光渐变，深色模式不出现顶缘亮带）。
/// 亚克力 / 云母按配方叠加细微噪点与顶部高光。
class _AppBarFill extends StatelessWidget {
  const _AppBarFill({
    required this.tintColor,
    required this.tintAlpha,
    required this.borderColor,
    this.highlightOpacity = 0,
    this.noiseOpacity = 0,
    this.isDark = true,
  });

  final Color tintColor;
  final double tintAlpha;
  final Color borderColor;
  final double highlightOpacity;
  final double noiseOpacity;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final fill = DecoratedBox(
      decoration: BoxDecoration(
        color: tintColor.withValues(alpha: tintAlpha),
        border: Border(bottom: BorderSide(color: borderColor, width: 0.8)),
      ),
      child: const SizedBox.expand(),
    );

    if (highlightOpacity <= 0.001 && noiseOpacity <= 0.001) return fill;

    return Stack(
      children: [
        fill,
        if (highlightOpacity > 0.001)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: highlightOpacity),
                      Colors.white.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (noiseOpacity > 0.001)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: MaterialNoisePainter(
                  opacity: noiseOpacity,
                  isDark: isDark,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

