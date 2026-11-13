import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../logging/app_logger.dart';

/// Dock 用的「液态玻璃」折射滤镜。
///
/// 普通磨砂只是把背景模糊一层，直线穿过玻璃仍然是直的，一眼就能看出是
/// 半透明塑料；真实玻璃的边缘会把背景像素沿曲面法线掰弯，并在最外圈产生
/// 极窄的冷暖分离与镜面高光。这里用 `ImageFilter.shader`（Impeller 专属）
/// 做这件事：
///
/// * 位移强度由圆角矩形 SDF 的梯度（真实曲面法线）控制，只在轮廓内侧
///   [band] 的边带里生效，中心位移为 0，所以 Dock 上的图标与文字不会被掰弯；
/// * 三个通道各取一个错开 [chroma] 的采样点，色散克制，不是彩虹描边；
/// * 采样的是**已经模糊过**的背景（`ImageFilterConfig.compose` 中折射为
///   `outer`、模糊为 `inner`，即 `refraction(blur(source))`）。
///
/// 任何一步不可用（非 Impeller 后端、shader 未预载、平台不支持）时返回
/// `null`，调用方退回普通磨砂，不影响功能。
class LiquidGlass {
  LiquidGlass._();

  /// 折射带宽度（dp）：只在轮廓内侧这么宽的一条边带里弯折背景。
  static const double band = 28;

  /// 最大背景位移（dp）。必须保持 `displacement < band / 1.5`，否则
  /// 透镜剖面最陡处采样点导数转负，最外圈背景被折成重影。
  static const double displacement = 18;

  /// RGB 通道位移差（dp）：三个通道沿位移向量微弱错开（红偏移最大、
  /// 蓝最小），贴合镜面边缘折射而不拉出彩虹边、久看晃眼。
  static const double chroma = 0.8;

  /// 纵向镜面折叠强度（dp）：上下缘采样点沿纵轴向控件内侧深处折叠的
  /// 附加位移（与 [displacement] 一起，全部被严格夹在控件自身纹理内
  /// 不越界），让上下缘映出靠里一截模糊背景，模拟曲面镜面反射感。
  static const double mirror = 14;

  /// shader 就绪状态。
  ///
  /// [preload] 是异步的：冷启动首帧构建 Dock 时 shader 还没加载完，
  /// [filterConfig] 只能返回 `null`（退化普通磨砂）。这里在加载完成后翻成
  /// `true`，监听它的 `GlassContainer`（nav 档）因此能重建出真正的折射，
  /// 而不是把整个进程生命周期都停在「磨砂」上。
  static final ValueNotifier<bool> ready = ValueNotifier<bool>(false);

  static ui.FragmentProgram? _program;
  static bool _loading = false;
  static bool _unavailable = false;

  // 真机排障日志只记一次：preload / filterConfig 可能被冷启动与监听重建
  // 反复触发，不节流就会在 logcat / 诊断报告里刷屏。
  static bool _loggedSkip = false;
  static bool _loggedFilterBuilt = false;
  static bool _loggedFilterFailed = false;

  /// 测试用：强制 [isReady] 为 `true`。
  ///
  /// `flutter_test` 跑在 Skia 后端，`ImageFilter.isShaderFilterSupported`
  /// 恒为 false，否则「就绪后压低 Dock 底色」这类分支无法覆盖。
  @visibleForTesting
  static bool debugForceReady = false;

  /// 是否已经具备渲染条件（shader 已加载且后端支持 shader filter）。
  static bool get isReady =>
      debugForceReady ||
      (_program != null && ui.ImageFilter.isShaderFilterSupported);

  /// 预载 shader。失败只记一次，不反复重试。
  static Future<void> preload() async {
    if (_program != null || _loading || _unavailable) return;
    _loading = true;
    try {
      _program = await ui.FragmentProgram.fromAsset(
        'shaders/liquid_glass.frag',
      );
      // 后端不支持 shader filter 时保持 false，调用方继续用纯磨砂。
      ready.value = isReady;
      // 真机液态玻璃排障的关键判据：isShaderFilterSupported=false 说明当前
      // 没走 Impeller；program=null 说明资产缺失。两者都会让 Dock 退回纯磨砂。
      AppLogger.instance.ui(
        LogLevel.info,
        '液态玻璃 shader 预载完成：'
        'isShaderFilterSupported=${ui.ImageFilter.isShaderFilterSupported} '
        'program=${_program != null} ready=${ready.value}',
      );
    } catch (error, stackTrace) {
      _unavailable = true;
      AppLogger.instance.ui(
        LogLevel.warn,
        '液态玻璃 shader 预载失败，退回纯磨砂',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _loading = false;
    }
  }

  /// 构造折射滤镜；不可用时返回 `null`。
  ///
  /// 所有几何量按设备像素给到 shader（`FlutterFragCoord` 是物理像素），
  /// 所以半径 / 带宽 / 位移 / 控件矩形都要乘 DPR。[bounds] 为该玻璃容器
  /// 在全局屏幕坐标系下的逻辑矩形；为 null 时 shader 退回整张纹理矩形。
  static ui.ImageFilter? createImageFilter({
    required double radius,
    required double devicePixelRatio,
    Rect? bounds,
    double scale = 1.0,
  }) {
    final program = _program;
    if (program == null || !ui.ImageFilter.isShaderFilterSupported) {
      if (!_loggedSkip) {
        _loggedSkip = true;
        // 区分三种退回原因：shader 还在预载（program=false、unavailable=false）、
        // 资产加载失败（unavailable=true）、后端不支持（isShaderFilterSupported=false）。
        AppLogger.instance.ui(
          LogLevel.info,
          '液态玻璃滤镜暂未启用：program=${program != null} '
          'unavailable=$_unavailable '
          'isShaderFilterSupported=${ui.ImageFilter.isShaderFilterSupported}',
        );
      }
      return null;
    }
    final dpr = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
    final effectiveScale = scale <= 0 ? 1.0 : scale;

    final shader = program.fragmentShader();
    // 索引 0–1 是引擎自动填的 u_size。
    // 索引 2–5 是 u_bounds: (centerX_px, centerY_px, halfW_px, halfH_px)。
    if (bounds != null && !bounds.isEmpty) {
      shader
        ..setFloat(2, bounds.center.dx * dpr)
        ..setFloat(3, bounds.center.dy * dpr)
        ..setFloat(4, bounds.width * 0.5 * dpr)
        ..setFloat(5, bounds.height * 0.5 * dpr);
    } else {
      shader
        ..setFloat(2, 0.0)
        ..setFloat(3, 0.0)
        ..setFloat(4, 0.0)
        ..setFloat(5, 0.0);
    }
    // 索引 6–7 是 u_shape: (radius_px, band_px)；8–10 是 u_strength:
    // (displacement_px, chroma_px, mirror_px)。
    shader
      ..setFloat(6, radius * effectiveScale * dpr)
      ..setFloat(7, band * effectiveScale * dpr)
      ..setFloat(8, displacement * effectiveScale * dpr)
      ..setFloat(9, chroma * effectiveScale * dpr)
      ..setFloat(10, mirror * effectiveScale * dpr);

    try {
      final filter = ui.ImageFilter.shader(shader);
      if (!_loggedFilterBuilt) {
        _loggedFilterBuilt = true;
        AppLogger.instance.ui(
          LogLevel.info,
          '液态玻璃滤镜已构建：radius=$radius dpr=$dpr bounds=$bounds',
        );
      }
      return filter;
    } catch (error, stackTrace) {
      if (!_loggedFilterFailed) {
        _loggedFilterFailed = true;
        AppLogger.instance.ui(
          LogLevel.warn,
          '液态玻璃滤镜构建失败，退回纯磨砂：radius=$radius dpr=$dpr',
          error: error,
          stackTrace: stackTrace,
        );
      }
      return null;
    }
  }

  /// 构造折射 [ImageFilterConfig]；不可用时返回 `null`。
  static ImageFilterConfig? filterConfig({
    required double radius,
    required double devicePixelRatio,
    Rect? bounds,
    double scale = 1.0,
  }) {
    final filter = createImageFilter(
      radius: radius,
      devicePixelRatio: devicePixelRatio,
      bounds: bounds,
      scale: scale,
    );
    return filter == null ? null : ImageFilterConfig(filter);
  }

  /// 测试用：把就绪状态与缓存清回初始值。
  @visibleForTesting
  static void debugReset() {
    _program = null;
    _loading = false;
    _unavailable = false;
    _loggedSkip = false;
    _loggedFilterBuilt = false;
    _loggedFilterFailed = false;
    debugForceReady = false;
    ready.value = false;
  }
}

/// 持有液态玻璃容器最近一次 paint 时的全局屏幕逻辑矩形与缓存滤镜。
///
/// 由 [LiquidGlassBoundsTracker] 在每次绘制前刷新，供 [ImageFilterConfig.resolve]
/// 同步读取，避免滚动或缩放预览期间 `u_bounds` 过期。
class LiquidGlassBoundsHolder {
  Rect? globalRect;
  Size? localSize;

  Rect? _cachedGlobalRect;
  Rect? _cachedLocalBounds;
  double? _cachedRadius;
  double? _cachedScale;
  double? _cachedDpr;
  ui.ImageFilter? _cachedInnerBlur;
  ui.ImageFilter? _cachedComposed;

  ui.ImageFilter? lookup({
    required Rect? globalRect,
    required Rect localBounds,
    required double radius,
    required double scale,
    required double dpr,
    required ui.ImageFilter innerBlur,
  }) {
    if (_cachedComposed != null &&
        _cachedGlobalRect == globalRect &&
        _cachedLocalBounds == localBounds &&
        _cachedRadius == radius &&
        _cachedScale == scale &&
        _cachedDpr == dpr &&
        _cachedInnerBlur == innerBlur) {
      return _cachedComposed;
    }
    return null;
  }

  void store({
    required Rect? globalRect,
    required Rect localBounds,
    required double radius,
    required double scale,
    required double dpr,
    required ui.ImageFilter innerBlur,
    required ui.ImageFilter composed,
  }) {
    _cachedGlobalRect = globalRect;
    _cachedLocalBounds = localBounds;
    _cachedRadius = radius;
    _cachedScale = scale;
    _cachedDpr = dpr;
    _cachedInnerBlur = innerBlur;
    _cachedComposed = composed;
  }

  void invalidateCache() {
    _cachedComposed = null;
  }
}

/// 在绘制 `BackdropFilter` 前捕获当前控件的全局屏幕位置，并在父级滚动视图
/// 滚动时通知子 `BackdropFilter` 重绘以更新 `u_bounds`。
class LiquidGlassBoundsTracker extends SingleChildRenderObjectWidget {
  const LiquidGlassBoundsTracker({
    super.key,
    required this.holder,
    this.scrollPosition,
    super.child,
  });

  final LiquidGlassBoundsHolder holder;
  final ScrollPosition? scrollPosition;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderLiquidGlassBoundsTracker(holder, scrollPosition);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    if (renderObject is _RenderLiquidGlassBoundsTracker) {
      renderObject
        ..holder = holder
        ..scrollPosition = scrollPosition;
    }
  }
}

class _RenderLiquidGlassBoundsTracker extends RenderProxyBox {
  _RenderLiquidGlassBoundsTracker(
    this._holder,
    ScrollPosition? scrollPosition,
  ) {
    this.scrollPosition = scrollPosition;
  }

  LiquidGlassBoundsHolder _holder;
  set holder(LiquidGlassBoundsHolder value) {
    if (identical(_holder, value)) return;
    _holder = value;
    markNeedsPaint();
  }

  ScrollPosition? _scrollPosition;
  set scrollPosition(ScrollPosition? value) {
    if (identical(_scrollPosition, value)) return;
    _scrollPosition?.removeListener(_onScroll);
    _scrollPosition = value;
    _scrollPosition?.addListener(_onScroll);
  }

  void _onScroll() {
    child?.markNeedsPaint();
  }

  @override
  void dispose() {
    _scrollPosition?.removeListener(_onScroll);
    _scrollPosition = null;
    _holder.invalidateCache();
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (hasSize) {
      final transform = getTransformTo(null);
      _holder.globalRect = MatrixUtils.transformRect(
        transform,
        Offset.zero & size,
      );
      _holder.localSize = size;
    }
    super.paint(context, offset);
  }
}
