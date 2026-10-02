import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../logging/app_logger.dart';
import '../page_transition_activity.dart';

/// 流体 Shader 壁纸（主页 / 我的 共用的整屏背景）。
///
/// `shaders/home_collage_background.frag` 是纯程序化着色器：颜色全部来自 uniform
/// （主题色 + 壁纸取色板），`u_texture` 只贡献 alpha，**不会采样壁纸像素**。
/// 因此不再用 `ImageFilter.shader` 对整屏壁纸做全分辨率滤镜（每帧还要解码 / 绘制
/// 一遍壁纸作为滤镜输入），而是：
///
/// * 着色器作为普通 `Paint.shader` 画进一个 [renderScale] 倍尺寸的子树（物理像素
///   数 1/4），再用 `ImageFilter.matrix` 双线性放大铺满整屏；着色器本身也裁掉了
///   最高频的几层噪声（见 `home_collage_background.frag` 顶部注释）；
/// * 帧率可配置（设置 → 个性化 → 流体 Shader → 帧率）：[targetFps] 达到屏幕刷新率
///   就每个 vsync 一帧，低于刷新率就用 `Timer` 把「下一帧」排到该到的 vsync，
///   **不用 `Ticker`**——Ticker 每个 vsync 都会让框架提交整屏帧并让 raster 线程
///   重绘（含首页磁贴的背景模糊），回调里自己节流并不能减少帧数；
/// * 按下列条件让路（全部不依赖原生通道）：
///   - 不可见分支 / 被不透明路由盖住（`TickerMode`）、App 非 resumed；
///   - 页面转场期间（[PageTransitionActivity.isBusy]，带看门狗）；
///   - 系统「减弱动画」（`MediaQuery.disableAnimations`）：只画静态一帧；
///   - 动画速度滑条为 0。
///
/// 着色器未加载 / 加载失败 / 绘制抛错时回退到 [fallback]（原始壁纸图）。
class HomeFluidBackground extends StatefulWidget {
  const HomeFluidBackground({
    super.key,
    required this.intensity,
    required this.themeColor,
    required this.monetColors,
    required this.isDarkMode,
    required this.opacity,
    required this.animationSpeed,
    required this.fallback,
    this.targetFps = 60,
  });

  /// 着色器渲染尺寸相对逻辑尺寸的缩放（0.5 = 宽高各一半，像素数 1/4）。
  static const double renderScale = 0.5;

  /// 单帧时间步长上限：超过视为暂停 / 卡顿后的恢复，丢弃这次增量避免动画跳变。
  static const Duration maxFrameDelta = Duration(milliseconds: 120);

  /// 目标帧率；达到屏幕刷新率时不节流（每个 vsync 一帧）。
  final int targetFps;

  final double intensity;
  final Color themeColor;
  final List<Color>? monetColors;
  final bool isDarkMode;
  final double opacity;
  final double animationSpeed;

  /// 着色器不可用时显示的内容（原始壁纸图）；着色器就绪后不会被构建。
  final Widget fallback;

  /// 目标帧率在给定屏幕刷新率下的出帧间隔；`null` 表示不节流（每个 vsync 一帧）。
  static Duration? frameIntervalFor(int fps, double refreshRate) {
    if (fps <= 0) return null;
    if (refreshRate <= 0 || fps >= refreshRate - 0.5) return null;
    return Duration(microseconds: (1000000 / fps).round());
  }

  @visibleForTesting
  static Future<ui.FragmentProgram> Function()? debugProgramLoader;

  /// 测试用：覆盖屏幕刷新率（测试环境没有真实 display）。
  @visibleForTesting
  static double? debugRefreshRate;

  /// 测试用：跳过真实绘制（widget 测试里每帧软件光栅化着色器很慢）。
  @visibleForTesting
  static bool debugSkipPaint = false;

  @visibleForTesting
  static void debugResetShaderCache({bool clearLoader = true}) {
    if (clearLoader) {
      debugProgramLoader = null;
    }
    debugRefreshRate = null;
    debugSkipPaint = false;
    _FluidShaderCache.reset();
  }

  @visibleForTesting
  static Future<ui.FragmentProgram?> debugLoadShader() {
    return _FluidShaderCache.load();
  }

  @visibleForTesting
  static bool get debugShaderInitialized => _FluidShaderCache.initialized;

  @override
  HomeFluidBackgroundState createState() => HomeFluidBackgroundState();
}

class HomeFluidBackgroundState extends State<HomeFluidBackground>
    with WidgetsBindingObserver {
  static const _busyPollInterval = Duration(milliseconds: 100);

  final _FrameSignal _signal = _FrameSignal();
  ui.FragmentShader? _shader;
  ui.Image? _maskImage;
  bool _renderFailed = false;
  int _loadGeneration = 0;
  bool _loadFailed = false;
  bool _resumedRetryUsed = false;
  bool _tickerModeEnabled = true;
  bool _reduceMotion = false;
  double _refreshRate = 60;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  // 出帧驱动：一次只持有一个待处理的帧回调或唤醒定时器。
  int? _frameCallbackId;
  Timer? _wakeTimer;
  Duration? _lastStamp;
  Duration? _nextDue;
  double _timeSeconds = 0.0;
  int _renderedFrames = 0;

  @visibleForTesting
  bool get debugDriverActive => _frameCallbackId != null || _wakeTimer != null;

  @visibleForTesting
  double get debugShaderTimeSeconds => _timeSeconds;

  @visibleForTesting
  int get debugRenderedFrames => _renderedFrames;

  @visibleForTesting
  ui.FragmentShader? get debugFragmentShader => _shader;

  @visibleForTesting
  bool get debugReduceMotion => _reduceMotion;

  @visibleForTesting
  bool get debugRenderFailed => _renderFailed;

  @override
  void initState() {
    super.initState();
    _lifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _loadShader();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = TickerMode.valuesOf(context).enabled;
    if (enabled != _tickerModeEnabled) {
      _tickerModeEnabled = enabled;
      _stopDriver();
    }
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce != _reduceMotion) {
      _reduceMotion = reduce;
      _signal.bump();
    }
    _refreshRate =
        HomeFluidBackground.debugRefreshRate ??
        View.maybeOf(context)?.display.refreshRate ??
        60.0;
    _syncDriver();
  }

  @override
  void didUpdateWidget(covariant HomeFluidBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 颜色 / 强度 / 不透明度 / 深浅色变化要重绘；帧率变化重排出帧计划（立即生效）。
    _signal.bump();
    if (oldWidget.targetFps != widget.targetFps) {
      _stopDriver();
    }
    _syncDriver();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      _stopDriver();
      _retryLoadAfterResume();
    }
    _syncDriver();
  }

  @override
  void dispose() {
    _loadGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    _stopDriver();
    _maskImage?.dispose();
    _maskImage = null;
    _shader?.dispose();
    _shader = null;
    _signal.dispose();
    super.dispose();
  }

  bool get _canRun =>
      _shader != null &&
      _maskImage != null &&
      !_renderFailed &&
      !_reduceMotion &&
      widget.animationSpeed > 0 &&
      _tickerModeEnabled &&
      _lifecycleState == AppLifecycleState.resumed;

  bool get _driverActive => _frameCallbackId != null || _wakeTimer != null;

  void _syncDriver() {
    if (_canRun) {
      if (!_driverActive) _requestFrame();
      return;
    }
    _stopDriver();
  }

  void _stopDriver() {
    final id = _frameCallbackId;
    if (id != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(id);
      _frameCallbackId = null;
    }
    _wakeTimer?.cancel();
    _wakeTimer = null;
    // 暂停期间的时间不补算，恢复后不跳变。
    _lastStamp = null;
    _nextDue = null;
  }

  void _requestFrame() {
    _frameCallbackId = SchedulerBinding.instance.scheduleFrameCallback(
      _onFrame,
    );
  }

  /// 每个出帧节拍的入口（transient frame callback，与 `Ticker` 同阶段）。
  void _onFrame(Duration stamp) {
    _frameCallbackId = null;
    if (!mounted || !_canRun) {
      _stopDriver();
      return;
    }
    // 页面转场期间让路：转场帧预算留给转场本身（外壳此时已快照，重绘壁纸也看
    // 不到）。不再请求帧，改用低频轮询等待结束（看门狗过期也能恢复）。
    if (PageTransitionActivity.instance.isBusy) {
      _lastStamp = null;
      _nextDue = null;
      _wakeTimer = Timer(_busyPollInterval, () {
        _wakeTimer = null;
        _syncDriver();
      });
      return;
    }

    final last = _lastStamp;
    _lastStamp = stamp;
    if (last != null) {
      final delta = stamp - last;
      if (delta > Duration.zero && delta <= HomeFluidBackground.maxFrameDelta) {
        _timeSeconds =
            (_timeSeconds +
                delta.inMicroseconds /
                    1000000.0 *
                    widget.animationSpeed.clamp(0.0, 2.0)) %
            60.0;
      }
    }
    _renderedFrames++;
    _signal.bump();
    _scheduleNext(stamp);
  }

  void _scheduleNext(Duration stamp) {
    final interval = HomeFluidBackground.frameIntervalFor(
      widget.targetFps,
      _refreshRate,
    );
    if (interval == null) {
      _nextDue = null;
      _requestFrame();
      return;
    }
    var due = (_nextDue ?? stamp) + interval;
    if (due <= stamp) {
      // 落后了一整帧以上：重新对齐，别连续补帧。
      due = stamp + interval;
    }
    _nextDue = due;
    final vsyncMicros = (1000000 / _refreshRate).round();
    final wait = due - stamp - Duration(microseconds: vsyncMicros ~/ 2);
    if (wait <= Duration.zero) {
      _requestFrame();
      return;
    }
    _wakeTimer = Timer(wait, () {
      _wakeTimer = null;
      if (mounted && _canRun) _requestFrame();
    });
  }

  void _retryLoadAfterResume() {
    if (_resumedRetryUsed || !_loadFailed || _shader != null) {
      return;
    }
    _resumedRetryUsed = true;
    _loadShader();
  }

  Future<void> _loadShader() async {
    final generation = ++_loadGeneration;
    final program = await _FluidShaderCache.load();
    if (!mounted || generation != _loadGeneration) {
      return;
    }
    final previous = _shader;
    final shader = program?.fragmentShader();
    previous?.dispose();
    _shader = shader;
    _loadFailed = program == null;
    _renderFailed = false;
    if (shader != null) {
      _maskImage ??= _buildOpaqueMask();
      if (_maskImage == null) {
        shader.dispose();
        _shader = null;
        _loadFailed = true;
      } else {
        // 着色器声明了 `u_texture`（只取 alpha）；作为 Paint shader 时绑 1x1
        // 不透明图，等价于「壁纸完全不透明」。
        shader.setImageSampler(0, _maskImage!);
      }
    }
    setState(() {});
    _syncDriver();
  }

  ui.Image? _buildOpaqueMask() {
    try {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 1, 1),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      final picture = recorder.endRecording();
      final image = picture.toImageSync(1, 1);
      picture.dispose();
      return image;
    } catch (error, stackTrace) {
      AppLogger.instance.ui(
        LogLevel.warn,
        '流体着色器遮罩图创建失败',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  void _onPaintFailed(Object error, StackTrace stackTrace) {
    if (_renderFailed) return;
    AppLogger.instance.ui(
      LogLevel.warn,
      '流体着色器绘制失败，回退原始壁纸',
      error: error,
      stackTrace: stackTrace,
    );
    _renderFailed = true;
    // paint 阶段不能 setState；下一帧再切到 fallback 并停掉出帧驱动。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {});
      _syncDriver();
    });
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    if (shader == null || _maskImage == null || _renderFailed) {
      return widget.fallback;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return widget.fallback;
        }
        const scale = HomeFluidBackground.renderScale;
        final small = Size(
          constraints.maxWidth * scale,
          constraints.maxHeight * scale,
        );
        // 子树只有整屏的 scale² 像素：着色器在这里跑，然后矩阵滤镜双线性放大。
        return RepaintBoundary(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.matrix(
              Matrix4.diagonal3Values(1 / scale, 1 / scale, 1).storage,
              filterQuality: FilterQuality.low,
            ),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: small.width,
                height: small.height,
                child: CustomPaint(
                  painter: _FluidPainter(
                    owner: this,
                    shader: shader,
                    repaint: _signal,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _applyUniforms(ui.FragmentShader shader, double width, double height) {
    final colors = _shaderPalette();
    shader
      ..setFloat(0, width)
      ..setFloat(1, height)
      ..setFloat(2, _timeSeconds)
      ..setFloat(3, widget.intensity.clamp(0.0, 1.0))
      ..setFloat(4, widget.themeColor.r)
      ..setFloat(5, widget.themeColor.g)
      ..setFloat(6, widget.themeColor.b)
      ..setFloat(7, widget.opacity.clamp(0.0, 1.0));
    for (var i = 0; i < 6; i++) {
      shader
        ..setFloat(8 + i * 3, colors[i].r)
        ..setFloat(9 + i * 3, colors[i].g)
        ..setFloat(10 + i * 3, colors[i].b);
    }
    shader.setFloat(26, widget.isDarkMode ? 1.0 : 0.0);
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

class _FrameSignal extends ChangeNotifier {
  void bump() => notifyListeners();
}

class _FluidPainter extends CustomPainter {
  _FluidPainter({
    required this.owner,
    required this.shader,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final HomeFluidBackgroundState owner;
  final ui.FragmentShader shader;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || HomeFluidBackground.debugSkipPaint) return;
    try {
      // FlutterFragCoord 是画布局部（逻辑像素）坐标，u_size 必须同为逻辑尺寸；
      // 传物理像素会让 uv 只覆盖图案的一角（放大 dpr 倍、细节全丢）。
      owner._applyUniforms(shader, size.width, size.height);
      canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    } catch (error, stackTrace) {
      owner._onPaintFailed(error, stackTrace);
    }
  }

  @override
  bool shouldRepaint(covariant _FluidPainter oldDelegate) =>
      oldDelegate.owner != owner || oldDelegate.shader != shader;
}

class _FluidShaderCache {
  static Future<ui.FragmentProgram?>? _load;
  static ui.FragmentProgram? _program;

  static bool get initialized => _program != null;

  static void reset() {
    _load = null;
    _program = null;
  }

  static Future<ui.FragmentProgram?> load() {
    final cached = _program;
    if (cached != null) {
      return Future<ui.FragmentProgram?>.value(cached);
    }
    return _load ??= () async {
      try {
        final loader = HomeFluidBackground.debugProgramLoader;
        final program = loader == null
            ? await ui.FragmentProgram.fromAsset(
                'shaders/home_collage_background.frag',
              )
            : await loader();
        _program = program;
        return program;
      } catch (error, stackTrace) {
        AppLogger.instance.ui(
          LogLevel.warn,
          '首页着色器加载失败',
          error: error,
          stackTrace: stackTrace,
        );
        return null;
      } finally {
        _load = null;
      }
    }();
  }
}
