import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
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
/// * 着色器作为普通 `Paint.shader` 画进一个 [renderScale] 倍尺寸的子树（像素
///   数不到 1/10），再用 `ImageFilter.matrix` 双线性放大铺满整屏；着色器本身也裁掉了
///   最高频的几层噪声（见 `home_collage_background.frag` 顶部注释）；
/// * 触摸、滚动（含惯性）和最后一根指针抬起后的 400ms 按 [targetFps] 出帧，
///   最高跟随屏幕刷新率；空闲时收紧到 [idleFps]，减少磁贴背景模糊的重算。
///   低于刷新率时用 `Timer` 把「下一帧」排到该到的 vsync，
///   **不用 `Ticker`**——Ticker 每个 vsync 都会让框架提交整屏帧并让 raster 线程
///   重绘（含首页磁贴的背景模糊），回调里自己节流并不能减少帧数；
/// * 按下列条件让路（全部不依赖原生通道）：
///   - 不可见分支 / 被不透明路由盖住（`TickerMode`）、App 非 resumed；
///   - 页面转场期间（[PageTransitionActivity.isBusy]，带看门狗）；
///   - 背景自身完全滚出视口；
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
    this.scrollController,
    this.idleFps = 30,
  });

  /// 着色器渲染尺寸相对逻辑尺寸的缩放（0.3 ≈ 像素数 9%，低频液态渐变双线性放大无损）。
  static const double renderScale = 0.3;

  /// 单帧时间步长上限：超过视为暂停 / 卡顿后的恢复，丢弃这次增量避免动画跳变。
  static const Duration maxFrameDelta = Duration(milliseconds: 120);

  /// 交互时的目标帧率；达到屏幕刷新率时每个 vsync 一帧。
  final int targetFps;

  /// 宿主页面的滚动控制器（可选），用于感知滚动及惯性滑行。
  final ScrollController? scrollController;

  /// 空闲时的帧率上限，默认 30 fps，且受 [targetFps] 限制。
  final int idleFps;

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
  /// 转场让路期间的兜底唤醒间隔：正常由 [PageTransitionActivity.active] 的
  /// 变化立即唤醒；看门狗判定陈旧登记时 `active` 不会翻转，靠这个兜底恢复。
  static const _busyFallbackInterval = Duration(milliseconds: 500);
  static const _interactionHold = Duration(milliseconds: 400);

  /// 是否正挂在 [PageTransitionActivity.active] 上等转场结束。
  bool _waitingForTransition = false;

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

  /// 滚动感知：当前挂着的 `ScrollPosition.isScrolling` 监听（position 会随
  /// 滚动视图 attach / detach 更换，懒绑定见 [_syncScrollPosition]）。
  ValueNotifier<bool>? _scrollingListened;
  final Set<int> _activePointers = {};
  Timer? _interactionHoldTimer;
  Duration _boostUntil = Duration.zero;
  bool _interacting = false;

  // 出帧驱动：一次只持有一个待处理的帧回调或唤醒定时器。
  int? _frameCallbackId;
  Timer? _wakeTimer;
  Duration? _lastStamp;
  Duration? _nextDue;
  late final _driverClock = GestureBinding.instance.samplingClock.stopwatch()
    ..start();
  Duration _lastFrameAt = Duration.zero;
  int _renderedFrames = 0;

  /// 全局共享的 Shader 时钟：主页 / 我的各有一个实例，若各自计时，切 tab
  /// 时两边相位不同，画面会突兀跳变。所有实例读写同一时间，同一帧时间戳
  /// 只推进一次（两页同时可见时不会变成两倍速）。
  static double _sharedTimeSeconds = 0.0;
  static Duration? _sharedStamp;

  double get _timeSeconds => _sharedTimeSeconds;

  @visibleForTesting
  static void debugResetSharedClock() {
    _sharedTimeSeconds = 0.0;
    _sharedStamp = null;
  }

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
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointerEvent);
    widget.scrollController?.addListener(_onScrollOffsetChanged);
    _loadShader();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncScrollPosition();
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
    if (oldWidget.targetFps != widget.targetFps ||
        oldWidget.idleFps != widget.idleFps) {
      _stopDriver();
    }
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController?.removeListener(_onScrollOffsetChanged);
      widget.scrollController?.addListener(_onScrollOffsetChanged);
      _bindScrolling(null);
    }
    _syncScrollPosition();
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
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointerEvent);
    widget.scrollController?.removeListener(_onScrollOffsetChanged);
    _interactionHoldTimer?.cancel();
    _bindScrolling(null);
    _stopDriver();
    _maskImage?.dispose();
    _maskImage = null;
    _shader?.dispose();
    _shader = null;
    _signal.dispose();
    super.dispose();
  }

  bool get _scrollBusy => _scrollingListened?.value ?? false;

  bool get _isInteracting =>
      _activePointers.isNotEmpty ||
      _scrollBusy ||
      _driverClock.elapsed < _boostUntil;

  void _onPointerEvent(PointerEvent event) {
    if (event is PointerDownEvent) {
      _activePointers.add(event.pointer);
      _interactionHoldTimer?.cancel();
      _interactionHoldTimer = null;
      if (_activePointers.length == 1) _syncDriver();
    } else if ((event is PointerUpEvent || event is PointerCancelEvent) &&
        _activePointers.remove(event.pointer) &&
        _activePointers.isEmpty) {
      _boostUntil = _driverClock.elapsed + _interactionHold;
      _interactionHoldTimer = Timer(_interactionHold, () {
        _interactionHoldTimer = null;
        _syncDriver();
      });
    }
  }

  /// 背景自身完全滚出视口：首页把背景放进随内容上滚的 Positioned，滚到功能
  /// 区底部后它已不可见，继续出帧只是白烧 GPU。
  bool get _offScreen {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    final view = View.maybeOf(context);
    // `localToGlobal` 返回逻辑像素，视口高度也要用逻辑尺寸比较。
    final logicalHeight = view == null
        ? double.infinity
        : view.physicalSize.height / view.devicePixelRatio;
    final topLeft = box.localToGlobal(Offset.zero);
    final bottom = topLeft.dy + box.size.height;
    return bottom <= 0 || topLeft.dy >= logicalHeight;
  }

  bool get _canRun =>
      _shader != null &&
      _maskImage != null &&
      !_renderFailed &&
      !_reduceMotion &&
      widget.animationSpeed > 0 &&
      _tickerModeEnabled &&
      _lifecycleState == AppLifecycleState.resumed &&
      !_offScreen;

  /// 懒绑定 `ScrollPosition.isScrolling`：position 在滚动视图 attach 后才存
  /// 在，且 attach / detach 会换对象，所以在依赖变化、出帧入口与 activity 通
  /// 知里都补一次绑定；没有 position（或没挂控制器）时视为不滚动。
  void _syncScrollPosition() {
    final controller = widget.scrollController;
    ValueNotifier<bool>? notifier;
    if (controller != null && controller.hasClients) {
      notifier = controller.position.isScrollingNotifier;
    }
    if (identical(notifier, _scrollingListened)) return;
    _bindScrolling(notifier);
  }

  void _bindScrolling(ValueNotifier<bool>? notifier) {
    _scrollingListened?.removeListener(_onScrollActivity);
    _scrollingListened = notifier;
    _scrollingListened?.addListener(_onScrollActivity);
  }

  void _onScrollActivity() {
    if (!mounted) return;
    _syncScrollPosition();
    _syncDriver();
  }

  void _onScrollOffsetChanged() {
    // 滚回视口时可能仍在同一次滚动中，isScrolling 不一定会再次通知。
    if (!_driverActive) _onScrollActivity();
  }

  bool get _driverActive => _frameCallbackId != null || _wakeTimer != null;

  void _syncDriver() {
    final wasInteracting = _interacting;
    _interacting = _isInteracting;
    if (!_canRun) {
      _stopDriver();
      return;
    }
    if (_waitingForTransition && _driverActive) return;
    if (!_driverActive) {
      _requestFrame();
    } else if (wasInteracting != _interacting) {
      _cancelScheduledFrame();
      _nextDue = null;
      final last = _lastStamp;
      if (_interacting || last == null) {
        _requestFrame();
      } else {
        _scheduleNext(
          last,
          elapsedSinceFrame: _driverClock.elapsed - _lastFrameAt,
        );
      }
    }
  }

  void _waitForTransitionEnd() {
    if (_waitingForTransition) return;
    _waitingForTransition = true;
    PageTransitionActivity.instance.active.addListener(_onTransitionActivity);
  }

  void _stopWaitingForTransition() {
    if (!_waitingForTransition) return;
    _waitingForTransition = false;
    PageTransitionActivity.instance.active.removeListener(
      _onTransitionActivity,
    );
  }

  void _onTransitionActivity() {
    if (PageTransitionActivity.instance.active.value) return;
    // 通知可能在 build / 帧回调中途派发：只做取消 + 请求帧，不 setState。
    _stopDriver();
    if (mounted) _syncDriver();
  }

  void _stopDriver() {
    _stopWaitingForTransition();
    _cancelScheduledFrame();
    // 暂停期间的时间不补算，恢复后不跳变。
    _lastStamp = null;
    _nextDue = null;
  }

  void _cancelScheduledFrame() {
    final id = _frameCallbackId;
    if (id != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(id);
      _frameCallbackId = null;
    }
    _wakeTimer?.cancel();
    _wakeTimer = null;
  }

  void _requestFrame() {
    _frameCallbackId = SchedulerBinding.instance.scheduleFrameCallback(
      _onFrame,
    );
  }

  /// 每个出帧节拍的入口（transient frame callback，与 `Ticker` 同阶段）。
  void _onFrame(Duration stamp) {
    _frameCallbackId = null;
    // position 可能在驱动运行期间才 attach / detach，顺手补绑定。
    _syncScrollPosition();
    if (!mounted || !_canRun) {
      _stopDriver();
      return;
    }
    // 页面转场期间暂停壁纸时钟，不再请求帧。等待活动信号结束，定时器兜底。
    if (PageTransitionActivity.instance.isBusy) {
      _lastStamp = null;
      _nextDue = null;
      // 不轮询：转场一结束（active 翻转）就在下一帧恢复。旧实现每 100ms
      // 轮询一次，返回页面后 Shader 最多还要多冻结 100ms。
      _waitForTransitionEnd();
      _wakeTimer = Timer(_busyFallbackInterval, () {
        _wakeTimer = null;
        _syncDriver();
      });
      return;
    }
    // 看门狗兜底恢复时也摘掉监听，避免之后 active 翻转再重启一次驱动。
    _stopWaitingForTransition();

    final last = _lastStamp;
    _lastStamp = stamp;
    _lastFrameAt = _driverClock.elapsed;
    // 同一帧已由别的实例推进过共享时钟时跳过；暂停后首帧（last 为空或
    // 间隔过大）不补算，恢复后不跳变。
    if (last != null && _sharedStamp != stamp) {
      final delta = stamp - last;
      if (delta > Duration.zero && delta <= HomeFluidBackground.maxFrameDelta) {
        final sharedLast = _sharedStamp;
        // 以共享时钟上次推进的时间戳为准，避免两个实例交替出帧时重复累加。
        final step = sharedLast != null && stamp > sharedLast
            ? (stamp - sharedLast < delta ? stamp - sharedLast : delta)
            : delta;
        _sharedTimeSeconds +=
            step.inMicroseconds /
            1000000.0 *
            widget.animationSpeed.clamp(0.0, 2.0);
      }
    }
    _sharedStamp = stamp;
    _renderedFrames++;
    _signal.bump();
    _interacting = _isInteracting;
    _scheduleNext(stamp);
  }

  /// 当前档位的帧率上限，屏幕刷新率由 [HomeFluidBackground.frameIntervalFor] 限制。
  int get _effectiveFps => _interacting
      ? widget.targetFps
      : math.min(widget.idleFps, widget.targetFps);

  void _scheduleNext(
    Duration stamp, {
    Duration elapsedSinceFrame = Duration.zero,
  }) {
    final interval = HomeFluidBackground.frameIntervalFor(
      _effectiveFps,
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
    final wait =
        due -
        stamp -
        elapsedSinceFrame -
        Duration(microseconds: vsyncMicros ~/ 2);
    if (wait <= Duration.zero) {
      _requestFrame();
      return;
    }
    _wakeTimer = Timer(wait, () {
      _wakeTimer = null;
      if (mounted) _syncDriver();
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
