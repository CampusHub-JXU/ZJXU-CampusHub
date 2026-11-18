import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/system_surface/system_settings_launcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    SystemSettingsLauncher.instance.setGatewayForTesting(null);
  });

  test('每个目标都以枚举透传给 gateway 并原样返回结果', () async {
    final gateway = _FakeSystemSettingsGateway()
      ..openResult = SystemSettingsOpenResult.target;
    SystemSettingsLauncher.instance.setGatewayForTesting(gateway);

    for (final target in SystemSettingsTarget.values) {
      final result = await SystemSettingsLauncher.instance.open(target);

      expect(result, SystemSettingsOpenResult.target, reason: target.name);
    }

    expect(gateway.opens, hasLength(SystemSettingsTarget.values.length));
    for (var i = 0; i < gateway.opens.length; i++) {
      expect(gateway.opens[i].target, SystemSettingsTarget.values[i]);
      expect(gateway.opens[i].channelId, isNull);
    }
  });

  test('gateway 的降级结果原样透传', () async {
    final gateway = _FakeSystemSettingsGateway();
    SystemSettingsLauncher.instance.setGatewayForTesting(gateway);

    for (final expected in SystemSettingsOpenResult.values) {
      gateway.openResult = expected;

      final result = await SystemSettingsLauncher.instance.open(
        SystemSettingsTarget.notifications,
      );

      expect(result, expected, reason: expected.name);
    }
  });

  group('parseOpenResult', () {
    test('原生小写字符串逐值映射到结果枚举', () {
      const expected = <String, SystemSettingsOpenResult>{
        'target': SystemSettingsOpenResult.target,
        'appDetails': SystemSettingsOpenResult.appDetails,
        'settings': SystemSettingsOpenResult.settings,
        'unavailable': SystemSettingsOpenResult.unavailable,
      };

      for (final entry in expected.entries) {
        expect(
          SystemSettingsLauncher.parseOpenResult(entry.key),
          entry.value,
          reason: entry.key,
        );
      }
    });

    test('未知字符串与 null 都降级为 unavailable', () {
      expect(
        SystemSettingsLauncher.parseOpenResult('unexpected'),
        SystemSettingsOpenResult.unavailable,
      );
      expect(
        SystemSettingsLauncher.parseOpenResult(null),
        SystemSettingsOpenResult.unavailable,
      );
      expect(
        SystemSettingsLauncher.parseOpenResult(''),
        SystemSettingsOpenResult.unavailable,
      );
    });
  });

  test('默认未注入 gateway 时（非 Android）open 返回 unavailable', () async {
    final result = await SystemSettingsLauncher.instance.open(
      SystemSettingsTarget.autostart,
    );

    expect(result, SystemSettingsOpenResult.unavailable);
  });

  test('通知渠道目标把 trim 后的 channelId 透传给 gateway', () async {
    final gateway = _FakeSystemSettingsGateway()
      ..openResult = SystemSettingsOpenResult.target;
    SystemSettingsLauncher.instance.setGatewayForTesting(gateway);

    final result = await SystemSettingsLauncher.instance.open(
      SystemSettingsTarget.notificationChannel,
      channelId: 'second_classroom_activity_reminder',
    );

    expect(result, SystemSettingsOpenResult.target);
    expect(
      gateway.opens.single.target,
      SystemSettingsTarget.notificationChannel,
    );
    expect(
      gateway.opens.single.channelId,
      'second_classroom_activity_reminder',
    );
  });

  test('channelId 缺失 / 空白时归一化为 null', () async {
    final gateway = _FakeSystemSettingsGateway()
      ..openResult = SystemSettingsOpenResult.appDetails;
    SystemSettingsLauncher.instance.setGatewayForTesting(gateway);

    await SystemSettingsLauncher.instance.open(
      SystemSettingsTarget.notificationChannel,
    );
    await SystemSettingsLauncher.instance.open(
      SystemSettingsTarget.notificationChannel,
      channelId: '   ',
    );
    await SystemSettingsLauncher.instance.open(
      SystemSettingsTarget.notificationChannel,
      channelId: '',
    );

    expect(gateway.opens, hasLength(3));
    for (final open in gateway.opens) {
      expect(open.target, SystemSettingsTarget.notificationChannel);
      expect(open.channelId, isNull);
    }
  });

  group('getStatus', () {
    test('委派给 gateway 并原样返回状态', () async {
      final gateway = _FakeSystemSettingsGateway()
        ..status = const SystemBackgroundStatus(
          notificationsEnabled: true,
          ignoringBatteryOptimizations: false,
          isXiaomiFamily: true,
        );
      SystemSettingsLauncher.instance.setGatewayForTesting(gateway);

      final status = await SystemSettingsLauncher.instance.getStatus();
      expect(gateway.getStatusCalls, 1);
      expect(status.available, isTrue);
      expect(status.notificationsEnabled, isTrue);
      expect(status.exactAlarmsAllowed, isNull);
      expect(status.ignoringBatteryOptimizations, isFalse);
      expect(status.isXiaomiFamily, isTrue);
    });

    test('默认未注入 gateway 时（非 Android）返回 unknown', () async {
      final status = await SystemSettingsLauncher.instance.getStatus();
      expect(status.available, isFalse);
      expect(status.isXiaomiFamily, isFalse);
    });
  });
}

/// 记录式 SystemSettingsGateway 替身。
class _FakeSystemSettingsGateway implements SystemSettingsGateway {
  final opens = <({SystemSettingsTarget target, String? channelId})>[];
  int getStatusCalls = 0;

  SystemSettingsOpenResult openResult = SystemSettingsOpenResult.target;
  SystemBackgroundStatus status = const SystemBackgroundStatus();

  @override
  Future<SystemSettingsOpenResult> open(
    SystemSettingsTarget target, {
    String? channelId,
  }) async {
    opens.add((target: target, channelId: channelId));
    return openResult;
  }

  @override
  Future<SystemBackgroundStatus> getStatus() async {
    getStatusCalls++;
    return status;
  }
}
