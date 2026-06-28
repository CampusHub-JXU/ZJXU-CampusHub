import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_logger.dart';
import '../notification/app_notification_service.dart';

/// Top-level handler for FCM background messages.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
  } catch (_) {
    return;
  }
}

/// Push service using Firebase Cloud Messaging.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  static const _keyFcmToken = 'push_fcm_token';

  bool _initialized = false;
  String? _fcmToken;

  String? get fcmToken => _fcmToken;

  Map<String, String> get tokens {
    final result = <String, String>{};
    if (_fcmToken != null) result['fcm'] = _fcmToken!;
    return result;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    await _restoreCachedToken();
    await _initFCM();
  }

  Future<void> _initFCM() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }

      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      final messaging = FirebaseMessaging.instance;

      await messaging.requestPermission(alert: true, badge: true, sound: true);

      final token = await messaging.getToken().timeout(
        const Duration(seconds: 10),
      );
      if (token != null) {
        _fcmToken = token;
        await _cacheFcmToken(token);
        AppLogger.instance.ui(LogLevel.info, 'FCM token 获取成功');
      }

      messaging.onTokenRefresh.listen((newToken) {
        _fcmToken = newToken;
        _cacheFcmToken(newToken);
        AppLogger.instance.ui(LogLevel.info, 'FCM token 已刷新');
      });

      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
      FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpened);

      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        _handleMessageOpened(initialMessage);
      }
    } on TimeoutException catch (_) {
      AppLogger.instance.ui(LogLevel.warn, 'FCM 初始化超时，已跳过推送通道');
    } on FirebaseException catch (e) {
      AppLogger.instance.ui(
        LogLevel.warn,
        'Firebase 初始化失败（可能是缺少 google-services.json）: ${e.message}',
      );
    } catch (e) {
      AppLogger.instance.ui(LogLevel.warn, 'FCM 初始化失败，已跳过推送通道: $e');
    }
  }

  void _handleForegroundMessage(RemoteMessage message) {
    AppLogger.instance.ui(
      LogLevel.info,
      'FCM 前台消息: ${message.notification?.title}',
    );
    AppNotificationService.instance.showNotification(
      id: DateTime.now().millisecondsSinceEpoch % 100000,
      title: message.notification?.title ?? '通知',
      body: message.notification?.body ?? '',
      payload: jsonEncode(message.data),
    );
  }

  void _handleMessageOpened(RemoteMessage message) {
    AppLogger.instance.ui(
      LogLevel.info,
      'FCM 消息点击: ${message.notification?.title}',
    );
    // TODO: route based on message.data['type'] when backend is ready
  }

  Future<void> _restoreCachedToken() async {
    final prefs = await SharedPreferences.getInstance();
    _fcmToken = prefs.getString(_keyFcmToken);
  }

  Future<void> _cacheFcmToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyFcmToken, token);
  }

  /// Convenience method for future backend upload.
  Future<void> uploadTokenToBackend({
    required String baseUrl,
    required String authToken,
  }) async {
    // TODO: implement when backend is ready
  }

  @visibleForTesting
  void debugReset() {
    _initialized = false;
    _fcmToken = null;
  }
}
