import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/glass_style_controller.dart';

/// 玻璃材质等级定义在参数中心（[GlassStyleController]），此处 re-export
/// 保持既有导入路径 `shared/widgets/glass_container.dart` 向后兼容。
export '../../core/theme/glass_style_controller.dart' show GlassTier;

/// Apple 质感的毛玻璃容器。
///
/// * 毛玻璃 = BackdropFilter(模糊 + 轻微提饱和) + 半透明 tint + 高光细描边；
/// * 形状默认使用连续曲率圆角（squircle，见 [AppShape]）；
/// * 三档模糊强度统一由 [GlassStyleController.sigmaFor] 派生，
///   设置页「模糊强度」滑条对卡片/底栏/弹层同步生效；
/// * [GlassStyleController.enabled] 关闭或滑条拉到 0 时整体降级为实色表面，
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

  /// 覆盖默认模糊策略：显式 `false` 关闭真实模糊（密集列表/内容不悬浮时省
  /// GPU），显式 `true` 强制开启，null 时跟随档位默认（card/nav/overlay
  /// 均默认真实模糊）。
  final bool? blurred;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final radius = borderRadius ?? AppRadius.cardBorder;
    final style = GlassStyleController.instance;

    return ValueListenableBuilder<bool>(
      valueListenable: style.enabled,
      builder: (context, _, _) {
        return ValueListenableBuilder<double>(
          valueListenable: style.blurSigma,
          builder: (context, _, _) {
            return ValueListenableBuilder<double>(
              valueListenable: style.tintOpacity,
              builder: (context, _, _) {
                return _buildSurface(
                  context,
                  glassEnabled: style.shouldBlur(),
                  isDark: isDark,
                  cs: cs,
                  radius: radius,
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildSurface(
    BuildContext context, {
    required bool glassEnabled,
    required bool isDark,
    required ColorScheme cs,
    required BorderRadius radius,
  }) {
    final useBlur = glassEnabled && (blurred ?? true);
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
      tintColor.withValues(alpha: _tintAlphaFor(isDark)),
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
                  sigmaX: _blurSigmaFor(),
                  sigmaY: _blurSigmaFor(),
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
  }

  double _blurSigmaFor() => GlassStyleController.instance.sigmaFor(tier);

  /// tint 不透明度：card 跟随设置页「玻璃透明度」，nav/overlay 为固定档位
  /// （浅色略高于深色），压低到磨砂水平让模糊可见、文字仍可读。
  double _tintAlphaFor(bool isDark) {
    final cardAlpha = GlassStyleController.instance.tintOpacity.value;
    if (tier == GlassTier.card) return isDark ? cardAlpha * 0.86 : cardAlpha;
    return isDark
        ? (tier == GlassTier.nav ? 0.42 : 0.58)
        : (tier == GlassTier.nav ? 0.52 : 0.66);
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
