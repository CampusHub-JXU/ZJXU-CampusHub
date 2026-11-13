import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/theme/glass_refraction.dart';

import '../../helpers/test_setup.dart';

void main() {
  setUp(() async {
    await resetTestEnvironment();
  });

  tearDown(() {
    LiquidGlass.debugReset();
  });

  group('液态玻璃几何量', () {
    test('折射带 28dp、位移 18dp、色散 ~0.8dp、纵向镜面折叠 ~14dp', () {
      expect(LiquidGlass.band, 28);
      expect(LiquidGlass.displacement, inInclusiveRange(16, 20));
      expect(LiquidGlass.chroma, inInclusiveRange(0.5, 1.2));
      expect(LiquidGlass.mirror, inInclusiveRange(10, 20));
    });

    test('位移小于带宽，透镜剖面才不会把背景折叠成重影', () {
      // 剖面最陡处采样点导数 ≈ 1 - 1.5 * displacement / band，必须保持为正。
      expect(LiquidGlass.displacement, lessThan(LiquidGlass.band / 1.5));
    });
  });

  group('就绪状态', () {
    test('初始未就绪：filterConfig 返回 null，调用方退回纯磨砂', () {
      expect(LiquidGlass.isReady, isFalse);
      expect(LiquidGlass.ready.value, isFalse);
      expect(LiquidGlass.filterConfig(radius: 22, devicePixelRatio: 3), isNull);
    });

    test('ready 是 ValueNotifier：翻转会通知监听者（GlassContainer 靠它重建）', () {
      var notifications = 0;
      void listener() => notifications++;
      LiquidGlass.ready.addListener(listener);
      addTearDown(() => LiquidGlass.ready.removeListener(listener));

      LiquidGlass.ready.value = true;
      expect(notifications, 1);

      // 同值重复赋值不应触发重建。
      LiquidGlass.ready.value = true;
      expect(notifications, 1);

      LiquidGlass.ready.value = false;
      expect(notifications, 2);
    });

    test('preload 失败不抛异常，也不会误报就绪', () async {
      // flutter_test 无 Impeller（或 shader 编译不可用）→ 只能停在退化状态。
      await LiquidGlass.preload();

      expect(LiquidGlass.isReady, isFalse);
      expect(LiquidGlass.ready.value, isFalse);
      expect(LiquidGlass.filterConfig(radius: 22, devicePixelRatio: 3), isNull);
    });

    test('debugReset 清掉强制就绪与就绪通知', () {
      LiquidGlass.debugForceReady = true;
      LiquidGlass.ready.value = true;

      LiquidGlass.debugReset();

      expect(LiquidGlass.debugForceReady, isFalse);
      expect(LiquidGlass.isReady, isFalse);
      expect(LiquidGlass.ready.value, isFalse);
    });
  });
}
