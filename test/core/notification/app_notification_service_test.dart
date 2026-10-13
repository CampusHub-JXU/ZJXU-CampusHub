import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/notification/app_notification_service.dart';

/// 冷启动点击通知的回归：App 被拉起时 flutter_local_notifications **不会**触发
/// `onDidReceiveNotificationResponse`，payload 只能从 `getNotificationAppLaunchDetails`
/// 取回。这里锁住「补发到 onTap / 暂存 pendingPayload」两条路径，避免
/// `second-classroom?id=` 冷启动丢 activityId。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const notificationsChannel = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );

  final service = AppNotificationService.instance;

  setUpAll(() {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
  });

  setUp(() {
    service.onTap = null;
    service.clearPendingPayload();
  });

  tearDown(() {
    service.onTap = null;
    service.clearPendingPayload();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationsChannel, null);
  });

  void mockLaunchDetails(Object? response) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationsChannel, (call) async {
          if (call.method == 'getNotificationAppLaunchDetails') {
            return response;
          }
          return null;
        });
  }

  Map<String, Object?> launchDetails({required String? payload}) {
    return <String, Object?>{
      'notificationLaunchedApp': true,
      'notificationResponse': <String, Object?>{
        'notificationId': 500001,
        'actionId': null,
        'input': null,
        'notificationResponseType': 0,
        'payload': payload,
      },
    };
  }

  test('冷启动 tap 在 onTap 就绪前暂存为 pendingPayload', () async {
    mockLaunchDetails(launchDetails(payload: 'second-classroom?id=2485'));

    await service.captureLaunchPayloadIfAny();

    expect(service.pendingPayload, 'second-classroom?id=2485');
  });

  test('冷启动 tap 在 onTap 已就绪时直接回调，不再暂存', () async {
    mockLaunchDetails(launchDetails(payload: 'second-classroom?id=3001'));
    final received = <String>[];
    service.onTap = received.add;

    await service.captureLaunchPayloadIfAny();

    expect(received, ['second-classroom?id=3001']);
    expect(service.pendingPayload, isNull);
  });

  test('非通知拉起时不产生 payload', () async {
    mockLaunchDetails(<String, Object?>{'notificationLaunchedApp': false});
    final received = <String>[];
    service.onTap = received.add;

    await service.captureLaunchPayloadIfAny();

    expect(received, isEmpty);
    expect(service.pendingPayload, isNull);
  });

  test('payload 为空时不回调也不暂存', () async {
    mockLaunchDetails(launchDetails(payload: ''));

    await service.captureLaunchPayloadIfAny();

    expect(service.pendingPayload, isNull);
  });

  test('通道缺失时静默返回，不抛出', () async {
    // 未注册 mock handler → MissingPluginException。
    await expectLater(service.captureLaunchPayloadIfAny(), completes);
    expect(service.pendingPayload, isNull);
  });
}
