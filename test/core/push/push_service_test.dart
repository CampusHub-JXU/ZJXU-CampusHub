import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/push/push_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    PushService.instance.debugReset();
  });

  test('tokens returns empty map when no token cached', () {
    expect(PushService.instance.tokens, isEmpty);
    expect(PushService.instance.fcmToken, isNull);
  });

  test('restores cached FCM token from SharedPreferences', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('push_fcm_token', 'test-fcm-token-123');

    await PushService.instance.initialize();

    expect(PushService.instance.fcmToken, 'test-fcm-token-123');
    expect(PushService.instance.tokens, {'fcm': 'test-fcm-token-123'});
  });

  test('debugReset clears all state', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('push_fcm_token', 'token');

    await PushService.instance.initialize();
    expect(PushService.instance.fcmToken, 'token');

    PushService.instance.debugReset();

    expect(PushService.instance.fcmToken, isNull);
    expect(PushService.instance.tokens, isEmpty);
  });

  test('initialize is idempotent', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('push_fcm_token', 'first');

    await PushService.instance.initialize();
    await PushService.instance.initialize();

    expect(PushService.instance.fcmToken, 'first');
  });
}
