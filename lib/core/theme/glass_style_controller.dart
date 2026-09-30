import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'surface_material.dart';

/// 玻璃材质等级。
///
/// 同一屏的模糊层数量直接决定 GPU 开销，等级制用于约束用量：
/// * [GlassTier.card] —— 内容卡片，模糊强度/透明度跟随全局参数
///   （[GlassStyleController.blurSigma]/[GlassStyleController.tintOpacity]），
///   默认真实模糊；密集列表/纯色内容可显式关闭以省 GPU。
/// * [GlassTier.nav] —— 底部导航 / 顶栏 / 悬浮操作条，整屏至多一个。
/// * [GlassTier.overlay] —— 弹层、菜单、抽屉头部，转瞬即逝，允许重模糊。
enum GlassTier { card, nav, overlay }

/// 全局玻璃材质参数中心。
///
/// 液态玻璃/毛玻璃是表现层增强：低端机或用户偏好下可整体降级为实色表面。
/// 所有玻璃组件（GlassContainer、玻璃 AppBar/底栏及各页玻璃卡片）统一从
/// 这里读取开关与材质参数，避免各页各自持有一套开关导致状态不同步。
///
/// 用户侧只保留一个开关：「亚克力材质」（默认开启）。开启时全局表面为
/// [SurfaceMaterialStyle.acrylic]（真实背景模糊 + 颗粒），关闭时降级为
/// [SurfaceMaterialStyle.solid]。风格与模糊强度、透明度参数不再对用户开放（各档差异在真机上
/// 难以分辨、设置页也无法实时预览），固定为默认值；渲染配方仍保留，供
/// 显式 `surfaceType` 覆盖与测试使用。旧版本持久化的风格/模糊/透明度键在
/// [restore] 时清除。
class GlassStyleController {
  GlassStyleController._();

  static final GlassStyleController instance = GlassStyleController._();

  static const _keyEnabled = 'glass_material_enabled_v1';
  static const _keyBlurSigma = 'glass_blur_sigma_v1';
  static const _keyTintOpacity = 'glass_tint_opacity_v1';
  static const _keyMaterialStyle = 'glass_material_style_v1';

  /// 当前表面材质风格，由 [enabled] 决定：开 = 亚克力，关 = 实色。
  /// 渲染配方见 [MaterialRecipe]。
  final ValueNotifier<SurfaceMaterialStyle> materialStyle =
      ValueNotifier<SurfaceMaterialStyle>(SurfaceMaterialStyle.acrylic);

  /// 「亚克力材质」开关（默认开启）。关闭后所有表面降级为实色，不产生 BackdropFilter。
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  /// 卡片级玻璃的模糊强度基准值（0-30）。
  ///
  /// 0 等价于「关闭模糊」：任何档位都不再创建 BackdropFilter（见 [shouldBlur]）。
  final ValueNotifier<double> blurSigma = ValueNotifier<double>(14);

  /// 卡片级玻璃的 tint 不透明度（0.2-1.0）。
  final ValueNotifier<double> tintOpacity = ValueNotifier<double>(0.84);

  bool _restored = false;

  /// 各材质档位的模糊强度派生（单一来源）。
  ///
  /// * card —— 直接使用 [blurSigma]，滑条 0-1:1 生效；
  /// * nav —— 常驻全屏层（底栏/顶栏），比卡片略重并保底，默认 24；
  /// * overlay —— 弹层转瞬即逝，允许更重，默认 30。
  /// 档位上限略高于滑条最大值 30，避免常驻层/弹层在低强度下糊不均匀。
  double sigmaFor(GlassTier tier) => switch (tier) {
    GlassTier.card => blurSigma.value,
    GlassTier.nav => _clampDouble(blurSigma.value + 10, 16, 30),
    GlassTier.overlay => _clampDouble(blurSigma.value + 16, 22, 36),
  };

  /// 是否允许创建 BackdropFilter。
  ///
  /// 总开关关闭或「模糊强度」拉到 0（<= 0.5）时一律为 false，
  /// 玻璃组件据此整体降级为实色表面，保证低端机流畅。
  bool shouldBlur() => enabled.value && blurSigma.value > 0.5;

  Future<void> restore() async {
    if (_restored) return;
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_keyEnabled) ?? true;
    materialStyle.value = _styleFor(enabled.value);
    _restored = true;
    // 旧版本可调的风格/模糊/透明度已下线，清掉残留键，避免日后误读。
    for (final key in _retiredKeys) {
      if (prefs.containsKey(key)) await prefs.remove(key);
    }
  }

  static const _retiredKeys = [
    _keyBlurSigma,
    _keyTintOpacity,
    _keyMaterialStyle,
  ];

  static SurfaceMaterialStyle _styleFor(bool enabled) =>
      enabled ? SurfaceMaterialStyle.acrylic : SurfaceMaterialStyle.solid;

  /// 测试入口：直接切换全局风格以覆盖各材质配方的渲染分支（不持久化）。
  @visibleForTesting
  Future<void> setMaterialStyle(SurfaceMaterialStyle style) async {
    materialStyle.value = style;
  }

  Future<void> setEnabled(bool value) async {
    enabled.value = value;
    materialStyle.value = _styleFor(value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnabled, value);
  }

  /// 测试入口：调整模糊基准以覆盖派生与降级分支（不持久化）。
  @visibleForTesting
  Future<void> setBlurSigma(double value) async {
    blurSigma.value = value.clamp(0.0, 30.0);
  }

  /// 测试入口：调整 tint 基准（不持久化）。
  @visibleForTesting
  Future<void> setTintOpacity(double value) async {
    tintOpacity.value = value.clamp(0.2, 1.0);
  }

  @visibleForTesting
  Future<void> debugReset() async {
    enabled.value = true;
    blurSigma.value = 14;
    tintOpacity.value = 0.84;
    materialStyle.value = SurfaceMaterialStyle.acrylic;
    _restored = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyEnabled);
    await prefs.remove(_keyBlurSigma);
    await prefs.remove(_keyTintOpacity);
    await prefs.remove(_keyMaterialStyle);
  }

  static double _clampDouble(double value, double min, double max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }
}
