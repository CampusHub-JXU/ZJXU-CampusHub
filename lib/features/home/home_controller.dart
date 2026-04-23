import 'dart:io';

import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum HomeFilterMode {
  brand('红黑白'),
  monet('莫奈取色'),
  custom('自定义');

  const HomeFilterMode(this.label);
  final String label;
}

class HomeController {
  HomeController._();
  static final HomeController instance = HomeController._();

  static const _keyBackgroundPath = 'home_background_image_path';
  static const _keyColorFilterEnabled = 'home_color_filter_enabled';
  static const _keyFilterMode = 'home_filter_mode';
  static const _keyCustomColor0 = 'home_custom_color_0';
  static const _keyCustomColor1 = 'home_custom_color_1';
  static const _keyCustomColor2 = 'home_custom_color_2';
  static const _keyFrostedGlass = 'home_frosted_glass_enabled';
  static const _keyFilterStrength = 'home_filter_strength';
  static const _keyBackgroundOpacity = 'home_background_opacity';
  static const _keyHeaderGlass = 'home_header_glass_enabled';
  static const _keyBgAlignX = 'home_background_align_x';
  static const _keyBgAlignY = 'home_background_align_y';

  final ValueNotifier<String?> backgroundImagePath = ValueNotifier(null);
  final ValueNotifier<bool> colorFilterEnabled = ValueNotifier(false);
  final ValueNotifier<HomeFilterMode> filterMode = ValueNotifier(HomeFilterMode.brand);
  final ValueNotifier<List<Color>> customFilterColors = ValueNotifier([
    const Color(0xFF8B1A2D),
    Colors.black,
    Colors.white,
  ]);
  final ValueNotifier<bool> frostedGlassEnabled = ValueNotifier(false);
  final ValueNotifier<bool> headerGlassEnabled = ValueNotifier(false);
  final ValueNotifier<double> filterStrength = ValueNotifier(0.25);
  final ValueNotifier<double> backgroundOpacity = ValueNotifier(1.0);
  final ValueNotifier<Alignment> backgroundAlignment = ValueNotifier(Alignment.center);

  /// Monet-extracted colors from current background image (cached in memory).
  List<Color>? _monetColors;
  String? _monetSourcePath;

  /// Synchronous access to cached monet colors (null if not yet extracted).
  List<Color>? get cachedMonetColors => _monetColors;

  // --- Color matrix constants ---

  static const _identityMatrix = <double>[
    1, 0, 0, 0, 0,
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0,
  ];

  /// Sepia-like warm tint matrix (brand mode: 红黑白).
  static const _brandTargetMatrix = <double>[
    0.393, 0.769, 0.189, 0, 0,
    0.349, 0.686, 0.168, 0, 0,
    0.272, 0.534, 0.131, 0, 0,
    0,     0,     0,     1, 0,
  ];

  /// Builds a monochrome tint matrix for a given color.
  static List<double> _tintTargetMatrix(Color color) {
    final r = color.r;
    final g = color.g;
    final b = color.b;
    return [
      0.2126 * r, 0.7152 * r, 0.0722 * r, 0, 0,
      0.2126 * g, 0.7152 * g, 0.0722 * g, 0, 0,
      0.2126 * b, 0.7152 * b, 0.0722 * b, 0, 0,
      0,          0,          0,          1, 0,
    ];
  }

  /// Lerps between identity and [target] by factor [t].
  static List<double> _lerpMatrix(List<double> target, double t) {
    return List<double>.generate(
      20,
      (i) => _identityMatrix[i] + (target[i] - _identityMatrix[i]) * t,
    );
  }

  /// Synchronous version for UI preview — uses cached monet colors.
  List<double> buildFilterMatrixSync(double strength) {
    if (strength <= 0) return _identityMatrix;
    final target = switch (filterMode.value) {
      HomeFilterMode.brand => _brandTargetMatrix,
      HomeFilterMode.monet => _tintTargetMatrix(
          cachedMonetColors?.first ?? const Color(0xFF8B1A2D),
        ),
      HomeFilterMode.custom => _tintTargetMatrix(customFilterColors.value.first),
    };
    return _lerpMatrix(target, strength.clamp(0.0, 1.0));
  }

  /// Builds the 5×4 color matrix for the current filter settings.
  /// [strength] controls the blend amount (0 = identity, 1 = full effect).
  Future<List<double>> buildFilterMatrix(double strength) async {
    if (strength <= 0) return _identityMatrix;
    final target = switch (filterMode.value) {
      HomeFilterMode.brand => _brandTargetMatrix,
      HomeFilterMode.monet => _tintTargetMatrix(
          (await getMonetColors()).first,
        ),
      HomeFilterMode.custom => _tintTargetMatrix(customFilterColors.value.first),
    };
    return _lerpMatrix(target, strength.clamp(0.0, 1.0));
  }

  /// Returns monet-extracted colors, computing them if needed.
  Future<List<Color>> getMonetColors() async {
    final path = backgroundImagePath.value;
    if (path == null) return _defaultBrandColors();
    if (_monetColors != null && _monetSourcePath == path) return _monetColors!;
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        FileImage(File(path)),
        size: const Size(200, 200),
        maximumColorCount: 8,
      );
      final dominant = palette.dominantColor?.color;
      final vibrant = palette.vibrantColor?.color;
      final muted = palette.mutedColor?.color;
      _monetColors = [
        dominant ?? const Color(0xFF8B1A2D),
        vibrant ?? Colors.black,
        muted ?? Colors.white,
      ];
      _monetSourcePath = path;
    } catch (_) {
      _monetColors = _defaultBrandColors();
      _monetSourcePath = path;
    }
    return _monetColors!;
  }

  static List<Color> _defaultBrandColors() => const [
    Color(0xFF8B1A2D),
    Colors.black,
    Colors.white,
  ];

  /// Returns the active filter gradient colors for the current mode.
  Future<List<Color>> getActiveFilterColors() async {
    return switch (filterMode.value) {
      HomeFilterMode.brand => _defaultBrandColors(),
      HomeFilterMode.monet => await getMonetColors(),
      HomeFilterMode.custom => customFilterColors.value,
    };
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    final path = prefs.getString(_keyBackgroundPath);
    if (path != null && await File(path).exists()) {
      backgroundImagePath.value = path;
    } else {
      await prefs.remove(_keyBackgroundPath);
      backgroundImagePath.value = null;
    }

    colorFilterEnabled.value = prefs.getBool(_keyColorFilterEnabled) ?? false;

    final modeIdx = prefs.getInt(_keyFilterMode);
    if (modeIdx != null && modeIdx >= 0 && modeIdx < HomeFilterMode.values.length) {
      filterMode.value = HomeFilterMode.values[modeIdx];
    }

    final c0 = prefs.getInt(_keyCustomColor0);
    final c1 = prefs.getInt(_keyCustomColor1);
    final c2 = prefs.getInt(_keyCustomColor2);
    if (c0 != null && c1 != null && c2 != null) {
      customFilterColors.value = [Color(c0), Color(c1), Color(c2)];
    }

    frostedGlassEnabled.value = prefs.getBool(_keyFrostedGlass) ?? false;
    headerGlassEnabled.value = prefs.getBool(_keyHeaderGlass) ?? false;

    filterStrength.value = prefs.getDouble(_keyFilterStrength) ?? 0.25;
    backgroundOpacity.value = prefs.getDouble(_keyBackgroundOpacity) ?? 1.0;

    final bgX = prefs.getDouble(_keyBgAlignX);
    final bgY = prefs.getDouble(_keyBgAlignY);
    if (bgX != null && bgY != null) {
      backgroundAlignment.value = Alignment(bgX, bgY);
    }
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
    backgroundImagePath.value = path;
  }

  Future<void> setColorFilterEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyColorFilterEnabled, enabled);
    colorFilterEnabled.value = enabled;
  }

  Future<void> setFilterMode(HomeFilterMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyFilterMode, mode.index);
    filterMode.value = mode;
  }

  Future<void> setCustomFilterColors(List<Color> colors) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyCustomColor0, colors[0].toARGB32());
    await prefs.setInt(_keyCustomColor1, colors[1].toARGB32());
    await prefs.setInt(_keyCustomColor2, colors[2].toARGB32());
    customFilterColors.value = colors;
  }

  Future<void> setFrostedGlassEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyFrostedGlass, enabled);
    frostedGlassEnabled.value = enabled;
  }

  Future<void> setHeaderGlassEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyHeaderGlass, enabled);
    headerGlassEnabled.value = enabled;
  }

  Future<void> setFilterStrength(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyFilterStrength, value);
    filterStrength.value = value;
  }

  Future<void> setBackgroundOpacity(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyBackgroundOpacity, value);
    backgroundOpacity.value = value;
  }

  Future<void> setBackgroundAlignment(Alignment alignment) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyBgAlignX, alignment.x);
    await prefs.setDouble(_keyBgAlignY, alignment.y);
    backgroundAlignment.value = alignment;
  }

  Future<void> clearBackgroundImage() async {
    await setBackgroundImagePath(null);
  }
}
