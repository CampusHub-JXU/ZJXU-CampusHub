import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/app_theme_controller.dart';
import '../home_controller.dart';
import 'home_glass_background_filter.dart';

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
      valueListenable: HomeController.instance.shaderEnabled,
      builder: (context, shaderEnabled, _) {
        return ValueListenableBuilder<double>(
          valueListenable: HomeController.instance.backgroundOpacity,
          builder: (context, opacity, _) {
            return ValueListenableBuilder<Alignment>(
              valueListenable: HomeController.instance.backgroundAlignment,
              builder: (context, alignment, _) {
                return ValueListenableBuilder<HomeBackgroundFit>(
                  valueListenable: HomeController.instance.backgroundFit,
                  builder: (context, fit, _) {
                    return ValueListenableBuilder<double>(
                      valueListenable: HomeController.instance.backgroundScale,
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
                              HomeController.instance.shaderStrength,
                          builder: (context, strength, _) {
                            return ValueListenableBuilder<List<Color>?>(
                              valueListenable:
                                  HomeController.instance.monetColors,
                              builder: (context, monetColors, _) {
                                return ValueListenableBuilder<double>(
                                  valueListenable:
                                      HomeController.instance.shaderOpacity,
                                  builder: (context, shaderOpacity, _) {
                                    return ValueListenableBuilder<double>(
                                      valueListenable: HomeController
                                          .instance
                                          .shaderAnimationSpeed,
                                      builder: (context, animationSpeed, _) {
                                        return ValueListenableBuilder<
                                          HomeShaderMode
                                        >(
                                          valueListenable: HomeController
                                              .instance
                                              .shaderMode,
                                          builder: (context, mode, _) {
                                            final themeColor =
                                                AppThemeController
                                                    .instance
                                                    .seedColor
                                                    .value;
                                            return HomeGlassBackgroundFilter(
                                              mode: mode,
                                              intensity: strength.clamp(
                                                0.0,
                                                1.0,
                                              ),
                                              levels: 14.0 - strength * 4.0,
                                              themeColor: themeColor,
                                              monetColors: monetColors,
                                              isDarkMode:
                                                  Theme.of(context)
                                                      .brightness ==
                                                  Brightness.dark,
                                              opacity: shaderOpacity,
                                              animationSpeed: animationSpeed,
                                              child: image,
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
        return Transform.translate(
          offset: offset,
          child: Transform.scale(
            scale: scale,
            child: Image.file(
              File(path),
              fit: fit.boxFit,
              alignment: Alignment.center,
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
