import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/glass_style_controller.dart';

/// 全局玻璃质感 AppBar。
///
/// 毛玻璃层放在 flexibleSpace 内，材质细节见 [GlassAppBarSpace]。
///
/// * 玻璃开启：模糊 + 半透明 tint 渐变 + 底部发丝线，悬浮于滚动内容之上；
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
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      flexibleSpace: GlassAppBarSpace(fallbackColor: backgroundColor),
    );
  }
}

/// 玻璃 AppBar 的填充层，可单独用于 [SliverAppBar.flexibleSpace]。
///
/// 注意：裁剪必须放在 BackdropFilter 的祖先位置。BackdropFilter 作用于
/// 整个父层 backdrop 而非自身 bounds，不先裁剪会把整屏内容糊掉。
///
/// [GlassStyleController.enabled] 关闭时回退为 [fallbackColor]（缺省为
/// 主题 surfaceContainer）的实色填充。
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
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : cs.outlineVariant.withValues(alpha: 0.45);
    final style = GlassStyleController.instance;

    return ValueListenableBuilder<bool>(
      valueListenable: style.enabled,
      builder: (context, glassEnabled, _) {
        final useGlass = glassEnabled && fallbackColor == null;
        return ClipRect(
          child: useGlass
              ? BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: _AppBarFill(
                    tintColor: tintColor,
                    tintAlpha: isDark ? 0.58 : 0.72,
                    borderColor: borderColor,
                  ),
                )
              : _AppBarFill(
                  tintColor: tintColor,
                  tintAlpha: 1.0,
                  borderColor: Colors.transparent,
                ),
        );
      },
    );
  }
}

/// 顶部受光、底部回光的 tint 渐变 + 底部发丝线。
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
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.alphaBlend(
              Colors.white.withValues(alpha: 0.14),
              tintColor.withValues(alpha: tintAlpha),
            ),
            tintColor.withValues(alpha: tintAlpha),
          ],
        ),
        border: Border(bottom: BorderSide(color: borderColor, width: 0.8)),
      ),
      child: const SizedBox.expand(),
    );
  }
}
