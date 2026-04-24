import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../home_controller.dart';

class HomeGlassBackgroundFilter extends StatefulWidget {
  const HomeGlassBackgroundFilter({
    super.key,
    required this.mode,
    required this.intensity,
    required this.levels,
    required this.themeColor,
    required this.monetColors,
    required this.isDarkMode,
    required this.opacity,
    required this.child,
  });

  final HomeShaderMode mode;
  final double intensity;
  final double levels;
  final Color themeColor;
  final List<Color>? monetColors;
  final bool isDarkMode;
  final double opacity;
  final Widget child;

  @override
  State<HomeGlassBackgroundFilter> createState() =>
      _HomeGlassBackgroundFilterState();
}

class _HomeGlassBackgroundFilterState extends State<HomeGlassBackgroundFilter>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  ui.FragmentShader? _fragmentShader;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _loadShader();
    _ticker = createTicker((elapsed) {
      if (widget.mode != HomeShaderMode.ribbon &&
          widget.mode != HomeShaderMode.collage) {
        return;
      }
      setState(() => _elapsed = elapsed);
    });
    if (widget.mode == HomeShaderMode.ribbon ||
        widget.mode == HomeShaderMode.collage) {
      _ticker.start();
    }
  }

  @override
  void didUpdateWidget(covariant HomeGlassBackgroundFilter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode) {
      _loadShader();
      if (widget.mode == HomeShaderMode.ribbon ||
          widget.mode == HomeShaderMode.collage) {
        if (!_ticker.isActive) _ticker.start();
      } else {
        _ticker.stop();
      }
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _fragmentShader?.dispose();
    super.dispose();
  }

  Future<void> _loadShader() async {
    await _HomeBackgroundShaderCache.initialize(widget.mode);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!ui.ImageFilter.isShaderFilterSupported ||
        !_HomeBackgroundShaderCache.initialized(widget.mode)) {
      return widget.child;
    }

    _fragmentShader?.dispose();
    _fragmentShader = _HomeBackgroundShaderCache.program(
      widget.mode,
    )!.fragmentShader();
    switch (widget.mode) {
      case HomeShaderMode.glass:
        _fragmentShader!
          ..setFloat(2, widget.intensity.clamp(0.0, 1.0))
          ..setFloat(3, widget.levels.clamp(4.0, 18.0))
          ..setFloat(4, widget.themeColor.r)
          ..setFloat(5, widget.themeColor.g)
          ..setFloat(6, widget.themeColor.b)
          ..setFloat(7, widget.opacity.clamp(0.0, 1.0))
          ..setFloat(8, widget.isDarkMode ? 1.0 : 0.0);
      case HomeShaderMode.ribbon:
        _fragmentShader!
          ..setFloat(2, _elapsed.inMilliseconds / 1000.0)
          ..setFloat(3, widget.intensity.clamp(0.0, 1.0))
          ..setFloat(4, widget.themeColor.r)
          ..setFloat(5, widget.themeColor.g)
          ..setFloat(6, widget.themeColor.b)
          ..setFloat(7, widget.opacity.clamp(0.0, 1.0))
          ..setFloat(8, widget.isDarkMode ? 1.0 : 0.0);
      case HomeShaderMode.collage:
        final colors = _shaderPalette();
        _fragmentShader!
          ..setFloat(2, _elapsed.inMilliseconds / 1000.0)
          ..setFloat(3, widget.intensity.clamp(0.0, 1.0))
          ..setFloat(4, widget.themeColor.r)
          ..setFloat(5, widget.themeColor.g)
          ..setFloat(6, widget.themeColor.b)
          ..setFloat(7, widget.opacity.clamp(0.0, 1.0))
          ..setFloat(8, colors[0].r)
          ..setFloat(9, colors[0].g)
          ..setFloat(10, colors[0].b)
          ..setFloat(11, colors[1].r)
          ..setFloat(12, colors[1].g)
          ..setFloat(13, colors[1].b)
          ..setFloat(14, colors[2].r)
          ..setFloat(15, colors[2].g)
          ..setFloat(16, colors[2].b)
          ..setFloat(17, colors[3].r)
          ..setFloat(18, colors[3].g)
          ..setFloat(19, colors[3].b)
          ..setFloat(20, colors[4].r)
          ..setFloat(21, colors[4].g)
          ..setFloat(22, colors[4].b)
          ..setFloat(23, colors[5].r)
          ..setFloat(24, colors[5].g)
          ..setFloat(25, colors[5].b)
          ..setFloat(26, widget.isDarkMode ? 1.0 : 0.0);
    }

    return ImageFiltered(
      imageFilter: ui.ImageFilter.shader(_fragmentShader!),
      child: CustomPaint(
        painter: _ShaderCoveragePainter(),
        child: widget.child,
      ),
    );
  }

  List<Color> _shaderPalette() {
    final colors = widget.monetColors;
    if (colors == null || colors.isEmpty) {
      final second = widget.isDarkMode
          ? const Color(0xFF1E1826)
          : const Color(0xFFF3E8F5);
      final third = widget.isDarkMode
          ? const Color(0xFF0B1020)
          : const Color(0xFFFFF7FA);
      return [
        widget.themeColor,
        second,
        third,
        _complement(widget.themeColor),
        _complement(second),
        _complement(third),
      ];
    }
    final first = colors[0];
    final second = colors.length > 1 ? colors[1] : widget.themeColor;
    final third = colors.length > 2 ? colors[2] : colors.last;
    return [
      first,
      second,
      third,
      _complement(first),
      _complement(second),
      _complement(third),
    ];
  }

  Color _complement(Color color) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withHue((hsl.hue + 180.0) % 360.0)
        .withSaturation((hsl.saturation * 1.08).clamp(0.0, 1.0))
        .withLightness((1.0 - hsl.lightness).clamp(0.18, 0.82))
        .toColor();
  }
}

class _ShaderCoveragePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color.fromARGB(1, 0, 0, 0)
      ..style = PaintingStyle.fill;
    canvas.drawPoints(ui.PointMode.points, <Offset>[
      Offset.zero,
      Offset(size.width - 1, 0),
      Offset(0, size.height - 1),
      Offset(size.width - 1, size.height - 1),
    ], paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _HomeBackgroundShaderCache {
  static final _initCalled = <HomeShaderMode>{};
  static final _programs = <HomeShaderMode, ui.FragmentProgram>{};

  static bool initialized(HomeShaderMode mode) => _programs.containsKey(mode);

  static ui.FragmentProgram? program(HomeShaderMode mode) => _programs[mode];

  static Future<void> initialize(HomeShaderMode mode) async {
    if (initialized(mode)) return;
    if (_initCalled.contains(mode)) {
      while (!initialized(mode)) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      return;
    }
    _initCalled.add(mode);
    _programs[mode] = await ui.FragmentProgram.fromAsset(_assetFor(mode));
  }

  static String _assetFor(HomeShaderMode mode) {
    return switch (mode) {
      HomeShaderMode.glass => 'shaders/home_glass_background.frag',
      HomeShaderMode.ribbon => 'shaders/home_ribbon_background.frag',
      HomeShaderMode.collage => 'shaders/home_collage_background.frag',
    };
  }
}
