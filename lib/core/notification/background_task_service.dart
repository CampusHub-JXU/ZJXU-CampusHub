import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:workmanager/workmanager.dart';

import '../logging/app_logger.dart';

const _dormElectricityCheckTask = 'dormElectricityCheck';
const _scheduledNotificationId = 200;
const _immediateNotificationId = 100;
const _channelId = 'dorm_electricity_alert';
const _channelName = '寝室电费提醒';

// SharedPreferences keys
const _keyCommunityId = 'dorm_community_id';
const _keyBuildingId = 'dorm_building_id';
const _keyFloorId = 'dorm_floor_id';
const _keyRoomId = 'dorm_room_id';
const _keyAlertEnabled = 'dorm_alert_enabled';
const _keyAlertThreshold = 'dorm_alert_threshold';
const _keyLastNotifiedDate = 'dorm_alert_last_notified_date';
const _keyCachedElectricity = 'dorm_cached_electricity';

// ── WorkManager callback (secondary fallback) ──────────────────────────

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == _dormElectricityCheckTask) {
      return await _executeBackgroundElectricityCheck();
    }
    return true;
  });
}

String _todayString() {
  final now = DateTime.now();
  return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}

String _formatElectricity(double value) {
  if (value == value.truncateToDouble()) return value.toInt().toString();
  return value.toStringAsFixed(2);
}

void _logBackgroundTask(
  LogLevel level,
  String message, {
  Object? error,
  StackTrace? stackTrace,
}) {
  AppLogger.instance.log(
    level,
    LogCategory.general,
    message,
    error: error,
    stackTrace: stackTrace,
  );
}

/// Fetch electricity value from the dorm API. Returns null on failure.
Future<double?> _fetchElectricityValue() async {
  final prefs = await SharedPreferences.getInstance();
  final communityId = prefs.getString(_keyCommunityId);
  final buildingId = prefs.getString(_keyBuildingId);
  final floorId = prefs.getString(_keyFloorId);
  final roomId = prefs.getString(_keyRoomId);
  if (communityId == null ||
      buildingId == null ||
      floorId == null ||
      roomId == null) {
    return null;
  }

  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      responseType: ResponseType.bytes,
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
        'X-Requested-With': 'XMLHttpRequest',
      },
    ),
  );

  try {
    final url =
        'http://jdhq.wap.zjxu.edu.cn/DormCharge/BaseElect/queryResult'
        '/ele_id/1'
        '/community_id/$communityId'
        '/building_id/$buildingId'
        '/floor_id/$floorId'
        '/room_id/$roomId';

    final resp = await dio.get<List<int>>(url);
    if (resp.data == null) return null;

    final html = utf8.decode(resp.data!, allowMalformed: true);
    final text = html_parser.parse(html).body?.text ?? '';

    final match = RegExp(
      r'实际剩余电量\s*[（(]度[)）]\s*(?:[:：]\s*)?([0-9]+(?:\.[0-9]+)?)',
      dotAll: true,
    ).firstMatch(text);

    if (match == null) return null;

    final value = double.tryParse(match.group(1)!);
    if (value != null) {
      // Cache the value so scheduled notifications can show it.
      await prefs.setDouble(_keyCachedElectricity, value);
    }
    return value;
  } finally {
    dio.close(force: true);
  }
}

/// Self-contained background check — no app singletons (WorkManager fallback).
Future<bool> _executeBackgroundElectricityCheck() async {
  try {
    final prefs = await SharedPreferences.getInstance();

    final alertEnabled = prefs.getBool(_keyAlertEnabled) ?? false;
    if (!alertEnabled) return true;

    final threshold = prefs.getDouble(_keyAlertThreshold) ?? 20.0;
    final lastNotified = prefs.getString(_keyLastNotifiedDate);
    final today = _todayString();
    if (lastNotified == today) return true;

    final value = await _fetchElectricityValue();
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
  } catch (error, stackTrace) {
    _logBackgroundTask(
      LogLevel.warn,
      '后台电费检查失败',
      error: error,
      stackTrace: stackTrace,
    );
    return false;
  }
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

    final threshold = prefs.getDouble(_keyAlertThreshold) ?? 20.0;
    final cachedValue = prefs.getDouble(_keyCachedElectricity);

    String body;
    if (cachedValue != null && cachedValue < threshold) {
      body =
          '剩余电量 ${_formatElectricity(cachedValue)} 度，低于 ${threshold.toInt()} 度阈值，请及时充值';
    } else {
      body = '每日电量检查 — 打开 App 查看最新电量';
    }

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

    _logBackgroundTask(LogLevel.info, '已安排每日电费提醒: $scheduled');
  } catch (error, stackTrace) {
    _logBackgroundTask(
      LogLevel.warn,
      '安排每日电费提醒失败',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

// ── Public service ─────────────────────────────────────────────────────

class BackgroundTaskService {
  BackgroundTaskService._();
  static final instance = BackgroundTaskService._();

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    tz_data.initializeTimeZones();

    // Primary: schedule daily alarm-clock notification.
    await _scheduleDailyAlarmNotification();

    // Secondary: WorkManager periodic task as fallback.
    await Workmanager().initialize(callbackDispatcher);
    await _registerWorkManagerTask();

    _initialized = true;
  }

  Future<void> _registerWorkManagerTask() async {
    await Workmanager().registerPeriodicTask(
      _dormElectricityCheckTask,
      _dormElectricityCheckTask,
      frequency: const Duration(hours: 8),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }

  /// Called when user toggles alert settings.
  Future<void> reRegisterIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_keyAlertEnabled) ?? false;
    if (enabled) {
      await _scheduleDailyAlarmNotification();
      await _registerWorkManagerTask();
    } else {
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.cancel(_scheduledNotificationId);
      await Workmanager().cancelByUniqueName(_dormElectricityCheckTask);
    }
  }

  /// Foreground check — called on app resume. Checks electricity and shows
  /// notification immediately if below threshold, then reschedules the
  /// daily alarm with fresh data.
  Future<void> foregroundCheckAndNotify() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final alertEnabled = prefs.getBool(_keyAlertEnabled) ?? false;
      if (!alertEnabled) return;

      final threshold = prefs.getDouble(_keyAlertThreshold) ?? 20.0;
      final lastNotified = prefs.getString(_keyLastNotifiedDate);
      final today = _todayString();

      final value = await _fetchElectricityValue();
      if (value == null) return;

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

      // Reschedule daily alarm with fresh cached value.
      await _scheduleDailyAlarmNotification();
    } catch (error, stackTrace) {
      _logBackgroundTask(
        LogLevel.warn,
        '前台电费检查失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
