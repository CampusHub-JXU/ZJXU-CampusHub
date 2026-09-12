import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主屏个性化状态控制器（背景图/着色器/毛玻璃/Monet 色板）。
///
/// 原为 features/home 下的主屏控制器；因被 settings 个性化页共享而下沉至
/// core/theme，prefs key 保持不变。

enum HomeShaderMode {
  glass('玻璃背景'),
  ribbon('流光丝带'),
  collage('流体纹理');

  const HomeShaderMode(this.label);
  final String label;
}

enum HomeBackgroundFit {
  cover('填充', BoxFit.cover),
  contain('适应', BoxFit.contain),
  fill('拉伸', BoxFit.fill),
  none('居中', BoxFit.none),
  fitWidth('跨区', BoxFit.fitWidth);

  const HomeBackgroundFit(this.label, this.boxFit);
  final String label;
  final BoxFit boxFit;
}

class PersonalizationController {
  PersonalizationController._();
  static final PersonalizationController instance =
      PersonalizationController._();

  static const _keyBackgroundPath = 'home_background_image_path';
  static const _keyShaderEnabled = 'home_shader_enabled';
  static const _keyLegacyColorFilterEnabled = 'home_color_filter_enabled';
  static const _keyShaderStrength = 'home_shader_strength';
  static const _keyShaderOpacity = 'home_shader_opacity';
  static const _keyShaderAnimationSpeed = 'home_shader_animation_speed';
  static const _keyLegacyFilterStrength = 'home_filter_strength';
  static const _keyBackgroundOpacity = 'home_background_opacity';
  static const _keyHeaderGlass = 'home_header_glass_enabled';
  static const _keyBgAlignX = 'home_background_align_x';
  static const _keyBgAlignY = 'home_background_align_y';
  static const _keyBackgroundFit = 'home_background_fit';
  static const _keyBackgroundScale = 'home_background_scale';
  static const _keyEmblemWatermark = 'home_emblem_watermark_enabled';
  static const _keyFullDayCourses = 'home_full_day_courses_enabled';
  static const _keyHomeCampusNotice = 'home_campus_notice_enabled';

  final ValueNotifier<String?> backgroundImagePath = ValueNotifier(null);
  final ValueNotifier<bool> shaderEnabled = ValueNotifier(false);
  final ValueNotifier<bool> headerGlassEnabled = ValueNotifier(false);
  final ValueNotifier<double> shaderStrength = ValueNotifier(0.45);
  final ValueNotifier<double> shaderOpacity = ValueNotifier(1.0);
  final ValueNotifier<double> shaderAnimationSpeed = ValueNotifier(1.0);
  final ValueNotifier<double> backgroundOpacity = ValueNotifier(1.0);
  final ValueNotifier<Alignment> backgroundAlignment = ValueNotifier(
    Alignment.center,
  );
  final ValueNotifier<HomeBackgroundFit> backgroundFit = ValueNotifier(
    HomeBackgroundFit.cover,
  );
  final ValueNotifier<double> backgroundScale = ValueNotifier(1.0);

  /// 首页 Hero 区右下的嘉兴大学校徽水印；默认开。
  final ValueNotifier<bool> emblemWatermarkEnabled = ValueNotifier(true);

  /// 首页「今天」段落展示全天课程（含已结束灰显）；关闭时仅显示
  /// 剩余课程。默认开（班级同学反馈想看一整天的课）。
  final ValueNotifier<bool> fullDayCoursesEnabled = ValueNotifier(true);

  /// 首页「校园公告」区块（资产行下方的教务处通知内容块）；默认关
  /// （新公告靠推送与通知中心红点即可），开启后首页展示该区块
  ///（通知中心与后台提醒不受影响）。
  final ValueNotifier<bool> homeCampusNoticeEnabled = ValueNotifier(false);

  final ValueNotifier<List<Color>?> monetColors = ValueNotifier(null);

  /// Monet-extracted colors from current background image (cached in memory).
  List<Color>? _monetColors;
  String? _monetSourcePath;

  /// Synchronous access to cached monet colors (null if not yet extracted).
  List<Color>? get cachedMonetColors => _monetColors;

  /// Returns monet-extracted colors, computing them if needed.
  Future<List<Color>> getMonetColors() async {
    final path = backgroundImagePath.value;
    if (path == null) {
      _monetColors = _defaultBrandColors();
      _monetSourcePath = null;
      monetColors.value = _monetColors;
      return _monetColors!;
    }
    if (_monetColors != null && _monetSourcePath == path) {
      monetColors.value = _monetColors;
      return _monetColors!;
    }
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        FileImage(File(path)),
        size: const Size(200, 200),
        maximumColorCount: 8,
      );
      final paletteColors = palette.paletteColors.map((e) => e.color).toList();
      final dominant = palette.dominantColor?.color;
      final vibrant = palette.vibrantColor?.color;
      final lightVibrant = palette.lightVibrantColor?.color;
      final darkVibrant = palette.darkVibrantColor?.color;
      final darkMuted = palette.darkMutedColor?.color;
      _monetColors = _buildExpressivePalette(
        paletteColors: paletteColors,
        dominant: dominant,
        vibrant: vibrant,
        lightVibrant: lightVibrant,
        darkVibrant: darkVibrant,
        darkMuted: darkMuted,
      );
      _monetSourcePath = path;
    } catch (_) {
      _monetColors = _defaultBrandColors();
      _monetSourcePath = path;
    }
    monetColors.value = _monetColors;
    return _monetColors!;
  }

  static List<Color> _buildExpressivePalette({
    required List<Color> paletteColors,
    required Color? dominant,
    required Color? vibrant,
    required Color? lightVibrant,
    required Color? darkVibrant,
    required Color? darkMuted,
  }) {
    final candidates = <Color>[
      ...paletteColors,
      ?dominant,
      ?vibrant,
      ?lightVibrant,
      ?darkVibrant,
      ?darkMuted,
    ];
    if (candidates.isEmpty) return _defaultBrandColors();

    final pink = _bestColor(
      candidates,
      targetHue: 326,
      fallback: vibrant ?? const Color(0xFFE94B9B),
      preferBright: true,
    );
    final cyan = _bestColor(
      candidates,
      targetHue: 197,
      fallback: const Color(0xFF38C7F4),
      preferBright: true,
    );
    final violet = _bestColor(
      candidates,
      targetHue: 252,
      fallback: dominant ?? const Color(0xFF4A3B8F),
      preferBright: false,
    );
    final deep =
        _darkestSaturated(candidates) ?? darkMuted ?? const Color(0xFF151D4F);
    final light =
        _lightestSaturated(candidates) ??
        lightVibrant ??
        const Color(0xFFF4C7E7);

    return [
      _boostColor(pink, saturationBoost: 1.18, lightnessShift: 0.03),
      _boostColor(cyan, saturationBoost: 1.15, lightnessShift: 0.04),
      _boostColor(violet, saturationBoost: 1.12, lightnessShift: -0.02),
      _boostColor(light, saturationBoost: 1.08, lightnessShift: 0.02),
      _boostColor(deep, saturationBoost: 1.12, lightnessShift: -0.04),
    ];
  }

  static Color _bestColor(
    List<Color> colors, {
    required double targetHue,
    required Color fallback,
    required bool preferBright,
  }) {
    Color? best;
    var bestScore = double.negativeInfinity;
    for (final color in colors) {
      final hsl = HSLColor.fromColor(color);
      final hueDistance = ((hsl.hue - targetHue + 540.0) % 360.0 - 180.0).abs();
      final brightnessScore = preferBright
          ? hsl.lightness
          : 1.0 - hsl.lightness;
      final score =
          hsl.saturation * 2.4 + brightnessScore * 0.7 - hueDistance / 90.0;
      if (score > bestScore) {
        bestScore = score;
        best = color;
      }
    }
    return best ?? fallback;
  }

  static Color? _darkestSaturated(List<Color> colors) {
    return _rankedColor(
      colors,
      (hsl) => hsl.saturation * 1.4 + (1.0 - hsl.lightness),
    );
  }

  static Color? _lightestSaturated(List<Color> colors) {
    return _rankedColor(colors, (hsl) => hsl.saturation * 1.2 + hsl.lightness);
  }

  static Color? _rankedColor(
    List<Color> colors,
    double Function(HSLColor) score,
  ) {
    Color? best;
    var bestScore = double.negativeInfinity;
    for (final color in colors) {
      final hsl = HSLColor.fromColor(color);
      final value = score(hsl);
      if (value > bestScore) {
        bestScore = value;
        best = color;
      }
    }
    return best;
  }

  static Color _boostColor(
    Color color, {
    required double saturationBoost,
    required double lightnessShift,
  }) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withSaturation((hsl.saturation * saturationBoost).clamp(0.0, 1.0))
        .withLightness((hsl.lightness + lightnessShift).clamp(0.12, 0.88))
        .toColor();
  }

  static List<Color> _defaultBrandColors() => const [
    Color(0xFF8B1A2D),
    Color(0xFFB03A48),
    Color(0xFF5A0D1A),
  ];

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    final path = prefs.getString(_keyBackgroundPath);
    if (path != null && await File(path).exists()) {
      backgroundImagePath.value = path;
    } else {
      await prefs.remove(_keyBackgroundPath);
      backgroundImagePath.value = null;
    }

    shaderEnabled.value =
        prefs.getBool(_keyShaderEnabled) ??
        prefs.getBool(_keyLegacyColorFilterEnabled) ??
        false;

    headerGlassEnabled.value = prefs.getBool(_keyHeaderGlass) ?? false;

    shaderStrength.value =
        (prefs.getDouble(_keyShaderStrength) ??
                prefs.getDouble(_keyLegacyFilterStrength) ??
                0.45)
            .clamp(0.0, 1.0);
    shaderOpacity.value = (prefs.getDouble(_keyShaderOpacity) ?? 1.0).clamp(
      0.0,
      1.0,
    );
    shaderAnimationSpeed.value =
        (prefs.getDouble(_keyShaderAnimationSpeed) ?? 1.0).clamp(0.0, 2.0);
    backgroundOpacity.value = prefs.getDouble(_keyBackgroundOpacity) ?? 1.0;

    final bgX = prefs.getDouble(_keyBgAlignX);
    final bgY = prefs.getDouble(_keyBgAlignY);
    if (bgX != null && bgY != null) {
      backgroundAlignment.value = Alignment(bgX, bgY);
    }

    final fitIdx = prefs.getInt(_keyBackgroundFit);
    if (fitIdx != null &&
        fitIdx >= 0 &&
        fitIdx < HomeBackgroundFit.values.length) {
      backgroundFit.value = HomeBackgroundFit.values[fitIdx];
    }
    backgroundScale.value = (prefs.getDouble(_keyBackgroundScale) ?? 1.0).clamp(
      0.5,
      3.0,
    );
    emblemWatermarkEnabled.value = prefs.getBool(_keyEmblemWatermark) ?? true;
    fullDayCoursesEnabled.value = prefs.getBool(_keyFullDayCourses) ?? true;
    homeCampusNoticeEnabled.value =
        prefs.getBool(_keyHomeCampusNotice) ?? false;
  }

  Future<void> setBackgroundImagePath(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path != null) {
      await prefs.setString(_keyBackgroundPath, path);
    } else {
      await prefs.remove(_keyBackgroundPath);
    }
    _monetColors = null;
    _monetSourcePath = null;
    monetColors.value = null;
    backgroundImagePath.value = path;
    if (shaderEnabled.value) {
      unawaited(getMonetColors());
    }
  }

  Future<void> setShaderEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShaderEnabled, enabled);
    shaderEnabled.value = enabled;
    if (enabled) {
      unawaited(getMonetColors());
    }
  }

  Future<void> setHeaderGlassEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyHeaderGlass, enabled);
    headerGlassEnabled.value = enabled;
  }

  Future<void> setShaderStrength(double value) async {
    final strength = value.clamp(0.0, 1.0);
    await _persistDouble(_keyShaderStrength, strength, shaderStrength);
  }

  Future<void> setShaderOpacity(double value) async {
    final opacity = value.clamp(0.0, 1.0);
    await _persistDouble(_keyShaderOpacity, opacity, shaderOpacity);
  }

  Future<void> setShaderAnimationSpeed(double value) async {
    final speed = value.clamp(0.0, 2.0);
    await _persistDouble(_keyShaderAnimationSpeed, speed, shaderAnimationSpeed);
  }

  Future<void> setBackgroundOpacity(double value) async {
    final opacity = value.clamp(0.0, 1.0);
    await _persistDouble(_keyBackgroundOpacity, opacity, backgroundOpacity);
  }

  Future<void> setBackgroundAlignment(Alignment alignment) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyBgAlignX, alignment.x);
    await prefs.setDouble(_keyBgAlignY, alignment.y);
    backgroundAlignment.value = alignment;
  }

  Future<void> setBackgroundFit(HomeBackgroundFit fit) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyBackgroundFit, fit.index);
    backgroundFit.value = fit;
  }

  Future<void> setBackgroundScale(double value) async {
    final scale = value.clamp(0.5, 3.0);
    await _persistDouble(_keyBackgroundScale, scale, backgroundScale);
  }

  Future<void> setEmblemWatermarkEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEmblemWatermark, enabled);
    emblemWatermarkEnabled.value = enabled;
  }

  Future<void> setFullDayCoursesEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyFullDayCourses, enabled);
    fullDayCoursesEnabled.value = enabled;
  }

  Future<void> setHomeCampusNoticeEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyHomeCampusNotice, enabled);
    homeCampusNoticeEnabled.value = enabled;
  }

  Future<void> _persistDouble(
    String key,
    double value,
    ValueNotifier<double> notifier,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(key, value);
    notifier.value = value;
  }

  @visibleForTesting
  void debugReset() {
    backgroundImagePath.value = null;
    shaderEnabled.value = false;
    shaderStrength.value = 0.45;
    shaderOpacity.value = 1.0;
    shaderAnimationSpeed.value = 1.0;
    backgroundOpacity.value = 1.0;
    backgroundAlignment.value = Alignment.center;
    backgroundFit.value = HomeBackgroundFit.cover;
    backgroundScale.value = 1.0;
    emblemWatermarkEnabled.value = true;
    fullDayCoursesEnabled.value = true;
    homeCampusNoticeEnabled.value = false;
    _monetColors = null;
    _monetSourcePath = null;
    monetColors.value = null;
  }
}
