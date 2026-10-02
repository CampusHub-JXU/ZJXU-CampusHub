import 'dart:io';

import 'package:flutter/material.dart';

import '../app_theme_controller.dart';
import '../personalization_controller.dart';
import 'home_fluid_background.dart';

class HomeBackgroundLayer extends StatelessWidget {
  const HomeBackgroundLayer({
    super.key,
    required this.path,
    this.useAsyncFilter = true,
    this.errorBuilder,
  });

  final String path;
  final bool useAsyncFilter;
  final WidgetBuilder? errorBuilder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: PersonalizationController.instance.shaderEnabled,
      builder: (context, shaderEnabled, _) {
        return ValueListenableBuilder<double>(
          valueListenable: PersonalizationController.instance.backgroundOpacity,
          builder: (context, opacity, _) {
            return ValueListenableBuilder<Alignment>(
              valueListenable:
                  PersonalizationController.instance.backgroundAlignment,
              builder: (context, alignment, _) {
                return ValueListenableBuilder<HomeBackgroundFit>(
                  valueListenable:
                      PersonalizationController.instance.backgroundFit,
                  builder: (context, fit, _) {
                    return ValueListenableBuilder<double>(
                      valueListenable:
                          PersonalizationController.instance.backgroundScale,
                      builder: (context, scale, _) {
                        final image = _buildImage(
                          context,
                          alignment,
                          fit,
                          scale,
                        );
                        if (!shaderEnabled || !useAsyncFilter) {
                          return Opacity(opacity: opacity, child: image);
                        }
                        return ValueListenableBuilder<double>(
                          valueListenable:
                              PersonalizationController.instance.shaderStrength,
                          builder: (context, strength, _) {
                            return ValueListenableBuilder<List<Color>?>(
                              valueListenable: PersonalizationController
                                  .instance
                                  .monetColors,
                              builder: (context, monetColors, _) {
                                return ValueListenableBuilder<double>(
                                  valueListenable: PersonalizationController
                                      .instance
                                      .shaderOpacity,
                                  builder: (context, shaderOpacity, _) {
                                    return ValueListenableBuilder<double>(
                                      valueListenable: PersonalizationController
                                          .instance
                                          .shaderAnimationSpeed,
                                      builder: (context, animationSpeed, _) {
                                        return ValueListenableBuilder<int>(
                                          valueListenable:
                                              PersonalizationController
                                                  .instance
                                                  .shaderFps,
                                          builder: (context, fps, _) {
                                            return HomeFluidBackground(
                                              intensity: strength.clamp(
                                                0.0,
                                                1.0,
                                              ),
                                              themeColor: AppThemeController
                                                  .instance
                                                  .seedColor
                                                  .value,
                                              monetColors: monetColors,
                                              isDarkMode:
                                                  Theme.of(context)
                                                      .brightness ==
                                                  Brightness.dark,
                                              opacity: shaderOpacity,
                                              animationSpeed: animationSpeed,
                                              targetFps: fps,
                                              fallback: image,
                                            );
                                          },
                                        );
                                      },
                                    );
                                  },
                                );
                              },
                            );
                          },
                        );
                      },
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

  Widget _buildImage(
    BuildContext context,
    Alignment alignment,
    HomeBackgroundFit fit,
    double scale,
  ) {
    final image = LayoutBuilder(
      builder: (context, constraints) {
        final offset = Offset(
          alignment.x * constraints.maxWidth * 0.5,
          alignment.y * constraints.maxHeight * 0.5,
        );
        // 原图保真存储，decode 尺寸在渲染层收敛（PRD §19），
        // 上限 2160px 避免大屏/高 DPR 一次性解出超大位图。
        final decodeWidth =
            (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(1, 2160);
        return Transform.translate(
          offset: offset,
          child: Transform.scale(
            scale: scale,
            child: Image.file(
              File(path),
              fit: fit.boxFit,
              alignment: Alignment.center,
              cacheWidth: decodeWidth,
              errorBuilder: (_, _, _) {
                return errorBuilder?.call(context) ?? const SizedBox.expand();
              },
            ),
          ),
        );
      },
    );
    if (!_usesWhiteEdgeFill(fit)) return image;
    return ColoredBox(color: Colors.white, child: image);
  }

  bool _usesWhiteEdgeFill(HomeBackgroundFit fit) {
    return fit == HomeBackgroundFit.contain ||
        fit == HomeBackgroundFit.none ||
        fit == HomeBackgroundFit.fitWidth;
  }
}
