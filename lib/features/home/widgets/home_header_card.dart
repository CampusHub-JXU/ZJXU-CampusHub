import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../app/app_theme_controller.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../home_controller.dart';

class HomeHeaderCard extends StatelessWidget {
  const HomeHeaderCard({
    super.key,
    required this.currentWeek,
    required this.canShowUpdateAction,
    required this.onTap,
    required this.onNoticeTap,
    required this.courseContent,
    this.updateAction,
  });

  final int currentWeek;
  final bool canShowUpdateAction;
  final VoidCallback onTap;
  final VoidCallback onNoticeTap;
  final Widget courseContent;
  final Widget? updateAction;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: HomeController.instance.headerGlassEnabled,
      builder: (context, glassEnabled, _) {
        return ValueListenableBuilder<String?>(
          valueListenable: HomeController.instance.backgroundImagePath,
          builder: (context, backgroundPath, _) {
            final effectiveGlassEnabled =
                glassEnabled && backgroundPath != null;
            return ValueListenableBuilder<double>(
              valueListenable: HomeController.instance.glassBlur,
              builder: (context, glassBlur, _) {
                return ValueListenableBuilder<double>(
                  valueListenable: HomeController.instance.glassOpacity,
                  builder: (context, glassOpacity, _) {
                    return ValueListenableBuilder<HomeTextColorMode>(
                      valueListenable:
                          AppThemeController.instance.homeTextColorMode,
                      builder: (context, _, _) {
                        return _buildWrapper(
                          context,
                          effectiveGlassEnabled,
                          glassBlur,
                          glassOpacity,
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

  Widget _buildWrapper(
    BuildContext context,
    bool glassEnabled,
    double glassBlur,
    double glassOpacity,
  ) {
    final radius = BorderRadius.circular(glassEnabled ? AppRadius.card : 12);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: radius,
          child: glassEnabled
              ? BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: glassBlur,
                    sigmaY: glassBlur,
                  ),
                  child: _buildContent(
                    context,
                    glassEnabled: glassEnabled,
                    glassOpacity: glassOpacity,
                    radius: radius,
                  ),
                )
              : _buildContent(
                  context,
                  glassEnabled: glassEnabled,
                  glassOpacity: glassOpacity,
                  radius: radius,
                ),
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context, {
    required bool glassEnabled,
    required double glassOpacity,
    required BorderRadius radius,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final headerAccentColor = AppThemeController.instance.resolveIconColor(
      context,
      colorScheme.primary,
    );
    final headerBaseColor = isDark
        ? _blendHeaderTint(
            colorScheme.surfaceContainerHigh,
            _shiftHeaderColor(
              headerAccentColor,
              saturationBoost: 0.9,
              lightnessShift: -0.38,
              maxLightness: 0.34,
            ),
            0.46,
          )
        : headerAccentColor;
    final headerDeepColor = _shiftHeaderColor(
      headerAccentColor,
      saturationBoost: isDark ? 0.88 : 1.04,
      lightnessShift: isDark ? -0.44 : -0.12,
      maxLightness: isDark ? 0.28 : 0.86,
    );
    final headerGlowColor = _shiftHeaderColor(
      headerAccentColor,
      saturationBoost: isDark ? 0.86 : 0.94,
      lightnessShift: isDark ? -0.26 : 0.06,
      maxLightness: isDark ? 0.38 : 0.86,
    );
    final solidGradientColors = [
      headerBaseColor.withValues(alpha: isDark ? 0.96 : 0.94),
      isDark
          ? _blendHeaderTint(
              colorScheme.surfaceContainerLowest,
              headerDeepColor,
              0.52,
            )
          : headerDeepColor,
    ];
    final glassGradientColors = [
      if (isDark)
        _blendHeaderTint(
          colorScheme.surfaceContainer,
          headerGlowColor,
          (glassOpacity * 0.22).clamp(0.12, 0.2),
        )
      else
        headerBaseColor.withValues(
          alpha: (glassOpacity * 0.62).clamp(0.42, 0.58),
        ),
      if (isDark)
        _blendHeaderTint(
          colorScheme.surfaceContainerLowest,
          headerDeepColor,
          (glassOpacity * 0.3).clamp(0.16, 0.24),
        )
      else
        headerDeepColor.withValues(
          alpha: (glassOpacity * 0.56).clamp(0.36, 0.52),
        ),
    ];
    final primaryTextColor = AppThemeController.instance
        .resolveHomeTextColorForBackground(context, headerBaseColor);
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColorForBackground(context, headerBaseColor);
    final tertiaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColorForBackground(context, headerBaseColor)
        .withValues(alpha: 0.78);
    final iconColor = AppThemeController.instance
        .resolveHomeTextColorForBackground(context, headerBaseColor);
    final decoration = glassEnabled
        ? BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: glassGradientColors,
            ),
            borderRadius: radius,
            border: Border.all(
              color: Colors.white.withValues(alpha: isDark ? 0.07 : 0.2),
              width: 1,
            ),
          )
        : BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: solidGradientColors,
            ),
            borderRadius: radius,
          );

    return Container(
      decoration: decoration,
      child: Stack(
        children: [
          Positioned(
            left: -40,
            bottom: -48,
            child: Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(
                  alpha: isDark ? 0.025 : (glassEnabled ? 0.06 : 0.08),
                ),
              ),
            ),
          ),
          Positioned(
            right: -30,
            top: -20,
            child: Opacity(
              opacity: isDark ? 0.045 : (glassEnabled ? 0.04 : 0.12),
              child: SvgPicture.asset(
                'assets/header_texture.svg',
                width: 200,
                height: 200,
              ),
            ),
          ),
          if (glassEnabled)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: isDark ? 0.018 : 0.12),
                      headerGlowColor.withValues(alpha: isDark ? 0.018 : 0.05),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(
                      alpha: isDark ? 0.016 : (glassEnabled ? 0.08 : 0.10),
                    ),
                    Colors.transparent,
                    Colors.black.withValues(
                      alpha: isDark ? 0.22 : (glassEnabled ? 0.06 : 0.1),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '第 $currentWeek 周',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: primaryTextColor,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '下节课',
                            style: TextStyle(
                              fontSize: 14,
                              color: secondaryTextColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (canShowUpdateAction && updateAction != null) ...[
                      updateAction!,
                      const SizedBox(width: 12),
                    ],
                    IconButton(
                      icon: Icon(
                        Icons.notifications_outlined,
                        color: iconColor,
                        size: 22,
                      ),
                      onPressed: onNoticeTap,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(child: courseContent),
                    const SizedBox(width: 8),
                    Text(
                      '查看课表 →',
                      style: TextStyle(fontSize: 12, color: tertiaryTextColor),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _shiftHeaderColor(
    Color color, {
    required double saturationBoost,
    required double lightnessShift,
    double maxLightness = 0.86,
  }) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withSaturation((hsl.saturation * saturationBoost).clamp(0.0, 1.0))
        .withLightness(
          (hsl.lightness + lightnessShift).clamp(0.14, maxLightness),
        )
        .toColor();
  }

  Color _blendHeaderTint(Color base, Color tint, double amount) =>
      Color.lerp(base, tint, amount)!;
}
