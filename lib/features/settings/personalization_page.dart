import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../home/home_controller.dart';
import '../home/widgets/home_background_layer.dart';
import 'widgets/personalization_background_section.dart';
import 'widgets/personalization_glass_section.dart';
import 'widgets/personalization_shader_section.dart';

class PersonalizationPage extends StatefulWidget {
  const PersonalizationPage({super.key});

  @override
  State<PersonalizationPage> createState() => _PersonalizationPageState();
}

class _PersonalizationPageState extends State<PersonalizationPage> {
  bool _previewDragging = false;
  double _gestureStartScale = 1.0;
  Alignment _gestureStartAlignment = Alignment.center;
  Offset _gestureStartFocalPoint = Offset.zero;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('首页个性化')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: _buildPreviewSection(context, maxHeight: 320),
          ),
          Expanded(
            child: ListView(
              physics: _previewDragging
                  ? const NeverScrollableScrollPhysics()
                  : const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: const [
                PersonalizationBackgroundSection(),
                SizedBox(height: 16),
                PersonalizationShaderSection(),
                SizedBox(height: 16),
                PersonalizationGlassSection(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Preview ---

  Widget _buildPreviewSection(BuildContext context, {double maxHeight = 520}) {
    return ValueListenableBuilder<String?>(
      valueListenable: HomeController.instance.backgroundImagePath,
      builder: (context, bgPath, _) {
        if (bgPath == null) {
          return Card(
            clipBehavior: Clip.antiAlias,
            child: Container(
              height: 120,
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.wallpaper_outlined,
                    size: 36,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '暂未设置背景图片',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return ValueListenableBuilder<Alignment>(
          valueListenable: HomeController.instance.backgroundAlignment,
          builder: (context, alignment, _) {
            return ValueListenableBuilder<double>(
              valueListenable: HomeController.instance.backgroundScale,
              builder: (context, scale, _) {
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final frameSize = _homePreviewFrameSize(
                      context,
                      constraints.maxWidth,
                      maxHeight: maxHeight,
                    );
                    final frameWidth = frameSize.width;
                    final frameHeight = frameSize.height;
                    return Center(
                      child: SizedBox(
                        width: frameWidth,
                        height: frameHeight,
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
                                setState(() => _previewDragging = true);
                              },
                              onScaleUpdate: (details) {
                                _updatePreviewTransform(
                                  focalPoint: details.focalPoint,
                                  frameSize: frameSize,
                                  scale: details.scale,
                                );
                              },
                              onScaleEnd: (_) {
                                setState(() => _previewDragging = false);
                                HomeController.instance.setBackgroundAlignment(
                                  HomeController
                                      .instance
                                      .backgroundAlignment
                                      .value,
                                );
                                HomeController.instance.setBackgroundScale(
                                  HomeController.instance.backgroundScale.value,
                                );
                              },
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  HomeBackgroundLayer(
                                    path: bgPath,
                                    errorBuilder: (context) {
                                      return Container(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.surfaceContainerHigh,
                                        child: const Center(
                                          child: Icon(
                                            Icons.broken_image_outlined,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
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

  Size _homePreviewFrameSize(
    BuildContext context,
    double maxWidth, {
    double maxHeight = 520,
  }) {
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
    final frameHeight = math.min(maxHeight, frameWidth / aspect);
    return Size(frameHeight * aspect, frameHeight);
  }

  Widget _buildHomeWidgetPreviewOverlay(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: HomeController.instance.headerGlassEnabled,
      builder: (context, headerGlassEnabled, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: HomeController.instance.frostedGlassEnabled,
          builder: (context, cardGlassEnabled, _) {
            return ValueListenableBuilder<double>(
              valueListenable: HomeController.instance.glassBlur,
              builder: (context, glassBlur, _) {
                return ValueListenableBuilder<double>(
                  valueListenable: HomeController.instance.glassOpacity,
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
    HomeController.instance.backgroundAlignment.value = Alignment(
      (_gestureStartAlignment.x + delta.dx / frameSize.width * 2).clamp(
        -2.0,
        2.0,
      ),
      (_gestureStartAlignment.y + delta.dy / frameSize.height * 2).clamp(
        -2.0,
        2.0,
      ),
    );
    HomeController.instance.backgroundScale.value = (_gestureStartScale * scale)
        .clamp(0.5, 3.0);
  }
}
