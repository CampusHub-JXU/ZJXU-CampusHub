import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/system_surface/system_settings_launcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('edu.zjxu.jxucampushub/system_settings');

  void mockChannel(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('每个目标都以 target.name 传给原生并映射 target 结果', () async {
    final calls = <MethodCall>[];
    mockChannel((call) async {
      calls.add(call);
      return 'target';
    });

    for (final target in SystemSettingsTarget.values) {
      final result = await SystemSettingsLauncher.instance.open(target);

      expect(result, SystemSettingsOpenResult.target, reason: target.name);
    }

    expect(calls, hasLength(SystemSettingsTarget.values.length));
    for (var i = 0; i < calls.length; i++) {
      expect(calls[i].method, 'open');
      expect(calls[i].arguments, {
        'target': SystemSettingsTarget.values[i].name,
      });
    }
  });

  test('原生返回小写字符串逐值映射到结果枚举', () async {
    const expected = <String, SystemSettingsOpenResult>{
      'target': SystemSettingsOpenResult.target,
      'appDetails': SystemSettingsOpenResult.appDetails,
      'settings': SystemSettingsOpenResult.settings,
      'unavailable': SystemSettingsOpenResult.unavailable,
    };

    for (final entry in expected.entries) {
      mockChannel((call) async => entry.key);

      final result = await SystemSettingsLauncher.instance.open(
        SystemSettingsTarget.notifications,
      );

      expect(result, entry.value, reason: entry.key);
    }
  });

  test('未知原生返回值降级为 unavailable', () async {
    mockChannel((call) async => 'unexpected');

    final result = await SystemSettingsLauncher.instance.open(
      SystemSettingsTarget.exactAlarms,
    );

    expect(result, SystemSettingsOpenResult.unavailable);
  });

  test('null 返回值降级为 unavailable', () async {
    mockChannel((call) async => null);

    final result = await SystemSettingsLauncher.instance.open(
      SystemSettingsTarget.batteryOptimization,
    );

    expect(result, SystemSettingsOpenResult.unavailable);
  });

  test('通道缺失（MissingPluginException）返回 unavailable', () async {
    final result = await SystemSettingsLauncher.instance.open(
      SystemSettingsTarget.autostart,
    );

    expect(result, SystemSettingsOpenResult.unavailable);
  });

  test('PlatformException 返回 unavailable 且不抛出', () async {
    mockChannel((call) async {
      throw PlatformException(code: 'open_failed', message: 'no activity');
    });

    final result = await SystemSettingsLauncher.instance.open(
      SystemSettingsTarget.appDetails,
    );

    expect(result, SystemSettingsOpenResult.unavailable);
  });

  test('通知渠道目标把 channelId 透传给原生', () async {
    final calls = <MethodCall>[];
    mockChannel((call) async {
      calls.add(call);
      return 'target';
    });

    final result = await SystemSettingsLauncher.instance.open(
      SystemSettingsTarget.notificationChannel,
      channelId: 'second_classroom_activity_reminder',
    );

    expect(result, SystemSettingsOpenResult.target);
    expect(calls.single.method, 'open');
    expect(calls.single.arguments, <String, Object?>{
      'target': 'notificationChannel',
      'channelId': 'second_classroom_activity_reminder',
    });
  });

  test('channelId 缺失 / 空白时不带 channelId 参数', () async {
    final calls = <MethodCall>[];
    mockChannel((call) async {
      calls.add(call);
      return 'appDetails';
    });

    await SystemSettingsLauncher.instance.open(
      SystemSettingsTarget.notificationChannel,
    );
    await SystemSettingsLauncher.instance.open(
      SystemSettingsTarget.notificationChannel,
      channelId: '   ',
    );

    expect(calls, hasLength(2));
    for (final call in calls) {
      expect(call.arguments, <String, Object?>{
        'target': 'notificationChannel',
      });
    }
  });

  group('getStatus', () {
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    test('解析各项状态，类型不符的项按不可查询', () async {
      mockChannel((call) async {
        expect(call.method, 'getStatus');
        return <String, Object?>{
          'notificationsEnabled': true,
          'exactAlarmsAllowed': null,
          'ignoringBatteryOptimizations': 'yes',
          'isXiaomiFamily': true,
        };
      });
      final status = await SystemSettingsLauncher.instance.getStatus();
      expect(status.available, isTrue);
      expect(status.notificationsEnabled, isTrue);
      expect(status.exactAlarmsAllowed, isNull);
      expect(status.ignoringBatteryOptimizations, isNull);
      expect(status.isXiaomiFamily, isTrue);
    });

    test('原生异常时整体未知，不抛出', () async {
      mockChannel((_) async => throw PlatformException(code: 'boom'));
      final status = await SystemSettingsLauncher.instance.getStatus();
      expect(status.available, isFalse);
      expect(status.isXiaomiFamily, isFalse);
    });
  });
}
