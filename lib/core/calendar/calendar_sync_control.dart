import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_logger.dart';
import 'calendar_event_ledger_store.dart';
import 'calendar_sync_channel.dart';
import 'calendar_sync_models.dart';

/// 系统日历同步的控制状态。
///
/// - [off]：默认；未绑定任何 owner，不允许写入。
/// - [enabled]：已由用户显式开启，绑定一个已验证正方 owner + 目标日历。
/// - [paused]：原 owner 的账本保留，但当前身份不是绑定 owner（登出/换号），
///   停止一切写入；同账号重登或重新显式 [CalendarSyncControl.enable] 才恢复。
/// - [cleanupPending]：用户已要求关闭并清理，未来写入被阻断；仍有删不掉/权限
///   拒绝/日历被移的事件残留，等待用户再次触发清理。绝不以清空账本假装完成。
enum CalendarSyncControlState { off, enabled, paused, cleanupPending }

/// 持久化的控制绑定：状态 + 已验证 owner + 目标日历。
///
/// 只存 owner 标识与日历 id，**不存任何凭据**（密码 / cookie / token 都不在此）。
@immutable
class CalendarSyncControlBinding {
  const CalendarSyncControlBinding({
    required this.state,
    this.ownerKey,
    this.calendarId,
  });

  static const CalendarSyncControlBinding off = CalendarSyncControlBinding(
    state: CalendarSyncControlState.off,
  );

  final CalendarSyncControlState state;

  /// 绑定 owner（私有的已验证正方学号标识）；[off] 时为 null。
  final String? ownerKey;

  /// 绑定目标日历 id；[off] 时为 null。
  final int? calendarId;

  bool get isValid {
    if (state == CalendarSyncControlState.off) {
      return ownerKey == null && calendarId == null;
    }
    return ownerKey != null &&
        ownerKey!.trim().isNotEmpty &&
        calendarId != null &&
        calendarId! > 0;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'v': CalendarSyncControlStore.schemaVersion,
    'state': state.name,
    'ownerKey': ownerKey,
    'calendarId': calendarId,
  };

  /// 严格解析；版本/结构不符返回 null（由 store 失败关闭为 off）。
  static CalendarSyncControlBinding? tryParse(Object? raw) {
    if (raw is! Map) return null;
    if (raw['v'] != CalendarSyncControlStore.schemaVersion) return null;

    final rawState = raw['state'];
    if (rawState is! String) return null;
    CalendarSyncControlState? state;
    for (final value in CalendarSyncControlState.values) {
      if (value.name == rawState) {
        state = value;
        break;
      }
    }
    if (state == null) return null;

    final rawOwner = raw['ownerKey'];
    if (rawOwner != null && rawOwner is! String) return null;
    final ownerKey = rawOwner is String && rawOwner.trim().isNotEmpty
        ? rawOwner.trim()
        : null;

    final rawCalendarId = raw['calendarId'];
    if (rawCalendarId != null && rawCalendarId is! int) return null;
    final calendarId = rawCalendarId is int && rawCalendarId > 0
        ? rawCalendarId
        : null;

    final binding = CalendarSyncControlBinding(
      state: state,
      ownerKey: ownerKey,
      calendarId: calendarId,
    );
    return binding.isValid ? binding : null;
  }

  @override
  String toString() =>
      'CalendarSyncControlBinding(state: ${state.name}, '
      'calendarId: $calendarId)';
}

/// 控制态持久化抽象，便于测试注入可控 store（内存/可阻塞）。
///
/// 生产实现为 [CalendarSyncControlStore]（单 JSON key）。
abstract interface class CalendarSyncStateStore {
  Future<CalendarSyncControlBinding> read();
  Future<void> write(CalendarSyncControlBinding binding);
  Future<void> clear();
}

/// 控制状态的单 JSON key 持久化（同 isolate 串行；仅前台主 isolate 使用）。
///
/// 损坏时**失败关闭为 [CalendarSyncControlBinding.off]**（不写入、不删原值），
/// 因为控制态不是事件归属数据；真正的归属账本由
/// [CalendarEventLedgerStore] 独立持久化且绝不静默丢弃。
class CalendarSyncControlStore implements CalendarSyncStateStore {
  CalendarSyncControlStore._();

  static final CalendarSyncControlStore instance = CalendarSyncControlStore._();

  static const String storageKey = 'calendar_sync_control_v1';
  static const int schemaVersion = 1;

  @visibleForTesting
  static CalendarSyncControlStore debugNew() => CalendarSyncControlStore._();

  /// 读盘；空值 / 损坏一律返回 [CalendarSyncControlBinding.off]（失败关闭）。
  @override
  Future<CalendarSyncControlBinding> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return CalendarSyncControlBinding.off;

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      AppLogger.instance.warn('日历同步控制状态 JSON 损坏，失败关闭为 off（原值保留）');
      return CalendarSyncControlBinding.off;
    }
    final binding = CalendarSyncControlBinding.tryParse(decoded);
    if (binding == null) {
      AppLogger.instance.warn('日历同步控制状态结构不符合协议，失败关闭为 off（原值保留）');
      return CalendarSyncControlBinding.off;
    }
    return binding;
  }

  @override
  Future<void> write(CalendarSyncControlBinding binding) async {
    assert(binding.isValid);
    final prefs = await SharedPreferences.getInstance();
    final written = await prefs.setString(
      storageKey,
      jsonEncode(binding.toJson()),
    );
    if (!written) {
      throw CalendarSyncException.ledgerUnavailable('日历同步控制状态写入未确认');
    }
  }

  /// 显式清除控制态（仅 [CalendarSyncControl] 在清理完成或重置时调用）。
  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    final existed = prefs.containsKey(storageKey);
    final removed = await prefs.remove(storageKey);
    if (existed && !removed) {
      throw CalendarSyncException.ledgerUnavailable('日历同步控制状态清除失败');
    }
  }
}

/// [CalendarSyncControl.enable] 的结果。
@immutable
class CalendarSyncEnableResult {
  const CalendarSyncEnableResult({
    required this.enabled,
    required this.state,
    this.calendarId,
    this.failure,
    this.blockedByCleanup = false,
  });

  final bool enabled;
  final CalendarSyncControlState state;
  final int? calendarId;
  final CalendarSyncException? failure;

  /// 因存在未完成的清理（[CalendarSyncControlState.cleanupPending]）被拒绝：
  /// 必须先完成残留清理，不允许覆盖绑定。
  final bool blockedByCleanup;

  bool get isSuccess => enabled;
}

/// [CalendarSyncControl.reconcilePending] 的结果。
@immutable
class CalendarSyncReconcileResult {
  const CalendarSyncReconcileResult({
    required this.reconciledCount,
    required this.pendingRemaining,
    this.failureKind,
    this.aborted = false,
  });

  /// 本次真正写回账本的 pending 项数（仅来自 provider 查询结果）。
  final int reconciledCount;

  /// 复核后仍为 pending 的项数（失败/无权限时不会减少）。
  final int pendingRemaining;

  /// 首个失败类别；null 表示本次未遇到异常。
  final CalendarSyncFailureKind? failureKind;

  /// 身份 revision 在跨 await 期间变化，旧结果被拒绝（未写账本）。
  final bool aborted;

  bool get hasFailure => failureKind != null;
  bool get isComplete =>
      !aborted && failureKind == null && pendingRemaining == 0;
}

/// 清理残留原因（供 UI 展示数量，不打印学号）。
enum CalendarSyncCleanupResidualReason {
  /// 原生返回 notDeleted（0 行 / 已被用户移动等）。
  notDeleted,

  /// READ/WRITE_CALENDAR 未授权或申请被拒。
  permissionDenied,

  /// 批次目标日历不可用（被删 / 被移）。
  calendarUnavailable,

  /// 其他平台/账本异常。
  platformFailure,

  /// pending 未能在关闭前复核出 eventId，无法安全删除。
  pendingUnreconciled,
}

/// [CalendarSyncControl.disableAndCleanup] 的结果。
@immutable
class CalendarSyncCleanupResult {
  const CalendarSyncCleanupResult({
    required this.deletedCount,
    required this.residualCount,
    required this.failedBatchCount,
    required this.residualReasons,
    this.failureKind,
    this.aborted = false,
  });

  /// 已确认删除并从账本移除的条数。
  final int deletedCount;

  /// 账本中仍保留的条数（含 pending 与删不掉项）；UI 显示该残留数量。
  final int residualCount;

  final int failedBatchCount;
  final Set<CalendarSyncCleanupResidualReason> residualReasons;
  final CalendarSyncFailureKind? failureKind;
  final bool aborted;

  bool get hasResidual => residualCount > 0;
  bool get isComplete => !aborted && failureKind == null && residualCount == 0;
}

/// 系统日历同步的核心控制状态机（core-only，不依赖 features/app）。
///
/// 职责：
/// - 默认 [CalendarSyncControlState.off]，零写入；
/// - 显式 [enable]：检查/申请权限、解析目标日历（用户选择或本 App 本地日历），
///   持久 owner + calendar 绑定与状态；
/// - [pauseIfOwnerMismatch]：登出/换号暂停并保留全部旧账本；同账号重登不暂停，
///   但推进内部 generation 使跨 await 的旧 revision 结果失效；
/// - [reconcilePending]：对**全部** owner / 批次的 pending 用
///   [CalendarSyncChannel.queryOwnedEvents] 找回 eventId，只经
///   [CalendarEventLedgerStore.recordRecoveredIds] 写回其原批次，不晋升 active；
/// - [disableAndCleanup]：先阻断未来写入，再遍历全部 owner / 日历批次（含旧账号
///   与 pending）逐项删除本 App 事件；只对确认删除的项 `removeEntries`，
///   其余保留并汇总残留原因；绝不 `clearAll` 假装完成。
///
/// 并发模型（同 isolate，linearizable）：
/// - 所有「读取 + 修改 + 持久化」的状态转移都在单条 [_serialize] Future 队列的
///   临界区内完成。原生 provider / 权限调用在临界区**之外**执行，但其结果必须
///   再次进入临界区做 generation + state 校验后才提交；因此不存在
///   「先检查 generation、再 await 写盘」的窗口——检查与写盘是同一临界区。
/// - 进入 [disableAndCleanup] 阻断阶段即原子地推进 generation 并持久化
///   `cleanupPending`，任何在途 `enable` 的迟到 `store.write` 都会因校验失败被
///   拒绝，不会覆盖已开始的禁用。
/// - [cleanupPending] 期间 [enable] 一律拒绝（绑定与残留账本保留），必须先完成
///   清理回到 [off] 才能重新开启。
/// - 本类不读取任何凭据，也不在后台/自动登录路径调用。
class CalendarSyncControl extends ChangeNotifier {
  /// 生产单例：默认 MethodChannel 门面 + 共享账本 + 共享控制态。
  CalendarSyncControl._production()
    : _channel = defaultCalendarSyncChannel,
      _ledger = CalendarEventLedgerStore.instance,
      _store = CalendarSyncControlStore.instance;

  /// 测试/注入构造：可替换 channel、账本与控制态存储。
  CalendarSyncControl._(this._channel, this._ledger, this._store);

  @visibleForTesting
  static CalendarSyncControl debugNew({
    required CalendarSyncChannel channel,
    required CalendarEventLedgerStore ledger,
    required CalendarSyncStateStore store,
  }) => CalendarSyncControl._(channel, ledger, store);

  static final CalendarSyncControl instance = CalendarSyncControl._production();

  final CalendarSyncChannel _channel;
  final CalendarEventLedgerStore _ledger;
  final CalendarSyncStateStore _store;

  CalendarSyncControlState _state = CalendarSyncControlState.off;
  String? _ownerKey;
  int? _calendarId;
  bool _loaded = false;

  /// 当前已验证会话的身份修订号（由协调器经 [pauseIfOwnerMismatch] 同步）。
  int _sessionRevision = 0;

  /// 内部操作代际：状态/身份变化即自增，跨 await 的旧结果据此被拒绝。
  int _generation = 0;

  /// 同 isolate 串行队列：状态 read/modify/write 与 store 持久化在临界区内完成。
  Future<void> _queueTail = Future<void>.value();

  CalendarSyncControlState get state => _state;
  String? get ownerKey => _ownerKey;
  int? get calendarId => _calendarId;
  int get sessionRevision => _sessionRevision;

  bool get isEnabled => _state == CalendarSyncControlState.enabled;

  /// 协调器是否允许发起新的日历写入：仅 [enabled] 为 true。
  bool get isWritable => isEnabled;

  /// 当前身份是否就是已授权可写的 owner + revision。
  bool canWriteFor({required String ownerKey, required int revision}) =>
      isEnabled && _ownerKey == ownerKey.trim() && revision == _sessionRevision;

  /// 测试专用：清空内存态（不动磁盘，磁盘由 mock prefs 重置）。
  @visibleForTesting
  void debugReset() {
    _state = CalendarSyncControlState.off;
    _ownerKey = null;
    _calendarId = null;
    _loaded = false;
    _sessionRevision = 0;
    _generation++;
    _queueTail = Future<void>.value();
  }

  /// 冷启动 / 回前台：从磁盘恢复绑定状态（不触发权限或 provider 调用）。
  Future<void> load() => _serialize(_ensureLoadedLocked);

  /// 当前账本残留条数（含 pending 与删不掉项），供设置页展示；
  /// 只读账本，不触发任何 CalendarProvider 调用。账本损坏时抛
  /// [CalendarSyncException]，调用方按失败展示，不得当作「已清干净」。
  Future<int> residualCount() => _serialize(() async {
    await _ensureLoadedLocked();
    return (await _ledger.reload()).allEntries.length;
  });

  /// 用户显式开启同步。
  ///
  /// [ownerKey] 必须是已验证的正方学号标识（协调器负责校验，非空即接受）。
  /// [calendarId] 为用户选择的目标日历；为 null 时使用本 App 专属本地日历
  /// （[CalendarSyncChannel.createOrGetLocalCalendar]）。权限拒绝 / 平台失败 /
  /// 非法参数都不会改变已有状态；[CalendarSyncControlState.cleanupPending]
  /// 期间一律拒绝（[CalendarSyncEnableResult.blockedByCleanup]）。
  Future<CalendarSyncEnableResult> enable({
    required String ownerKey,
    int? calendarId,
    int revision = 0,
  }) async {
    await _serialize(_ensureLoadedLocked);

    final trimmedOwner = ownerKey.trim();
    if (trimmedOwner.isEmpty) {
      return _enableFailure(
        CalendarSyncException.invalidArgument('ownerKey 不能为空'),
      );
    }
    if (calendarId != null && calendarId <= 0) {
      return _enableFailure(
        CalendarSyncException.invalidArgument('calendarId 必须为正整数'),
      );
    }

    // 原子预检：cleanupPending 期间不得覆盖绑定，先完成清理。
    final precheck = await _serialize(() async {
      await _ensureLoadedLocked();
      return (
        generation: _generation,
        blocked: _state == CalendarSyncControlState.cleanupPending,
      );
    });
    if (precheck.blocked) return _blockedByCleanupResult();
    final captured = precheck.generation;

    // 权限弹窗 / 本地日历解析在临界区外；结果提交前必须重新校验。
    final granted = await _ensurePermission();
    if (_generation != captured) {
      return _enableFailure(
        CalendarSyncException.invalidArgument('开启请求已被新的身份变更取代'),
      );
    }
    if (!granted) {
      return _enableFailure(
        CalendarSyncException(
          kind: CalendarSyncFailureKind.permissionDenied,
          message: '日历读写权限未授予，同步未开启',
        ),
      );
    }

    int resolvedCalendarId;
    if (calendarId != null) {
      resolvedCalendarId = calendarId;
    } else {
      try {
        final local = await _channel.createOrGetLocalCalendar();
        resolvedCalendarId = local.id;
      } on CalendarSyncException catch (error) {
        return _enableFailure(error);
      }
    }

    // 提交：generation 校验 + state 校验 + store.write 在同一临界区内原子完成，
    // 迟到的写不会绕过已开始的 disable。
    final result = await _serialize(() async {
      await _ensureLoadedLocked();
      if (_generation != captured) {
        return _enableFailure(
          CalendarSyncException.invalidArgument('开启请求已被新的身份变更取代'),
        );
      }
      if (_state == CalendarSyncControlState.cleanupPending) {
        return _blockedByCleanupResult();
      }
      try {
        await _store.write(
          CalendarSyncControlBinding(
            state: CalendarSyncControlState.enabled,
            ownerKey: trimmedOwner,
            calendarId: resolvedCalendarId,
          ),
        );
      } on CalendarSyncException catch (error) {
        return _enableFailure(error);
      }
      _state = CalendarSyncControlState.enabled;
      _ownerKey = trimmedOwner;
      _calendarId = resolvedCalendarId;
      _sessionRevision = revision;
      _generation++;
      return CalendarSyncEnableResult(
        enabled: true,
        state: CalendarSyncControlState.enabled,
        calendarId: resolvedCalendarId,
      );
    });

    if (result.enabled) notifyListeners();
    return result;
  }

  /// 根据当前身份同步控制状态（登出 / 换号 / 同账号重登 / 回前台）。
  ///
  /// - [ownerKey] 为 null（登出）或与绑定 owner 不同（换号）：[enabled] → [paused]，
  ///   保留全部旧账本，不删任何事件；
  /// - 与绑定 owner 相同：不暂停；[paused] 恢复为 [enabled]（同账号重登）；
  /// - 无论是否改变状态，只要 owner/revision 与内部记录不同就推进 generation，
  ///   使跨 await 的旧 revision 写结果被拒绝（不污染新状态）；
  /// - [cleanupPending] 不会被自动恢复，也不因身份变化而取消进行中的清理。
  ///
  /// 整个状态转移在串行临界区内原子完成，与 [enable] 的提交互斥。
  Future<CalendarSyncControlState> pauseIfOwnerMismatch({
    required String? ownerKey,
    required int revision,
  }) => _serialize(() async {
    await _ensureLoadedLocked();

    final trimmed = ownerKey?.trim();
    final hasOwner = trimmed != null && trimmed.isNotEmpty;
    final bound = _ownerKey;

    if (!hasOwner || trimmed != bound) {
      if (_state == CalendarSyncControlState.enabled) {
        await _persistStateLocked(CalendarSyncControlState.paused);
        _generation++;
        notifyListeners();
      } else {
        // 身份已变化即让在途旧结果失效，即使当前并非 enabled。
        _generation++;
      }
      _sessionRevision = revision;
      return _state;
    }

    // 同一绑定 owner。
    if (_state == CalendarSyncControlState.cleanupPending) {
      _sessionRevision = revision;
      return _state;
    }
    if (revision != _sessionRevision) {
      _sessionRevision = revision;
      _generation++;
      if (_state == CalendarSyncControlState.paused) {
        await _persistStateLocked(CalendarSyncControlState.enabled);
        notifyListeners();
      }
      return _state;
    }
    if (_state == CalendarSyncControlState.paused) {
      await _persistStateLocked(CalendarSyncControlState.enabled);
      _generation++;
      notifyListeners();
    }
    return _state;
  });

  /// 对所有 owner / 批次复核 pending，把 provider 查回的 eventId 写回其原批次。
  ///
  /// 无权限 / 平台异常 / 账本异常都保留 pending 并返回失败；跨 await 身份变化时
  /// 旧结果被拒绝（[CalendarSyncReconcileResult.aborted]），不写账本。
  Future<CalendarSyncReconcileResult> reconcilePending() async {
    final captured = await _serialize(() async {
      await _ensureLoadedLocked();
      return _generation;
    });
    final outcome = await _reconcileAll(captured);
    return CalendarSyncReconcileResult(
      reconciledCount: outcome.reconciled,
      pendingRemaining: outcome.pendingRemaining,
      failureKind: outcome.failureKind,
      aborted: outcome.aborted,
    );
  }

  /// 关闭同步并清理本 App 写入的全部事件。
  ///
  /// 顺序：先原子阻断未来写入（[cleanupPending] + 推进 generation）→ 复核全部
  /// pending → 遍历**全部** owner / 日历批次逐项删除（精确
  /// calendarId + opaqueId + eventId）→ 只对确认删除的项 `removeEntries`。
  /// notDeleted / 权限拒绝 / 日历被移 / pending 无法复核都保留账本并汇总残留原因；
  /// 只有账本清空且无失败才回到 [off]。重复调用安全（[off] 且账本为空直接返回完成）。
  Future<CalendarSyncCleanupResult> disableAndCleanup() async {
    await _serialize(_ensureLoadedLocked);

    CalendarEventLedgerSnapshot pre;
    try {
      pre = await _ledger.reload();
    } on CalendarSyncException catch (error) {
      return CalendarSyncCleanupResult(
        deletedCount: 0,
        residualCount: 0,
        failedBatchCount: 0,
        residualReasons: const <CalendarSyncCleanupResidualReason>{},
        failureKind: error.kind,
      );
    }

    // 原子阻断阶段：置 cleanupPending（若尚未）+ 推进 generation。
    final block = await _serialize(() async {
      await _ensureLoadedLocked();
      if (_state == CalendarSyncControlState.off && pre.isEmpty) {
        return (complete: true, changed: false, generation: _generation);
      }
      final wasCleanupPending =
          _state == CalendarSyncControlState.cleanupPending;
      if (!wasCleanupPending) {
        await _persistStateLocked(CalendarSyncControlState.cleanupPending);
      }
      // 每次 disable 启动都推进 generation：旧 disable 与迟到 enable 均失效。
      _generation++;
      return (
        complete: false,
        changed: !wasCleanupPending,
        generation: _generation,
      );
    });
    if (block.complete) {
      return const CalendarSyncCleanupResult(
        deletedCount: 0,
        residualCount: 0,
        failedBatchCount: 0,
        residualReasons: <CalendarSyncCleanupResidualReason>{},
      );
    }
    final generation = block.generation;
    if (block.changed) notifyListeners();

    // 关闭前先复核 pending，能安全删除的尽量删除（临界区外，逐点 generation 校验）。
    final reconcile = await _reconcileAll(generation);
    if (reconcile.aborted) {
      final remaining = await _tryResidualCount();
      return CalendarSyncCleanupResult(
        deletedCount: 0,
        residualCount: remaining ?? 0,
        failedBatchCount: 0,
        residualReasons: <CalendarSyncCleanupResidualReason>{
          if (reconcile.pendingRemaining > 0)
            CalendarSyncCleanupResidualReason.pendingUnreconciled,
        },
        failureKind:
            reconcile.failureKind ??
            (remaining == null
                ? CalendarSyncFailureKind.ledgerUnavailable
                : null),
        aborted: true,
      );
    }

    final reasons = <CalendarSyncCleanupResidualReason>{};
    if (reconcile.failureKind != null) {
      reasons.add(_residualFor(reconcile.failureKind!));
    }
    if (reconcile.pendingRemaining > 0) {
      reasons.add(CalendarSyncCleanupResidualReason.pendingUnreconciled);
    }

    var deletedCount = 0;
    var failedBatchCount = 0;
    var failureKind = reconcile.failureKind;

    CalendarEventLedgerSnapshot snapshot;
    try {
      snapshot = await _ledger.reload();
    } on CalendarSyncException catch (error) {
      return CalendarSyncCleanupResult(
        deletedCount: 0,
        residualCount: 0,
        failedBatchCount: 0,
        residualReasons: reasons,
        failureKind: error.kind,
      );
    }
    if (!_isCurrent(generation)) {
      return CalendarSyncCleanupResult(
        deletedCount: 0,
        residualCount: snapshot.allEntries.length,
        failedBatchCount: 0,
        residualReasons: reasons,
        failureKind: failureKind,
        aborted: true,
      );
    }

    for (final batch in snapshot.allBatches) {
      final committed = batch.entries.values
          .where((entry) => !entry.isPending)
          .toList();
      if (committed.isEmpty) continue;

      for (final chunk in _chunk(
        committed,
        CalendarSyncProtocol.maxBatchEvents,
      )) {
        if (!_isCurrent(generation)) {
          final remaining = await _tryResidualCount();
          return CalendarSyncCleanupResult(
            deletedCount: deletedCount,
            residualCount: remaining ?? 0,
            failedBatchCount: failedBatchCount,
            residualReasons: reasons,
            failureKind:
                failureKind ??
                (remaining == null
                    ? CalendarSyncFailureKind.ledgerUnavailable
                    : null),
            aborted: true,
          );
        }

        final CalendarSyncDeleteResult result;
        try {
          result = await _channel.deleteOwnedEventsByIds(
            calendarId: batch.calendarId,
            events: <CalendarSyncOwnedEvent>[
              for (final entry in chunk)
                CalendarSyncOwnedEvent(
                  opaqueId: entry.opaqueId,
                  eventId: entry.eventId!,
                ),
            ],
          );
        } on CalendarSyncException catch (error) {
          failureKind ??= error.kind;
          failedBatchCount++;
          reasons.add(_residualFor(error.kind));
          continue;
        }

        final deletedEventIds = result.deletedIds.toSet();
        final deletedOpaqueIds = <String>[
          for (final entry in chunk)
            if (deletedEventIds.contains(entry.eventId)) entry.opaqueId,
        ];
        if (deletedOpaqueIds.isNotEmpty) {
          try {
            deletedCount += await _ledger.removeEntries(
              ownerKey: batch.ownerKey,
              generation: batch.generation,
              opaqueIds: deletedOpaqueIds,
            );
          } on CalendarSyncException catch (error) {
            failureKind ??= error.kind;
            reasons.add(_residualFor(error.kind));
          }
        }
        if (result.notDeletedIds.isNotEmpty) {
          reasons.add(CalendarSyncCleanupResidualReason.notDeleted);
        }
      }
    }

    // 最终提交：残留判定 + 清绑定/置 off 在同一临界区内，且仅在 generation 未变
    // （没有新的 disable/身份变更介入）时允许。
    return _finalizeCleanup(
      generation: generation,
      deletedCount: deletedCount,
      failedBatchCount: failedBatchCount,
      failureKind: failureKind,
      reasons: reasons,
    );
  }

  Future<CalendarSyncCleanupResult> _finalizeCleanup({
    required int generation,
    required int deletedCount,
    required int failedBatchCount,
    required CalendarSyncFailureKind? failureKind,
    required Set<CalendarSyncCleanupResidualReason> reasons,
  }) => _serialize(() async {
    await _ensureLoadedLocked();
    final residual = await _tryResidualCount();
    if (residual == null) {
      return CalendarSyncCleanupResult(
        deletedCount: deletedCount,
        residualCount: 0,
        failedBatchCount: failedBatchCount,
        residualReasons: reasons,
        failureKind: failureKind ?? CalendarSyncFailureKind.ledgerUnavailable,
        aborted: _generation != generation,
      );
    }
    if (residual == 0 && failureKind == null && _generation == generation) {
      try {
        await _store.clear();
      } on CalendarSyncException catch (error) {
        return CalendarSyncCleanupResult(
          deletedCount: deletedCount,
          residualCount: 0,
          failedBatchCount: failedBatchCount,
          residualReasons: reasons,
          failureKind: error.kind,
        );
      }
      _state = CalendarSyncControlState.off;
      _ownerKey = null;
      _calendarId = null;
      _generation++;
      notifyListeners();
      return CalendarSyncCleanupResult(
        deletedCount: deletedCount,
        residualCount: 0,
        failedBatchCount: failedBatchCount,
        residualReasons: reasons,
      );
    }
    return CalendarSyncCleanupResult(
      deletedCount: deletedCount,
      residualCount: residual,
      failedBatchCount: failedBatchCount,
      residualReasons: reasons,
      failureKind: failureKind,
      aborted: _generation != generation,
    );
  });

  // ── 内部 ────────────────────────────────────────────────────────────

  /// 同 isolate 串行队列：临界区内 read/modify/write 不被其他转移交错。
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
    final binding = await _store.read();
    _state = binding.state;
    _ownerKey = binding.ownerKey;
    _calendarId = binding.calendarId;
    _loaded = true;
  }

  Future<void> _persistStateLocked(CalendarSyncControlState next) async {
    final binding = next == CalendarSyncControlState.off
        ? CalendarSyncControlBinding.off
        : CalendarSyncControlBinding(
            state: next,
            ownerKey: _ownerKey,
            calendarId: _calendarId,
          );
    // 极端情况下（控制态丢失但账本仍在）没有可持久化的绑定：只阻断本次会话的
    // 写入，不写入非法绑定；重启后按 off + 非空账本继续走清理路径。
    if (binding.isValid) {
      await _store.write(binding);
    }
    _state = next;
  }

  bool _isCurrent(int generation) => _generation == generation;

  /// 检查权限，未授权则申请一次；任一平台缺失/异常都由 channel 降级为 false。
  Future<bool> _ensurePermission() async {
    if (await _channel.checkPermissions()) return true;
    return _channel.requestPermissions();
  }

  CalendarSyncEnableResult _enableFailure(CalendarSyncException error) =>
      CalendarSyncEnableResult(enabled: false, state: _state, failure: error);

  CalendarSyncEnableResult _blockedByCleanupResult() =>
      CalendarSyncEnableResult(
        enabled: false,
        state: _state,
        blockedByCleanup: true,
        failure: CalendarSyncException.invalidArgument(
          '存在未完成的日历清理，需先完成清理再开启同步',
        ),
      );

  /// 遍历全部 owner / 批次复核 pending。调用方已确保账本可读。
  Future<_ReconcileOutcome> _reconcileAll(int generation) async {
    CalendarEventLedgerSnapshot snapshot;
    try {
      snapshot = await _ledger.reload();
    } on CalendarSyncException catch (error) {
      return _ReconcileOutcome(
        reconciled: 0,
        pendingRemaining: 0,
        failureKind: error.kind,
      );
    }
    if (!_isCurrent(generation)) {
      return _ReconcileOutcome(
        reconciled: 0,
        pendingRemaining: snapshot.pendingEntryCount,
        aborted: true,
      );
    }

    var reconciled = 0;
    CalendarSyncFailureKind? failureKind;

    for (final batch in snapshot.allBatches) {
      final pendingOpaqueIds = <String>[
        for (final entry in batch.entries.values)
          if (entry.isPending) entry.opaqueId,
      ];
      if (pendingOpaqueIds.isEmpty) continue;

      if (!_isCurrent(generation)) {
        return _ReconcileOutcome(
          reconciled: reconciled,
          pendingRemaining: snapshot.pendingEntryCount,
          failureKind: failureKind,
          aborted: true,
        );
      }

      final List<CalendarSyncOwnedEvent> found;
      try {
        found = await _channel.queryOwnedEvents(
          calendarId: batch.calendarId,
          opaqueIds: pendingOpaqueIds,
        );
      } on CalendarSyncException catch (error) {
        failureKind ??= error.kind;
        continue;
      }

      if (!_isCurrent(generation)) {
        return _ReconcileOutcome(
          reconciled: reconciled,
          pendingRemaining: snapshot.pendingEntryCount,
          failureKind: failureKind,
          aborted: true,
        );
      }
      if (found.isEmpty) continue;

      final eventIds = <String, int>{
        for (final event in found) event.opaqueId: event.eventId,
      };
      try {
        reconciled += await _ledger.recordRecoveredIds(
          ownerKey: batch.ownerKey,
          generation: batch.generation,
          eventIds: eventIds,
        );
      } on CalendarSyncException catch (error) {
        failureKind ??= error.kind;
      }
    }

    final pendingRemaining = await _tryPendingCount();
    if (pendingRemaining == null) {
      return _ReconcileOutcome(
        reconciled: reconciled,
        pendingRemaining: 0,
        failureKind: failureKind ?? CalendarSyncFailureKind.ledgerUnavailable,
      );
    }
    return _ReconcileOutcome(
      reconciled: reconciled,
      pendingRemaining: pendingRemaining,
      failureKind: failureKind,
    );
  }

  Future<int?> _tryPendingCount() async {
    try {
      return (await _ledger.reload()).pendingEntryCount;
    } on CalendarSyncException {
      return null;
    }
  }

  Future<int?> _tryResidualCount() async {
    try {
      return (await _ledger.reload()).allEntries.length;
    } on CalendarSyncException {
      return null;
    }
  }

  static CalendarSyncCleanupResidualReason _residualFor(
    CalendarSyncFailureKind kind,
  ) => switch (kind) {
    CalendarSyncFailureKind.permissionDenied =>
      CalendarSyncCleanupResidualReason.permissionDenied,
    CalendarSyncFailureKind.calendarUnavailable =>
      CalendarSyncCleanupResidualReason.calendarUnavailable,
    _ => CalendarSyncCleanupResidualReason.platformFailure,
  };

  static Iterable<List<T>> _chunk<T>(List<T> items, int size) sync* {
    for (var start = 0; start < items.length; start += size) {
      final end = start + size < items.length ? start + size : items.length;
      yield items.sublist(start, end);
    }
  }
}

@immutable
class _ReconcileOutcome {
  const _ReconcileOutcome({
    required this.reconciled,
    required this.pendingRemaining,
    this.failureKind,
    this.aborted = false,
  });

  final int reconciled;
  final int pendingRemaining;
  final CalendarSyncFailureKind? failureKind;
  final bool aborted;
}
