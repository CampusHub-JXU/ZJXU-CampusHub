import 'dart:io';

import 'package:flutter/material.dart';

import '../home_controller.dart';

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
      valueListenable: HomeController.instance.colorFilterEnabled,
      builder: (context, filterEnabled, _) {
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
                        if (!filterEnabled) {
                          return Opacity(opacity: opacity, child: image);
                        }
                        if (!useAsyncFilter) {
                          final matrix = HomeController.instance
                              .buildFilterMatrixSync(
                                HomeController.instance.filterStrength.value,
                              );
                          return Opacity(
                            opacity: opacity,
                            child: ColorFiltered(
                              colorFilter: ColorFilter.matrix(matrix),
                              child: image,
                            ),
                          );
                        }
                        return ValueListenableBuilder<double>(
                          valueListenable:
                              HomeController.instance.filterStrength,
                          builder: (context, strength, _) {
                            return ValueListenableBuilder<HomeFilterMode>(
                              valueListenable:
                                  HomeController.instance.filterMode,
                              builder: (context, mode, _) {
                                return FutureBuilder<List<double>>(
                                  future: HomeController.instance
                                      .buildFilterMatrix(strength),
                                  builder: (context, snapshot) {
                                    final matrix = snapshot.data;
                                    if (matrix == null) {
                                      return Opacity(
                                        opacity: opacity,
                                        child: image,
                                      );
                                    }
                                    return Opacity(
                                      opacity: opacity,
                                      child: ColorFiltered(
                                        colorFilter: ColorFilter.matrix(matrix),
                                        child: image,
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
