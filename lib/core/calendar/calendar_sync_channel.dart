import 'package:flutter/services.dart';

import '../logging/app_logger.dart';
import 'calendar_sync_models.dart';

/// 系统日历同步通道门面（仅前台主 Activity 注册的
/// `edu.zjxu.jxucampushub/calendar_sync`）。
///
/// 契约要点：
/// - 所有失败都抛 [CalendarSyncException]（含类别与原生 code），绝不吞成成功；
/// - 参数只含协议字段：opaqueId / 标题 / 地点 / 时间 / 提醒 / 时区，**不传**
///   studentId / businessKey 等本地身份与业务键；
/// - `checkPermissions` / `requestPermissions` 按固定协议返回 `bool`：只有原生
///   明确返回 `true` 才是已授权；平台缺失或平台异常一律 `false`，调用方必须把
///   `false` 当作「未授权 / 不可用」，不得据此继续写入。
abstract interface class CalendarSyncChannel {
  /// `READ_CALENDAR` + `WRITE_CALENDAR` 是否都已授权。
  Future<bool> checkPermissions();

  /// 申请两项日历权限；已授权直接 true，拒绝/平台缺失 false。
  Future<bool> requestPermissions();

  /// 返回本 App 专属本地日历；不存在则创建。不会误认其他 App 的日历。
  Future<CalendarSyncLocalCalendar> createOrGetLocalCalendar();

  /// 列出用户可写日历，仅用于选择目标，不自动写入。
  Future<List<CalendarSyncWritableCalendar>> listWritableCalendars();

  /// 查询目标日历内本 App 拥有的事件；[opaqueIds] 为 null 表示查全部。
  Future<List<CalendarSyncOwnedEvent>> queryOwnedEvents({
    required int calendarId,
    List<String>? opaqueIds,
  });

  /// 批量插入/更新绝对非重复事件；整批失败即抛错，不部分报成功。
  Future<CalendarSyncBatchResult> upsertEventBatch({
    required int calendarId,
    required List<CalendarSyncEventDraft> events,
  });

  /// 按 eventId 删除本 App 拥有的事件；0 行归入 notDeleted。
  Future<CalendarSyncDeleteResult> deleteOwnedEventsByIds({
    required int calendarId,
    required List<CalendarSyncOwnedEvent> events,
  });
}

/// 只读「本 App 遗留事件日历」发现门面（Issue #48 第一阶段契约，**只读**）。
///
/// 与写入 / 控制 facade [CalendarSyncChannel] 分离：本阶段只冻结**只读发现**能力，
/// 从而**不**扩大既有 provider 接口、不强迫既有 FakeProvider 更新（core 阶段再决定
/// 是否并入 [CalendarSyncChannel]）。
///
/// 契约要点：
/// - 绝不创建 / 删除 / 修改任何事件或日历；只返回候选与完整性标记；
/// - 绝不抛异常：平台缺失 / 异常 / 结构非法一律降级为 `complete=false` 的保守结果，
///   调用方**不得**把空列表当作「已清干净」；
/// - 结果只含 `calendarId / displayName / writable`，不含账号 / owner 等身份信息。
abstract interface class CalendarOwnedEventDiscovery {
  /// 只读列出「当前包名 + 合法 marker」证实的本 App 遗留事件日历。
  Future<CalendarOwnedCalendarDiscovery> listOwnedEventCalendars();
}

/// 默认门面实例；阶段 2 的 coordinator 直接复用它（测试注入 mock channel）。
final CalendarSyncChannel defaultCalendarSyncChannel =
    MethodChannelCalendarSyncChannel();

/// 只读遗留扫描门面实例（与写入门面分离，能力更窄，供 core 阶段注入 / 测试）。
final CalendarOwnedEventDiscovery defaultCalendarOwnedEventDiscovery =
    MethodChannelCalendarSyncChannel();

/// 基于 `MethodChannel` 的实现。
class MethodChannelCalendarSyncChannel
    implements CalendarSyncChannel, CalendarOwnedEventDiscovery {
  MethodChannelCalendarSyncChannel({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel(CalendarSyncProtocol.channelName);

  final MethodChannel _channel;

  /// 通道参数白名单：只允许协议字段，防止身份/业务键泄漏到 provider。
  static const Set<String> _allowedArgumentKeys = <String>{
    'calendarId',
    'opaqueIds',
    'events',
  };

  static const Set<String> _allowedEventKeys = <String>{
    'opaqueId',
    'title',
    'location',
    'startMillis',
    'endMillis',
    'reminderMinutes',
    'timeZone',
    'eventId',
  };

  @override
  Future<bool> checkPermissions() =>
      _readPermission(CalendarSyncProtocol.methodCheckPermissions);

  @override
  Future<bool> requestPermissions() =>
      _readPermission(CalendarSyncProtocol.methodRequestPermissions);

  @override
  Future<CalendarSyncLocalCalendar> createOrGetLocalCalendar() async {
    const operation = CalendarSyncProtocol.methodCreateOrGetLocalCalendar;
    final raw = await _invoke(operation);
    final calendar = CalendarSyncLocalCalendar.tryParse(raw);
    if (calendar == null) {
      throw CalendarSyncException.invalidResponse(operation, raw);
    }
    return calendar;
  }

  @override
  Future<List<CalendarSyncWritableCalendar>> listWritableCalendars() async {
    const operation = CalendarSyncProtocol.methodListWritableCalendars;
    final raw = await _invoke(operation);
    if (raw is! List) {
      throw CalendarSyncException.invalidResponse(operation, raw);
    }
    final calendars = <CalendarSyncWritableCalendar>[];
    final seenIds = <int>{};
    for (final item in raw) {
      final calendar = CalendarSyncWritableCalendar.tryParse(item);
      if (calendar == null) {
        throw CalendarSyncException.invalidResponse(operation, item);
      }
      if (!seenIds.add(calendar.id)) {
        throw CalendarSyncException.invalidResponse(
          operation,
          item,
          reason: '日历 id 重复',
        );
      }
      calendars.add(calendar);
    }
    return List<CalendarSyncWritableCalendar>.unmodifiable(calendars);
  }

  @override
  Future<List<CalendarSyncOwnedEvent>> queryOwnedEvents({
    required int calendarId,
    List<String>? opaqueIds,
  }) async {
    const operation = CalendarSyncProtocol.methodQueryOwnedEvents;
    _requireCalendarId(calendarId);

    Set<String>? requestedOpaqueIds;
    List<String>? normalizedOpaqueIds;
    if (opaqueIds != null) {
      if (opaqueIds.length > CalendarSyncProtocol.maxQueryOpaqueIds) {
        throw CalendarSyncException.invalidArgument(
          'opaqueIds 超过 ${CalendarSyncProtocol.maxQueryOpaqueIds} 项',
        );
      }
      final seen = <String>{};
      for (final opaqueId in opaqueIds) {
        if (!CalendarSyncOpaqueId.isValid(opaqueId)) {
          throw CalendarSyncException.invalidArgument('opaqueIds 含非法随机标识');
        }
        if (!seen.add(opaqueId)) {
          throw CalendarSyncException.invalidArgument('opaqueIds 含重复项');
        }
      }
      requestedOpaqueIds = seen;
      normalizedOpaqueIds = List<String>.unmodifiable(opaqueIds);
    }

    final raw = await _invoke(operation, <String, Object?>{
      'calendarId': calendarId,
      'opaqueIds': ?normalizedOpaqueIds,
    });
    if (raw is! List) {
      throw CalendarSyncException.invalidResponse(operation, raw);
    }

    final events = <CalendarSyncOwnedEvent>[];
    final seenOpaqueIds = <String>{};
    for (final item in raw) {
      final event = CalendarSyncOwnedEvent.tryParse(item);
      if (event == null) {
        throw CalendarSyncException.invalidResponse(operation, item);
      }
      if (!seenOpaqueIds.add(event.opaqueId)) {
        throw CalendarSyncException.invalidResponse(
          operation,
          item,
          reason: 'opaqueId 重复',
        );
      }
      if (requestedOpaqueIds != null &&
          !requestedOpaqueIds.contains(event.opaqueId)) {
        throw CalendarSyncException.invalidResponse(
          operation,
          item,
          reason: '返回了未请求的 opaqueId',
        );
      }
      events.add(event);
    }
    return List<CalendarSyncOwnedEvent>.unmodifiable(events);
  }

  @override
  Future<CalendarSyncBatchResult> upsertEventBatch({
    required int calendarId,
    required List<CalendarSyncEventDraft> events,
  }) async {
    const operation = CalendarSyncProtocol.methodUpsertEventBatch;
    _requireCalendarId(calendarId);
    if (events.isEmpty) {
      throw CalendarSyncException.invalidArgument('批次至少需要一个事件');
    }
    if (events.length > CalendarSyncProtocol.maxBatchEvents) {
      throw CalendarSyncException.invalidArgument(
        '批次事件数超过 ${CalendarSyncProtocol.maxBatchEvents}',
      );
    }

    final requestedOpaqueIds = <String>{};
    for (final event in events) {
      final reason = event.validate();
      if (reason != null) {
        throw CalendarSyncException.invalidArgument('事件参数非法：$reason');
      }
      if (!requestedOpaqueIds.add(event.opaqueId)) {
        throw CalendarSyncException.invalidArgument('批次内 opaqueId 重复');
      }
    }

    final raw = await _invoke(operation, <String, Object?>{
      'calendarId': calendarId,
      'events': <Object?>[for (final event in events) event.toChannelMap()],
    });
    final result = CalendarSyncBatchResult.tryParse(raw);
    if (result == null) {
      throw CalendarSyncException.invalidResponse(operation, raw);
    }
    for (final opaqueId in result.eventIds.keys) {
      if (!requestedOpaqueIds.contains(opaqueId)) {
        throw CalendarSyncException.invalidResponse(
          operation,
          raw,
          reason: '返回了未请求的 opaqueId',
        );
      }
    }
    // 协议要求整批原子返回全部 eventIds；缺项会让账本留下无法确认的 pending，
    // 必须在门面就拒绝，交由调用方按失败处理。
    if (!result.coversAll(requestedOpaqueIds)) {
      throw CalendarSyncException.invalidResponse(
        operation,
        raw,
        reason: 'eventIds 未覆盖整批事件',
      );
    }
    return result;
  }

  @override
  Future<CalendarSyncDeleteResult> deleteOwnedEventsByIds({
    required int calendarId,
    required List<CalendarSyncOwnedEvent> events,
  }) async {
    const operation = CalendarSyncProtocol.methodDeleteOwnedEventsByIds;
    _requireCalendarId(calendarId);
    if (events.isEmpty) {
      throw CalendarSyncException.invalidArgument('批次至少需要一个事件');
    }
    if (events.length > CalendarSyncProtocol.maxBatchEvents) {
      throw CalendarSyncException.invalidArgument(
        '批次事件数超过 ${CalendarSyncProtocol.maxBatchEvents}',
      );
    }

    final requestedEventIds = <int>{};
    final seenOpaqueIds = <String>{};
    for (final event in events) {
      if (!CalendarSyncOpaqueId.isValid(event.opaqueId)) {
        throw CalendarSyncException.invalidArgument('opaqueId 不是合法随机标识');
      }
      if (event.eventId <= 0) {
        throw CalendarSyncException.invalidArgument('eventId 必须为正整数');
      }
      if (!seenOpaqueIds.add(event.opaqueId)) {
        throw CalendarSyncException.invalidArgument('批次内 opaqueId 重复');
      }
      if (!requestedEventIds.add(event.eventId)) {
        throw CalendarSyncException.invalidArgument('批次内 eventId 重复');
      }
    }

    final raw = await _invoke(operation, <String, Object?>{
      'calendarId': calendarId,
      'events': <Object?>[
        for (final event in events)
          <String, Object?>{
            'opaqueId': event.opaqueId,
            'eventId': event.eventId,
          },
      ],
    });
    final result = CalendarSyncDeleteResult.tryParse(raw);
    if (result == null) {
      throw CalendarSyncException.invalidResponse(operation, raw);
    }

    final deleted = result.deletedIds.toSet();
    final notDeleted = result.notDeletedIds.toSet();
    if (deleted.length != result.deletedIds.length ||
        notDeleted.length != result.notDeletedIds.length) {
      throw CalendarSyncException.invalidResponse(
        operation,
        raw,
        reason: '删除结果含重复 eventId',
      );
    }
    if (deleted.intersection(notDeleted).isNotEmpty) {
      throw CalendarSyncException.invalidResponse(
        operation,
        raw,
        reason: '同一 eventId 同时出现在删除与未删除列表',
      );
    }
    // 协议：0 行按 notDeleted 返回，因此每个请求的 eventId 都必须被明确分类。
    if (deleted.length + notDeleted.length != requestedEventIds.length ||
        !deleted.union(notDeleted).containsAll(requestedEventIds)) {
      throw CalendarSyncException.invalidResponse(
        operation,
        raw,
        reason: '删除结果未覆盖整批 eventId',
      );
    }
    return result;
  }

  @override
  Future<CalendarOwnedCalendarDiscovery> listOwnedEventCalendars() async {
    const operation = CalendarSyncProtocol.methodListOwnedEventCalendars;
    // 只读、无参数：绝不传 opaqueIds / 路径 / owner 包名等任何输入。
    assert(_assertArgumentsAreOpaque(operation, const <String, Object?>{}));
    try {
      final raw = await _channel.invokeMethod<Object?>(
        operation,
        const <String, Object?>{},
      );
      return CalendarOwnedCalendarDiscovery.tryParse(raw) ??
          CalendarOwnedCalendarDiscovery.unavailable();
    } on MissingPluginException {
      return CalendarOwnedCalendarDiscovery.unavailable();
    } on PlatformException catch (error) {
      // 只按固定 code 分类，绝不记录原始 payload / 课程信息。
      AppLogger.instance.warn('日历遗留扫描降级：$operation (${error.code})');
      return error.code == 'permission_denied'
          ? CalendarOwnedCalendarDiscovery.permissionDenied()
          : CalendarOwnedCalendarDiscovery.unavailable();
    } on Exception {
      AppLogger.instance.warn('日历遗留扫描降级：$operation');
      return CalendarOwnedCalendarDiscovery.unavailable();
    }
  }

  /// 权限查询/申请按固定协议降级为 `bool`。
  ///
  /// 只有原生明确返回 `true` 才返回 true；`MissingPluginException`
  /// （非 Android / 测试环境）与 `PlatformException`（含权限申请在途）都返回
  /// false，并记录类别供诊断——绝不把未知/异常当作已授权。
  Future<bool> _readPermission(String method) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(method);
      if (raw is bool) return raw;
      AppLogger.instance.warn('日历权限通道返回非布尔值：$method');
      return false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      AppLogger.instance.warn('日历权限通道失败：$method (${error.code})');
      return false;
    } on Exception catch (error) {
      AppLogger.instance.warn('日历权限通道异常：$method ($error)');
      return false;
    }
  }

  Future<Object?> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    assert(_assertArgumentsAreOpaque(method, arguments));
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException catch (error) {
      throw CalendarSyncException.missingPlugin(method, cause: error);
    } on PlatformException catch (error) {
      AppLogger.instance.warn('日历通道调用失败：$method (${error.code})');
      throw CalendarSyncException.fromPlatformException(
        error,
        operation: method,
      );
    } on Exception catch (error) {
      AppLogger.instance.warn('日历通道调用异常：$method ($error)');
      throw CalendarSyncException(
        kind: CalendarSyncFailureKind.platformError,
        message: '$method 平台调用异常',
        cause: error,
      );
    }
  }

  /// debug 断言：通道参数不得出现协议之外的字段（如 studentId / businessKey）。
  static bool _assertArgumentsAreOpaque(
    String method,
    Map<String, Object?>? arguments,
  ) {
    if (arguments == null) return true;
    for (final key in arguments.keys) {
      if (!_allowedArgumentKeys.contains(key)) {
        throw StateError('日历通道 $method 出现非协议参数：$key');
      }
    }
    final events = arguments['events'];
    if (events is List) {
      for (final event in events) {
        if (event is! Map) continue;
        for (final key in event.keys) {
          if (!_allowedEventKeys.contains(key)) {
            throw StateError('日历通道 $method 事件出现非协议参数：$key');
          }
        }
      }
    }
    return true;
  }

  static void _requireCalendarId(int calendarId) {
    if (calendarId <= 0) {
      throw CalendarSyncException.invalidArgument('calendarId 必须为正整数');
    }
  }
}
