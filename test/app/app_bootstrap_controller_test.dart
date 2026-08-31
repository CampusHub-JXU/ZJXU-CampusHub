import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/app/app_bootstrap_controller.dart';

void main() {
  tearDown(() {
    // 控制器为单例：复位到 idle，避免跨用例串扰。
    AppBootstrapController.instance.debugReset();
  });

  group('AppBootstrapController.navigationReady 派生信号', () {
    test('idle/warming 阶段为 false，localStateReady/completed 为 true', () {
      final controller = AppBootstrapController.instance;

      controller.debugReset();
      expect(controller.navigationReady.value, isFalse);

      controller.debugSetPhase(AppBootstrapPhase.warming);
      expect(controller.navigationReady.value, isFalse);

      controller.debugSetPhase(AppBootstrapPhase.localStateReady);
      expect(controller.navigationReady.value, isTrue);

      controller.debugSetPhase(AppBootstrapPhase.completed);
      expect(controller.navigationReady.value, isTrue);
    });

    test('回退到 warming 时信号同步翻回 false', () {
      final controller = AppBootstrapController.instance;

      controller.debugSetPhase(AppBootstrapPhase.completed);
      expect(controller.navigationReady.value, isTrue);

      controller.debugSetPhase(AppBootstrapPhase.warming);
      expect(controller.navigationReady.value, isFalse);
    });

    test('navigationReady 与 phase 变更同批通知监听者', () {
      final controller = AppBootstrapController.instance;
      final observed = <bool>[];
      void listener() => observed.add(controller.navigationReady.value);
      controller.navigationReady.addListener(listener);
      addTearDown(() => controller.navigationReady.removeListener(listener));

      controller.debugSetPhase(AppBootstrapPhase.localStateReady);
      expect(observed, [true]);
    });
  });
}
