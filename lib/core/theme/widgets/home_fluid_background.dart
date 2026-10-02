import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../logging/app_logger.dart';
import '../page_transition_activity.dart';

/// 流体 Shader 壁纸（主页 / 我的 共用的整屏背景）。
///
/// `shaders/home_collage_background.frag` 是纯程序化着色器：颜色全部来自 uniform
/// （主题色 + 壁纸取色板），`u_texture` 只贡献 alpha，**不会采样壁纸像素**。
/// 因此不再用 `ImageFilter.shader` 对整屏壁纸做全分辨率滤镜（每帧还要解码 / 绘制
/// 一遍壁纸作为滤镜输入），而是：
///
/// * 以 [renderScale] 倍物理分辨率把着色器画进一张小图（`Picture.toImageSync`），
///   再双线性放大铺满——着色器逐像素成本约降到 1/4；
/// * 只在 [frameInterval]（约 15fps）的 `Timer` 节拍上标脏重新出图——**不用
///   `Ticker`**（Ticker 每个 vsync 都会让框架提交整屏帧，节流不了 raster）；
///   其余重绘（滚动、转场）复用缓存图，不再重跑着色器；
/// * 按下列条件让路（全部不依赖原生通道）：
///   - 不可见分支 / 被不透明路由盖住（`TickerMode`）、App 非 resumed；
///   - 页面转场期间（[PageTransitionActivity]）；
///   - 系统「减弱动画」（`MediaQuery.disableAnimations`）：只画静态一帧；
///   - 用户 [idleFreezeAfter] 没有任何触摸：2 秒内缓出后冻结并停掉定时器，
///     下一次触摸缓入恢复。
///
/// 着色器未加载 / 加载失败 / 出图失败时回退到 [fallback]（原始壁纸图）。
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
  });

  /// 着色器出图相对物理像素的缩放（0.5 = 宽高各一半，像素数 1/4）。
  static const double renderScale = 0.5;

  /// 重新出图的最小间隔（约 15fps）。流体漂移很慢，更高帧率肉眼无差别；每次出图都会让首页磁贴的背景模糊重采样，帧率就是功耗。
  static const Duration frameInterval = Duration(milliseconds: 64);

  /// 无触摸多久后开始缓出并冻结动画。
  static const Duration idleFreezeAfter = Duration(seconds: 45);

  final double intensity;
  final Color themeColor;
  final List<Color>? monetColors;
  final bool isDarkMode;
  final double opacity;
  final double animationSpeed;

  /// 着色器不可用时显示的内容（原始壁纸图）；着色器就绪后不会被构建。
  final Widget fallback;

  @visibleForTesting
  static Future<ui.FragmentProgram> Function()? debugProgramLoader;

  /// 测试用：跳过真实出图（widget 测试里每帧软件光栅化着色器很慢）。
  @visibleForTesting
  static bool debugSkipRender = false;

  @visibleForTesting
  static void debugResetShaderCache({bool clearLoader = true}) {
    if (clearLoader) {
      debugProgramLoader = null;
    }
    debugSkipRender = false;
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
  static const _fadeOutSeconds = 2.0;
  static const _fadeInSeconds = 0.6;

  Timer? _timer;
  final _FrameSignal _signal = _FrameSignal();
  ui.FragmentShader? _shader;
  ui.Image? _maskImage;
  ui.Image? _frame;
  bool _frameDirty = true;
  bool _renderFailed = false;
  int _loadGeneration = 0;
  bool _loadFailed = false;
  bool _resumedRetryUsed = false;
  bool _tickerModeEnabled = true;
  bool _reduceMotion = false;
  bool _frozen = false;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  /// 距上次触摸（或计时重启）已过的「名义时间」，每个节拍累加 [frameInterval]。
  Duration _sinceActivity = Duration.zero;
  double _timeSeconds = 0.0;

  /// 动画速度系数 0..1：空闲冻结时缓出到 0，触摸后缓入回 1。
  double _motion = 1.0;

  @visibleForTesting
  bool get debugTickerActive => _timer?.isActive ?? false;

  @visibleForTesting
  double get debugShaderTimeSeconds => _timeSeconds;

  @visibleForTesting
  ui.FragmentShader? get debugFragmentShader => _shader;

  @visibleForTesting
  bool get debugFrozen => _frozen;

  @visibleForTesting
  bool get debugReduceMotion => _reduceMotion;

  @visibleForTesting
  double get debugMotion => _motion;

  @visibleForTesting
  bool get debugRenderFailed => _renderFailed;

  @override
  void initState() {
    super.initState();
    _lifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
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
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce != _reduceMotion) {
      _reduceMotion = reduce;
      _frameDirty = true;
      _signal.bump();
    }
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant HomeFluidBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 任何参数变化（颜色 / 强度 / 不透明度 / 深浅色）都要重新出图；动画速度
    // 只影响时间推进，不需要。
    _frameDirty = true;
    _signal.bump();
    _syncTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      _resetTickClock();
      _retryLoadAfterResume();
    }
    _syncTimer();
  }

  @override
  void dispose() {
    _loadGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _timer?.cancel();
    _timer = null;
    _frame?.dispose();
    _frame = null;
    _maskImage?.dispose();
    _maskImage = null;
    _shader?.dispose();
    _shader = null;
    _signal.dispose();
    super.dispose();
  }

  /// 任何触摸都算「有人在用」：重置空闲计时，并把已冻结的动画唤醒。
  void _onPointer(PointerEvent event) {
    if (event is PointerHoverEvent) return;
    _sinceActivity = Duration.zero;
    if (_frozen) {
      _frozen = false;
      _syncTimer();
    }
  }

  /// 出图节拍（[Timer.periodic]，**不是** `Ticker`）。
  ///
  /// 必须用定时器而不是每个 vsync 回调的 Ticker：只要有 Ticker 在跑，框架每个
  /// vsync 都会提交整棵图层树并让 raster 线程整屏重绘（含首页磁贴的背景模糊），
  /// 在回调里自己节流并不能减少帧数。定时器只在节拍上标脏，才是真正的 15fps。
  /// 时间按名义节拍推进（定时器被推迟时动画略慢，对装饰动效无所谓）。
  void _onTick() {
    // 页面转场期间不推进：转场帧预算留给转场本身（外壳此时已快照，重绘壁纸
    // 也看不到）；这段时间也不计入空闲，避免转场结束后动画跳变。
    if (PageTransitionActivity.instance.active.value) return;

    final step = HomeFluidBackground.frameInterval;
    final seconds = step.inMicroseconds / 1000000.0;
    _sinceActivity += step;
    final idle = _sinceActivity >= HomeFluidBackground.idleFreezeAfter;
    if (idle) {
      _motion = math.max(0.0, _motion - seconds / _fadeOutSeconds);
    } else {
      _motion = math.min(1.0, _motion + seconds / _fadeInSeconds);
    }
    _timeSeconds =
        (_timeSeconds +
            seconds * widget.animationSpeed.clamp(0.0, 2.0) * _motion) %
        60.0;
    _frameDirty = true;
    _signal.bump();
    if (idle && _motion <= 0.0) {
      // 已缓出到静止：停掉定时器，不再有任何帧调度，直到下一次触摸。
      _frozen = true;
      _syncTimer();
    }
  }

  bool get _shouldRun =>
      _shader != null &&
      !_renderFailed &&
      !_reduceMotion &&
      !_frozen &&
      widget.animationSpeed > 0 &&
      _tickerModeEnabled &&
      _lifecycleState == AppLifecycleState.resumed;

  void _syncTimer() {
    if (_shouldRun) {
      _timer ??= Timer.periodic(HomeFluidBackground.frameInterval, (_) {
        _onTick();
      });
      return;
    }
    if (_timer != null) {
      _timer!.cancel();
      _timer = null;
      _resetTickClock();
    }
  }

  void _resetTickClock() {
    _sinceActivity = Duration.zero;
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
    _shader = program?.fragmentShader();
    previous?.dispose();
    _loadFailed = program == null;
    _renderFailed = false;
    _frameDirty = true;
    if (_shader != null && _maskImage == null) {
      _maskImage = _buildOpaqueMask();
      if (_maskImage == null) {
        _shader?.dispose();
        _shader = null;
        _loadFailed = true;
      }
    }
    setState(() {});
    _syncTimer();
  }

  /// 着色器声明了 `u_texture`（只取 alpha）；作为 Paint shader 绘制时给它一张
  /// 1x1 不透明图，等价于「壁纸完全不透明」。
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

  /// 由 painter 在 paint 阶段调用：返回当前应绘制的低分辨率图；仅当参数 /
  /// 时间 / 尺寸变化时才真正重跑着色器。
  ui.Image? _frameFor(Size size, double devicePixelRatio) {
    final shader = _shader;
    final mask = _maskImage;
    if (shader == null || mask == null || _renderFailed) return null;
    if (HomeFluidBackground.debugSkipRender) return null;
    final width = math.max(
      1,
      (size.width * devicePixelRatio * HomeFluidBackground.renderScale).round(),
    );
    final height = math.max(
      1,
      (size.height * devicePixelRatio * HomeFluidBackground.renderScale)
          .round(),
    );
    final cached = _frame;
    if (!_frameDirty &&
        cached != null &&
        cached.width == width &&
        cached.height == height) {
      return cached;
    }
    try {
      _applyUniforms(shader, width.toDouble(), height.toDouble());
      shader.setImageSampler(0, mask);
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..shader = shader,
      );
      final picture = recorder.endRecording();
      final image = picture.toImageSync(width, height);
      picture.dispose();
      cached?.dispose();
      _frame = image;
      _frameDirty = false;
      return image;
    } catch (error, stackTrace) {
      AppLogger.instance.ui(
        LogLevel.warn,
        '流体着色器出图失败，回退原始壁纸',
        error: error,
        stackTrace: stackTrace,
      );
      _renderFailed = true;
      _frame?.dispose();
      _frame = null;
      // paint 阶段不能 setState；下一帧再切到 fallback 并停掉定时器。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {});
        _syncTimer();
      });
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_shader == null || _maskImage == null || _renderFailed) {
      return widget.fallback;
    }
    return SizedBox.expand(
      child: CustomPaint(
        painter: _FluidPainter(
          owner: this,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          repaint: _signal,
        ),
      ),
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
    required this.devicePixelRatio,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final HomeFluidBackgroundState owner;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final image = owner._frameFor(size, devicePixelRatio);
    if (image == null) return;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(covariant _FluidPainter oldDelegate) =>
      oldDelegate.owner != owner ||
      oldDelegate.devicePixelRatio != devicePixelRatio;
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
