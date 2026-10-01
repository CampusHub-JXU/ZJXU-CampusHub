import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'surface_material.dart';

/// 表面材质等级。
///
/// 同一屏的模糊层数量直接决定 GPU 开销，等级制用于约束用量：
/// * [GlassTier.card] —— 内容卡片，默认真实模糊；密集列表/纯色内容可显式关闭
///   以省 GPU。
/// * [GlassTier.nav] —— 底部导航 / 顶栏 / 悬浮操作条，整屏至多一个。
/// * [GlassTier.overlay] —— 弹层、菜单、抽屉头部，转瞬即逝，允许重模糊。
enum GlassTier { card, nav, overlay }

/// 全局表面材质开关中心。
///
/// 亚克力是表现层增强：低端机或用户偏好下可整体降级为实色表面。
/// 所有材质组件（GlassContainer、AppTileSurface、AppBar/底栏及各页卡片）统一
/// 从这里读取开关，避免各页各自持有一套开关导致状态不同步。
///
/// 用户侧只保留一个开关：「亚克力材质」（默认开启）。开启时全局表面为
/// [SurfaceMaterialStyle.acrylic]（真实背景模糊 + 颗粒），关闭时降级为
/// [SurfaceMaterialStyle.solid]。风格与模糊强度、透明度不再可调，固定为
/// [kSurfaceBlurBase] / [kSurfaceTintOpacity]。旧版本持久化的风格/模糊/透明度键在
/// [restore] 时清除，读取时只认 [enabled] 键，因此旧的 glass / mica 取值不会复活。
class GlassStyleController {
  GlassStyleController._();

  static final GlassStyleController instance = GlassStyleController._();

  static const _keyEnabled = 'glass_material_enabled_v1';
  static const _keyBlurSigma = 'glass_blur_sigma_v1';
  static const _keyTintOpacity = 'glass_tint_opacity_v1';
  static const _keyMaterialStyle = 'glass_material_style_v1';

  /// 「亚克力材质」开关（默认开启）。关闭后所有表面降级为实色，不产生 BackdropFilter。
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  bool _restored = false;

  /// 当前表面材质风格，由 [enabled] 决定：开 = 亚克力，关 = 实色。
  /// 渲染配方见 [MaterialRecipe]。
  SurfaceMaterialStyle get materialStyle =>
      enabled.value ? SurfaceMaterialStyle.acrylic : SurfaceMaterialStyle.solid;

  Future<void> restore() async {
    if (_restored) return;
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_keyEnabled) ?? true;
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
    for (final key in _retiredKeys) {
      await prefs.remove(key);
    }
  }
}
