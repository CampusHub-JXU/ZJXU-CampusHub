import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class AppNotificationService {
  AppNotificationService._();
  static final AppNotificationService instance = AppNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const _channelId = 'dorm_electricity_alert';
  static const _channelName = '寝室电费提醒';
  static const _channelDescription = '当寝室剩余电量低于设定阈值时发送提醒';
  static const _secondClassroomChannelId = 'second_classroom_activity_reminder';
  static const _secondClassroomChannelName = '第二课堂活动提醒';
  static const _secondClassroomChannelDescription = '订阅活动名后，同名活动开始招募时提醒';
  static const _noticeUpdateChannelId = 'jwc_notice';
  static const _noticeUpdateChannelName = '教务处通知';
  static const _noticeUpdateChannelDescription = '教务处通知公告有新增时提醒';

  bool _initialized = false;
  Future<void>? _initializing;

  /// Tap callback — set by app after router is ready.
  void Function(String payload)? onTap;

  /// Payload queued before onTap was set (cold-start from notification).
  String? _pendingPayload;
  String? get pendingPayload => _pendingPayload;
  void clearPendingPayload() => _pendingPayload = null;

  Future<void> initialize({bool requestNotificationPermission = true}) async {
    if (!_initialized) {
      final initializing = _initializing;
      if (initializing != null) {
        await initializing;
      } else {
        final future = _initializeOnce();
        _initializing = future;
        await future.whenComplete(() => _initializing = null);
      }
    }

    if (requestNotificationPermission) {
      await requestPermission();
    }
  }

  Future<void> _initializeOnce() async {
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

    await _createAndroidChannels();

    _initialized = true;
  }

  Future<bool> requestPermission() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return false;
    return await android.requestNotificationsPermission() ?? false;
  }

  /// 系统通知权限是否开启（播报前置条件；被拒时同步仍更新数据与未读，
  /// 只跳过弹窗，恢复后由待播报队列补发）。
  Future<bool> areNotificationsEnabled() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return false;
    return await android.areNotificationsEnabled() ?? false;
  }

  /// 教务处通知聚合提醒。同一 [id] 覆盖旧聚合，不在通知栏堆积。
  Future<void> showNoticeUpdateNotification({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    if (!_initialized) {
      await initialize(requestNotificationPermission: false);
    }

    await _plugin.show(
      id,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _noticeUpdateChannelId,
          _noticeUpdateChannelName,
          channelDescription: _noticeUpdateChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
      ),
      payload: payload,
    );
  }

  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_initialized) {
      await initialize(requestNotificationPermission: false);
    }

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

  Future<void> showSecondClassroomRecruitingNotification({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    if (!_initialized) {
      await initialize(requestNotificationPermission: false);
    }

    await _plugin.show(
      id,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _secondClassroomChannelId,
          _secondClassroomChannelName,
          channelDescription: _secondClassroomChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
      ),
      payload: payload,
    );
  }

  Future<void> _createAndroidChannels() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return;

    await android.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDescription,
        importance: Importance.high,
      ),
    );
    await android.createNotificationChannel(
      const AndroidNotificationChannel(
        _secondClassroomChannelId,
        _secondClassroomChannelName,
        description: _secondClassroomChannelDescription,
        importance: Importance.high,
      ),
    );
    await android.createNotificationChannel(
      const AndroidNotificationChannel(
        _noticeUpdateChannelId,
        _noticeUpdateChannelName,
        description: _noticeUpdateChannelDescription,
        importance: Importance.high,
      ),
    );
  }
}
