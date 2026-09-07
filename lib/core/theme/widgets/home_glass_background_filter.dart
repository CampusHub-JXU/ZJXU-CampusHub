import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../logging/app_logger.dart';
import '../personalization_controller.dart';

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
    required this.animationSpeed,
    required this.child,
  });

  final HomeShaderMode mode;
  final double intensity;
  final double levels;
  final Color themeColor;
  final List<Color>? monetColors;
  final bool isDarkMode;
  final double opacity;
  final double animationSpeed;
  final Widget child;

  @visibleForTesting
  static Future<ui.FragmentProgram> Function(HomeShaderMode mode)?
  debugProgramLoader;

  @visibleForTesting
  static void debugResetShaderCache({bool clearLoader = true}) {
    if (clearLoader) {
      debugProgramLoader = null;
    }
    _HomeBackgroundShaderCache.reset();
  }

  @visibleForTesting
  static Future<ui.FragmentProgram?> debugLoadShader(HomeShaderMode mode) {
    return _HomeBackgroundShaderCache.load(mode);
  }

  @visibleForTesting
  static bool debugShaderInitialized(HomeShaderMode mode) {
    return _HomeBackgroundShaderCache.initialized(mode);
  }

  @override
  HomeGlassBackgroundFilterState createState() =>
      HomeGlassBackgroundFilterState();
}

class HomeGlassBackgroundFilterState extends State<HomeGlassBackgroundFilter>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _frameInterval = Duration(milliseconds: 33);
  static const _maxTickDelta = Duration(milliseconds: 120);

  late final Ticker _ticker;
  ui.FragmentShader? _fragmentShader;
  HomeShaderMode? _boundMode;
  int _loadGeneration = 0;
  bool _loadFailed = false;
  bool _resumedRetryUsed = false;
  bool _tickerModeEnabled = true;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  Duration _lastTickElapsed = Duration.zero;
  Duration _lastPaintElapsed = Duration.zero;
  Duration _pendingTickDelta = Duration.zero;
  double _shaderTimeSeconds = 0.0;

  @visibleForTesting
  bool get debugTickerActive => _ticker.isActive;

  @visibleForTesting
  HomeShaderMode? get debugBoundMode => _boundMode;

  @visibleForTesting
  double get debugShaderTimeSeconds => _shaderTimeSeconds;

  @visibleForTesting
  ui.FragmentShader? get debugFragmentShader => _fragmentShader;

  @override
  void initState() {
    super.initState();
    _lifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_onTick);
    _loadShader();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = TickerMode.valuesOf(context).enabled;
    if (enabled && !_tickerModeEnabled) {
      _resetTickClock();
    }
    _tickerModeEnabled = enabled;
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant HomeGlassBackgroundFilter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode) {
      _releaseShader();
      _loadFailed = false;
      _resumedRetryUsed = false;
      _loadShader();
    }
    _syncTicker();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      _resetTickClock();
      _retryLoadAfterResume();
    }
    _syncTicker();
  }

  @override
  void dispose() {
    _loadGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _releaseShader();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    if (!_modeNeedsTicker) {
      return;
    }
    if (_lastTickElapsed == Duration.zero) {
      _lastTickElapsed = elapsed;
      return;
    }
    final delta = elapsed - _lastTickElapsed;
    _lastTickElapsed = elapsed;
    if (delta <= Duration.zero) {
      return;
    }
    if (delta > _maxTickDelta) {
      _pendingTickDelta = Duration.zero;
      return;
    }
    _pendingTickDelta += delta;
    if (elapsed - _lastPaintElapsed < _frameInterval) {
      return;
    }
    _lastPaintElapsed = elapsed;
    _shaderTimeSeconds =
        (_shaderTimeSeconds +
            _pendingTickDelta.inMicroseconds /
                1000000.0 *
                widget.animationSpeed.clamp(0.0, 2.0)) %
        60.0;
    _pendingTickDelta = Duration.zero;
    setState(() {});
  }

  bool get _modeNeedsTicker =>
      widget.mode == HomeShaderMode.ribbon ||
      widget.mode == HomeShaderMode.collage;

  bool get _lifecycleAllowsTicker =>
      _lifecycleState == AppLifecycleState.resumed;

  void _syncTicker() {
    final shouldRun =
        _modeNeedsTicker && _tickerModeEnabled && _lifecycleAllowsTicker;
    if (shouldRun) {
      if (!_ticker.isActive) {
        _ticker.start();
      }
      return;
    }
    if (_ticker.isActive) {
      _ticker.stop();
      _resetTickClock();
    }
  }

  void _resetTickClock() {
    _lastTickElapsed = Duration.zero;
    _lastPaintElapsed = Duration.zero;
    _pendingTickDelta = Duration.zero;
  }

  void _releaseShader() {
    _fragmentShader?.dispose();
    _fragmentShader = null;
    _boundMode = null;
  }

  void _retryLoadAfterResume() {
    if (_resumedRetryUsed || !_loadFailed || _fragmentShader != null) {
      return;
    }
    _resumedRetryUsed = true;
    _loadShader();
  }

  Future<void> _loadShader() async {
    final mode = widget.mode;
    final generation = ++_loadGeneration;
    final program = await _HomeBackgroundShaderCache.load(mode);
    if (!mounted || generation != _loadGeneration || widget.mode != mode) {
      return;
    }
    final previous = _fragmentShader;
    _fragmentShader = program?.fragmentShader();
    previous?.dispose();
    _boundMode = mode;
    _loadFailed = program == null;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final shader = _fragmentShader;
    if (!ui.ImageFilter.isShaderFilterSupported || shader == null) {
      return widget.child;
    }

    _applyUniforms(shader);
    return ImageFiltered(
      imageFilter: ui.ImageFilter.shader(shader),
      child: CustomPaint(
        painter: const _ShaderCoveragePainter(),
        child: widget.child,
      ),
    );
  }

  void _applyUniforms(ui.FragmentShader shader) {
    switch (widget.mode) {
      case HomeShaderMode.glass:
        shader
          ..setFloat(2, widget.intensity.clamp(0.0, 1.0))
          ..setFloat(3, widget.levels.clamp(4.0, 18.0))
          ..setFloat(4, widget.themeColor.r)
          ..setFloat(5, widget.themeColor.g)
          ..setFloat(6, widget.themeColor.b)
          ..setFloat(7, widget.opacity.clamp(0.0, 1.0))
          ..setFloat(8, widget.isDarkMode ? 1.0 : 0.0);
      case HomeShaderMode.ribbon:
        shader
          ..setFloat(2, _shaderTimeSeconds)
          ..setFloat(3, widget.intensity.clamp(0.0, 1.0))
          ..setFloat(4, widget.themeColor.r)
          ..setFloat(5, widget.themeColor.g)
          ..setFloat(6, widget.themeColor.b)
          ..setFloat(7, widget.opacity.clamp(0.0, 1.0))
          ..setFloat(8, widget.isDarkMode ? 1.0 : 0.0);
      case HomeShaderMode.collage:
        final colors = _shaderPalette();
        shader
          ..setFloat(2, _shaderTimeSeconds)
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
  }

  List<Color> _shaderPalette() {
    final colors = widget.monetColors;
    if (colors == null || colors.isEmpty) {
      final second = _themeTone(
        widget.themeColor,
        hueDelta: 18,
        saturationScale: 0.72,
        lightness: widget.isDarkMode ? 0.18 : 0.91,
      );
      final third = _themeTone(
        widget.themeColor,
        hueDelta: -24,
        saturationScale: 0.44,
        lightness: widget.isDarkMode ? 0.08 : 0.97,
      );
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

  Color _themeTone(
    Color color, {
    required double hueDelta,
    required double saturationScale,
    required double lightness,
  }) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withHue((hsl.hue + hueDelta) % 360.0)
        .withSaturation((hsl.saturation * saturationScale).clamp(0.0, 1.0))
        .withLightness(lightness.clamp(0.0, 1.0))
        .toColor();
  }
}

class _ShaderCoveragePainter extends CustomPainter {
  const _ShaderCoveragePainter();

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
  static final _loads = <HomeShaderMode, Future<ui.FragmentProgram?>>{};
  static final _programs = <HomeShaderMode, ui.FragmentProgram>{};

  static bool initialized(HomeShaderMode mode) => _programs.containsKey(mode);

  static void reset() {
    _loads.clear();
    _programs.clear();
  }

  static Future<ui.FragmentProgram?> load(HomeShaderMode mode) {
    final cached = _programs[mode];
    if (cached != null) {
      return Future<ui.FragmentProgram?>.value(cached);
    }
    return _loads.putIfAbsent(mode, () async {
      try {
        final loader = HomeGlassBackgroundFilter.debugProgramLoader;
        final program = loader == null
            ? await ui.FragmentProgram.fromAsset(_assetFor(mode))
            : await loader(mode);
        _programs[mode] = program;
        return program;
      } catch (error, stackTrace) {
        AppLogger.instance.ui(
          LogLevel.warn,
          '首页着色器加载失败: ${mode.name}',
          error: error,
          stackTrace: stackTrace,
        );
        return null;
      } finally {
        _loads.remove(mode);
      }
    });
  }

  static String _assetFor(HomeShaderMode mode) {
    return switch (mode) {
      HomeShaderMode.glass => 'shaders/home_glass_background.frag',
      HomeShaderMode.ribbon => 'shaders/home_ribbon_background.frag',
      HomeShaderMode.collage => 'shaders/home_collage_background.frag',
    };
  }
}
