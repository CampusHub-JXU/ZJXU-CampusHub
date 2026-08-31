// 寝室电费后台任务逻辑。
//
// 自 core/notification/background_task_service.dart 下沉（架构反转）：
// core 只保留通用 WorkManager 调度能力，电费检查与通知业务由本文件承载，
// 统一通过 BackgroundTaskService 的通用 API 注册/取消任务。

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../core/logging/app_logger.dart';
import '../../core/notification/background_task_service.dart';
import 'dorm_electricity_service.dart';

const dormElectricityCheck = 'dormElectricityCheck';
const _scheduledNotificationId = 200;
const _immediateNotificationId = 100;
const _channelId = 'dorm_electricity_alert';
const _channelName = '寝室电费提醒';

// SharedPreferences keys
const _keyAlertEnabled = 'dorm_alert_enabled';
const _keyAlertThreshold = 'dorm_alert_threshold';
const _keyLastNotifiedDate = 'dorm_alert_last_notified_date';
const _keyCachedElectricity = 'dorm_cached_electricity';
const _keyCachedElectricityUpdatedAt = 'dorm_cached_electricity_updated_at';
const _keyAreaId = 'dorm_epay_area_id';
const _keyBuildingId = 'dorm_epay_building_id';
const _keyFloorId = 'dorm_epay_floor_id';
const _keyRoomId = 'dorm_epay_room_id';
const _backgroundCacheMaxAge = Duration(hours: 24);

String _todayString() {
  final now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}

String _formatElectricity(double value) {
  if (value == value.truncateToDouble()) return value.toInt().toString();
  return value.toStringAsFixed(2);
}

double? _readFreshConfiguredElectricity(SharedPreferences prefs) {
  if (prefs.getString(_keyAreaId) == null ||
      prefs.getString(_keyBuildingId) == null ||
      prefs.getString(_keyFloorId) == null ||
      prefs.getString(_keyRoomId) == null) {
    return null;
  }
  final updatedAtMillis = prefs.getInt(_keyCachedElectricityUpdatedAt);
  if (updatedAtMillis == null) return null;
  final age = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(updatedAtMillis),
  );
  if (age.isNegative || age > _backgroundCacheMaxAge) return null;
  return prefs.getDouble(_keyCachedElectricity);
}

Future<void> _showNotification({
  required int id,
  required double value,
  required double threshold,
}) async {
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );

  await plugin.show(
    id,
    '寝室电费不足',
    '剩余电量 ${_formatElectricity(value)} 度，低于 ${threshold.toInt()} 度阈值，请及时充值',
    const NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: '当寝室剩余电量低于设定阈值时发送提醒',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      ),
    ),
    payload: 'dorm-electricity',
  );
}

/// Schedule a daily alarm-clock notification for 8:00 AM tomorrow.
/// Uses `setAlarmClock` mode — fires reliably even when the app is killed
/// or the device is in Doze mode.
Future<void> _scheduleDailyAlarmNotification() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final alertEnabled = prefs.getBool(_keyAlertEnabled) ?? false;
    if (!alertEnabled) return;

    // 这是系统层重复闹钟，文案会在注册时固化，无法在每天投递前重新校验
    // 房间和缓存时效。因此这里只发通用提醒；带具体电量的低电通知只由
    // 通过配置与 24 小时时效校验的前台/WorkManager 即时检查发送。
    const body = '每日电量检查 — 打开 App 查看最新电量';

    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );

    // Calculate next 8:00 AM.
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(tz.local, now.year, now.month, now.day, 8);
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }

    await plugin.zonedSchedule(
      _scheduledNotificationId,
      '寝室电费提醒',
      body,
      scheduled,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: '当寝室剩余电量低于设定阈值时发送提醒',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.alarmClock,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: 'dorm-electricity',
      matchDateTimeComponents: DateTimeComponents.time,
    );

    AppLogger.instance.storage(LogLevel.debug, '已安排寝室电费每日提醒: $scheduled');
  } catch (e) {
    AppLogger.instance.storage(LogLevel.warn, '安排寝室电费每日提醒失败: $e');
  }
}

/// 寝室电费后台任务：低电量检查（前台/后台 isolate）与每日提醒调度。
class DormElectricityBackground {
  DormElectricityBackground._();
  static final instance = DormElectricityBackground._();

  /// 后台检查入口，由 app 层 dispatcher 在 WorkManager isolate 中调用。
  ///
  /// epay100 查询依赖前台 WebView 会话，WorkManager 后台 isolate 仅使用
  /// 最近一次前台刷新写入的缓存值判断低电量。
  Future<bool> executeBackgroundCheck() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final alertEnabled = prefs.getBool(_keyAlertEnabled) ?? false;
      if (!alertEnabled) return true;

      final threshold = prefs.getDouble(_keyAlertThreshold) ?? 20.0;
      final lastNotified = prefs.getString(_keyLastNotifiedDate);
      final today = _todayString();
      if (lastNotified == today) return true;

      final value = _readFreshConfiguredElectricity(prefs);
      if (value == null) return true;

      if (value < threshold) {
        await _showNotification(
          id: _immediateNotificationId,
          value: value,
          threshold: threshold,
        );
        await prefs.setString(_keyLastNotifiedDate, today);
      } else {
        await prefs.remove(_keyLastNotifiedDate);
      }

      return true;
    } catch (_) {
      return false;
    }
  }

  /// 注册寝室电费后台任务：每日 8:00 闹钟提醒（主）+ WorkManager
  /// 8 小时周期兜底检查（次）。
  Future<void> ensureScheduled() async {
    // Primary: schedule daily alarm-clock notification.
    await _scheduleDailyAlarmNotification();

    // Secondary: WorkManager periodic task as fallback.
    await BackgroundTaskService.instance.registerPeriodicTask(
      uniqueName: dormElectricityCheck,
      frequency: const Duration(hours: 8),
    );
  }

  /// 用户切换电费预警设置后调用：启用则重排，禁用则取消。
  Future<void> reRegisterIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_keyAlertEnabled) ?? false;
    if (enabled) {
      await ensureScheduled();
    } else {
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.cancel(_scheduledNotificationId);
      await BackgroundTaskService.instance.cancelTask(dormElectricityCheck);
    }
  }

  /// Foreground check — called on app resume. Refreshes electricity through
  /// the epay100 WebView-backed service, shows a low-value notification when
  /// needed, then reschedules the daily alarm with the latest cache.
  Future<void> foregroundCheck() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final alertEnabled = prefs.getBool(_keyAlertEnabled) ?? false;
      if (!alertEnabled) return;

      final threshold = prefs.getDouble(_keyAlertThreshold) ?? 20.0;
      final lastNotified = prefs.getString(_keyLastNotifiedDate);
      final today = _todayString();

      final value = await DormElectricityService.instance.fetchElectricity(
        forceRefresh: true,
      );
      if (value == null || DormElectricityService.instance.lastError != null) {
        return;
      }

      if (value < threshold && lastNotified != today) {
        await _showNotification(
          id: _immediateNotificationId,
          value: value,
          threshold: threshold,
        );
        await prefs.setString(_keyLastNotifiedDate, today);
      } else if (value >= threshold) {
        await prefs.remove(_keyLastNotifiedDate);
      }

      // 重排只含通用文案的每日提醒；具体电量不会固化进重复闹钟。
      await _scheduleDailyAlarmNotification();
    } catch (e) {
      AppLogger.instance.storage(LogLevel.warn, '前台电费检查失败: $e');
    }
  }
}
