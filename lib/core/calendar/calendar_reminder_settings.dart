import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'calendar_sync_models.dart';

/// 课表日历同步的「课前提醒提前量」设置（单整数持久化，默认 20 分钟）。
///
/// 语义与边界：
/// - 只存一个分钟整数，**不存**任何身份 / 凭据 / 账号标识；
/// - 未手动设置、读盘缺失、类型不符或超出协议上限时一律回退默认 20 分钟，
///   不猜测也不崩溃；
/// - 提醒由系统日历负责（不是 App 闹钟），本设置只决定投影事件写入
///   `reminderMinutes` 的值；修改后由前台协调器在下一次 diff 中 upsert 生效；
/// - 默认关闭 / 未登录 / 不在前台时，本设置不触发任何系统日历写入
///   （协调器仍走既有零写入门禁）。
class CalendarReminderSettings extends ChangeNotifier {
  CalendarReminderSettings._();

  static final CalendarReminderSettings instance = CalendarReminderSettings._();

  /// 持久化 storage key（单整数；损坏按默认处理，不阻塞其他设置）。
  static const String storageKey = 'calendar_reminder_minutes_v1';

  /// 未设置时的默认提前量（分钟）。
  static const int defaultReminderMinutes = 20;

  /// 设置页可选项（分钟）；顺序即展示顺序，0 表示不提醒。
  static const List<int> presetMinutes = <int>[0, 5, 10, 15, 20, 30, 60];

  int _reminderMinutes = defaultReminderMinutes;
  bool _loaded = false;

  /// 当前生效的提前量（分钟）。冷启动尚未 [load] 时为默认值。
  int get reminderMinutes => _reminderMinutes;

  bool get isLoaded => _loaded;

  /// 测试专用：清空内存态（不动磁盘；磁盘由 mock prefs 重置）。
  @visibleForTesting
  void debugReset() {
    _reminderMinutes = defaultReminderMinutes;
    _loaded = false;
  }

  /// 冷启动 / 设置页打开时从磁盘恢复；越界或类型不符回退默认。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.get(storageKey);
    _reminderMinutes = _sanitize(raw is int ? raw : null);
    _loaded = true;
    notifyListeners();
  }

  /// 设置提前量：先按协议范围消毒，再落盘；写盘未确认时**不**改内存态。
  Future<void> setReminderMinutes(int minutes) async {
    final value = _sanitize(minutes);
    final prefs = await SharedPreferences.getInstance();
    final written = await prefs.setInt(storageKey, value);
    if (!written) return;
    if (_reminderMinutes == value && _loaded) return;
    _reminderMinutes = value;
    _loaded = true;
    notifyListeners();
  }

  /// 范围消毒：缺失 / 负数 / 超协议上限一律回退默认（不静默截断成可疑值）。
  static int _sanitize(int? raw) {
    if (raw == null) return defaultReminderMinutes;
    if (raw < 0 || raw > CalendarSyncProtocol.maxReminderMinutes) {
      return defaultReminderMinutes;
    }
    return raw;
  }
}
