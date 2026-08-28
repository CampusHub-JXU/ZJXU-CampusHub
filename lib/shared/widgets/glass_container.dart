import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/glass_style_controller.dart';

/// 玻璃材质等级。
///
/// 同一屏的模糊层数量直接决定 GPU 开销，等级制用于约束用量：
/// * [GlassTier.card] —— 内容卡片，默认**不模糊**（半透明 tint + 高光描边），
///   只有内容明确悬浮在富媒体/背景之上时才开 [blurred]。
/// * [GlassTier.nav] —— 底部导航 / 悬浮操作条，整屏至多一个。
/// * [GlassTier.overlay] —— 弹层、菜单、抽屉头部，转瞬即逝，允许重模糊。
enum GlassTier { card, nav, overlay }

/// Apple 质感的毛玻璃容器。
///
/// * 毛玻璃 = BackdropFilter(模糊 + 轻微提饱和) + 半透明 tint + 高光细描边；
/// * 形状默认使用连续曲率圆角（squircle，见 [AppShape]）；
/// * [GlassStyleController.enabled] 关闭时整体降级为实色表面，
///   不创建 BackdropFilter，保证低端机流畅。
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.tier = GlassTier.card,
    this.borderRadius,
    this.padding,
    this.width,
    this.height,
    this.alignment,
    this.blurred,
    this.onTap,
  });

  final Widget child;
  final GlassTier tier;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;
  final AlignmentGeometry? alignment;

  /// 覆盖该等级的默认模糊策略；仅在 tier == card 时有意义。
  final bool? blurred;
  final VoidCallback? onTap;

  double get _defaultBlurSigma => switch (tier) {
    GlassTier.card => 18,
    GlassTier.nav => 24,
    GlassTier.overlay => 30,
  };

  double get _tintAlpha => switch (tier) {
    GlassTier.card => 0.72,
    GlassTier.nav => 0.62,
    GlassTier.overlay => 0.86,
  };

  double get _tintAlphaDark => switch (tier) {
    GlassTier.card => 0.58,
    GlassTier.nav => 0.52,
    GlassTier.overlay => 0.78,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final radius = borderRadius ?? AppRadius.cardBorder;

    return ValueListenableBuilder<bool>(
      valueListenable: GlassStyleController.instance.enabled,
      builder: (context, glassEnabled, _) {
        final useBlur = glassEnabled && (blurred ?? tier != GlassTier.card);
        final tintAlpha = isDark ? _tintAlphaDark : _tintAlpha;
        final tintColor = isDark
            ? cs.surfaceContainerLow
            : cs.surfaceContainerLowest;
        final borderAlpha = glassEnabled
            ? (isDark ? 0.14 : 0.70)
            : (isDark ? 0.10 : 0.55);
        final borderColor = isDark
            ? Colors.white.withValues(alpha: borderAlpha)
            : cs.outlineVariant.withValues(alpha: borderAlpha);

        // 玻璃 tint 与边缘高光合成为一个渐变（gradient 会覆盖 color）：
        // 顶部受光面提亮更多，底部回光面几乎保持 tint 本色。
        Color tintWithHighlight(double highlightAlpha) => Color.alphaBlend(
          Colors.white.withValues(alpha: highlightAlpha),
          tintColor.withValues(alpha: tintAlpha),
        );

        final content = Container(
          width: width,
          height: height,
          alignment: alignment,
          padding: padding,
          decoration: ShapeDecoration(
            color: useBlur
                ? null
                : (isDark ? cs.surfaceContainerLow : cs.surfaceContainerLowest),
            gradient: useBlur
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      tintWithHighlight(isDark ? 0.10 : 0.34),
                      tintWithHighlight(isDark ? 0.02 : 0.08),
                    ],
                  )
                : null,
            shadows: useBlur ? _shadows(isDark) : null,
            shape: RoundedSuperellipseBorder(
              borderRadius: radius,
              side: BorderSide(color: borderColor, width: isDark ? 0.8 : 1.0),
            ),
          ),
          child: child,
        );

        // 关键：裁剪必须放在 BackdropFilter 的祖先位置。
        // BackdropFilter 会把模糊作用于整个父层 backdrop 而非自身 bounds，
        // 不先裁剪就会把整屏内容糊掉。
        final glassLayer = ClipRRect(
          borderRadius: radius,
          child: useBlur
              ? BackdropFilter(
                  filter: ImageFilter.compose(
                    outer: ImageFilter.blur(
                      sigmaX: _defaultBlurSigma,
                      sigmaY: _defaultBlurSigma,
                    ),
                    inner: const ColorFilter.matrix(<double>[
                      1.06, 0, 0, 0, 0, //
                      0, 1.06, 0, 0, 0, //
                      0, 0, 1.06, 0, 0, //
                      0, 0, 0, 1, 0,
                    ]),
                  ),
                  child: content,
                )
              : content,
        );

        if (onTap == null) return glassLayer;

        return Material(
          color: Colors.transparent,
          child: InkWell(borderRadius: radius, onTap: onTap, child: glassLayer),
        );
      },
    );
  }

  List<BoxShadow> _shadows(bool isDark) {
    if (isDark) {
      return const [
        BoxShadow(
          color: Color(0x33000000),
          blurRadius: 18,
          offset: Offset(0, 6),
        ),
      ];
    }
    return const [
      BoxShadow(color: Color(0x14000000), blurRadius: 14, offset: Offset(0, 4)),
    ];
  }
}
