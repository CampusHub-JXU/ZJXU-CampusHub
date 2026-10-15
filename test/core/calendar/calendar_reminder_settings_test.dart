import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/calendar/calendar_reminder_settings.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_models.dart';

/// 课前提醒提前量设置的离线单测：只 mock SharedPreferences，不触达系统日历。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    CalendarReminderSettings.instance.debugReset();
  });

  test('未手动设置时默认 20 分钟', () async {
    final settings = CalendarReminderSettings.instance;
    expect(settings.reminderMinutes, 20);
    expect(
      settings.reminderMinutes,
      CalendarReminderSettings.defaultReminderMinutes,
    );

    await settings.load();
    expect(settings.reminderMinutes, 20);
  });

  test('读盘恢复已持久化的提前量', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      CalendarReminderSettings.storageKey: 45,
    });
    final settings = CalendarReminderSettings.instance;

    await settings.load();

    expect(settings.reminderMinutes, 45);
  });

  test('load 只在首次加载或有效提前量改变时通知监听者', () async {
    final settings = CalendarReminderSettings.instance;
    var notified = 0;
    void listener() => notified++;
    settings.addListener(listener);
    addTearDown(() => settings.removeListener(listener));

    await settings.load();
    expect(notified, 1);

    await settings.load();
    expect(notified, 1);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(CalendarReminderSettings.storageKey, 30);
    await settings.load();
    expect(settings.reminderMinutes, 30);
    expect(notified, 2);

    await prefs.setString(CalendarReminderSettings.storageKey, 'damaged');
    await settings.load();
    expect(settings.reminderMinutes, 20);
    expect(notified, 3);

    await settings.load();
    expect(notified, 3);
  });

  test('设置后落盘并可被重新读回', () async {
    final settings = CalendarReminderSettings.instance;
    await settings.load();

    await settings.setReminderMinutes(30);
    expect(settings.reminderMinutes, 30);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(CalendarReminderSettings.storageKey), 30);

    // 模拟重启：清内存态后重新读盘仍为 30。
    settings.debugReset();
    await settings.load();
    expect(settings.reminderMinutes, 30);
  });

  test('0 是受支持的预设（课程开始时提醒），不被消毒为默认值', () async {
    final settings = CalendarReminderSettings.instance;
    expect(CalendarReminderSettings.presetMinutes, contains(0));

    await settings.load();
    await settings.setReminderMinutes(0);
    expect(settings.reminderMinutes, 0);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(CalendarReminderSettings.storageKey), 0);
  });

  test('超出协议上限或负数一律回退默认 20，不静默截断', () async {
    final settings = CalendarReminderSettings.instance;

    await settings.setReminderMinutes(
      CalendarSyncProtocol.maxReminderMinutes + 1,
    );
    expect(settings.reminderMinutes, 20);

    await settings.setReminderMinutes(-5);
    expect(settings.reminderMinutes, 20);
  });

  test('读盘类型不符或越界时回退默认，不崩溃', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      CalendarReminderSettings.storageKey: 'not-an-int',
    });
    final settings = CalendarReminderSettings.instance;

    await settings.load();
    expect(settings.reminderMinutes, 20);

    SharedPreferences.setMockInitialValues(<String, Object>{
      CalendarReminderSettings.storageKey: 999999,
    });
    settings.debugReset();
    await settings.load();
    expect(settings.reminderMinutes, 20);
  });

  test('setReminderMinutes 仅在写盘确认后通知监听者', () async {
    final settings = CalendarReminderSettings.instance;
    await settings.load();

    var notified = 0;
    void listener() => notified++;
    settings.addListener(listener);
    addTearDown(() => settings.removeListener(listener));

    await settings.setReminderMinutes(60);
    expect(notified, 1);

    // 同值重复设置不再发通知（避免无意义的前台重同步）。
    await settings.setReminderMinutes(60);
    expect(notified, 1);
  });
}
