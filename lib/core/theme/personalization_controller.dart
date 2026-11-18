import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主屏个性化状态控制器（背景图/着色器/毛玻璃/Monet 色板）。
///
/// 原为 features/home 下的主屏控制器；因被 settings 个性化页共享而下沉至
/// core/theme，prefs key 保持不变。

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
  static const _keyShaderFps = 'home_shader_fps';
  static const _keyLegacyFilterStrength = 'home_filter_strength';
  static const _keyBackgroundOpacity = 'home_background_opacity';

  /// 已下线的「课表卡片毛玻璃」开关（只影响过预览，真实首页从未使用）；restore 时清除。
  static const _keyRetiredHeaderGlass = 'home_header_glass_enabled';
  static const _keyBgAlignX = 'home_background_align_x';
  static const _keyBgAlignY = 'home_background_align_y';
  static const _keyBackgroundFit = 'home_background_fit';
  static const _keyBackgroundScale = 'home_background_scale';
  static const _keyEmblemWatermark = 'home_emblem_watermark_enabled';
  static const _keyFullDayCourses = 'home_full_day_courses_enabled';
  static const _keyHomeCampusNotice = 'home_campus_notice_enabled';

  final ValueNotifier<String?> backgroundImagePath = ValueNotifier(null);

  /// 流体 Shader 的出厂默认值（新安装为开）。
  ///
  /// 流体 Shader 并非对壁纸做滤镜：它用壁纸取色（未设壁纸时用主题色）**程序化生成**
  /// 背景，不依赖壁纸，设了壁纸则会替换壁纸画面。所以升级用户里「已设壁纸、从未碰过此开关」的人不能被静默
  /// 切换，见 [init] 的迁移分支。
  static const bool kShaderEnabledDefault = true;

  final ValueNotifier<bool> shaderEnabled = ValueNotifier(
    kShaderEnabledDefault,
  );
  final ValueNotifier<double> shaderStrength = ValueNotifier(0.45);
  final ValueNotifier<double> shaderOpacity = ValueNotifier(1.0);
  final ValueNotifier<double> shaderAnimationSpeed = ValueNotifier(1.0);

  /// 流体 Shader 帧率档位（fps）。高于屏幕刷新率的档位等同「每个 vsync 一帧」。
  static const List<int> kShaderFpsSteps = [30, 45, 60, 90, 120];
  static const int kShaderFpsDefault = 60;

  /// 把任意值吸附到最近的档位（持久化值被手改 / 旧版本缺失时兜底）。
  static int snapShaderFps(int value) {
    var best = kShaderFpsSteps.first;
    for (final step in kShaderFpsSteps) {
      if ((step - value).abs() < (best - value).abs()) best = step;
    }
    return best;
  }

  final ValueNotifier<int> shaderFps = ValueNotifier(kShaderFpsDefault);
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

  /// 首页「今天」段落的行数上限：开启最多 6 条、关闭最多 3 条；已结束的课
  /// 两种模式都不显示。默认开（班级同学反馈想看一整天的课）。
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
      // 未设壁纸：不给取色板，HomeFluidBackground 回退到按主题色推导配色。
      _monetColors = null;
      _monetSourcePath = null;
      monetColors.value = null;
      return const [];
    }
    if (_monetColors != null && _monetSourcePath == path) {
      monetColors.value = _monetColors;
      return _monetColors!;
    }
    try {
      final swatches = await _extractSwatches(File(path));
      _monetColors = _buildExpressivePalette(
        paletteColors: swatches.palette,
        dominant: swatches.dominant,
        vibrant: swatches.vibrant,
        lightVibrant: swatches.lightVibrant,
        darkVibrant: swatches.darkVibrant,
        darkMuted: swatches.darkMuted,
      );
      _monetSourcePath = path;
    } catch (_) {
      _monetColors = _defaultBrandColors();
      _monetSourcePath = path;
    }
    monetColors.value = _monetColors;
    return _monetColors!;
  }

  /// 缩小到约 200px 后用 Celebi 量化（与 palette_generator 的 200×200 /
  /// 8 色配置对应），按人口排序，并按 HSL 区间挑出 vibrant / muted 色板。
  static Future<_ImageSwatches> _extractSwatches(File file) async {
    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 200,
      targetHeight: 200,
    );
    final ui.Image image;
    try {
      image = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
    final ByteData? data;
    try {
      data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    } finally {
      image.dispose();
    }
    if (data == null) return const _ImageSwatches();

    final pixels = <int>[];
    for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
      final a = data.getUint8(i + 3);
      if (a < 128) continue;
      pixels.add(
        (0xFF << 24) |
            (data.getUint8(i) << 16) |
            (data.getUint8(i + 1) << 8) |
            data.getUint8(i + 2),
      );
    }
    if (pixels.isEmpty) return const _ImageSwatches();

    final quantized = await QuantizerCelebi().quantize(pixels, 8);
    final entries = quantized.colorToCount.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final palette = [for (final e in entries) Color(e.key)];
    if (palette.isEmpty) return const _ImageSwatches();

    Color? pick(double minL, double maxL, double minS, double maxS) {
      Color? best;
      var bestScore = double.negativeInfinity;
      for (final color in palette) {
        final hsl = HSLColor.fromColor(color);
        if (hsl.lightness < minL ||
            hsl.lightness > maxL ||
            hsl.saturation < minS ||
            hsl.saturation > maxS) {
          continue;
        }
        // 人口靠前者优先（palette 已按人口降序），同区间内偏好高饱和。
        final score = hsl.saturation - palette.indexOf(color) * 0.05;
        if (score > bestScore) {
          bestScore = score;
          best = color;
        }
      }
      return best;
    }

    return _ImageSwatches(
      palette: palette,
      dominant: palette.first,
      vibrant: pick(0.3, 0.7, 0.35, 1.0),
      lightVibrant: pick(0.55, 1.0, 0.35, 1.0),
      darkVibrant: pick(0.0, 0.45, 0.35, 1.0),
      darkMuted: pick(0.0, 0.45, 0.0, 0.4),
    );
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
    final hadStoredWallpaper = path != null;
    if (path != null && await File(path).exists()) {
      backgroundImagePath.value = path;
    } else {
      await prefs.remove(_keyBackgroundPath);
      backgroundImagePath.value = null;
    }

    final storedShader =
        prefs.getBool(_keyShaderEnabled) ??
        prefs.getBool(_keyLegacyColorFilterEnabled);
    if (storedShader != null) {
      // 用户（或旧版本）明确存过的值永远优先，包括显式 false。
      shaderEnabled.value = storedShader;
    } else if (hadStoredWallpaper) {
      // 键缺失 + 已有壁纸 = 升级前的老用户从未选择过 Shader：保持他们看到的
      // 纯壁纸，并落盘成显式 false，避免之后删壁纸 / 重装前再次被默认值翻转。
      shaderEnabled.value = false;
      await prefs.setBool(_keyShaderEnabled, false);
    } else {
      shaderEnabled.value = kShaderEnabledDefault;
    }

    if (prefs.containsKey(_keyRetiredHeaderGlass)) {
      await prefs.remove(_keyRetiredHeaderGlass);
    }

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
    shaderFps.value = snapShaderFps(
      prefs.getInt(_keyShaderFps) ?? kShaderFpsDefault,
    );
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

  Future<void> setShaderFps(int fps) async {
    final snapped = snapShaderFps(fps);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyShaderFps, snapped);
    shaderFps.value = snapped;
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
    shaderEnabled.value = kShaderEnabledDefault;
    shaderStrength.value = 0.45;
    shaderOpacity.value = 1.0;
    shaderAnimationSpeed.value = 1.0;
    shaderFps.value = kShaderFpsDefault;
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

class _ImageSwatches {
  const _ImageSwatches({
    this.palette = const [],
    this.dominant,
    this.vibrant,
    this.lightVibrant,
    this.darkVibrant,
    this.darkMuted,
  });

  final List<Color> palette;
  final Color? dominant;
  final Color? vibrant;
  final Color? lightVibrant;
  final Color? darkVibrant;
  final Color? darkMuted;
}
