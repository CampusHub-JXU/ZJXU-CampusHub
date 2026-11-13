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
/// 亚克力**始终开启**，用户侧不再提供开关：全局表面固定为
/// [SurfaceMaterialStyle.acrylic]（真实背景模糊 + 颗粒），模糊强度与透明度固定为
/// [kSurfaceBlurBase] / [kSurfaceTintOpacity]。旧版本持久化的开关 / 风格 / 模糊 /
/// 透明度键在 [restore] 时一律清除，旧的「关闭」取值不会复活。
/// [enabled] 仍保留为可监听值，只供测试切到实色路径（[setEnabled]）。
class GlassStyleController {
  GlassStyleController._();

  static final GlassStyleController instance = GlassStyleController._();

  static const _keyEnabled = 'glass_material_enabled_v1';
  static const _keyBlurSigma = 'glass_blur_sigma_v1';
  static const _keyTintOpacity = 'glass_tint_opacity_v1';
  static const _keyMaterialStyle = 'glass_material_style_v1';
  static const _keyFrostGrain = 'frost_grain_enabled_v1';

  /// 亚克力是否开启：生产环境恒为 true；测试可经 [setEnabled] 切到实色。
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  /// 磨砂表面是否叠加稀疏闪粉贴图（`frost_grain.dart`）。用户开关已下线，
  /// 恒为 **false**（旧持久化键随 [restore] 清理，见 [_retiredKeys]）；只影响
  /// 贴图层，模糊 / 雾 / 描边不变。测试仍可手动改值以覆盖闪粉路径。
  final ValueNotifier<bool> frostGrainEnabled = ValueNotifier<bool>(false);

  /// 材质表面需要重建的合并信号：亚克力开关或闪粉开关任一变化。
  late final Listenable surfaceChanged = Listenable.merge([
    enabled,
    frostGrainEnabled,
  ]);

  bool _restored = false;

  /// 当前表面材质风格，由 [enabled] 决定：开 = 亚克力，关 = 实色。
  /// 渲染配方见 [MaterialRecipe]。
  SurfaceMaterialStyle get materialStyle =>
      enabled.value ? SurfaceMaterialStyle.acrylic : SurfaceMaterialStyle.solid;

  Future<void> restore() async {
    if (_restored) return;
    final prefs = await SharedPreferences.getInstance();
    enabled.value = true;
    frostGrainEnabled.value = false;
    _restored = true;
    // 开关与可调的风格/模糊/透明度（含磨砂闪粉）均已下线，清掉残留键，
    // 避免日后误读，也确保旧版本开过闪粉的用户升级后回到默认关闭。
    for (final key in _retiredKeys) {
      if (prefs.containsKey(key)) await prefs.remove(key);
    }
  }

  /// 仅测试：切换闪粉贴图层（不落盘，[restore] 恒复位为 false）。
  @visibleForTesting
  Future<void> setFrostGrainEnabled(bool value) async {
    if (frostGrainEnabled.value == value) return;
    frostGrainEnabled.value = value;
  }

  static const _retiredKeys = [
    _keyEnabled,
    _keyBlurSigma,
    _keyTintOpacity,
    _keyMaterialStyle,
    _keyFrostGrain,
  ];

  /// 仅测试：切换亚克力 / 实色路径（不落盘）。
  @visibleForTesting
  Future<void> setEnabled(bool value) async => enabled.value = value;

  /// 仅测试：让下一次 [restore] 重新读盘（验证旧键清理）。
  @visibleForTesting
  void debugMarkUnrestored() => _restored = false;

  @visibleForTesting
  Future<void> debugReset() async {
    enabled.value = true;
    frostGrainEnabled.value = false;
    _restored = true;
    final prefs = await SharedPreferences.getInstance();
    for (final key in _retiredKeys) {
      await prefs.remove(key);
    }
  }
}
