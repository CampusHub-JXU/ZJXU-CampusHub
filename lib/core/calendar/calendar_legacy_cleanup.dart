import 'package:flutter/foundation.dart';

/// 遗留清理（Issue #48）的固定失败 / 原因集；**无任意错误字符串**。
enum CalendarLegacyCleanupFailure {
  /// provider 不可用 / 扫描整体失败。
  providerUnavailable,

  /// READ/WRITE_CALENDAR 未授权或被拒。
  permissionDenied,

  /// 达到行数 / 日历数上限：结论不完整。
  scanLimit,

  /// 命中日历元数据缺失 / 查询失败。
  calendarUnavailable,

  /// 私有账本读写失败。
  ledgerUnavailable,

  /// 私有账本 JSON 损坏（不静默丢弃）。
  ledgerCorrupted,

  /// 有 pending 未能在清理前复核出 eventId。
  pendingUnreconciled,

  /// 用户确认的预览已过期 / 非当前扫描。
  invalidPreview,

  /// 跨 await 期间身份 / 控制态变化，旧结果被拒绝。
  aborted,
}

/// 单个日历的遗留清理只读预览（Issue #48）。
@immutable
class CalendarLegacyCleanupCalendarPreview {
  const CalendarLegacyCleanupCalendarPreview({
    required this.calendarId,
    this.displayName,
    this.writable,
    required this.recordedCount,
    required this.orphanCount,
    required this.ownedCount,
  });

  final int calendarId;

  /// 展示名（已去敏）；未知为 null。
  final String? displayName;

  /// 是否可写；**null 表示未知**（元数据缺失 / 查询失败），此时不得删除。
  final bool? writable;

  /// 账本已记录的自有事件数。
  final int recordedCount;

  /// provider 标记证实但账本未记录的自有事件数（孤儿）。
  final int orphanCount;

  /// 该日历内本 App 自有事件总数（= [recordedCount] 与孤儿之和的下界）。
  final int ownedCount;

  /// 是否可安全删除：**仅**当预览明确证实 `writable == true` 时才为真。
  /// `false`（只读）与 `null`（元数据缺失 / 查询失败，未知）都**不得删除**
  /// （未知需重新核验后才可删除）。
  bool get isDeletable => writable == true;

  @override
  String toString() =>
      'CalendarLegacyCleanupCalendarPreview(calendarId: $calendarId, '
      'recorded: $recordedCount, orphan: $orphanCount, '
      'owned: $ownedCount, writable: $writable)';
}

/// 遗留清理的候选三元组（控制层私有持有；清理会校验预览同一性，
/// 用户无法借伪造的预览删除未扫描事件）。
@immutable
class LegacyCleanupCandidate {
  const LegacyCleanupCandidate({
    required this.calendarId,
    required this.opaqueId,
    required this.eventId,
    required this.recorded,
  });

  final int calendarId;
  final String opaqueId;
  final int eventId;
  final bool recorded;
}

/// 遗留清理只读预览（Issue #48）。
///
/// **不含**任何课程标题 / 学号 / 账号；[candidates] 由控制层持有，
/// `cleanupLegacyOwnedEvents` 只接受与当前扫描**同一对象**的预览。
@immutable
class CalendarLegacyCleanupScan {
  const CalendarLegacyCleanupScan({
    required this.token,
    required this.calendars,
    required this.complete,
    required this.reason,
    required this.totalKnownOwnedCount,
    required this.recordedOrphanCount,
    required this.dismissible,
    required this.candidates,
  });

  /// 代际令牌：与当前控制代际绑定，用户确认时校验。
  final String token;

  final List<CalendarLegacyCleanupCalendarPreview> calendars;

  /// 是否为**完整**扫描（原生完整 + 无降级）。
  final bool complete;

  /// 不完整时的固定原因；完整时为 null。
  final CalendarLegacyCleanupFailure? reason;

  /// 扫描证实存在的自有事件总数（已知下界）。
  final int totalKnownOwnedCount;

  /// 账本未记录、但 provider 标记证实的孤儿事件数。
  final int recordedOrphanCount;

  /// 是否可在无残留时安全 dismiss 回 `off`。
  final bool dismissible;

  /// 候选（控制层持有；不可预览外删除）。
  final List<LegacyCleanupCandidate> candidates;

  bool get isEmpty => calendars.isEmpty;
  bool get hasResidual => totalKnownOwnedCount > 0;

  @override
  String toString() =>
      'CalendarLegacyCleanupScan(token: $token, calendars: ${calendars.length}, '
      'complete: $complete, known: $totalKnownOwnedCount, '
      'orphans: $recordedOrphanCount)';
}

/// 遗留清理结果（Issue #48）。
@immutable
class CalendarLegacyCleanupResult {
  const CalendarLegacyCleanupResult({
    required this.deletedCount,
    required this.residualCount,
    required this.complete,
    required this.failures,
    this.aborted = false,
  });

  /// 已确认删除的条数（按 provider 实查删除的 eventId 计）。
  final int deletedCount;

  /// 删除后复扫仍证实的自有事件数（**已知下界**，非「零即干净」）。
  final int residualCount;

  /// 是否确认清干净（完整复扫 0 残留 + 账本已解决 + 已 drain）。
  final bool complete;

  final Set<CalendarLegacyCleanupFailure> failures;
  final bool aborted;

  @override
  String toString() =>
      'CalendarLegacyCleanupResult(deleted: $deletedCount, '
      'residual: $residualCount, complete: $complete, '
      'failures: ${failures.length}, aborted: $aborted)';
}

/// 把候选按 opaqueId 分轮：每轮内 opaqueId 唯一，满足通道批次约束。
///
/// 与 [CalendarLegacyCleanupResult] 同文件的内部工具（拆分以满足仓库
/// `large_dart_files` ≤ 1600 行规则），**不属于**冻结的清理公开契约；
/// 语义不变：同一 opaqueId 的多条候选被拆到不同轮，绝不合并成一条。
List<List<LegacyCleanupCandidate>> partitionUniqueOpaqueCandidates(
  List<LegacyCleanupCandidate> candidates,
) {
  final rounds = <List<LegacyCleanupCandidate>>[];
  final seenInRound = <String>{};
  var current = <LegacyCleanupCandidate>[];
  for (final candidate in candidates) {
    if (seenInRound.contains(candidate.opaqueId)) {
      rounds.add(current);
      current = <LegacyCleanupCandidate>[];
      seenInRound.clear();
    }
    current.add(candidate);
    seenInRound.add(candidate.opaqueId);
  }
  if (current.isNotEmpty) rounds.add(current);
  return rounds;
}
