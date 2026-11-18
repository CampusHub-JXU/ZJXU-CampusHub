import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/notification/app_notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final service = AppNotificationService.instance;
  late List<MethodCall> calls;
  Object? launchDetails;
  Future<void> Function()? onCreateChannel;
  Future<void> Function()? onReadLaunchDetails;

  Map<String, Object?> response({
    String? payload = 'second-classroom?id=2485',
    int id = 500001,
  }) => {
    'notificationId': id,
    'actionId': null,
    'input': null,
    'notificationResponseType': 0,
    'payload': payload,
  };

  Future<void> tap(Map<String, Object?> response) async {
    final completed = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('didReceiveNotificationResponse', response),
      ),
      (_) => completed.complete(),
    );
    await completed.future;
  }

  setUp(() {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    service.debugReset();
    calls = [];
    launchDetails = {
      'notificationLaunchedApp': true,
      'notificationResponse': response(),
    };
    onCreateChannel = null;
    onReadLaunchDetails = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'initialize':
          return true;
        case 'createNotificationChannel':
          await onCreateChannel?.call();
          return null;
        case 'getNotificationAppLaunchDetails':
          await onReadLaunchDetails?.call();
          return launchDetails;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    service.debugReset();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('并发 initialize 只初始化一次、创建五渠道并补发一次', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    onCreateChannel = () async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    };
    final received = <String>[];
    service.onTap = received.add;
    final first = service.initialize(requestNotificationPermission: false);
    await entered.future;
    final second = service.initialize(requestNotificationPermission: false);
    release.complete();
    await Future.wait([first, second]);
    await service.initialize(requestNotificationPermission: false);

    expect(calls.where((c) => c.method == 'initialize'), hasLength(1));
    expect(
      calls.where((c) => c.method == 'createNotificationChannel'),
      hasLength(5),
    );
    expect(
      calls.where((c) => c.method == 'getNotificationAppLaunchDetails'),
      hasLength(1),
    );
    expect(received, ['second-classroom?id=2485']);
  });

  test('initialize 冷启动暂存后消费，重复初始化不会再次暂存', () async {
    await service.initialize(requestNotificationPermission: false);
    expect(service.pendingPayload, 'second-classroom?id=2485');
    final received = <String>[];
    service.onTap = received.add;
    service.onTap!(service.pendingPayload!);
    service.clearPendingPayload();
    await service.initialize(requestNotificationPermission: false);

    expect(received, ['second-classroom?id=2485']);
    expect(service.pendingPayload, isNull);
  });

  for (final consumePending in [false, true]) {
    test('渠道创建期间 callback 与启动详情同一次点击只交付一次，暂存消费=$consumePending', () async {
      final received = <String>[];
      if (!consumePending) service.onTap = received.add;
      var tapped = false;
      onCreateChannel = () async {
        if (tapped) return;
        tapped = true;
        await tap(response());
        if (consumePending) {
          expect(service.pendingPayload, 'second-classroom?id=2485');
          service.onTap = received.add;
          service.onTap!(service.pendingPayload!);
          service.clearPendingPayload();
        }
      };

      await service.initialize(requestNotificationPermission: false);
      expect(received, ['second-classroom?id=2485']);
      expect(service.pendingPayload, isNull);
      // 初始化结束后，同一通知的真实再次点击不能被永久去重。
      await tap(response());
      expect(received, [
        'second-classroom?id=2485',
        'second-classroom?id=2485',
      ]);
    });
  }

  test('读取启动详情期间 callback 与重放同一点击只交付一次', () async {
    final received = <String>[];
    service.onTap = received.add;
    onReadLaunchDetails = () => tap(response());
    await service.initialize(requestNotificationPermission: false);
    expect(received, ['second-classroom?id=2485']);
  });

  test('相同 payload 的不同通知仍分别交付', () async {
    final received = <String>[];
    service.onTap = received.add;
    onReadLaunchDetails = () => tap(response(id: 500002));
    await service.initialize(requestNotificationPermission: false);
    expect(received, ['second-classroom?id=2485', 'second-classroom?id=2485']);
  });

  test('初始化期间多次真实点击同一通知仍分别交付，只跳过详情重放', () async {
    final received = <String>[];
    service.onTap = received.add;
    onReadLaunchDetails = () async {
      await tap(response());
      await tap(response());
    };
    await service.initialize(requestNotificationPermission: false);
    expect(received, ['second-classroom?id=2485', 'second-classroom?id=2485']);
  });

  test('非通知拉起、空 payload 和启动详情通道缺失均不交付', () async {
    for (final details in [
      {'notificationLaunchedApp': false},
      {
        'notificationLaunchedApp': true,
        'notificationResponse': response(payload: ''),
      },
      null,
    ]) {
      service.debugReset();
      launchDetails = details;
      final received = <String>[];
      service.onTap = received.add;
      if (details == null) {
        onReadLaunchDetails = () async => throw MissingPluginException();
      }
      await service.initialize(requestNotificationPermission: false);
      expect(received, isEmpty);
      expect(service.pendingPayload, isNull);
    }
  });

  test('Android 实现缺失时权限未知，播报仍保守跳过', () async {
    IOSFlutterLocalNotificationsPlugin.registerWith();
    expect(await service.notificationPermissionStatus(), isNull);
    expect(await service.areNotificationsEnabled(), isFalse);
  });
}
