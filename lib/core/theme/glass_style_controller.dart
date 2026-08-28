import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局玻璃材质开关。
///
/// 液态玻璃/毛玻璃是表现层增强：低端机或用户偏好下可整体降级为实色表面。
/// 所有玻璃组件（[GlassContainer] 及各页玻璃卡片）统一从这里读取开关，
/// 避免各页各自持有一套开关导致状态不同步。
class GlassStyleController {
  GlassStyleController._();

  static final GlassStyleController instance = GlassStyleController._();

  static const _keyEnabled = 'glass_material_enabled_v1';

  /// 玻璃材质总开关。关闭后所有玻璃表面降级为实色，不产生 BackdropFilter。
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  bool _restored = false;

  Future<void> restore() async {
    if (_restored) return;
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_keyEnabled) ?? true;
    _restored = true;
  }

  Future<void> setEnabled(bool value) async {
    enabled.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnabled, value);
  }

  @visibleForTesting
  Future<void> debugReset() async {
    enabled.value = true;
    _restored = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyEnabled);
  }
}
