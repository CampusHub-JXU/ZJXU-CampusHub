import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/glass_style_controller.dart';
import '../../../core/theme/personalization_controller.dart';
import '../../../core/theme/widgets/home_background_layer.dart';
import '../../../shared/widgets/app_tile_surface.dart';
import '../../../shared/widgets/glass_container.dart';

/// 预览场景：「主页」用真实首页场景并支持拖动/捏合调整壁纸；
/// 「功能」「我的」只是静态示意（壁纸 + 占位磁贴 + dock），不跑真实页面树。
enum AppearancePreviewScene { home, functions, my }

/// 按下即宣告胜出的缩放识别器：预览框处于可调状态时，竖向拖动不交给外层
/// 可滚动列表（默认竖向拖动的判定阈值比缩放小，会先赢走手势）。
class _EagerScaleGestureRecognizer extends ScaleGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class _PreviewGestureDetector extends StatelessWidget {
  const _PreviewGestureDetector({
    required this.eager,
    required this.onScaleStart,
    required this.onScaleUpdate,
    required this.onScaleEnd,
    required this.child,
  });

  final bool eager;
  final GestureScaleStartCallback? onScaleStart;
  final GestureScaleUpdateCallback? onScaleUpdate;
  final GestureScaleEndCallback? onScaleEnd;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!eager) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: onScaleStart,
        onScaleUpdate: onScaleUpdate,
        onScaleEnd: onScaleEnd,
        child: child,
      );
    }
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        _EagerScaleGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<_EagerScaleGestureRecognizer>(
              _EagerScaleGestureRecognizer.new,
              (r) => r
                ..onStart = onScaleStart
                ..onUpdate = onScaleUpdate
                ..onEnd = onScaleEnd,
            ),
      },
      child: child,
    );
  }
}

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
    this.scene = AppearancePreviewScene.home,
  });

  final double maxHeight;

  /// 预览哪个页面；手势只在 [AppearancePreviewScene.home] 生效。
  final AppearancePreviewScene scene;

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
    final cs = Theme.of(context).colorScheme;
    final isHome = widget.scene == AppearancePreviewScene.home;
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
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHigh,
                              border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant
                                    .withValues(alpha: 0.7),
                              ),
                            ),
                            child: _PreviewGestureDetector(
                              // 可调壁纸时按下即独占手势，竖向拖动不再被外层
                              // 设置列表抢去滚动；框外拖动照常滚动页面。
                              eager: isHome && bgPath != null,
                              onScaleStart: !isHome
                                  ? null
                                  : (details) {
                                      _gestureStartScale = scale;
                                      _gestureStartAlignment = alignment;
                                      _gestureStartFocalPoint =
                                          details.focalPoint;
                                    },
                              onScaleUpdate: !isHome
                                  ? null
                                  : (details) {
                                      _updatePreviewTransform(
                                        focalPoint: details.focalPoint,
                                        frameSize: frameSize,
                                        scale: details.scale,
                                      );
                                    },
                              onScaleEnd: !isHome
                                  ? null
                                  : (_) {
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
                                    _buildPreviewBackgroundPlaceholder(context),
                                  switch (widget.scene) {
                                    AppearancePreviewScene.home =>
                                      widget.homeSceneBuilder?.call(context) ??
                                          _buildHomeWidgetPreviewOverlay(
                                            context,
                                          ),
                                    AppearancePreviewScene.functions =>
                                      const _FunctionsSceneMock(),
                                    AppearancePreviewScene.my =>
                                      const _MySceneMock(),
                                  },
                                  if (isHome && bgPath != null)
                                    Positioned(
                                      top: 10,
                                      right: 10,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: cs.inverseSurface.withValues(
                                            alpha: 0.72,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            AppRadius.chip,
                                          ),
                                        ),
                                        child: Text(
                                          '拖动 / 双指缩放',
                                          style: TextStyle(
                                            color: cs.onInverseSurface,
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
    // 与真实首页一致：顶部课表区不加模糊，功能卡片走亚克力。
    return ValueListenableBuilder<bool>(
      valueListenable: GlassStyleController.instance.enabled,
      builder: (context, cardGlassEnabled, _) {
        return _buildHomeWidgetPreviewBoxes(
          context,
          headerGlassEnabled: false,
          cardGlassEnabled: cardGlassEnabled,
        );
      },
    );
  }

  Widget _buildHomeWidgetPreviewBoxes(
    BuildContext context, {
    required bool headerGlassEnabled,
    required bool cardGlassEnabled,
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
      return Positioned(
        left: left,
        top: top,
        width: width,
        height: height,
        child: IgnorePointer(
          child: GlassContainer(
            borderRadius: borderRadius,
            blurred: glassEnabled,
            child: const SizedBox.expand(),
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

/// 静态示意的底部 dock：与真实 dock 同为浮层材质，只画四个占位点。
class _DockMock extends StatelessWidget {
  const _DockMock({required this.activeIndex});

  final int activeIndex;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final dockHeight = (h * 0.075).clamp(10.0, 44.0);
        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(bottom: h * 0.025),
            child: IgnorePointer(
              child: GlassContainer(
                tier: GlassTier.nav,
                width: w * 0.62,
                height: dockHeight,
                borderRadius: BorderRadius.circular(dockHeight / 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (var i = 0; i < 4; i++)
                      Container(
                        width: dockHeight * 0.32,
                        height: dockHeight * 0.32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i == activeIndex
                              ? cs.primary
                              : cs.onSurfaceVariant.withValues(alpha: 0.45),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 示意用的文字条（一段圆角色块）。
class _BarMock extends StatelessWidget {
  const _BarMock({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(height / 2),
      ),
    );
  }
}

Widget _tileMock(double radius) => IgnorePointer(
  child: AppTileSurface(
    borderRadius: BorderRadius.circular(radius),
    child: const SizedBox.expand(),
  ),
);

/// 「功能」页示意：标题 + 两列磁贴网格 + dock。
class _FunctionsSceneMock extends StatelessWidget {
  const _FunctionsSceneMock();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final pad = w * 0.07;
        final gap = w * 0.035;
        final tileW = (w - pad * 2 - gap) / 2;
        final tileH = tileW * 0.62;
        final radius = w * 0.045;
        final top = h * 0.14;
        return Stack(
          children: [
            Positioned(
              left: pad,
              top: h * 0.06,
              child: _BarMock(width: w * 0.22, height: h * 0.028),
            ),
            for (var i = 0; i < 8; i++)
              Positioned(
                left: pad + (i % 2) * (tileW + gap),
                top: top + (i ~/ 2) * (tileH + gap),
                width: tileW,
                height: tileH,
                child: _tileMock(radius),
              ),
            const Positioned.fill(child: _DockMock(activeIndex: 2)),
          ],
        );
      },
    );
  }
}

/// 「我的」页示意：标题 + 两枚方形账号磁贴 + 一枚宽设置磁贴 + dock。
class _MySceneMock extends StatelessWidget {
  const _MySceneMock();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final pad = w * 0.07;
        final gap = w * 0.035;
        final squareW = (w - pad * 2 - gap) / 2;
        final radius = w * 0.045;
        final tilesTop = h * 0.22;
        return Stack(
          children: [
            Positioned(
              left: pad,
              top: h * 0.07,
              child: _BarMock(width: w * 0.2, height: h * 0.034),
            ),
            Positioned(
              left: pad,
              top: h * 0.13,
              child: _BarMock(width: w * 0.38, height: h * 0.018),
            ),
            for (var i = 0; i < 2; i++)
              Positioned(
                left: pad + i * (squareW + gap),
                top: tilesTop,
                width: squareW,
                height: squareW * 0.9,
                child: _tileMock(radius),
              ),
            Positioned(
              left: pad,
              top: tilesTop + squareW * 0.9 + gap,
              width: w - pad * 2,
              height: squareW * 0.34,
              child: _tileMock(radius),
            ),
            const Positioned.fill(child: _DockMock(activeIndex: 3)),
          ],
        );
      },
    );
  }
}
