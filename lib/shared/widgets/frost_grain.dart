// 磨砂玻璃的稀疏闪粉层（Issue #47）。
//
// 一张**预生成**的 512×512 灰度 + alpha PNG（白色稀疏细小闪点，约 1–3 dp）经 [DecorationImage]
// 平铺到表面装饰上——随装饰一起被 squircle / 圆角裁剪，不需要额外 widget 层，也不逐帧
// 生成任何像素。平铺周期 = 512 / [kFrostGrainScale] = 256 逻辑 dp，**与 DPR 无关**
// （1x / 2x / 3x 都是 256dp 重复一次，不会再出现「1 个物理像素一个点」的细碎感）。
//
// **静态**：只有贴图 + 固定 opacity，没有动画 / 定时器 / `scheduleFrameCallback`，
// 因此天然尊重系统「移除动画」与 App 生命周期。参考实现（Pulse Windows）里的
// 5.2s 反相位呼吸**未实现**：Issue #49 的帧时仪器化已就绪，但还没有真实默认视觉 /
// 性能基线，先不引入持续动画（baseline-gated，见 `docs/sparse-acrylic-grain.md`）。
//
// 生成器 `tools/materials/generate_frost_grain.py`（纯标准库、确定性；两个独立种子
// 11 / 29 的阈值峰值图静态合成为这一张）。**不是** SVG `feTurbulence` 的逐位等价，
// 也**不是** Windows Composition 的移植。

import 'package:flutter/widgets.dart';

/// 稀疏闪粉贴图资源（512×512 灰度 + alpha，白色峰值，可平铺无缝）。
const String kFrostGrainAsset = 'assets/textures/frost_grain_peaks.png';

/// [DecorationImage] 的绘制缩放：512 光栅像素 → **256 逻辑 dp** 的平铺周期。
const double kFrostGrainScale = 2.0;

/// 浅色档强度。峰值是白色，叠在浅色乳白雾（≈ 纯白）上本来几乎看不见，所以浅色档
/// 取接近满的 0.90：只有这样细小闪点才能在浅色填充上留下「若隐若现」的提亮
/// （仍然很克制；没有引入第二张深色贴图 / 染色，见 `docs/sparse-acrylic-grain.md`
/// 「浅色模式」）。
const double kFrostGrainOpacityLight = 0.90;

/// 深色档强度。闪点只有约 1–3 dp 且稀疏（覆盖率约 4%），0.55 让亮点在深色填充上
/// 清晰但不刺眼（贴图最亮峰值 alpha 255，实合成 ≈ 填充 + 55% 白）。
const double kFrostGrainOpacityDark = 0.55;

AssetImage? _grainAsset;
DecorationImage? _lightGrain;
DecorationImage? _darkGrain;

/// 稀疏闪粉装饰图。浅 / 深色各取一档强度，实例全局复用。
///
/// 贴图由 [ImageCache] 按 (asset, scale) 缓存：widget 重建、切主题、滚动都不会重新
/// 解码 PNG，也不会重新生成任何像素。
DecorationImage frostGrainImage({required bool isDark}) {
  _grainAsset ??= const AssetImage(kFrostGrainAsset);
  if (isDark) {
    return _darkGrain ??= DecorationImage(
      image: _grainAsset!,
      repeat: ImageRepeat.repeat,
      scale: kFrostGrainScale,
      opacity: kFrostGrainOpacityDark,
      // low：贴图在 DPR 3 上被放大 1.5×，双线性让峰值柔和；none 会画出方块像素。
      filterQuality: FilterQuality.low,
    );
  }
  return _lightGrain ??= DecorationImage(
    image: _grainAsset!,
    repeat: ImageRepeat.repeat,
    scale: kFrostGrainScale,
    opacity: kFrostGrainOpacityLight,
    filterQuality: FilterQuality.low,
  );
}
