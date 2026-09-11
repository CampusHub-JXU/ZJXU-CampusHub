import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/glass_style_controller.dart';
import '../../../core/theme/personalization_controller.dart';
import '../../../core/theme/widgets/home_background_layer.dart';

/// 外观页顶部的真实比例首页预览（PRD 0.7.0 §16/§17）。
///
/// 从原 `PersonalizationPage` 抽出的可复用预览：背景走真实
/// [HomeBackgroundLayer]，卡片/头部按当前 Glass 配置合成。
/// TODO(0.7.0-B2): 换成与真实 Home 共用的 HomeSurfaceScene。
class AppearancePreview extends StatefulWidget {
  const AppearancePreview({
    super.key,
    this.maxHeight = 320,
    this.homeSceneBuilder,
  });

  final double maxHeight;

  /// 真实首页场景构建器（由 app 层注入 `HomeSurfaceScene`，避免
  /// feature→feature 依赖）。为空时回退到内置示意层。
  final WidgetBuilder? homeSceneBuilder;

  @override
  State<AppearancePreview> createState() => _AppearancePreviewState();
}

class _AppearancePreviewState extends State<AppearancePreview> {
  double _gestureStartScale = 1.0;
  Alignment _gestureStartAlignment = Alignment.center;
  Offset _gestureStartFocalPoint = Offset.zero;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: PersonalizationController.instance.backgroundImagePath,
      builder: (context, bgPath, _) {
        return ValueListenableBuilder<Alignment>(
          valueListenable:
              PersonalizationController.instance.backgroundAlignment,
          builder: (context, alignment, _) {
            return ValueListenableBuilder<double>(
              valueListenable:
                  PersonalizationController.instance.backgroundScale,
              builder: (context, scale, _) {
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final frameSize = _homePreviewFrameSize(
                      context,
                      constraints.maxWidth,
                    );
                    return Center(
                      child: SizedBox(
                        width: frameSize.width,
                        height: frameSize.height,
                        child: ClipRRect(
                          borderRadius: AppRadius.tileBorder,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHigh,
                              border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant
                                    .withValues(alpha: 0.7),
                              ),
                            ),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onScaleStart: (details) {
                                _gestureStartScale = scale;
                                _gestureStartAlignment = alignment;
                                _gestureStartFocalPoint = details.focalPoint;
                              },
                              onScaleUpdate: (details) {
                                _updatePreviewTransform(
                                  focalPoint: details.focalPoint,
                                  frameSize: frameSize,
                                  scale: details.scale,
                                );
                              },
                              onScaleEnd: (_) {
                                PersonalizationController.instance
                                    .setBackgroundAlignment(
                                      PersonalizationController
                                          .instance
                                          .backgroundAlignment
                                          .value,
                                    );
                                PersonalizationController.instance
                                    .setBackgroundScale(
                                      PersonalizationController
                                          .instance
                                          .backgroundScale
                                          .value,
                                    );
                              },
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  if (bgPath != null)
                                    HomeBackgroundLayer(
                                      path: bgPath,
                                      errorBuilder: (context) {
                                        return Container(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerHigh,
                                        );
                                      },
                                    )
                                  else
                                    _buildPreviewBackgroundPlaceholder(
                                      context,
                                    ),
                                  widget.homeSceneBuilder?.call(context) ??
                                      _buildHomeWidgetPreviewOverlay(context),
                                  Positioned(
                                    top: 10,
                                    right: 10,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(
                                          alpha: 0.42,
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          AppRadius.chip,
                                        ),
                                      ),
                                      child: const Text(
                                        '首页可见区域 · 拖动/双指缩放',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Size _homePreviewFrameSize(BuildContext context, double maxWidth) {
    final media = MediaQuery.of(context);
    const bottomNavigationHeight = 80.0;
    final visibleHeight = math.max(
      1.0,
      media.size.height -
          media.padding.top -
          media.padding.bottom -
          bottomNavigationHeight,
    );
    final aspect = media.size.width / visibleHeight;
    final frameWidth = maxWidth;
    final frameHeight = math.min(widget.maxHeight, frameWidth / aspect);
    return Size(frameHeight * aspect, frameHeight);
  }

  Widget _buildPreviewBackgroundPlaceholder(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surfaceContainerHigh,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.wallpaper_outlined,
              size: 32,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(height: 6),
            Text(
              '暂未设置背景图片',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeWidgetPreviewOverlay(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: PersonalizationController.instance.headerGlassEnabled,
      builder: (context, headerGlassEnabled, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: GlassStyleController.instance.enabled,
          builder: (context, cardGlassEnabled, _) {
            return ValueListenableBuilder<double>(
              valueListenable: GlassStyleController.instance.blurSigma,
              builder: (context, glassBlur, _) {
                return ValueListenableBuilder<double>(
                  valueListenable: GlassStyleController.instance.tintOpacity,
                  builder: (context, glassOpacity, _) {
                    return _buildHomeWidgetPreviewBoxes(
                      context,
                      headerGlassEnabled: headerGlassEnabled,
                      cardGlassEnabled: cardGlassEnabled,
                      glassBlur: glassBlur,
                      glassOpacity: glassOpacity,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildHomeWidgetPreviewBoxes(
    BuildContext context, {
    required bool headerGlassEnabled,
    required bool cardGlassEnabled,
    required double glassBlur,
    required double glassOpacity,
  }) {
    Widget box({
      required double left,
      required double top,
      required double width,
      required double height,
      required bool glassEnabled,
      double radius = 10,
    }) {
      final borderRadius = BorderRadius.circular(radius);
      final surfaceAlpha = glassEnabled ? glassOpacity : 0.16;
      final borderAlpha = glassEnabled ? 0.42 : 0.72;
      final content = DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: surfaceAlpha),
          borderRadius: borderRadius,
          border: Border.all(
            color: Colors.white.withValues(alpha: borderAlpha),
            width: 1.2,
          ),
        ),
      );
      return Positioned(
        left: left,
        top: top,
        width: width,
        height: height,
        child: IgnorePointer(
          child: ClipRRect(
            borderRadius: borderRadius,
            child: glassEnabled
                ? BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: glassBlur,
                      sigmaY: glassBlur,
                    ),
                    child: content,
                  )
                : content,
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final pad = w * 0.055;
        return Stack(
          children: [
            box(
              left: pad,
              top: h * 0.09,
              width: w - pad * 2,
              height: h * 0.22,
              glassEnabled: headerGlassEnabled,
              radius: 16,
            ),
            box(
              left: pad,
              top: h * 0.36,
              width: (w - pad * 2 - 8) / 2,
              height: h * 0.16,
              glassEnabled: cardGlassEnabled,
            ),
            box(
              left: pad + (w - pad * 2 + 8) / 2,
              top: h * 0.36,
              width: (w - pad * 2 - 8) / 2,
              height: h * 0.13,
              glassEnabled: cardGlassEnabled,
            ),
            box(
              left: pad,
              top: h * 0.54,
              width: (w - pad * 2 - 8) / 2,
              height: h * 0.10,
              glassEnabled: cardGlassEnabled,
            ),
            box(
              left: pad + (w - pad * 2 + 8) / 2,
              top: h * 0.51,
              width: (w - pad * 2 - 8) / 2,
              height: h * 0.10,
              glassEnabled: cardGlassEnabled,
            ),
          ],
        );
      },
    );
  }

  void _updatePreviewTransform({
    required Offset focalPoint,
    required Size frameSize,
    required double scale,
  }) {
    final delta = focalPoint - _gestureStartFocalPoint;
    PersonalizationController.instance.backgroundAlignment.value = Alignment(
      (_gestureStartAlignment.x + delta.dx / frameSize.width * 2).clamp(
        -2.0,
        2.0,
      ),
      (_gestureStartAlignment.y + delta.dy / frameSize.height * 2).clamp(
        -2.0,
        2.0,
      ),
    );
    PersonalizationController.instance.backgroundScale.value =
        (_gestureStartScale * scale).clamp(0.5, 3.0);
  }
}
