import 'dart:math';

import 'package:flutter/services.dart';

/// 系统日历同步通道的固定协议常量。
///
/// 与原生侧
/// `android/app/src/main/kotlin/edu/zjxu/jxucampushub/platform/calendar/CalendarSyncContract.kt`
/// 保持 lockstep：通道名、方法名、字段名、上限与错误类别必须同步修改。
/// 参数与结果只使用 StandardMethodCodec 支持的基本类型
/// （`Map<String, Object?>` / `List` / `String` / `int` / `bool`）。
abstract final class CalendarSyncProtocol {
  static const String channelName = 'edu.zjxu.jxucampushub/calendar_sync';

  static const String methodCheckPermissions = 'checkPermissions';
  static const String methodRequestPermissions = 'requestPermissions';
  static const String methodCreateOrGetLocalCalendar =
      'createOrGetLocalCalendar';
  static const String methodListWritableCalendars = 'listWritableCalendars';
  static const String methodQueryOwnedEvents = 'queryOwnedEvents';
  static const String methodUpsertEventBatch = 'upsertEventBatch';
  static const String methodDeleteOwnedEventsByIds = 'deleteOwnedEventsByIds';

  /// 原生单批事件上限；Dart 侧先校验，避免无谓的 IPC 往返。
  static const int maxBatchEvents = 100;

  /// 原生单次 opaqueId 过滤上限。
  static const int maxQueryOpaqueIds = 500;

  static const int maxTitleLength = 512;
  static const int maxLocationLength = 1024;
  static const int maxTimeZoneLength = 64;
  static const int maxReminderMinutes = 10080;

  /// businessKey 只存私有 ledger，长度上限由本地约定，不发给原生。
  static const int maxBusinessKeyLength = 512;
}

/// 随机 opaqueId 生成与校验。
///
/// 写入系统日历 `CUSTOM_APP_URI` 的标识必须是不含身份信息的随机值：
/// [generate] 只用 [Random.secure] 生成规范 UUID v4；[isValid] 与原生
/// `CalendarSyncContract.isValidOpaqueId` 等价，同时接受规范 UUID 与
/// 16–64 位纯 hex（覆盖原生侧可能回写的等价形态）。
///
/// 禁止把学号 / 课程名 / businessKey 拼进 opaqueId。
abstract final class CalendarSyncOpaqueId {
  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static final RegExp _hexPattern = RegExp(r'^[0-9a-fA-F]{16,64}$');

  static final Random _secureRandom = Random.secure();

  /// 是否是可安全写进 provider URI 的 opaqueId。
  static bool isValid(String value) =>
      _uuidPattern.hasMatch(value) || _hexPattern.hasMatch(value);

  /// 生成规范 UUID v4（小写）。[random] 仅测试注入，生产必须走 [Random.secure]。
  static String generate({Random? random}) {
    final rng = random ?? _secureRandom;
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
    final buffer = StringBuffer();
    for (var index = 0; index < bytes.length; index++) {
      if (index == 4 || index == 6 || index == 8 || index == 10) {
        buffer.write('-');
      }
      buffer.write(bytes[index].toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

/// 通道/账本的失败类别。
///
/// 调用方必须按类别降级，禁止把任何失败当成写入成功。
enum CalendarSyncFailureKind {
  /// 平台无实现（非 Android、测试环境、方法未注册）。
  missingPlugin,

  /// `READ_CALENDAR` + `WRITE_CALENDAR` 未授权（原生每次写入前复查）。
  permissionDenied,

  /// 平台明确声明不支持（如非 Android 实现）。
  unsupported,

  /// 已有权限申请在途，本次未取得授权，可稍后重试。
  requestsInFlight,

  /// 同一 opaqueId 已归属其他日历，拒绝重复插入。
  ownershipConflict,

  /// 专属本地日历不可用（重复、不可写、id 非法）。
  calendarUnavailable,

  /// 系统日历 provider 不可用。
  providerUnavailable,

  /// 批次任一操作失败，整批未生效。
  batchFailed,

  /// 本地参数或原生 `invalid_args`：请求本身不合法。
  invalidArgument,

  /// 原生返回值不符合固定协议（null / 类型错 / 缺项 / 越界）。
  invalidResponse,

  /// 其他平台异常。
  platformError,

  /// 私有账本读写失败（写盘未确认）。
  ledgerUnavailable,

  /// 私有账本 JSON 损坏；不会静默丢弃或覆盖，需显式重置。
  ledgerCorrupted,
}

/// 日历同步的 typed failure。
///
/// 所有平台/解析失败都必须转成该异常；[code] 保留原生错误类别供诊断，
/// 消息不携带课程名、账号或 URI。
class CalendarSyncException implements Exception {
  const CalendarSyncException({
    required this.kind,
    required this.message,
    this.code,
    this.cause,
  });

  final CalendarSyncFailureKind kind;
  final String message;

  /// 原生 `PlatformException.code`（如 `permission_denied`）；本地失败为 null。
  final String? code;
  final Object? cause;

  factory CalendarSyncException.missingPlugin(
    String operation, {
    Object? cause,
  }) {
    return CalendarSyncException(
      kind: CalendarSyncFailureKind.missingPlugin,
      message: '$operation 平台通道不可用',
      cause: cause,
    );
  }

  factory CalendarSyncException.invalidResponse(
    String operation,
    Object? raw, {
    String? reason,
  }) {
    // 只带原始值的运行时类型，绝不把可能含课程信息的原值写进异常/日志。
    final typeName = raw == null ? 'null' : raw.runtimeType.toString();
    return CalendarSyncException(
      kind: CalendarSyncFailureKind.invalidResponse,
      message:
          '$operation 返回结构不符合协议（$typeName）'
          '${reason == null ? '' : '：$reason'}',
    );
  }

  factory CalendarSyncException.invalidArgument(String message) {
    return CalendarSyncException(
      kind: CalendarSyncFailureKind.invalidArgument,
      message: message,
    );
  }

  factory CalendarSyncException.ledgerUnavailable(
    String message, {
    Object? cause,
  }) {
    return CalendarSyncException(
      kind: CalendarSyncFailureKind.ledgerUnavailable,
      message: message,
      cause: cause,
    );
  }

  factory CalendarSyncException.ledgerCorrupted(
    String message, {
    Object? cause,
  }) {
    return CalendarSyncException(
      kind: CalendarSyncFailureKind.ledgerCorrupted,
      message: message,
      cause: cause,
    );
  }

  /// 把原生 `PlatformException` 映射为固定类别；未知 code 保留为
  /// [CalendarSyncFailureKind.platformError]，不猜测成功。
  factory CalendarSyncException.fromPlatformException(
    PlatformException error, {
    required String operation,
  }) {
    return CalendarSyncException(
      kind: _kindForPlatformCode(error.code),
      message: '$operation 平台调用失败',
      code: error.code,
      cause: error,
    );
  }

  static CalendarSyncFailureKind _kindForPlatformCode(String code) {
    switch (code) {
      case 'permission_denied':
        return CalendarSyncFailureKind.permissionDenied;
      case 'invalid_args':
        return CalendarSyncFailureKind.invalidArgument;
      case 'provider_unavailable':
        return CalendarSyncFailureKind.providerUnavailable;
      case 'calendar_unavailable':
        return CalendarSyncFailureKind.calendarUnavailable;
      case 'ownership_conflict':
        return CalendarSyncFailureKind.ownershipConflict;
      case 'batch_failed':
        return CalendarSyncFailureKind.batchFailed;
      case 'unsupported':
        return CalendarSyncFailureKind.unsupported;
      case 'requests_in_flight':
        return CalendarSyncFailureKind.requestsInFlight;
    }
    final normalized = code.toLowerCase();
    if (normalized.contains('permission')) {
      return CalendarSyncFailureKind.permissionDenied;
    }
    if (normalized.contains('unsupported') ||
        normalized.contains('notimplemented') ||
        normalized.contains('not_implemented')) {
      return CalendarSyncFailureKind.unsupported;
    }
    return CalendarSyncFailureKind.platformError;
  }

  bool get isPermissionDenied =>
      kind == CalendarSyncFailureKind.permissionDenied;

  bool get isPlatformMissing => kind == CalendarSyncFailureKind.missingPlugin;

  /// 是否为可重试的瞬时失败（不含参数错误与账本损坏）。
  bool get isRetryable => switch (kind) {
    CalendarSyncFailureKind.missingPlugin ||
    CalendarSyncFailureKind.requestsInFlight ||
    CalendarSyncFailureKind.providerUnavailable ||
    CalendarSyncFailureKind.batchFailed ||
    CalendarSyncFailureKind.platformError ||
    CalendarSyncFailureKind.ledgerUnavailable => true,
    CalendarSyncFailureKind.permissionDenied ||
    CalendarSyncFailureKind.unsupported ||
    CalendarSyncFailureKind.ownershipConflict ||
    CalendarSyncFailureKind.calendarUnavailable ||
    CalendarSyncFailureKind.invalidArgument ||
    CalendarSyncFailureKind.invalidResponse ||
    CalendarSyncFailureKind.ledgerCorrupted => false,
  };

  @override
  String toString() =>
      'CalendarSyncException(${kind.name}'
      '${code == null ? '' : ', code: $code'}): $message';
}

/// 本 App 专属本地日历（`createOrGetLocalCalendar` 结果）。
class CalendarSyncLocalCalendar {
  const CalendarSyncLocalCalendar({
    required this.id,
    required this.displayName,
  });

  final int id;
  final String displayName;

  /// 严格解析；任何 null / 未知字段形态都返回 null，由门面转成 typed failure。
  static CalendarSyncLocalCalendar? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = _asPositiveInt(raw['id']);
    final displayName = raw['displayName'];
    if (id == null || displayName is! String) return null;
    if (displayName.trim().isEmpty) return null;
    return CalendarSyncLocalCalendar(id: id, displayName: displayName);
  }

  @override
  String toString() =>
      'CalendarSyncLocalCalendar(id: $id, displayName: $displayName)';
}

/// 用户可写的系统日历（`listWritableCalendars` 结果，仅用于选择）。
class CalendarSyncWritableCalendar {
  const CalendarSyncWritableCalendar({
    required this.id,
    required this.displayName,
    this.accountName,
  });

  final int id;
  final String displayName;

  /// 账号名；原生对空串返回 null，这里同样把空白归一为 null。
  final String? accountName;

  static CalendarSyncWritableCalendar? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = _asPositiveInt(raw['id']);
    final displayName = raw['displayName'];
    if (id == null || displayName is! String) return null;
    if (displayName.trim().isEmpty) return null;

    final rawAccount = raw['accountName'];
    if (rawAccount != null && rawAccount is! String) return null;
    final accountName = rawAccount is String && rawAccount.trim().isNotEmpty
        ? rawAccount
        : null;
    return CalendarSyncWritableCalendar(
      id: id,
      displayName: displayName,
      accountName: accountName,
    );
  }

  @override
  String toString() =>
      'CalendarSyncWritableCalendar(id: $id, displayName: $displayName, '
      'accountName: $accountName)';
}

/// 本 App 拥有的系统日历事件引用（`queryOwnedEvents` 结果 / 删除入参）。
class CalendarSyncOwnedEvent {
  const CalendarSyncOwnedEvent({required this.opaqueId, required this.eventId});

  final String opaqueId;
  final int eventId;

  static CalendarSyncOwnedEvent? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final opaqueId = raw['opaqueId'];
    final eventId = _asPositiveInt(raw['eventId']);
    if (opaqueId is! String || eventId == null) return null;
    if (!CalendarSyncOpaqueId.isValid(opaqueId)) return null;
    return CalendarSyncOwnedEvent(opaqueId: opaqueId, eventId: eventId);
  }

  @override
  String toString() =>
      'CalendarSyncOwnedEvent(opaqueId: $opaqueId, eventId: $eventId)';
}

/// 写入系统日历的单个绝对非重复事件（`upsertEventBatch` 入参）。
///
/// 字段集合与原生 `parseEventInput` 严格一致；**没有** studentId / businessKey
/// 字段，私有映射只留在 Dart 侧 ledger。
class CalendarSyncEventDraft {
  const CalendarSyncEventDraft({
    required this.opaqueId,
    required this.title,
    required this.location,
    required this.startMillis,
    required this.endMillis,
    required this.reminderMinutes,
    required this.timeZone,
  });

  final String opaqueId;
  final String title;
  final String location;
  final int startMillis;
  final int endMillis;
  final int reminderMinutes;

  /// IANA 时区 ID（如 `Asia/Shanghai`）；原生会再次校验并拒绝静默回退。
  final String timeZone;

  /// 校验并返回可读原因；合法返回 null。
  String? validate() {
    if (!CalendarSyncOpaqueId.isValid(opaqueId)) {
      return 'opaqueId 不是合法随机标识';
    }
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) return '标题为空';
    if (trimmedTitle.length > CalendarSyncProtocol.maxTitleLength) {
      return '标题超过 ${CalendarSyncProtocol.maxTitleLength} 字符';
    }
    if (location.length > CalendarSyncProtocol.maxLocationLength) {
      return '地点超过 ${CalendarSyncProtocol.maxLocationLength} 字符';
    }
    if (startMillis <= 0) return '开始时间必须为有效毫秒时间戳';
    if (endMillis <= startMillis) return '结束时间必须晚于开始时间';
    if (reminderMinutes < 0 ||
        reminderMinutes > CalendarSyncProtocol.maxReminderMinutes) {
      return '提醒提前量超出 0–${CalendarSyncProtocol.maxReminderMinutes} 分钟';
    }
    if (!isValidTimeZone(timeZone)) return '时区不是可用的 IANA ID';
    return null;
  }

  /// 与原生 `CalendarSyncContract.isValidTimeZone` 等价的本地前置校验；
  /// 原生还会用系统时区库做最终判定。
  static bool isValidTimeZone(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return false;
    if (trimmed.length > CalendarSyncProtocol.maxTimeZoneLength) return false;
    if (RegExp(r'\s').hasMatch(trimmed)) return false;
    return true;
  }

  /// 通道参数：只含协议固定 7 字段，绝不夹带身份或业务键。
  Map<String, Object?> toChannelMap() => <String, Object?>{
    'opaqueId': opaqueId,
    'title': title,
    'location': location,
    'startMillis': startMillis,
    'endMillis': endMillis,
    'reminderMinutes': reminderMinutes,
    'timeZone': timeZone,
  };

  @override
  String toString() =>
      'CalendarSyncEventDraft(opaqueId: $opaqueId, startMillis: $startMillis, '
      'endMillis: $endMillis, reminderMinutes: $reminderMinutes)';
}

/// 本地课程 → 事件的业务计划：只进私有 ledger，绝不传给原生。
class CalendarSyncEventPlan {
  const CalendarSyncEventPlan({
    required this.opaqueId,
    required this.businessKey,
  });

  final String opaqueId;

  /// 业务键（如学期 + 课程 + 周次/节次的本地标识）；不进 provider。
  final String businessKey;

  String? validate() {
    if (!CalendarSyncOpaqueId.isValid(opaqueId)) {
      return 'opaqueId 不是合法随机标识';
    }
    if (businessKey.trim().isEmpty) return 'businessKey 为空';
    if (businessKey.length > CalendarSyncProtocol.maxBusinessKeyLength) {
      return 'businessKey 超过 ${CalendarSyncProtocol.maxBusinessKeyLength} 字符';
    }
    return null;
  }

  @override
  String toString() => 'CalendarSyncEventPlan(opaqueId: $opaqueId)';
}

/// `upsertEventBatch` 结果。
class CalendarSyncBatchResult {
  const CalendarSyncBatchResult({
    required this.insertedCount,
    required this.updatedCount,
    required this.eventIds,
  });

  final int insertedCount;
  final int updatedCount;

  /// opaqueId → provider eventId；协议要求覆盖整批事件。
  final Map<String, int> eventIds;

  int get totalCount => insertedCount + updatedCount;

  bool coversAll(Iterable<String> opaqueIds) {
    for (final opaqueId in opaqueIds) {
      if (!eventIds.containsKey(opaqueId)) return false;
    }
    return true;
  }

  /// 严格解析；计数与映射必须自洽，否则返回 null（由门面转 invalidResponse）。
  static CalendarSyncBatchResult? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final insertedCount = _asNonNegativeInt(raw['insertedCount']);
    final updatedCount = _asNonNegativeInt(raw['updatedCount']);
    final rawEventIds = raw['eventIds'];
    if (insertedCount == null || updatedCount == null) return null;
    if (rawEventIds is! Map) return null;

    final eventIds = <String, int>{};
    for (final entry in rawEventIds.entries) {
      final opaqueId = entry.key;
      final eventId = _asPositiveInt(entry.value);
      if (opaqueId is! String || eventId == null) return null;
      if (!CalendarSyncOpaqueId.isValid(opaqueId)) return null;
      if (eventIds.containsKey(opaqueId)) return null;
      eventIds[opaqueId] = eventId;
    }
    if (eventIds.length != insertedCount + updatedCount) return null;

    return CalendarSyncBatchResult(
      insertedCount: insertedCount,
      updatedCount: updatedCount,
      eventIds: Map<String, int>.unmodifiable(eventIds),
    );
  }

  @override
  String toString() =>
      'CalendarSyncBatchResult(inserted: $insertedCount, '
      'updated: $updatedCount, eventIds: ${eventIds.length})';
}

/// `deleteOwnedEventsByIds` 结果：按 eventId 分类返回，0 行归入未删除。
class CalendarSyncDeleteResult {
  const CalendarSyncDeleteResult({
    required this.deletedIds,
    required this.notDeletedIds,
  });

  final List<int> deletedIds;
  final List<int> notDeletedIds;

  /// 是否全部删除成功；false 时调用方必须保留对应账本项供下次复核。
  bool get isComplete => notDeletedIds.isEmpty;

  static CalendarSyncDeleteResult? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final deletedIds = _asPositiveIntList(raw['deletedIds']);
    final notDeletedIds = _asPositiveIntList(raw['notDeletedIds']);
    if (deletedIds == null || notDeletedIds == null) return null;
    return CalendarSyncDeleteResult(
      deletedIds: List<int>.unmodifiable(deletedIds),
      notDeletedIds: List<int>.unmodifiable(notDeletedIds),
    );
  }

  @override
  String toString() =>
      'CalendarSyncDeleteResult(deleted: ${deletedIds.length}, '
      'notDeleted: ${notDeletedIds.length})';
}

int? _asPositiveInt(Object? value) {
  if (value is! int) return null;
  return value > 0 ? value : null;
}

int? _asNonNegativeInt(Object? value) {
  if (value is! int) return null;
  return value >= 0 ? value : null;
}

List<int>? _asPositiveIntList(Object? value) {
  if (value is! List) return null;
  final result = <int>[];
  for (final item in value) {
    final parsed = _asPositiveInt(item);
    if (parsed == null) return null;
    result.add(parsed);
  }
  return result;
}
