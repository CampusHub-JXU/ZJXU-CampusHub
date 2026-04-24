import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

const _dormElectricityCheckTask = 'dormElectricityCheck';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == _dormElectricityCheckTask) {
      return await _executeDormElectricityCheck();
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

/// Self-contained background check — no app singletons.
Future<bool> _executeDormElectricityCheck() async {
  try {
    final prefs = await SharedPreferences.getInstance();

    // Room config
    final communityId = prefs.getString('dorm_community_id');
    final buildingId = prefs.getString('dorm_building_id');
    final floorId = prefs.getString('dorm_floor_id');
    final roomId = prefs.getString('dorm_room_id');
    if (communityId == null ||
        buildingId == null ||
        floorId == null ||
        roomId == null) {
      return true;
    }

    // Alert settings
    final alertEnabled = prefs.getBool('dorm_alert_enabled') ?? false;
    if (!alertEnabled) return true;

    final threshold = prefs.getDouble('dorm_alert_threshold') ?? 20.0;

    // Already notified today?
    final lastNotified = prefs.getString('dorm_alert_last_notified_date');
    final today = _todayString();
    if (lastNotified == today) return true;

    // Fetch electricity
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
      if (resp.data == null) return true;

      final html = utf8.decode(resp.data!, allowMalformed: true);
      final text = html_parser.parse(html).body?.text ?? '';

      final match = RegExp(
        r'实际剩余电量\s*[（(]度[)）]\s*(?:[:：]\s*)?([0-9]+(?:\.[0-9]+)?)',
        dotAll: true,
      ).firstMatch(text);

      if (match == null) return true;

      final value = double.tryParse(match.group(1)!);
      if (value == null) return true;

      if (value < threshold) {
        await _showBackgroundNotification(value: value, threshold: threshold);
        await prefs.setString('dorm_alert_last_notified_date', today);
      } else {
        // Above threshold — reset so we can alert again when it drops.
        await prefs.remove('dorm_alert_last_notified_date');
      }

      return true;
    } finally {
      dio.close(force: true);
    }
  } catch (e) {
    if (kDebugMode) debugPrint('Background electricity check failed: $e');
    return false;
  }
}

Future<void> _showBackgroundNotification({
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
    100,
    '寝室电费不足',
    '剩余电量 ${_formatElectricity(value)} 度，低于 ${threshold.toInt()} 度阈值，请及时充值',
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'dorm_electricity_alert',
        '寝室电费提醒',
        channelDescription: '当寝室剩余电量低于设定阈值时发送提醒',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      ),
    ),
    payload: 'dorm-electricity',
  );
}

class BackgroundTaskService {
  BackgroundTaskService._();
  static final instance = BackgroundTaskService._();

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    await Workmanager().initialize(callbackDispatcher);
    await _registerTask();

    _initialized = true;
  }

  Future<void> _registerTask() async {
    await Workmanager().registerPeriodicTask(
      _dormElectricityCheckTask,
      _dormElectricityCheckTask,
      frequency: const Duration(hours: 8),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
    );
  }

  Future<void> reRegisterIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('dorm_alert_enabled') ?? false;
    if (enabled) {
      await _registerTask();
    } else {
      await Workmanager().cancelByUniqueName(_dormElectricityCheckTask);
    }
  }
}
