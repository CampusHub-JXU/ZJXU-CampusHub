import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局玻璃材质参数中心。
///
/// 液态玻璃/毛玻璃是表现层增强：低端机或用户偏好下可整体降级为实色表面。
/// 所有玻璃组件（[GlassContainer] 及各页玻璃卡片）统一从这里读取开关与
/// 材质参数，避免各页各自持有一套开关导致状态不同步。
class GlassStyleController {
  GlassStyleController._();

  static final GlassStyleController instance = GlassStyleController._();

  static const _keyEnabled = 'glass_material_enabled_v1';
  static const _keyBlurSigma = 'glass_blur_sigma_v1';
  static const _keyTintOpacity = 'glass_tint_opacity_v1';

  /// 玻璃材质总开关。关闭后所有玻璃表面降级为实色，不产生 BackdropFilter。
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  /// 卡片级玻璃的模糊强度（0-30）。
  final ValueNotifier<double> blurSigma = ValueNotifier<double>(14);

  /// 卡片级玻璃的 tint 不透明度（0.2-1.0）。
  final ValueNotifier<double> tintOpacity = ValueNotifier<double>(0.84);

  bool _restored = false;

  Future<void> restore() async {
    if (_restored) return;
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_keyEnabled) ?? true;
    blurSigma.value = (prefs.getDouble(_keyBlurSigma) ?? 14).clamp(0.0, 30.0);
    tintOpacity.value = (prefs.getDouble(_keyTintOpacity) ?? 0.84).clamp(
      0.2,
      1.0,
    );
    _restored = true;
  }

  Future<void> setEnabled(bool value) async {
    enabled.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnabled, value);
  }

  Future<void> setBlurSigma(double value) async {
    final sigma = value.clamp(0.0, 30.0);
    blurSigma.value = sigma;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyBlurSigma, sigma);
  }

  Future<void> setTintOpacity(double value) async {
    final opacity = value.clamp(0.2, 1.0);
    tintOpacity.value = opacity;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyTintOpacity, opacity);
  }

  @visibleForTesting
  Future<void> debugReset() async {
    enabled.value = true;
    blurSigma.value = 14;
    tintOpacity.value = 0.84;
    _restored = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyEnabled);
    await prefs.remove(_keyBlurSigma);
    await prefs.remove(_keyTintOpacity);
  }
}
