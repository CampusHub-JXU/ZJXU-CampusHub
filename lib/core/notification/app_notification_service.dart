import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class AppNotificationService {
  AppNotificationService._();
  static final AppNotificationService instance = AppNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const _channelId = 'dorm_electricity_alert';
  static const _channelName = '寝室电费提醒';
  static const _channelDescription = '当寝室剩余电量低于设定阈值时发送提醒';

  bool _initialized = false;

  /// Tap callback — set by app after router is ready.
  void Function(String payload)? onTap;

  /// Payload queued before onTap was set (cold-start from notification).
  String? _pendingPayload;
  String? get pendingPayload => _pendingPayload;
  void clearPendingPayload() => _pendingPayload = null;

  Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload == null || payload.isEmpty) return;
        if (onTap != null) {
          onTap!(payload);
        } else {
          _pendingPayload = payload;
        }
      },
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: _channelDescription,
            importance: Importance.high,
          ),
        );

    _initialized = true;

    // Request Android 13+ notification permission.
    await requestPermission();
  }

  Future<bool> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin
    >();
    if (android == null) return false;
    return await android.requestNotificationsPermission() ?? false;
  }

  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_initialized) await initialize();

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      ),
    );

    await _plugin.show(id, title, body, details, payload: payload);
  }
}
