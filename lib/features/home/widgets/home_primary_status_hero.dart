import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../app/app_theme_controller.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/glass_style_controller.dart';
import '../home_controller.dart';
import '../models/home_presentation.dart';

/// Primary Status Hero：首页唯一的最强视觉焦点。
///
/// 顶部行为「嘉兴大学 + 周次 chip + 更新角标 + 通知铃铛」，
/// 主体为状态大字 + 时间 + 课程名 + 地点元信息 + 「查看课表」入口；
/// 整卡可点开课表。背景图 + 头卡玻璃开关开启时保留玻璃效果
/// （ClipRRect 必须位于 BackdropFilter 祖先位置）。
class HomePrimaryStatusHero extends StatelessWidget {
  const HomePrimaryStatusHero({
    super.key,
    required this.hero,
    required this.weekLabel,
    required this.canShowUpdateAction,
    required this.onOpenSchedule,
    required this.onNotificationTap,
    this.onUpdateTap,
  });

  final HomeHeroPresentation hero;

  /// 周次文案：「第 N 周」/「未开学」/「学期已结束」。
  final String weekLabel;
  final bool canShowUpdateAction;
  final VoidCallback onOpenSchedule;
  final VoidCallback onNotificationTap;
  final VoidCallback? onUpdateTap;

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
              valueListenable: GlassStyleController.instance.blurSigma,
              builder: (context, glassBlur, _) {
                return ValueListenableBuilder<double>(
                  valueListenable: GlassStyleController.instance.tintOpacity,
                  builder: (context, glassOpacity, _) {
                    return _buildHero(
                      context,
                      glassEnabled: effectiveGlassEnabled,
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

  Widget _buildHero(
    BuildContext context, {
    required bool glassEnabled,
    required double glassBlur,
    required double glassOpacity,
  }) {
    final radius = AppRadius.cardBorder;
    return Semantics(
      button: true,
      label: '${hero.headline} ${hero.courseName ?? ''}，查看课表',
      child: GestureDetector(
        onTap: onOpenSchedule,
        child: ClipRRect(
          borderRadius: radius,
          // 铁律：裁剪必须在 BackdropFilter 的祖先位置。
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
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTitleRow(context, iconColor),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  hero.headline,
                  style: TextStyle(
                    fontSize: 26,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: primaryTextColor,
                  ),
                ),
                if (hero.timeText != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    hero.timeText!,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: secondaryTextColor,
                    ),
                  ),
                ],
                if (hero.courseName != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    hero.courseName!,
                    style: TextStyle(
                      fontSize: 30,
                      height: 1.15,
                      fontWeight: FontWeight.w800,
                      color: primaryTextColor,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (hero.locationText != null || hero.lessonText != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Flexible(
                        child: Row(
                          children: [
                            Icon(
                              Icons.location_on_outlined,
                              size: 14,
                              color: secondaryTextColor,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                hero.locationText ?? '',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: secondaryTextColor,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (hero.lessonText != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          hero.lessonText!,
                          style: TextStyle(
                            fontSize: 12,
                            color: secondaryTextColor.withValues(alpha: 0.78),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                Row(
                  children: [
                    Text(
                      '查看课表',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: secondaryTextColor,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.arrow_forward_ios,
                      size: 12,
                      color: secondaryTextColor,
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

  Widget _buildTitleRow(BuildContext context, Color iconColor) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          '嘉兴大学',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: iconColor,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: iconColor.withValues(alpha: 0.18)),
            ),
            child: Text(
              weekLabel,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: iconColor.withValues(alpha: 0.96),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const Spacer(),
        if (canShowUpdateAction && onUpdateTap != null) ...[
          _buildUpdateAction(cs, iconColor),
          const SizedBox(width: 12),
        ],
        IconButton(
          icon: Icon(Icons.notifications_outlined, color: iconColor, size: 22),
          onPressed: onNotificationTap,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          tooltip: '通知中心',
        ),
      ],
    );
  }

  Widget _buildUpdateAction(ColorScheme cs, Color iconColor) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          icon: Icon(Icons.system_update_outlined, color: iconColor, size: 22),
          onPressed: onUpdateTap,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          tooltip: '发现新版本',
        ),
        Positioned(
          right: -1,
          top: -1,
          child: Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: cs.error,
              shape: BoxShape.circle,
              border: Border.all(color: cs.onError, width: 1.2),
            ),
          ),
        ),
      ],
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
