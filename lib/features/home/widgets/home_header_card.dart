import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../app/app_theme_controller.dart';
import '../../../app/theme.dart';
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
                      glassEnabled,
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
  }

  Widget _buildWrapper(
    BuildContext context,
    bool glassEnabled,
    double glassBlur,
    double glassOpacity,
  ) {
    final radius = BorderRadius.circular(glassEnabled ? 20 : 12);
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
    final headerAlpha = (glassOpacity * 0.52).clamp(0.20, 0.54);
    final primaryTextColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      Colors.white,
    );
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(
          context,
          Colors.white.withValues(alpha: 0.72),
        );
    final tertiaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(
          context,
          Colors.white.withValues(alpha: 0.50),
        );
    final iconColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      Colors.white,
    );
    final decoration = glassEnabled
        ? BoxDecoration(
            color: AppColors.primary.withValues(alpha: headerAlpha),
            borderRadius: radius,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.20),
              width: 1,
            ),
          )
        : BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF7B1527), AppColors.primary, Color(0xFFB7485E)],
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
                  alpha: glassEnabled ? 0.06 : 0.08,
                ),
              ),
            ),
          ),
          Positioned(
            right: -30,
            top: -20,
            child: Opacity(
              opacity: glassEnabled ? 0.04 : 0.12,
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
                      Colors.white.withValues(alpha: 0.16),
                      Colors.white.withValues(alpha: 0.04),
                      Colors.transparent,
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
}
