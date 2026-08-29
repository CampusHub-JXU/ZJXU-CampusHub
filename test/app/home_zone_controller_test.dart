import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/home/home_zone_controller.dart';

void main() {
  tearDown(() {
    // 控制器为单例：复位分区并清空注入的滚动实现，避免跨用例串扰。
    HomeZoneController.instance
      ..scrollToTop = null
      ..scrollToFunction = null
      ..updateZone(0);
  });

  group('HomeZoneController', () {
    test('updateZone 仅在实际变化时通知，重复值去重', () {
      final controller = HomeZoneController.instance;
      var notifyCount = 0;
      void listener() => notifyCount++;
      controller.addListener(listener);
      addTearDown(() => controller.removeListener(listener));

      controller.updateZone(1);
      expect(controller.zoneIndex, 1);
      expect(notifyCount, 1);

      controller.updateZone(1);
      expect(notifyCount, 1, reason: '重复设置同一分区不应触发通知');

      controller.updateZone(0);
      expect(controller.zoneIndex, 0);
      expect(notifyCount, 2);
    });

    test('requestHome/requestFunction 调用注入的滚动实现', () async {
      final controller = HomeZoneController.instance;
      var homeCalls = 0;
      var functionCalls = 0;
      controller.scrollToTop = () async => homeCalls++;
      controller.scrollToFunction = () async => functionCalls++;

      await controller.requestHome();
      await controller.requestFunction();

      expect(homeCalls, 1);
      expect(functionCalls, 1);
    });

    test('未注入滚动实现时 requestHome/requestFunction 安全 no-op', () async {
      final controller = HomeZoneController.instance;
      controller
        ..scrollToTop = null
        ..scrollToFunction = null;

      // 不抛异常即通过。
      await controller.requestHome();
      await controller.requestFunction();

      expect(controller.zoneIndex, 0);
    });
  });
}
