import 'package:flutter/services.dart';

import 'package:jxu_campus_hub/core/calendar/calendar_sync_models.dart';

/// 纯内存假原生实现：记录调用、允许逐方法注入行为；绝不触达真实系统日历。
///
/// 覆盖既有 `calendar_sync` 写入方法（权限 / 日历 / 查询 / 批量 / 删除）与
/// Issue #48 的**只读**遗留发现方法（`listOwnedEventCalendars` / `scanOwnedEvents`）。
/// 删除会按返回的 `deletedIds` 从内存 provider 中移除，因此清理后的复扫结果与
/// 真实 provider 一致（残留下界会被如实算出）。
class FakeCalendarSyncNative {
  bool permissions = true;
  bool grantOnRequest = true;

  final List<String> calls = <String>[];
  int checkCalls = 0;
  int requestCalls = 0;
  int createCalendarCalls = 0;
  int listCalls = 0;
  int deleteCalls = 0;
  int listOwnedCalls = 0;
  int scanOwnedCalls = 0;

  List<CalendarSyncWritableCalendar> calendars =
      const <CalendarSyncWritableCalendar>[];

  // ── Issue #48 只读遗留发现（合成数据，仅当前包名 + marker 语义）─────────

  /// `listOwnedEventCalendars` 返回的自有日历元数据。
  List<CalendarOwnedCalendarInfo> ownedCalendars =
      const <CalendarOwnedCalendarInfo>[];
  bool discoveryComplete = true;
  CalendarOwnedDiscoveryReason? discoveryReason;

  /// provider 中「当前包名 + 合法 marker」证实的自有事件（按 calendarId）。
  Map<int, List<CalendarSyncOwnedEvent>> ownedEvents =
      <int, List<CalendarSyncOwnedEvent>>{};
  bool scanComplete = true;
  CalendarOwnedDiscoveryReason? scanReason;

  /// 置上后 `listOwnedEventCalendars` 等待该 Future（在途扫描 / 离开页面测试）。
  Future<void>? listOwnedGate;

  /// 置上后 `createOrGetLocalCalendar` 等待该 Future（在途重复点击测试）。
  Future<void>? createGate;

  /// 覆盖删除返回；未设时按内存 provider 精确命中删除。
  CalendarSyncDeleteResult Function(List<CalendarSyncOwnedEvent> events)?
  onDelete;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'checkPermissions':
        checkCalls++;
        return permissions;
      case 'requestPermissions':
        requestCalls++;
        if (grantOnRequest) permissions = true;
        return permissions;
      case 'createOrGetLocalCalendar':
        createCalendarCalls++;
        final gate = createGate;
        if (gate != null) {
          createGate = null;
          await gate;
        }
        return <String, Object?>{'id': 42, 'displayName': '嘉兴大学课程'};
      case 'listWritableCalendars':
        listCalls++;
        return <Object?>[
          for (final calendar in calendars)
            <String, Object?>{
              'id': calendar.id,
              'displayName': calendar.displayName,
              if (calendar.accountName != null)
                'accountName': calendar.accountName,
            },
        ];
      case 'queryOwnedEvents':
        return <Object?>[];
      case 'listOwnedEventCalendars':
        listOwnedCalls++;
        final gate = listOwnedGate;
        if (gate != null) {
          listOwnedGate = null;
          await gate;
        }
        return <String, Object?>{
          'calendars': <Object?>[
            for (final calendar in ownedCalendars)
              <String, Object?>{
                'calendarId': calendar.calendarId,
                if (calendar.displayName != null)
                  'displayName': calendar.displayName,
                if (calendar.writable != null) 'writable': calendar.writable,
              },
          ],
          'complete': discoveryComplete,
          if (discoveryReason != null) 'reason': discoveryReason!.wireCode,
        };
      case 'scanOwnedEvents':
        scanOwnedCalls++;
        final calendarId =
            (call.arguments as Map<Object?, Object?>)['calendarId'] as int;
        return <String, Object?>{
          'events': <Object?>[
            for (final event
                in ownedEvents[calendarId] ?? const <CalendarSyncOwnedEvent>[])
              <String, Object?>{
                'opaqueId': event.opaqueId,
                'eventId': event.eventId,
              },
          ],
          'complete': scanComplete,
          if (scanReason != null) 'reason': scanReason!.wireCode,
        };
      case 'deleteOwnedEventsByIds':
        deleteCalls++;
        final calendarId =
            (call.arguments as Map<Object?, Object?>)['calendarId'] as int;
        final events = _parseEvents(call.arguments);
        final result =
            onDelete?.call(events) ??
            _defaultDelete(calendarId: calendarId, events: events);
        _applyDeletions(calendarId: calendarId, deletedIds: result.deletedIds);
        return <String, Object?>{
          'deletedIds': result.deletedIds,
          'notDeletedIds': result.notDeletedIds,
        };
      case 'upsertEventBatch':
        final rawEvents =
            (call.arguments as Map<Object?, Object?>)['events']
                as List<Object?>;
        return <String, Object?>{
          'insertedCount': rawEvents.length,
          'updatedCount': 0,
          'eventIds': <String, int>{
            for (var index = 0; index < rawEvents.length; index++)
              (rawEvents[index] as Map<Object?, Object?>)['opaqueId'] as String:
                  index + 1,
          },
        };
      default:
        return null;
    }
  }

  CalendarSyncDeleteResult _defaultDelete({
    required int calendarId,
    required List<CalendarSyncOwnedEvent> events,
  }) {
    final current = ownedEvents[calendarId] ?? const <CalendarSyncOwnedEvent>[];
    final deleted = <int>[];
    final notDeleted = <int>[];
    for (final event in events) {
      final match = current.any(
        (candidate) =>
            candidate.opaqueId == event.opaqueId &&
            candidate.eventId == event.eventId,
      );
      if (match) {
        deleted.add(event.eventId);
      } else {
        notDeleted.add(event.eventId);
      }
    }
    return CalendarSyncDeleteResult(
      deletedIds: deleted,
      notDeletedIds: notDeleted,
    );
  }

  void _applyDeletions({
    required int calendarId,
    required List<int> deletedIds,
  }) {
    if (deletedIds.isEmpty) return;
    final remaining = <CalendarSyncOwnedEvent>[
      for (final event
          in ownedEvents[calendarId] ?? const <CalendarSyncOwnedEvent>[])
        if (!deletedIds.contains(event.eventId)) event,
    ];
    ownedEvents[calendarId] = remaining;
  }

  static List<CalendarSyncOwnedEvent> _parseEvents(Object? arguments) {
    final raw = (arguments as Map<Object?, Object?>)['events'] as List<Object?>;
    return <CalendarSyncOwnedEvent>[
      for (final item in raw) CalendarSyncOwnedEvent.tryParse(item)!,
    ];
  }
}
