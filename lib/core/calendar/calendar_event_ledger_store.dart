import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'calendar_sync_models.dart';

/// 一条「本地课程 → 系统日历事件」的归属记录（仅存 App 私有 ledger）。
///
/// [businessKey] 是本地业务标识（如学期 + 课程 + 周次），只用于重算差量；
/// provider 里只有随机 [opaqueId]。[eventId] 为 null 表示该计划已持久化但
/// 原生批次结果尚未确认（pending），重启后必须按 opaqueId 查询找回。
@immutable
class CalendarEventLedgerEntry {
  const CalendarEventLedgerEntry({
    required this.opaqueId,
    required this.businessKey,
    this.eventId,
  });

  final String opaqueId;
  final String businessKey;
  final int? eventId;

  bool get isPending => eventId == null;

  CalendarEventLedgerEntry withEventId(int value) => CalendarEventLedgerEntry(
    opaqueId: opaqueId,
    businessKey: businessKey,
    eventId: value,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'businessKey': businessKey,
    'eventId': eventId,
  };

  /// 严格解析；opaqueId 非法 / businessKey 为空 / eventId 非正整数都返回 null。
  static CalendarEventLedgerEntry? tryParse(String opaqueId, Object? raw) {
    if (raw is! Map) return null;
    if (!CalendarSyncOpaqueId.isValid(opaqueId)) return null;

    final businessKey = raw['businessKey'];
    if (businessKey is! String || businessKey.trim().isEmpty) return null;
    if (businessKey.length > CalendarSyncProtocol.maxBusinessKeyLength) {
      return null;
    }

    final rawEventId = raw['eventId'];
    int? eventId;
    if (rawEventId != null) {
      if (rawEventId is! int || rawEventId <= 0) return null;
      eventId = rawEventId;
    }

    return CalendarEventLedgerEntry(
      opaqueId: opaqueId,
      businessKey: businessKey,
      eventId: eventId,
    );
  }

  @override
  String toString() =>
      'CalendarEventLedgerEntry(opaqueId: $opaqueId, pending: $isPending)';
}

/// 一次授权/写入批次：同一 [generation] 下的全部计划共享目标日历。
@immutable
class CalendarEventLedgerBatch {
  const CalendarEventLedgerBatch({
    required this.ownerKey,
    required this.generation,
    required this.calendarId,
    required this.createdAt,
    required this.entries,
  });

  final String ownerKey;

  /// 批次随机标识；只有匹配的 generation 才允许登记 eventId。
  final String generation;

  final int calendarId;
  final DateTime createdAt;

  /// opaqueId → 归属记录（保持插入顺序）。
  final Map<String, CalendarEventLedgerEntry> entries;

  int get pendingCount =>
      entries.values.where((entry) => entry.isPending).length;

  int get committedCount => entries.length - pendingCount;

  bool get isEmpty => entries.isEmpty;

  CalendarEventLedgerBatch copyWith({
    Map<String, CalendarEventLedgerEntry>? entries,
  }) => CalendarEventLedgerBatch(
    ownerKey: ownerKey,
    generation: generation,
    calendarId: calendarId,
    createdAt: createdAt,
    entries: entries ?? this.entries,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'generation': generation,
    'calendarId': calendarId,
    'createdAt': createdAt.toIso8601String(),
    'entries': <String, Object?>{
      for (final entry in entries.entries) entry.key: entry.value.toJson(),
    },
  };

  static CalendarEventLedgerBatch? tryParse(String ownerKey, Object? raw) {
    if (raw is! Map) return null;

    final generation = raw['generation'];
    final calendarId = raw['calendarId'];
    final createdAt = DateTime.tryParse(raw['createdAt']?.toString() ?? '');
    final rawEntries = raw['entries'];
    if (generation is! String || generation.isEmpty) return null;
    if (calendarId is! int || calendarId <= 0) return null;
    if (createdAt == null) return null;
    if (rawEntries is! Map) return null;

    final entries = <String, CalendarEventLedgerEntry>{};
    for (final item in rawEntries.entries) {
      final opaqueId = item.key;
      if (opaqueId is! String) return null;
      final entry = CalendarEventLedgerEntry.tryParse(opaqueId, item.value);
      if (entry == null) return null;
      entries[opaqueId] = entry;
    }
    // 空批次没有归属信息；写路径不会产生，出现即视为损坏。
    if (entries.isEmpty) return null;

    return CalendarEventLedgerBatch(
      ownerKey: ownerKey,
      generation: generation,
      calendarId: calendarId,
      createdAt: createdAt,
      entries: Map<String, CalendarEventLedgerEntry>.unmodifiable(entries),
    );
  }

  @override
  String toString() =>
      'CalendarEventLedgerBatch(generation: $generation, calendarId: $calendarId, '
      'entries: ${entries.length}, pending: $pendingCount)';
}

/// 私有账本全量快照：ownerKey → 批次列表（插入序，最后一个为该日历最新批次）。
@immutable
class CalendarEventLedgerSnapshot {
  const CalendarEventLedgerSnapshot({required this.owners});

  static const CalendarEventLedgerSnapshot empty = CalendarEventLedgerSnapshot(
    owners: <String, List<CalendarEventLedgerBatch>>{},
  );

  final Map<String, List<CalendarEventLedgerBatch>> owners;

  List<CalendarEventLedgerBatch> batchesFor(String ownerKey) =>
      owners[ownerKey] ?? const <CalendarEventLedgerBatch>[];

  List<CalendarEventLedgerBatch> get allBatches => <CalendarEventLedgerBatch>[
    for (final batches in owners.values) ...batches,
  ];

  List<CalendarEventLedgerEntry> get allEntries => <CalendarEventLedgerEntry>[
    for (final batch in allBatches) ...batch.entries.values,
  ];

  int get pendingEntryCount =>
      allEntries.where((entry) => entry.isPending).length;

  bool get isEmpty => allBatches.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'v': CalendarEventLedgerStore.schemaVersion,
    'owners': <String, Object?>{
      for (final owner in owners.entries)
        owner.key: <Object?>[for (final batch in owner.value) batch.toJson()],
    },
  };

  /// 严格解析；版本不符、结构异常、空批次都返回 null（由 store 转 typed failure）。
  static CalendarEventLedgerSnapshot? tryParse(Object? raw) {
    if (raw is! Map) return null;
    if (raw['v'] != CalendarEventLedgerStore.schemaVersion) return null;

    final rawOwners = raw['owners'];
    if (rawOwners is! Map) return null;

    final owners = <String, List<CalendarEventLedgerBatch>>{};
    for (final owner in rawOwners.entries) {
      final ownerKey = owner.key;
      if (ownerKey is! String || ownerKey.isEmpty) return null;
      final rawBatches = owner.value;
      if (rawBatches is! List) return null;

      final batches = <CalendarEventLedgerBatch>[];
      final generations = <String>{};
      for (final rawBatch in rawBatches) {
        final batch = CalendarEventLedgerBatch.tryParse(ownerKey, rawBatch);
        if (batch == null) return null;
        if (!generations.add(batch.generation)) return null;
        batches.add(batch);
      }
      if (batches.isEmpty) continue;
      owners[ownerKey] = List<CalendarEventLedgerBatch>.unmodifiable(batches);
    }
    return CalendarEventLedgerSnapshot(
      owners: Map<String, List<CalendarEventLedgerBatch>>.unmodifiable(owners),
    );
  }

  @override
  String toString() =>
      'CalendarEventLedgerSnapshot(owners: ${owners.length}, '
      'batches: ${allBatches.length}, pending: $pendingEntryCount)';
}

/// [CalendarEventLedgerStore.commitBatch] 的判定结果。
enum CalendarEventLedgerCommitStatus {
  committed,

  /// ownerKey 不在账本中（可能已被清理）。
  unknownOwner,

  /// generation 不存在（已被清理或从未持久化）。
  unknownBatch,

  /// 同一 owner + 日历已有更新的批次；旧 generation 的迟到结果被拒绝。
  staleGeneration,
}

/// commit 结果：只有 [status] 为 committed 才允许调用方认为 eventId 已登记。
@immutable
class CalendarEventLedgerCommitResult {
  const CalendarEventLedgerCommitResult({
    required this.status,
    this.appliedOpaqueIds = const <String>[],
    this.unknownOpaqueIds = const <String>[],
  });

  final CalendarEventLedgerCommitStatus status;

  /// 已登记（或幂等重放）的 opaqueId。
  final List<String> appliedOpaqueIds;

  /// 不属于该批次或 eventId 非法的 opaqueId，不写入账本。
  final List<String> unknownOpaqueIds;

  bool get accepted => status == CalendarEventLedgerCommitStatus.committed;

  @override
  String toString() =>
      'CalendarEventLedgerCommitResult(status: ${status.name}, '
      'applied: ${appliedOpaqueIds.length}, unknown: ${unknownOpaqueIds.length})';
}

/// 系统日历事件的私有归属账本。
///
/// 持久化在 SharedPreferences 的**单个固定 JSON key**（[storageKey]），按
/// ownerKey 保留所有账号/授权批次的归属，供换号后暂停同步与关闭时清理。
///
/// 并发模型（重要）：
/// - 同一 isolate 内的所有读改写通过内部串行队列执行，避免整 key
///   read-modify-write 互相覆盖；
/// - **不声明跨 isolate 原子性**：本功能仅前台主 isolate 使用，后台引擎不注册
///   该通道，也没有第二个 isolate 写账本；
/// - 事务顺序由调用方保证：`beginPendingBatch`（先持久化随机 opaqueId +
///   businessKey + generation + calendarId）→ 原生 batch → `commitBatch`
///   （只在 generation 匹配时登记 eventId）。失败/拒绝时 pending 一律保留，
///   重启后用 `queryOwnedEvents` 按 opaqueId 找回。
///
/// 损坏处理：JSON 无法解析或结构不符合协议时抛
/// [CalendarSyncFailureKind.ledgerCorrupted]，**不删除也不覆盖**原值；
/// 只有显式 [clearAll] 才清空。停用同步 / 登出 / 换号都不得调用 [clearAll]，
/// 否则会丢失原账号事件的归属，导致之后无法清理。
class CalendarEventLedgerStore {
  CalendarEventLedgerStore._();

  static final CalendarEventLedgerStore instance = CalendarEventLedgerStore._();

  /// 固定单 JSON storage key（同 isolate 串行；见类注释）。
  static const String storageKey = 'calendar_event_ledger_v1';
  static const int schemaVersion = 1;

  CalendarEventLedgerSnapshot _snapshot = CalendarEventLedgerSnapshot.empty;
  bool _loaded = false;
  Future<void> _queueTail = Future<void>.value();

  /// 当前内存镜像；未 [reload] 时为空快照。
  CalendarEventLedgerSnapshot get snapshot => _snapshot;

  bool get isLoaded => _loaded;

  /// 全部 owner（换号后仍保留，用于关闭同步时遍历清理）。
  List<String> get ownerKeys =>
      List<String>.unmodifiable(_snapshot.owners.keys);

  /// 测试专用：创建独立实例，避免共享单例内存态。
  @visibleForTesting
  static CalendarEventLedgerStore debugNew() => CalendarEventLedgerStore._();

  /// 测试专用：清空内存态（不动磁盘，磁盘由
  /// `SharedPreferences.setMockInitialValues` 重置）。不得在操作在途时调用。
  @visibleForTesting
  void debugReset() {
    _snapshot = CalendarEventLedgerSnapshot.empty;
    _loaded = false;
    _queueTail = Future<void>.value();
  }

  // ── 读路径 ──────────────────────────────────────────────────────────

  /// 重新读盘并刷新内存镜像（冷启动 / 回前台 / 恢复 pending 批次）。
  ///
  /// 解析失败抛 `ledgerCorrupted`，磁盘原值保留。
  Future<CalendarEventLedgerSnapshot> reload() => _serialize(() async {
    final prefs = await SharedPreferences.getInstance();
    await _reloadPreferences(prefs);
    _snapshot = _decode(prefs.getString(storageKey));
    _loaded = true;
    return _snapshot;
  });

  /// 某日历当前可写的批次（该 owner + calendarId 最新创建的一个）；
  /// 没有则返回 null。调用前应先 [reload]。
  CalendarEventLedgerBatch? activeBatch({
    required String ownerKey,
    required int calendarId,
  }) {
    final batches = _snapshot.owners[ownerKey];
    if (batches == null) return null;
    for (final batch in batches.reversed) {
      if (batch.calendarId == calendarId) return batch;
    }
    return null;
  }

  /// 某 owner 的全部归属记录（含 pending 与其他日历）。
  List<CalendarEventLedgerEntry> entriesForOwner(
    String ownerKey,
  ) => <CalendarEventLedgerEntry>[
    for (final batch in _snapshot.batchesFor(ownerKey)) ...batch.entries.values,
  ];

  /// 按业务键查归属（差量重算用）；同键多批次时返回最新批次中的一条。
  CalendarEventLedgerEntry? entryForBusinessKey({
    required String ownerKey,
    required String businessKey,
  }) {
    final batches = _snapshot.batchesFor(ownerKey);
    for (final batch in batches.reversed) {
      for (final entry in batch.entries.values) {
        if (entry.businessKey == businessKey) return entry;
      }
    }
    return null;
  }

  // ── 写路径 ──────────────────────────────────────────────────────────

  /// 持久化一批 pending 计划并返回批次（含 generation）。
  ///
  /// 返回前一定已经写盘：只有拿到批次对象后，调用方才允许发起原生
  /// `upsertEventBatch`。同一 owner + 日历再次调用会创建新批次并使其成为
  /// 当前批次，旧 generation 的迟到结果将被 [commitBatch] 拒绝。
  Future<CalendarEventLedgerBatch> beginPendingBatch({
    required String ownerKey,
    required int calendarId,
    required List<CalendarSyncEventPlan> plans,
    String? generation,
    DateTime? now,
  }) => _serialize(() async {
    await _ensureLoadedLocked();
    _validateOwnerKey(ownerKey);
    if (calendarId <= 0) {
      throw CalendarSyncException.invalidArgument('calendarId 必须为正整数');
    }
    if (plans.isEmpty) {
      throw CalendarSyncException.invalidArgument('批次至少需要一个事件计划');
    }
    if (plans.length > CalendarSyncProtocol.maxBatchEvents) {
      throw CalendarSyncException.invalidArgument(
        '批次计划数超过 ${CalendarSyncProtocol.maxBatchEvents}',
      );
    }

    final entries = <String, CalendarEventLedgerEntry>{};
    for (final plan in plans) {
      final reason = plan.validate();
      if (reason != null) {
        throw CalendarSyncException.invalidArgument('事件计划非法：$reason');
      }
      if (entries.containsKey(plan.opaqueId)) {
        throw CalendarSyncException.invalidArgument('批次内 opaqueId 重复');
      }
      if (_findEntry(plan.opaqueId) != null) {
        throw CalendarSyncException.invalidArgument('opaqueId 已存在账本，不能重复建立归属');
      }
      entries[plan.opaqueId] = CalendarEventLedgerEntry(
        opaqueId: plan.opaqueId,
        businessKey: plan.businessKey,
      );
    }

    final resolvedGeneration = generation == null
        ? CalendarSyncOpaqueId.generate()
        : generation.trim();
    if (resolvedGeneration.isEmpty) {
      throw CalendarSyncException.invalidArgument('generation 不能为空');
    }
    if (_findBatch(ownerKey, resolvedGeneration) != null) {
      throw CalendarSyncException.invalidArgument('generation 已存在');
    }

    final batch = CalendarEventLedgerBatch(
      ownerKey: ownerKey,
      generation: resolvedGeneration,
      calendarId: calendarId,
      createdAt: now ?? DateTime.now(),
      entries: Map<String, CalendarEventLedgerEntry>.unmodifiable(entries),
    );

    final owners = _copyOwners();
    owners[ownerKey] = <CalendarEventLedgerBatch>[
      ...owners[ownerKey] ?? const <CalendarEventLedgerBatch>[],
      batch,
    ];
    await _persistLocked(CalendarEventLedgerSnapshot(owners: owners));
    return batch;
  });

  /// 登记原生批次返回的 eventIds。
  ///
  /// 只有该 generation 仍是所属 owner + 日历的当前批次时才接受；否则返回
  /// [CalendarEventLedgerCommitStatus.staleGeneration] /
  /// [CalendarEventLedgerCommitStatus.unknownBatch]，**绝不写入**。未知
  /// opaqueId 与非法 eventId 不写入并归入 `unknownOpaqueIds`。
  Future<CalendarEventLedgerCommitResult> commitBatch({
    required String ownerKey,
    required String generation,
    required Map<String, int> eventIds,
  }) => _serialize(() async {
    await _ensureLoadedLocked();

    final batches = _snapshot.owners[ownerKey];
    if (batches == null || batches.isEmpty) {
      return const CalendarEventLedgerCommitResult(
        status: CalendarEventLedgerCommitStatus.unknownOwner,
      );
    }
    final index = batches.indexWhere((batch) => batch.generation == generation);
    if (index < 0) {
      return const CalendarEventLedgerCommitResult(
        status: CalendarEventLedgerCommitStatus.unknownBatch,
      );
    }

    final batch = batches[index];
    final currentBatch = activeBatch(
      ownerKey: ownerKey,
      calendarId: batch.calendarId,
    );
    if (!identical(currentBatch, batch)) {
      return const CalendarEventLedgerCommitResult(
        status: CalendarEventLedgerCommitStatus.staleGeneration,
      );
    }

    final applied = <String>[];
    final unknown = <String>[];
    final nextEntries = Map<String, CalendarEventLedgerEntry>.of(batch.entries);
    var changed = false;
    for (final item in eventIds.entries) {
      final entry = nextEntries[item.key];
      if (entry == null || item.value <= 0) {
        unknown.add(item.key);
        continue;
      }
      if (entry.eventId != item.value) {
        nextEntries[item.key] = entry.withEventId(item.value);
        changed = true;
      }
      applied.add(item.key);
    }

    if (changed) {
      final owners = _copyOwners();
      final updatedBatches = <CalendarEventLedgerBatch>[...owners[ownerKey]!];
      updatedBatches[index] = batch.copyWith(
        entries: Map<String, CalendarEventLedgerEntry>.unmodifiable(
          nextEntries,
        ),
      );
      owners[ownerKey] = updatedBatches;
      await _persistLocked(CalendarEventLedgerSnapshot(owners: owners));
    }

    return CalendarEventLedgerCommitResult(
      status: CalendarEventLedgerCommitStatus.committed,
      appliedOpaqueIds: List<String>.unmodifiable(applied),
      unknownOpaqueIds: List<String>.unmodifiable(unknown),
    );
  });

  /// 把原生 `queryOwnedEvents` 已核验的 opaqueId → eventId 写回**其原批次**。
  ///
  /// 只用于崩溃恢复 / 关闭清理前的 pending 补记（阶段 2 的受约束恢复路径）：
  /// - **不检查 activeBatch**，因此对旧 generation 批次同样生效；
  /// - **不晋升 active**，不改变批次顺序，不放宽 [commitBatch] 的迟到结果守卫；
  /// - 只更新目标批次中**当前仍为 pending** 的项；已提交且 eventId 不同的项
  ///   不会被覆盖（provider 查询只针对 pending，正常不会出现）；
  /// - 未知 owner / generation / opaqueId 一律忽略并返回 0（幂等）。
  ///
  /// 返回实际写回的条数；调用方必须只在拿到真实 provider 查询结果后才调用。
  Future<int> recordRecoveredIds({
    required String ownerKey,
    required String generation,
    required Map<String, int> eventIds,
  }) => _serialize(() async {
    await _ensureLoadedLocked();
    if (eventIds.isEmpty) return 0;

    final owners = _copyOwners();
    final batches = owners[ownerKey];
    if (batches == null) return 0;
    final index = batches.indexWhere((batch) => batch.generation == generation);
    if (index < 0) return 0;

    final batch = batches[index];
    final nextEntries = Map<String, CalendarEventLedgerEntry>.of(batch.entries);
    var recovered = 0;
    for (final item in eventIds.entries) {
      if (item.value <= 0) continue;
      final entry = nextEntries[item.key];
      if (entry == null) continue;
      // 已提交且 eventId 不同：不覆盖既有归属。
      if (!entry.isPending) continue;
      nextEntries[item.key] = entry.withEventId(item.value);
      recovered++;
    }
    if (recovered == 0) return 0;

    final updatedBatches = <CalendarEventLedgerBatch>[...batches];
    updatedBatches[index] = batch.copyWith(
      entries: Map<String, CalendarEventLedgerEntry>.unmodifiable(nextEntries),
    );
    owners[ownerKey] = updatedBatches;
    await _persistLocked(CalendarEventLedgerSnapshot(owners: owners));
    return recovered;
  });

  /// 受约束地把已提交事件的原 eventId 重绑定为 provider 实查的新 eventId。
  ///
  /// 仅用于「同 opaqueId 的事件被系统删除后又以新 id 重建」：原生 upsert 返回了
  /// 新 eventId，而账本仍存旧 id，若不回写会导致关闭清理残留。
  ///
  /// 约束（CAS）：必须同时满足 owner + generation + opaqueId，且该条当前
  /// eventId 恰为 [expectedOldEventId]，才写入 [providerVerifiedNewEventId]；
  /// 任一不符返回 false，调用方必须 fail closed。不晋升 active、不改批次顺序、
  /// 不放宽 [commitBatch] 守卫。
  Future<bool> reassignEventId({
    required String ownerKey,
    required String generation,
    required String opaqueId,
    required int expectedOldEventId,
    required int providerVerifiedNewEventId,
  }) => _serialize(() async {
    await _ensureLoadedLocked();
    if (expectedOldEventId <= 0 || providerVerifiedNewEventId <= 0) {
      return false;
    }
    if (expectedOldEventId == providerVerifiedNewEventId) return true;

    final owners = _copyOwners();
    final batches = owners[ownerKey];
    if (batches == null) return false;
    final index = batches.indexWhere((batch) => batch.generation == generation);
    if (index < 0) return false;

    final batch = batches[index];
    final entry = batch.entries[opaqueId];
    if (entry == null) return false;
    if (entry.eventId != expectedOldEventId) return false;

    final nextEntries = Map<String, CalendarEventLedgerEntry>.of(batch.entries);
    nextEntries[opaqueId] = entry.withEventId(providerVerifiedNewEventId);
    final updatedBatches = <CalendarEventLedgerBatch>[...batches];
    updatedBatches[index] = batch.copyWith(
      entries: Map<String, CalendarEventLedgerEntry>.unmodifiable(nextEntries),
    );
    owners[ownerKey] = updatedBatches;
    await _persistLocked(CalendarEventLedgerSnapshot(owners: owners));
    return true;
  });

  /// 逐项移除已确认清理成功的归属（删除成功的 eventId 对应项）。
  ///
  /// 只移除 [opaqueIds] 中的项；失败/未确认的项保留在账本里供下次复核。
  /// 批次清空后自动移除，owner 不再有批次时自动移除；返回移除条数。
  /// 未知 generation 返回 0（幂等），不抛错。
  Future<int> removeEntries({
    required String ownerKey,
    required String generation,
    required Iterable<String> opaqueIds,
  }) => _serialize(() async {
    await _ensureLoadedLocked();
    final removedIds = opaqueIds.toSet();
    if (removedIds.isEmpty) return 0;

    final owners = _copyOwners();
    final batches = owners[ownerKey];
    if (batches == null) return 0;
    final index = batches.indexWhere((batch) => batch.generation == generation);
    if (index < 0) return 0;

    final batch = batches[index];
    final nextEntries = Map<String, CalendarEventLedgerEntry>.of(batch.entries)
      ..removeWhere((opaqueId, _) => removedIds.contains(opaqueId));
    final removedCount = batch.entries.length - nextEntries.length;
    if (removedCount == 0) return 0;

    final updatedBatches = <CalendarEventLedgerBatch>[...batches];
    if (nextEntries.isEmpty) {
      updatedBatches.removeAt(index);
    } else {
      updatedBatches[index] = batch.copyWith(
        entries: Map<String, CalendarEventLedgerEntry>.unmodifiable(
          nextEntries,
        ),
      );
    }
    if (updatedBatches.isEmpty) {
      owners.remove(ownerKey);
    } else {
      owners[ownerKey] = updatedBatches;
    }
    await _persistLocked(CalendarEventLedgerSnapshot(owners: owners));
    return removedCount;
  });

  /// 显式清空整个账本（含磁盘 key）。
  ///
  /// 仅限两种场景：用户明确重置日历同步、或账本损坏且用户确认重建。
  /// 停用同步 / 登出 / 换账号一律不得调用（会丢失原账号事件归属）。
  Future<void> clearAll() => _serialize(() async {
    final prefs = await SharedPreferences.getInstance();
    final existed = prefs.containsKey(storageKey);
    final removed = await prefs.remove(storageKey);
    if (existed && !removed) {
      throw CalendarSyncException.ledgerUnavailable('日历账本清除失败');
    }
    _snapshot = CalendarEventLedgerSnapshot.empty;
    _loaded = true;
  });

  // ── 内部 ────────────────────────────────────────────────────────────

  /// 同 isolate 串行队列：整 key read-modify-write 不互相覆盖。
  Future<T> _serialize<T>(Future<T> Function() action) {
    final previous = _queueTail;
    final result = previous.then<T>((_) => action());
    _queueTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _ensureLoadedLocked() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    await _reloadPreferences(prefs);
    _snapshot = _decode(prefs.getString(storageKey));
    _loaded = true;
  }

  Future<void> _reloadPreferences(SharedPreferences prefs) async {
    try {
      await prefs.reload();
    } on Exception catch (error) {
      throw CalendarSyncException.ledgerUnavailable('日历账本读取失败', cause: error);
    }
  }

  Future<void> _persistLocked(CalendarEventLedgerSnapshot next) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(next.toJson());
    final written = await prefs.setString(storageKey, encoded);
    if (!written) {
      throw CalendarSyncException.ledgerUnavailable('日历账本写入未确认');
    }
    _snapshot = next;
  }

  CalendarEventLedgerSnapshot _decode(String? raw) {
    if (raw == null || raw.isEmpty) return CalendarEventLedgerSnapshot.empty;

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (error) {
      throw CalendarSyncException.ledgerCorrupted(
        '日历账本 JSON 无法解析（原值保留，需显式重置）',
        cause: error,
      );
    }
    final snapshot = CalendarEventLedgerSnapshot.tryParse(decoded);
    if (snapshot == null) {
      throw CalendarSyncException.ledgerCorrupted('日历账本结构不符合协议（原值保留，需显式重置）');
    }
    return snapshot;
  }

  Map<String, List<CalendarEventLedgerBatch>> _copyOwners() =>
      <String, List<CalendarEventLedgerBatch>>{
        for (final owner in _snapshot.owners.entries)
          owner.key: List<CalendarEventLedgerBatch>.of(owner.value),
      };

  CalendarEventLedgerBatch? _findBatch(String ownerKey, String generation) {
    for (final batch in _snapshot.batchesFor(ownerKey)) {
      if (batch.generation == generation) return batch;
    }
    return null;
  }

  CalendarEventLedgerEntry? _findEntry(String opaqueId) {
    for (final batch in _snapshot.allBatches) {
      final entry = batch.entries[opaqueId];
      if (entry != null) return entry;
    }
    return null;
  }

  static void _validateOwnerKey(String ownerKey) {
    if (ownerKey.trim().isEmpty) {
      throw CalendarSyncException.invalidArgument('ownerKey 不能为空');
    }
  }
}
