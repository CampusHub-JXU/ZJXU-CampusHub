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

  final ValueNotifier<String?> backgroundImagePath = ValueNotifier(null);
  final ValueNotifier<bool> colorFilterEnabled = ValueNotifier(false);
  final ValueNotifier<HomeFilterMode> filterMode = ValueNotifier(HomeFilterMode.brand);
  final ValueNotifier<List<Color>> customFilterColors = ValueNotifier([
    const Color(0xFF8B1A2D),
    Colors.black,
    Colors.white,
  ]);
  final ValueNotifier<bool> frostedGlassEnabled = ValueNotifier(false);

  /// Monet-extracted colors from current background image (cached in memory).
  List<Color>? _monetColors;
  String? _monetSourcePath;

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

  Future<void> clearBackgroundImage() async {
    await setBackgroundImagePath(null);
  }
}
