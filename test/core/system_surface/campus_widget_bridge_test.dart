import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/system_surface/campus_widget_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('edu.zjxu.jxucampushub/widget');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('pushSnapshot 把投影包装为 {snapshot: ...} 推送', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });

    await CampusWidgetBridge.instance.pushSnapshot({'a': 1});

    expect(calls.single.method, 'pushSnapshot');
    expect(calls.single.arguments, {
      'snapshot': {'a': 1},
    });
  });

  test('requestPin / isSupported 返回原生结果，null 视为 false', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'requestPin' => true,
        'isSupported' => null,
        _ => null,
      };
    });

    expect(await CampusWidgetBridge.instance.requestPin(), isTrue);
    expect(await CampusWidgetBridge.instance.isSupported(), isFalse);
  });

  test('通道缺失时静默降级', () async {
    await CampusWidgetBridge.instance.pushSnapshot({'a': 1});
    expect(await CampusWidgetBridge.instance.requestPin(), isFalse);
    expect(await CampusWidgetBridge.instance.isSupported(), isFalse);
  });

  test('PlatformException 降级且不抛出', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'invalid_args', message: 'bad');
    });

    await CampusWidgetBridge.instance.pushSnapshot({'a': 1});
    expect(await CampusWidgetBridge.instance.requestPin(), isFalse);
    expect(await CampusWidgetBridge.instance.isSupported(), isFalse);
  });
}
