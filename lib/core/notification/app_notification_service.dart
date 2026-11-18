import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

enum AppNotificationPriority { high, normal, low }

enum AppNotificationChannel {
  auth,
  secondClassroom,
  dormElectricity,
  notice,
  low,
}

class AppNotificationService {
  AppNotificationService._();
  static final AppNotificationService instance = AppNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const dormElectricityChannelId = 'dorm_electricity_alert_v2';
  static const _channelName = '寝室电费提醒';
  static const _channelDescription = '当寝室剩余电量低于设定阈值时发送提醒';

  /// 「第二课堂活动提醒」通知渠道 ID。
  ///
  /// 系统设置按渠道跳转（`SystemSettingsTarget.notificationChannel`）需要它；
  /// **一旦创建不可随意更改**，否则已安装用户的渠道设置会重置。
  static const secondClassroomChannelId = 'second_classroom_activity_reminder';
  static const _secondClassroomChannelName = '第二课堂活动提醒';
  static const _secondClassroomChannelDescription = '订阅活动名后，同名活动开始招募时提醒';
  @Deprecated('已由 noticeUpdateChannelId 取代；旧渠道不可降级')
  static const legacyNoticeUpdateChannelId = 'jwc_notice';
  static const noticeUpdateChannelId = 'jwc_notice_v2';
  static const _noticeUpdateChannelName = '教务处通知';
  static const _noticeUpdateChannelDescription = '教务处通知公告有新增时提醒';
  static const authChannelId = 'auth_alert';
  static const lowChannelId = 'jxu_low';

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
    // 只保护初始化期间的启动详情重放：callback 已交付的点击不再补发。
    // 不按 payload 永久去重，同一通知后续的真实点击仍逐次交付。
    final deliveredResponses =
        <(int?, String?, String?, NotificationResponseType, String?)>{};
    var capturingLaunch = true;
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        if (capturingLaunch) deliveredResponses.add(_responseKey(response));
        _dispatchPayload(response.payload);
      },
    );

    await _createAndroidChannels();
    // 冷启动：App 被通知点击拉起时 flutter_local_notifications 不会触发
    // onDidReceiveNotificationResponse，payload 只能从 launch details 取回；
    // 不补这一步 `second-classroom?id=` 等点击直达会丢失。
    try {
      final response = await _readLaunchResponse();
      if (response != null &&
          !deliveredResponses.contains(_responseKey(response))) {
        _dispatchPayload(response.payload);
      }
    } finally {
      capturingLaunch = false;
      deliveredResponses.clear();
    }

    _initialized = true;
  }

  Future<NotificationResponse?> _readLaunchResponse() async {
    final NotificationAppLaunchDetails? details;
    try {
      details = await _plugin.getNotificationAppLaunchDetails();
    } catch (_) {
      return null;
    }
    if (details == null || !details.didNotificationLaunchApp) return null;
    return details.notificationResponse;
  }

  static (int?, String?, String?, NotificationResponseType, String?)
  _responseKey(NotificationResponse response) => (
    response.id,
    response.actionId,
    response.input,
    response.notificationResponseType,
    response.payload,
  );

  @visibleForTesting
  void debugReset() {
    _initialized = false;
    _initializing = null;
    onTap = null;
    clearPendingPayload();
  }

  void _dispatchPayload(String? payload) {
    if (payload == null || payload.isEmpty) return;
    if (onTap != null) {
      onTap!(payload);
    } else {
      _pendingPayload = payload;
    }
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
  Future<bool> areNotificationsEnabled() async =>
      await notificationPermissionStatus() == true;

  /// 仅 false 表示明确未授权；平台不支持 / 无返回值时为 null（未知）。
  Future<bool?> notificationPermissionStatus() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return null;
    return await android.areNotificationsEnabled();
  }

  /// 教务处通知聚合提醒。同一 [id] 覆盖旧聚合，不在通知栏堆积。
  Future<void> showNoticeUpdateNotification({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) => showAppNotification(
    id: id,
    title: title,
    body: body,
    payload: payload,
    priority: AppNotificationPriority.normal,
    channel: AppNotificationChannel.notice,
  );

  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) => showAppNotification(
    id: id,
    title: title,
    body: body,
    payload: payload,
    priority: AppNotificationPriority.normal,
    channel: AppNotificationChannel.dormElectricity,
  );

  Future<void> showSecondClassroomRecruitingNotification({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) => showAppNotification(
    id: id,
    title: title,
    body: body,
    payload: payload,
    priority: AppNotificationPriority.high,
    channel: AppNotificationChannel.secondClassroom,
  );

  /// 业务渠道独立保留；priority 与指定渠道的重要性必须一致。
  Future<void> showAppNotification({
    required int id,
    required String title,
    required String body,
    required AppNotificationPriority priority,
    String? payload,
    AppNotificationChannel? channel,
  }) async {
    if (!_initialized) {
      await initialize(requestNotificationPermission: false);
    }
    final selected =
        channel ??
        switch (priority) {
          AppNotificationPriority.high => AppNotificationChannel.auth,
          AppNotificationPriority.normal => AppNotificationChannel.notice,
          AppNotificationPriority.low => AppNotificationChannel.low,
        };
    final (
      channelId,
      name,
      description,
      importance,
      androidPriority,
      expectedPriority,
    ) = switch (selected) {
      AppNotificationChannel.auth => (
        authChannelId,
        '登录状态提醒',
        '登录失效时提醒',
        Importance.high,
        Priority.high,
        AppNotificationPriority.high,
      ),
      AppNotificationChannel.secondClassroom => (
        secondClassroomChannelId,
        _secondClassroomChannelName,
        _secondClassroomChannelDescription,
        Importance.high,
        Priority.high,
        AppNotificationPriority.high,
      ),
      AppNotificationChannel.dormElectricity => (
        dormElectricityChannelId,
        _channelName,
        _channelDescription,
        Importance.defaultImportance,
        Priority.defaultPriority,
        AppNotificationPriority.normal,
      ),
      AppNotificationChannel.notice => (
        noticeUpdateChannelId,
        _noticeUpdateChannelName,
        _noticeUpdateChannelDescription,
        Importance.defaultImportance,
        Priority.defaultPriority,
        AppNotificationPriority.normal,
      ),
      AppNotificationChannel.low => (
        lowChannelId,
        '后台提示',
        '后台任务提示',
        Importance.low,
        Priority.low,
        AppNotificationPriority.low,
      ),
    };
    if (priority != expectedPriority) {
      throw ArgumentError('通知优先级与业务渠道不匹配');
    }
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          name,
          channelDescription: description,
          importance: importance,
          priority: androidPriority,
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
        dormElectricityChannelId,
        _channelName,
        description: _channelDescription,
        importance: Importance.defaultImportance,
      ),
    );
    await android.createNotificationChannel(
      const AndroidNotificationChannel(
        secondClassroomChannelId,
        _secondClassroomChannelName,
        description: _secondClassroomChannelDescription,
        importance: Importance.high,
      ),
    );
    await android.createNotificationChannel(
      const AndroidNotificationChannel(
        noticeUpdateChannelId,
        _noticeUpdateChannelName,
        description: _noticeUpdateChannelDescription,
        importance: Importance.defaultImportance,
      ),
    );
    await android.createNotificationChannel(
      const AndroidNotificationChannel(
        authChannelId,
        '登录状态提醒',
        description: '登录失效时提醒',
        importance: Importance.high,
      ),
    );
    await android.createNotificationChannel(
      const AndroidNotificationChannel(
        lowChannelId,
        '后台提示',
        description: '后台任务提示',
        importance: Importance.low,
      ),
    );
  }
}
