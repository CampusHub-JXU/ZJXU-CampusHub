import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:jxu_campus_hub/core/calendar/calendar_sync_channel.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_models.dart';

/// 设备端系统日历 provider 自检（仅 Android、仅 dev 包）。
///
/// 本文件只走真实 `MethodChannelCalendarSyncChannel`，**不**启动 JXU App UI、
/// **不**触发课表同步 / 登录，也不写入任何真实课程数据：事件标题与地点均为合成
/// 占位，`opaqueId` 为 `Random.secure` 生成的随机 UUID。
///
/// 安全边界：
/// - 运行前要求 `READ_CALENDAR` + `WRITE_CALENDAR` 已由 host **临时**授予；未授权
///   直接失败并给出授权指引，绝不自动申请权限 / 发起登录，也绝不静默 skip 当通过。
/// - 只按 `(calendarId, opaqueId)` 查询本次随机事件，只按
///   `(calendarId, opaqueId, eventId)` 精确删除；禁止删除日历行、按标题批量删除，
///   也不触碰其他事件。
/// - 若初始查询发现该随机 opaqueId 已有记录（极端碰撞），拒绝写入与删除，保留现场。
/// - 清理无条件执行（语义等价 `try/finally`）：即便插入在返回前抛错、还没拿到
///   eventId，也先按本次 opaqueId 找回 id 再精确删除。清理失败会让测试失败并保留
///   随机标记日志，供人工定向救援；不做任何宽删。
const Duration _inspectionPause = Duration(seconds: 15);

/// 合成、非隐私的占位内容，绝不包含学号 / 课名 / 业务键。
const String _syntheticTitle =
    'JXU CalendarSync self-test (synthetic, not a real course)';
const String _syntheticLocation = 'JXU test location (synthetic)';

/// 事件时区与提醒提前量；provider 侧会再次校验时区并拒绝静默回退。
const String _timeZone = 'Asia/Shanghai';
const int _reminderMinutes = 10;

/// 随机标记日志前缀，host 可用 `adb logcat` 按此前缀 grep 定位救援信息。
const String _markerPrefix = 'JXU_CALENDAR_SYNC_PROBE';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'calendar_sync provider: permission-gated insert/update/delete round-trip',
    (tester) async {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      final String packageName = packageInfo.packageName;

      // debug / profile 的 applicationIdSuffix 为 `.dev`，专属本地日历的
      // accountName 由 packageName 派生；这里强制只在 dev 包运行，避免与 release 串扰。
      if (!packageName.endsWith('.dev')) {
        fail(
          '本自检只允许 debug/profile 的 .dev 包运行（与 release 包隔离）。'
          '当前包名：$packageName。请在 dev 包上重跑。',
        );
      }

      final CalendarSyncChannel channel = MethodChannelCalendarSyncChannel();

      // 权限前置：必须 host 已临时授予，未授权即失败（不申请、不登录、不静默跳过）。
      if (!await channel.checkPermissions()) {
        fail(
          '日历权限未就绪：需要 READ_CALENDAR + WRITE_CALENDAR 均已授予。\n'
          '本测试不会自动申请权限或发起登录。请 host 先临时授权后重跑：\n'
          '  系统设置 → 应用 → $packageName → 权限 → 日历 → 允许；\n'
          '  或 adb shell pm grant $packageName android.permission.READ_CALENDAR\n'
          '     adb shell pm grant $packageName android.permission.WRITE_CALENDAR',
        );
      }

      // 连续两次应定位到同一个本 App 专属本地日历（只定位，不创建第二份）。
      final CalendarSyncLocalCalendar first = await channel
          .createOrGetLocalCalendar();
      final CalendarSyncLocalCalendar second = await channel
          .createOrGetLocalCalendar();
      if (first.id != second.id) {
        fail(
          'createOrGetLocalCalendar 两次返回不同日历 id（${first.id} vs ${second.id}），'
          '专属本地日历不唯一，拒绝继续写入。',
        );
      }
      final int calendarId = first.id;

      _logMarker('packageName', packageName);
      _logMarker('calendarId', '$calendarId');

      final String opaqueId = CalendarSyncOpaqueId.generate();
      _logMarker('opaqueId', opaqueId);

      // 极端碰撞防护：全新随机 id 理论上不应命中任何旧记录；若命中则拒绝写入与删除。
      final List<CalendarSyncOwnedEvent> preExisting = await channel
          .queryOwnedEvents(
            calendarId: calendarId,
            opaqueIds: <String>[opaqueId],
          );
      if (preExisting.isNotEmpty) {
        fail(
          '随机 opaqueId 命中已有记录（极端碰撞）：$opaqueId。'
          '拒绝写入与删除，保留现场供人工排查。',
        );
      }

      // 事件定在未来 >= 7 天，Asia/Shanghai，起止为绝对 UTC 毫秒。
      final DateTime baseStartUtc = DateTime.now().toUtc().add(
        const Duration(days: 7, hours: 1),
      );

      var mutationStarted = false;
      Object? scenarioError;
      StackTrace? scenarioStack;
      try {
        mutationStarted = true;

        final CalendarSyncEventDraft insertedDraft = _buildDraft(
          opaqueId: opaqueId,
          startUtc: baseStartUtc,
        );
        final CalendarSyncBatchResult insertResult = await channel
            .upsertEventBatch(
              calendarId: calendarId,
              events: <CalendarSyncEventDraft>[insertedDraft],
            );
        expect(insertResult.insertedCount, 1, reason: '首次 upsert 应插入 1 条');
        expect(insertResult.updatedCount, 0, reason: '首次 upsert 不应更新');
        final int? insertedEventId = insertResult.eventIds[opaqueId];
        expect(insertedEventId, isNotNull, reason: '结果必须回填本次 eventId');
        expect(insertedEventId! > 0, isTrue);
        _logMarker('insertedEventId', '$insertedEventId');
        await _pauseForInspection(insertedEventId);

        // 只按 (calendarId, opaqueId) 查询本次事件。
        final List<CalendarSyncOwnedEvent> afterInsert = await channel
            .queryOwnedEvents(
              calendarId: calendarId,
              opaqueIds: <String>[opaqueId],
            );
        expect(afterInsert.length, 1, reason: '插入后本次事件应恰好 1 条');
        expect(afterInsert.single.eventId, insertedEventId);
        expect(afterInsert.single.opaqueId, opaqueId);

        // 更新同一 opaqueId 的事件：eventId 必须保持不变。
        final CalendarSyncEventDraft updatedDraft = _buildDraft(
          opaqueId: opaqueId,
          startUtc: baseStartUtc.add(const Duration(hours: 1)),
        );
        final CalendarSyncBatchResult updateResult = await channel
            .upsertEventBatch(
              calendarId: calendarId,
              events: <CalendarSyncEventDraft>[updatedDraft],
            );
        expect(updateResult.insertedCount, 0, reason: '更新不应再插入');
        expect(updateResult.updatedCount, 1, reason: '更新应命中同一条');
        expect(updateResult.eventIds[opaqueId], insertedEventId);
        await _pauseForInspection(insertedEventId);

        final List<CalendarSyncOwnedEvent> afterUpdate = await channel
            .queryOwnedEvents(
              calendarId: calendarId,
              opaqueIds: <String>[opaqueId],
            );
        expect(afterUpdate.length, 1, reason: '更新后本次事件仍应恰好 1 条');
        expect(afterUpdate.single.eventId, insertedEventId);

        // 只对本次 (calendarId, opaqueId, eventId) 精确删除。
        final CalendarSyncDeleteResult deleteResult = await channel
            .deleteOwnedEventsByIds(
              calendarId: calendarId,
              events: <CalendarSyncOwnedEvent>[
                CalendarSyncOwnedEvent(
                  opaqueId: opaqueId,
                  eventId: insertedEventId,
                ),
              ],
            );
        expect(deleteResult.deletedIds, <int>[insertedEventId]);
        expect(deleteResult.notDeletedIds, isEmpty);
        expect(deleteResult.isComplete, isTrue);

        final List<CalendarSyncOwnedEvent> afterDelete = await channel
            .queryOwnedEvents(
              calendarId: calendarId,
              opaqueIds: <String>[opaqueId],
            );
        expect(afterDelete, isEmpty, reason: '删除后本次事件应消失');
      } catch (error, stackTrace) {
        scenarioError = error;
        scenarioStack = stackTrace;
      }

      // 无条件清理（语义等价 try/finally）：即使插入在返回前抛错、没有 eventId，
      // 也先按本次随机 opaqueId 找回 id 再精确删除。
      Object? cleanupError;
      if (mutationStarted) {
        try {
          await _cleanupOwnedEvent(
            channel,
            calendarId: calendarId,
            opaqueId: opaqueId,
          );
        } catch (error) {
          cleanupError = error;
        }
      }

      if (cleanupError != null) {
        final String rescue =
            '$_markerPrefix 清理失败，需人工定向救援：'
            'packageName=$packageName calendarId=$calendarId opaqueId=$opaqueId。'
            '仅可删除该日历下 '
            'CUSTOM_APP_URI=jxucampushub://calendar-event/$opaqueId 的自有事件；'
            '禁止删除日历行、按标题或整日历删除。';
        if (scenarioError != null) {
          fail('场景失败：$scenarioError\n\n清理也失败：$cleanupError\n$rescue');
        }
        fail('清理失败：$cleanupError\n$rescue');
      }
      if (scenarioError != null) {
        Error.throwWithStackTrace(
          scenarioError,
          scenarioStack ?? StackTrace.current,
        );
      }
    },
    // 通道仅 Android 主引擎注册；非 Android 平台结构性跳过（权限缺失仍会失败）。
    skip: !Platform.isAndroid,
  );
}

CalendarSyncEventDraft _buildDraft({
  required String opaqueId,
  required DateTime startUtc,
}) {
  final DateTime endUtc = startUtc.add(const Duration(hours: 1));
  return CalendarSyncEventDraft(
    opaqueId: opaqueId,
    title: _syntheticTitle,
    location: _syntheticLocation,
    startMillis: startUtc.millisecondsSinceEpoch,
    endMillis: endUtc.millisecondsSinceEpoch,
    reminderMinutes: _reminderMinutes,
    timeZone: _timeZone,
  );
}

/// 插入 / 更新后短暂停留，给 host 用 `adb shell content query` 按 event_id 精确
/// 核对 `Reminders.MINUTES`；仅打印随机 eventId 与 adb 提示，不含任何业务信息。
Future<void> _pauseForInspection(int eventId) async {
  debugPrint(
    '$_markerPrefix inspect_eventId=$eventId '
    'adb: adb shell content query --uri content://com.android.calendar/reminders '
    '--where "event_id=$eventId" --projection "minutes:method"',
  );
  debugPrint(
    '$_markerPrefix waiting=${_inspectionPause.inSeconds}s '
    'for host reminder verification (Reminders.MINUTES=$_reminderMinutes)',
  );
  await Future<void>.delayed(_inspectionPause);
}

/// 精确清理本次随机 opaqueId 的自有事件。
///
/// 只按 `(calendarId, opaqueId)` 查询、只按 `(calendarId, opaqueId, eventId)`
/// 删除；0 行未删除即抛错，交由调用方让测试失败并保留救援标记。
Future<void> _cleanupOwnedEvent(
  CalendarSyncChannel channel, {
  required int calendarId,
  required String opaqueId,
}) async {
  final List<CalendarSyncOwnedEvent> owned = await channel.queryOwnedEvents(
    calendarId: calendarId,
    opaqueIds: <String>[opaqueId],
  );
  if (owned.isEmpty) return;

  final CalendarSyncDeleteResult result = await channel.deleteOwnedEventsByIds(
    calendarId: calendarId,
    events: owned,
  );
  if (!result.isComplete) {
    throw StateError('精确删除后仍有未删除的本次事件：notDeleted=${result.notDeletedIds}');
  }
}

void _logMarker(String label, String value) {
  debugPrint('$_markerPrefix $label=$value');
}
