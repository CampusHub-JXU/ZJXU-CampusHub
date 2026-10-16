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

  test('requestPin 携带 size 参数并映射结果码', () async {
    final calls = <MethodCall>[];
    var reply = 'requested';
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply;
    });

    for (final size in CampusWidgetSize.values) {
      expect(
        await CampusWidgetBridge.instance.requestPin(size),
        CampusWidgetPinResult.requested,
      );
    }
    expect(calls.map((c) => c.method), everyElement('requestPin'));
    expect(calls.map((c) => c.arguments), [
      {'size': 'small'},
      {'size': 'medium'},
      {'size': 'large'},
    ]);

    reply = 'unsupported';
    expect(
      await CampusWidgetBridge.instance.requestPin(CampusWidgetSize.small),
      CampusWidgetPinResult.unsupported,
    );
    reply = 'rejected';
    expect(
      await CampusWidgetBridge.instance.requestPin(CampusWidgetSize.medium),
      CampusWidgetPinResult.rejected,
    );
    reply = 'error';
    expect(
      await CampusWidgetBridge.instance.requestPin(CampusWidgetSize.large),
      CampusWidgetPinResult.error,
    );
  });

  test('requestPin 未知 / 旧版返回值降级为 error，isSupported null 视为 false', () async {
    Object? reply = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return call.method == 'requestPin' ? reply : null;
    });

    // 旧版原生返回 bool：不再被当作成功。
    expect(
      await CampusWidgetBridge.instance.requestPin(CampusWidgetSize.small),
      CampusWidgetPinResult.error,
    );
    reply = null;
    expect(
      await CampusWidgetBridge.instance.requestPin(CampusWidgetSize.small),
      CampusWidgetPinResult.error,
    );
    expect(await CampusWidgetBridge.instance.isSupported(), isFalse);
  });

  test('通道缺失时静默降级', () async {
    await CampusWidgetBridge.instance.pushSnapshot({'a': 1});
    expect(
      await CampusWidgetBridge.instance.requestPin(CampusWidgetSize.large),
      CampusWidgetPinResult.unsupported,
    );
    expect(await CampusWidgetBridge.instance.isSupported(), isFalse);
  });

  test('PlatformException 降级且不抛出', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'invalid_args', message: 'bad');
    });

    await CampusWidgetBridge.instance.pushSnapshot({'a': 1});
    expect(
      await CampusWidgetBridge.instance.requestPin(CampusWidgetSize.medium),
      CampusWidgetPinResult.error,
    );
    expect(await CampusWidgetBridge.instance.isSupported(), isFalse);
  });

  test('requestPin 遇到非平台异常映射为 error 而不抛出', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw StateError('boom');
    });

    expect(
      await CampusWidgetBridge.instance.requestPin(CampusWidgetSize.small),
      CampusWidgetPinResult.error,
    );
  });

  group('CampusWidgetStatus.fromPlatformValue', () {
    test('解析数量与同步时间，非正数 / 非整数按未放置', () {
      final at = DateTime(2026, 10, 16, 9, 55);
      final status = CampusWidgetStatus.fromPlatformValue(<Object?, Object?>{
        'pinSupported': true,
        'installed': <Object?, Object?>{'small': 1, 'medium': 0, 'large': '2'},
        'lastSnapshotAtMs': at.millisecondsSinceEpoch,
      });
      expect(status.pinSupported, isTrue);
      expect(status.installedCount(CampusWidgetSize.small), 1);
      expect(status.installedCount(CampusWidgetSize.medium), 0);
      expect(status.installedCount(CampusWidgetSize.large), 0);
      expect(status.lastSnapshotAt, at);
    });

    test('非 Map / 缺字段降级为未知或空', () {
      expect(
        identical(
          CampusWidgetStatus.fromPlatformValue(null),
          CampusWidgetStatus.unknown,
        ),
        isTrue,
      );
      final empty = CampusWidgetStatus.fromPlatformValue(<Object?, Object?>{
        'lastSnapshotAtMs': 0,
      });
      expect(empty.pinSupported, isFalse);
      expect(empty.installed, isEmpty);
      expect(empty.lastSnapshotAt, isNull);
    });
  });
}
