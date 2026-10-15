import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/digests/sha256.dart';

import 'package:jxu_campus_hub/shared/widgets/app_tile_surface.dart';
import 'package:jxu_campus_hub/shared/widgets/frost_grain.dart';

import '../../helpers/texture_probe.dart';

/// 已提交贴图的 sha256。**重新生成贴图后必须同步更新**（生成器会打印新值）；
/// 见 `docs/sparse-acrylic-grain.md`。
const String _expectedSha256 =
    '96936912df3f84b90dd98b0d0ef96f79e4110098a42a0df5a8a437776df48251';

/// 贴图文件路径（相对包根，`flutter test` 的 cwd 就是包根）。
const String _assetPath = 'assets/textures/frost_grain_peaks.png';

String _sha256Hex(Uint8List bytes) {
  final digest = SHA256Digest().process(bytes);
  final buffer = StringBuffer();
  for (final b in digest) {
    buffer.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Uint8List assetBytes;
  late TextureProbe texture;

  setUpAll(() async {
    assetBytes = File(_assetPath).readAsBytesSync();
    texture = decodeTexture(assetBytes);
  });

  group('frostGrainImage 配方', () {
    test('浅 / 深色各复用同一实例，两档互不相同', () {
      final light = frostGrainImage(isDark: false);
      final dark = frostGrainImage(isDark: true);
      expect(identical(frostGrainImage(isDark: false), light), isTrue);
      expect(identical(frostGrainImage(isDark: true), dark), isTrue);
      expect(identical(light, dark), isFalse);
    });

    test('静态平铺配方：repeat + 固定 scale / opacity + low 过滤', () {
      final dark = frostGrainImage(isDark: true);
      expect(dark.repeat, ImageRepeat.repeat);
      expect(dark.scale, kFrostGrainScale);
      expect(dark.opacity, kFrostGrainOpacityDark);
      expect(dark.filterQuality, FilterQuality.low);
      expect(dark.image, isA<AssetImage>());
      expect((dark.image as AssetImage).assetName, kFrostGrainAsset);

      final light = frostGrainImage(isDark: false);
      expect(light.repeat, ImageRepeat.repeat);
      expect(light.scale, kFrostGrainScale);
      expect(light.opacity, kFrostGrainOpacityLight);
      expect(light.filterQuality, FilterQuality.low);
      expect(identical(light.image, dark.image), isTrue);
    });

    test('平铺周期 = 贴图边长 / scale = 256 逻辑 dp（与 DPR 无关）', () {
      expect(texture.width, texture.height);
      expect(texture.width / kFrostGrainScale, 256.0);
      expect(kFrostGrainScale, 2.0);
    });

    testWidgets('资源已注册进 asset bundle（可被 rootBundle 加载）', (tester) async {
      final data = await rootBundle.load(kFrostGrainAsset);
      expect(data.lengthInBytes, assetBytes.length);
      expect(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        assetBytes,
      );
    });
  });

  group('已提交贴图属性', () {
    test('尺寸 512×512、8 位、灰度 + alpha', () {
      expect(texture.width, 512);
      expect(texture.height, 512);
      expect(texture.colorType, 4);
      expect(texture.pixelCount, 512 * 512);
    });

    test('白色峰值：所有像素 RGB 均为 255', () {
      expect(texture.allPixelsHaveRgb(255), isTrue);
    });

    test('稀疏：覆盖比例与亮峰值比例都很低', () {
      final coverage = texture.coverage();
      final bright = texture.brightFraction();
      expect(coverage, greaterThan(0.01));
      expect(coverage, lessThan(0.08), reason: '覆盖比例过高会退回「密布 / 灰尘」观感');
      expect(bright, greaterThan(0.0005));
      expect(bright, lessThan(0.01), reason: '亮峰值过多会像星空 / 雪花');
      expect(texture.maxAlpha(), 255, reason: '最亮峰值应达到满 alpha');
    });

    test('细小闪点而非团块：平均水平游程 2–6 像素、最长游程 <= 16 像素', () {
      // 512 像素 / 256 dp，即 1 dp = 2 像素。旧的低频贴图平均游程 15 像素、
      // 成片 10–20 dp，在屏幕上是灰尘 / 污渍；新的闪点只有约 1–3 dp。
      final mean = texture.meanHorizontalRun();
      expect(mean, greaterThan(2.0), reason: '逐像素噪声游程约为 1');
      expect(mean, lessThan(6.0), reason: '游程过长说明峰值退回成片团块');
      expect(
        texture.maxHorizontalRun(),
        lessThanOrEqualTo(16),
        reason: '任何峰值都不应超过 8 逻辑 dp 宽',
      );
    });

    test('可无缝平铺：接缝两侧的峰值像素同样连续', () {
      final seam = texture.seamOverlap();
      final interior = texture.interiorOverlap();
      expect(interior, greaterThan(0));
      expect(
        seam,
        greaterThan(interior * 0.5),
        reason:
            '环绕连续时接缝重叠率应与内部同量级（seam=$seam interior=$interior）；'
            '两列独立时只有约 0.04',
      );
    });

    test('字节可复现：sha256 与记录值一致', () {
      expect(_sha256Hex(assetBytes), _expectedSha256);
    });
  });

  group('静态（无持续动画）', () {
    testWidgets('渲染磁贴后不持续调度帧，超过 5.2s 周期仍无新帧', (tester) async {
      tester.view.physicalSize = const Size(600, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 240,
                height: 96,
                child: AppTileSurface(child: SizedBox.expand()),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);

      // 静态材质没有 5.2s 反相位呼吸：推进超过一个周期后仍不应有新帧排队。
      await tester.pump(const Duration(seconds: 6));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });
}
