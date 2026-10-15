import 'package:flutter/foundation.dart';

import '../async/serial_queue.dart';
import '../logging/app_logger.dart';
import 'calendar_event_ledger_store.dart';
import 'calendar_legacy_cleanup.dart';
import 'calendar_sync_channel.dart';
import 'calendar_sync_control_store.dart';
import 'calendar_sync_models.dart';

export 'calendar_legacy_cleanup.dart';
export 'calendar_sync_control_store.dart';

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
/// - [pauseIfOwnerMismatch]：仅在当前已验证 owner 与绑定 owner 不同（真正换号）
///   时暂停并保留全部旧账本；登出 / 会话缺失保持 [enabled] 并进入「等待身份」
///   （[isWaitingForIdentity]，不落盘、不写日历）；同账号重登不暂停，
///   但推进内部 generation 使跨 await 的旧 revision 结果失效；
/// - [reconcilePending]：对**全部** owner / 批次的 pending 用
///   [CalendarSyncChannel.queryOwnedEvents] 找回 eventId，只经
///   [CalendarEventLedgerStore.recordRecoveredIds] 写回其原批次，不晋升 active；
/// - [disableAndCleanup]：先阻断未来写入，再遍历全部 owner / 日历批次（含旧账号
///   与 pending）逐项删除本 App 事件；只对确认删除的项 `removeEntries`，
///   其余保留并汇总残留原因；绝不 `clearAll` 假装完成。
///
/// 并发模型（同 isolate，linearizable）：
/// - 所有「读取 + 修改 + 持久化」的状态转移都在单条 [SerialQueue] Future 队列的
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
      _discovery = defaultCalendarOwnedEventDiscovery,
      _ledger = CalendarEventLedgerStore.instance,
      _store = CalendarSyncControlStore.instance;

  /// 测试/注入构造：可替换 channel、账本与控制态存储。
  CalendarSyncControl._(
    this._channel,
    this._discovery,
    this._ledger,
    this._store,
  );

  @visibleForTesting
  static CalendarSyncControl debugNew({
    required CalendarSyncChannel channel,
    required CalendarEventLedgerStore ledger,
    required CalendarSyncStateStore store,
    CalendarOwnedEventDiscovery? discovery,
  }) => CalendarSyncControl._(
    channel,
    discovery ?? defaultCalendarOwnedEventDiscovery,
    ledger,
    store,
  );

  static final CalendarSyncControl instance = CalendarSyncControl._production();

  final CalendarSyncChannel _channel;
  final CalendarOwnedEventDiscovery _discovery;
  final CalendarEventLedgerStore _ledger;
  final CalendarSyncStateStore _store;

  /// 清理前的 drain 钩子（由协调器安装；core 不 import app，避免层间依赖）。
  Future<void> Function()? _beforeCleanupDrain;

  /// 最近一次只读遗留扫描预览（用户确认时校验身份 / 代际）。
  CalendarLegacyCleanupScan? _latestScan;

  /// 安装 / 清除清理前的 drain 钩子（协调器在 `start` 时安装，退出时只移除自己的）。
  ///
  /// 钩子在 `scanLegacyOwnedEvents` / `cleanupLegacyOwnedEvents` / `disableAndCleanup`
  /// 的**临界区之外**调用（否则会与内部串行队列互相等待死锁）。未安装钩子时表示
  /// 没有在途写入者（如未启动的协调器 / 测试），跳过即可。
  void setBeforeCleanupDrain(Future<void> Function()? hook) {
    _beforeCleanupDrain = hook;
  }

  CalendarSyncControlState _state = CalendarSyncControlState.off;
  String? _ownerKey;
  int? _calendarId;
  bool _loaded = false;

  /// 当前已验证会话的身份修订号（由协调器经 [pauseIfOwnerMismatch] 同步）。
  int _sessionRevision = 0;

  /// 协调器最近同步进来的**当前已验证 owner**；null 表示教务未登录 / 会话缺失 /
  /// 冷启动尚未恢复。仅内存态、不落盘（持久态只认绑定 owner）。
  String? _identityOwner;

  /// 内部操作代际：状态/身份变化即自增，跨 await 的旧结果据此被拒绝。
  int _generation = 0;

  /// 同 isolate 串行队列：状态 read/modify/write 与 store 持久化在临界区内完成。
  final SerialQueue _queue = SerialQueue();

  CalendarSyncControlState get state => _state;
  String? get ownerKey => _ownerKey;
  int? get calendarId => _calendarId;
  int get sessionRevision => _sessionRevision;

  bool get isEnabled => _state == CalendarSyncControlState.enabled;

  /// 协调器是否允许发起新的日历写入：仅 [enabled] 为 true。
  bool get isWritable => isEnabled;

  /// 已 [enabled] 但当前没有已验证身份（教务登出 / 会话过期 / 冷启动尚未恢复）：
  /// 绑定与账本都保留，开关保持开启，但不会有任何写入；同一 owner 重新登录后
  /// 自动继续。这是派生状态，**不持久化**，也不是 [CalendarSyncControlState]。
  bool get isWaitingForIdentity => isEnabled && _identityOwner == null;

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
    _identityOwner = null;
    _generation++;
    _queue.reset();
  }

  /// 冷启动 / 回前台：从磁盘恢复绑定状态（不触发权限或 provider 调用）。
  Future<void> load() => _queue.run(_ensureLoadedLocked);

  /// 当前账本残留条数（含 pending 与删不掉项），供设置页展示；
  /// 只读账本，不触发任何 CalendarProvider 调用。账本损坏时抛
  /// [CalendarSyncException]，调用方按失败展示，不得当作「已清干净」。
  Future<int> residualCount() => _queue.run(() async {
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
    await _queue.run(_ensureLoadedLocked);

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
    final precheck = await _queue.run(() async {
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
    final result = await _queue.run(() async {
      await _ensureLoadedLocked();
      if (_generation != captured) {
        return _enableFailure(
          CalendarSyncException.invalidArgument('开启请求已被新的身份变更取代'),
        );
      }
      if (_state == CalendarSyncControlState.cleanupPending) {
        return _blockedByCleanupResult();
      }
      // C2：同一 owner 在**其他**日历仍有账本归属时拒绝换日历开启，
      // 避免跨日历复制出重复副本（必须先清理旧日历残留）。
      if (await _hasOtherCalendarBindings(trimmedOwner, resolvedCalendarId)) {
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
      // enable 的调用方已校验过 owner 是当前已验证身份。
      _identityOwner = trimmedOwner;
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
  /// - [ownerKey] 为 null / 空白（教务登出、会话过期、冷启动尚未恢复）：**不暂停、
  ///   不落盘**，保持当前持久态（[enabled] 即进入 [isWaitingForIdentity]，绑定与
  ///   账本都保留，协调器因缺身份不写日历）；无已验证身份不等于换号；
  /// - [ownerKey] 为非空已验证学号且与绑定 owner 不同（真正换号）：[enabled] →
  ///   [paused]（落盘），保留全部旧账本，不删任何事件；
  /// - 与绑定 owner 相同：不暂停；[paused] 恢复为 [enabled]（同账号重登，含旧版本
  ///   因登出而落盘的 [paused]）；
  /// - 无论是否改变状态，只要 owner/revision 与内部记录不同就推进 generation，
  ///   使跨 await 的旧 revision 写结果被拒绝（不污染新状态）；
  /// - [cleanupPending] 不会被自动恢复，也不因身份变化而取消进行中的清理。
  ///
  /// 整个状态转移在串行临界区内原子完成，与 [enable] 的提交互斥。
  Future<CalendarSyncControlState> pauseIfOwnerMismatch({
    required String? ownerKey,
    required int revision,
  }) => _queue.run(() async {
    await _ensureLoadedLocked();

    final trimmed = ownerKey?.trim();
    final hasOwner = trimmed != null && trimmed.isNotEmpty;
    final bound = _ownerKey;
    final wasWaiting = isWaitingForIdentity;
    final identityChanged =
        _identityOwner != (hasOwner ? trimmed : null) ||
        revision != _sessionRevision;
    _identityOwner = hasOwner ? trimmed : null;

    if (!hasOwner) {
      // 无已验证身份（登出 / 过期 / 尚未恢复）：不是换号，不改持久态。
      // 身份变化仍推进 generation，让跨 await 的旧结果失效。
      if (identityChanged) _generation++;
      _sessionRevision = revision;
      if (wasWaiting != isWaitingForIdentity) notifyListeners();
      return _state;
    }

    if (trimmed != bound) {
      // 真正换号：已验证的另一账号。
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
      } else if (wasWaiting) {
        notifyListeners();
      }
      return _state;
    }
    if (_state == CalendarSyncControlState.paused) {
      await _persistStateLocked(CalendarSyncControlState.enabled);
      _generation++;
      notifyListeners();
    } else if (wasWaiting) {
      notifyListeners();
    }
    return _state;
  });

  /// 对所有 owner / 批次复核 pending，把 provider 查回的 eventId 写回其原批次。
  ///
  /// 无权限 / 平台异常 / 账本异常都保留 pending 并返回失败；跨 await 身份变化时
  /// 旧结果被拒绝（[CalendarSyncReconcileResult.aborted]），不写账本。
  Future<CalendarSyncReconcileResult> reconcilePending() async {
    final captured = await _queue.run(() async {
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
  /// pending → 遍历**全部** owner / 日历批次，删除前按 `calendarId + opaqueIds`
  /// 用 [CalendarSyncChannel.queryOwnedEvents] 核对 provider 当前 eventId（用户手删
  /// 后同 opaqueId 事件可能以新 id 重建），使用查回的新 id 精确删除 → 只对确认
  /// 删除的项 `removeEntries`。查询失败 / notDeleted / 权限拒绝 / 日历被移 /
  /// pending 无法复核都保留账本并汇总残留原因；只有账本清空且无失败才回到
  /// [off]。重复调用安全（[off] 且账本为空直接返回完成）。
  Future<CalendarSyncCleanupResult> disableAndCleanup() async {
    await _queue.run(_ensureLoadedLocked);

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
    final block = await _queue.run(() async {
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

    // 关闭前的 drain：让协调器在途 upsert 先落地再复核 / 删除（临界区外，避免死锁）。
    if (!await _drainBeforeCleanup()) {
      final remaining = await _tryResidualCount();
      return CalendarSyncCleanupResult(
        deletedCount: 0,
        residualCount: remaining ?? 0,
        failedBatchCount: 0,
        residualReasons: <CalendarSyncCleanupResidualReason>{
          CalendarSyncCleanupResidualReason.pendingUnreconciled,
        },
        failureKind: remaining == null
            ? CalendarSyncFailureKind.ledgerUnavailable
            : null,
      );
    }
    if (!_isCurrent(generation)) {
      final remaining = await _tryResidualCount();
      return CalendarSyncCleanupResult(
        deletedCount: 0,
        residualCount: remaining ?? 0,
        failedBatchCount: 0,
        residualReasons: const <CalendarSyncCleanupResidualReason>{},
        failureKind: remaining == null
            ? CalendarSyncFailureKind.ledgerUnavailable
            : null,
        aborted: true,
      );
    }

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

      // 删除前按 calendarId + opaqueIds 核对 provider 当前 eventId：用户手删后
      // 同 opaqueId 事件可能以新 id 重建，直接用账本旧 id 会残留。
      final Map<String, int> providerEventIds;
      try {
        final queried = await _channel.queryOwnedEvents(
          calendarId: batch.calendarId,
          opaqueIds: <String>[for (final entry in committed) entry.opaqueId],
        );
        providerEventIds = <String, int>{
          for (final event in queried) event.opaqueId: event.eventId,
        };
      } on CalendarSyncException catch (error) {
        // 查询失败（含权限拒绝）：保留全部残留，绝不删除、绝不假称清干净。
        failureKind ??= error.kind;
        failedBatchCount++;
        reasons.add(_residualFor(error.kind));
        continue;
      }
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

        // 优先使用 provider 查回的当前 id；未查回时回退账本 id——原生删除的
        // selection 同时限定 _id + calendar_id + CUSTOM_APP_PACKAGE +
        // CUSTOM_APP_URI，命中 0 行按 notDeleted，绝不会误删别的行。
        final requested = <CalendarSyncOwnedEvent>[
          for (final entry in chunk)
            CalendarSyncOwnedEvent(
              opaqueId: entry.opaqueId,
              eventId: providerEventIds[entry.opaqueId] ?? entry.eventId!,
            ),
        ];

        final CalendarSyncDeleteResult result;
        try {
          result = await _channel.deleteOwnedEventsByIds(
            calendarId: batch.calendarId,
            events: requested,
          );
        } on CalendarSyncException catch (error) {
          failureKind ??= error.kind;
          failedBatchCount++;
          reasons.add(_residualFor(error.kind));
          continue;
        }

        final deletedEventIds = result.deletedIds.toSet();
        final deletedOpaqueIds = <String>[
          for (var index = 0; index < chunk.length; index++)
            if (deletedEventIds.contains(requested[index].eventId))
              chunk[index].opaqueId,
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
  }) => _queue.run(() async {
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

  /// 只读扫描本 App 遗留事件（Issue #48）：先阻断写入 + drain，再只读扫描候选
  /// 日历（账本批次日历 ∪ 当前绑定日历）。**绝不删除任何东西**。
  Future<CalendarLegacyCleanupScan> scanLegacyOwnedEvents() async {
    await _queue.run(_ensureLoadedLocked);

    final block = await _queue.run(() async {
      await _ensureLoadedLocked();
      final wasPending = _state == CalendarSyncControlState.cleanupPending;
      if (!wasPending) {
        await _persistStateLocked(CalendarSyncControlState.cleanupPending);
      }
      _generation++;
      return (changed: !wasPending, generation: _generation);
    });
    if (block.changed) notifyListeners();
    final generation = block.generation;

    if (!await _drainBeforeCleanup()) {
      return _failedScan(CalendarLegacyCleanupFailure.pendingUnreconciled);
    }
    if (!_isCurrent(generation)) {
      return _failedScan(CalendarLegacyCleanupFailure.aborted);
    }

    CalendarEventLedgerSnapshot ledger;
    try {
      ledger = await _ledger.reload();
    } on CalendarSyncException catch (error) {
      return _failedScan(_scanFailureFor(error.kind));
    }
    if (!_isCurrent(generation)) {
      return _failedScan(CalendarLegacyCleanupFailure.aborted);
    }

    final discovery = await _discovery.listOwnedEventCalendars();
    if (!_isCurrent(generation)) {
      return _failedScan(CalendarLegacyCleanupFailure.aborted);
    }

    // 候选日历 = discovery 证实的自有日历 ∪ 账本批次日历 ∪ 当前绑定日历。
    final candidateIds = <int>{
      for (final calendar in discovery.calendars) calendar.calendarId,
      for (final batch in ledger.allBatches) batch.calendarId,
      ?_calendarId,
    };

    var complete = discovery.complete;
    CalendarLegacyCleanupFailure? reason = _scanFailureForDiscovery(
      discovery.reason,
    );
    if (candidateIds.length > CalendarSyncProtocol.maxOwnedCalendars) {
      complete = false;
      reason ??= CalendarLegacyCleanupFailure.scanLimit;
    }

    final recordedTuples = <(int, String, int)>{};
    for (final batch in ledger.allBatches) {
      for (final entry in batch.entries.values) {
        // pending 尚无已确认 eventId，预览中仍归为未确认，不在只读扫描时补记。
        final eventId = entry.eventId;
        if (eventId == null) continue;
        recordedTuples.add((batch.calendarId, entry.opaqueId, eventId));
      }
    }
    final metaById = <int, CalendarOwnedCalendarInfo>{
      for (final calendar in discovery.calendars) calendar.calendarId: calendar,
    };

    final previews = <CalendarLegacyCleanupCalendarPreview>[];
    final candidates = <LegacyCleanupCandidate>[];
    var totalKnown = 0;
    var totalOrphan = 0;
    for (final calendarId in candidateIds) {
      if (!_isCurrent(generation)) {
        return _failedScan(CalendarLegacyCleanupFailure.aborted);
      }
      if (totalKnown >= CalendarSyncProtocol.maxScanRows) {
        complete = false;
        reason ??= CalendarLegacyCleanupFailure.scanLimit;
        break;
      }
      final scan = await _discovery.scanOwnedEvents(calendarId: calendarId);
      if (!scan.complete) {
        complete = false;
        reason ??= _scanFailureForDiscovery(scan.reason);
      }
      final meta = metaById[calendarId];
      var orphan = 0;
      var recordedCount = 0;
      for (final event in scan.events) {
        final recorded = recordedTuples.contains((
          calendarId,
          event.opaqueId,
          event.eventId,
        ));
        if (recorded) {
          recordedCount++;
        } else {
          orphan++;
        }
        candidates.add(
          LegacyCleanupCandidate(
            calendarId: calendarId,
            opaqueId: event.opaqueId,
            eventId: event.eventId,
            recorded: recorded,
          ),
        );
      }
      totalKnown += scan.events.length;
      totalOrphan += orphan;
      previews.add(
        CalendarLegacyCleanupCalendarPreview(
          calendarId: calendarId,
          displayName: meta?.displayName,
          writable: meta?.writable,
          recordedCount: recordedCount,
          orphanCount: orphan,
          ownedCount: scan.events.length,
        ),
      );
    }

    final result = CalendarLegacyCleanupScan(
      token: CalendarSyncOpaqueId.generate(),
      calendars: List<CalendarLegacyCleanupCalendarPreview>.unmodifiable(
        previews,
      ),
      complete: complete,
      reason: reason,
      totalKnownOwnedCount: totalKnown,
      recordedOrphanCount: totalOrphan,
      dismissible: complete && totalKnown == 0 && ledger.allEntries.isEmpty,
      candidates: List<LegacyCleanupCandidate>.unmodifiable(candidates),
    );
    _latestScan = result;
    return result;
  }

  /// 删除**用户已确认**的遗留预览候选（Issue #48）：只删重新核验仍在 provider 中的
  /// 精确 `(calendarId, opaqueId, eventId)` 三元组，绝不按标题模糊删、绝不 `clearAll`。
  Future<CalendarLegacyCleanupResult> cleanupLegacyOwnedEvents(
    CalendarLegacyCleanupScan preview,
  ) async {
    await _queue.run(_ensureLoadedLocked);

    final block = await _queue.run(() async {
      await _ensureLoadedLocked();
      if (!identical(_latestScan, preview) ||
          _latestScan?.token != preview.token) {
        return (valid: false, changed: false, generation: _generation);
      }
      final wasPending = _state == CalendarSyncControlState.cleanupPending;
      if (!wasPending) {
        await _persistStateLocked(CalendarSyncControlState.cleanupPending);
      }
      _generation++;
      return (valid: true, changed: !wasPending, generation: _generation);
    });
    if (!block.valid) {
      return _cleanupAbort(CalendarLegacyCleanupFailure.invalidPreview);
    }
    if (block.changed) notifyListeners();
    final generation = block.generation;

    if (!await _drainBeforeCleanup()) {
      return _cleanupAbort(CalendarLegacyCleanupFailure.pendingUnreconciled);
    }
    if (!_isCurrent(generation)) {
      return _cleanupAbort(CalendarLegacyCleanupFailure.aborted, aborted: true);
    }

    CalendarEventLedgerSnapshot ledger;
    try {
      ledger = await _ledger.reload();
    } on CalendarSyncException catch (error) {
      return _cleanupAbort(_scanFailureFor(error.kind));
    }

    final byCalendar = <int, List<LegacyCleanupCandidate>>{};
    for (final candidate in preview.candidates) {
      byCalendar.putIfAbsent(candidate.calendarId, () => []).add(candidate);
    }
    // 处理范围 = 预览候选日历 ∪ 账本批次日历（含无 marker 的陈旧账本日历）。
    final calendarIds = <int>{
      ...byCalendar.keys,
      for (final batch in ledger.allBatches) batch.calendarId,
    };

    // 预览本身不完整（权限 / 上限 / 日历元数据未知）时如实计入失败，绝不谎称干净。
    final failures = <CalendarLegacyCleanupFailure>{
      if (!preview.complete)
        preview.reason ?? CalendarLegacyCleanupFailure.providerUnavailable,
    };
    var deletedCount = 0;
    var aborted = false;

    // 1) 删除前重新核验 + 精确删除（每个 opaqueId 每次至多一个 eventId，避免
    //    通道「批次内 opaqueId 重复」拒绝）。
    for (final calendarId in calendarIds) {
      if (!_isCurrent(generation)) {
        aborted = true;
        break;
      }
      final previewCandidates = byCalendar[calendarId] ?? const [];
      if (previewCandidates.isEmpty) continue;
      // 只删冻结预览**明确证实可写**的日历；未知 / 只读一律不删并计为不完整。
      if (!preview.calendars.any(
        (c) => c.calendarId == calendarId && c.writable == true,
      )) {
        failures.add(CalendarLegacyCleanupFailure.calendarUnavailable);
        continue;
      }

      final scan = await _discovery.scanOwnedEvents(calendarId: calendarId);
      if (!_isCurrent(generation)) {
        aborted = true;
        break;
      }
      if (!scan.complete) {
        failures.add(
          _scanFailureForDiscovery(scan.reason) ??
              CalendarLegacyCleanupFailure.providerUnavailable,
        );
        continue;
      }
      final certified = <String>{
        for (final event in scan.events) '${event.opaqueId}#${event.eventId}',
      };
      final verified = <LegacyCleanupCandidate>[
        for (final candidate in previewCandidates)
          if (certified.contains('${candidate.opaqueId}#${candidate.eventId}'))
            candidate,
      ];
      if (verified.isEmpty) continue;

      for (final round in partitionUniqueOpaqueCandidates(verified)) {
        for (final chunk in _chunk(
          round,
          CalendarSyncProtocol.maxBatchEvents,
        )) {
          if (!_isCurrent(generation)) {
            aborted = true;
            break;
          }
          final CalendarSyncDeleteResult deleteResult;
          try {
            deleteResult = await _channel.deleteOwnedEventsByIds(
              calendarId: calendarId,
              events: <CalendarSyncOwnedEvent>[
                for (final candidate in chunk)
                  CalendarSyncOwnedEvent(
                    opaqueId: candidate.opaqueId,
                    eventId: candidate.eventId,
                  ),
              ],
            );
          } on CalendarSyncException catch (error) {
            failures.add(_scanFailureFor(error.kind));
            continue;
          }
          deletedCount += deleteResult.deletedIds.length;
          if (deleteResult.notDeletedIds.isNotEmpty) {
            failures.add(CalendarLegacyCleanupFailure.calendarUnavailable);
          }
        }
        if (aborted) break;
      }
      if (aborted) break;
    }

    // 2) 复扫全部候选日历：计算残留下界 + 用完整扫描的「证实缺失」清理陈旧账本。
    var residual = 0;
    var postComplete = !aborted;
    for (final calendarId in calendarIds) {
      if (!_isCurrent(generation)) {
        aborted = true;
        break;
      }
      final scan = await _discovery.scanOwnedEvents(calendarId: calendarId);
      if (!_isCurrent(generation)) {
        aborted = true;
        break;
      }
      if (!scan.complete) {
        postComplete = false;
        failures.add(
          _scanFailureForDiscovery(scan.reason) ??
              CalendarLegacyCleanupFailure.providerUnavailable,
        );
        continue;
      }
      residual += scan.events.length;
      final certified = <String>{
        for (final event in scan.events) event.opaqueId,
      };
      final resolved = <String, List<String>>{};
      for (final batch in ledger.allBatches) {
        if (batch.calendarId != calendarId) continue;
        for (final entry in batch.entries.values) {
          if (certified.contains(entry.opaqueId)) continue;
          resolved
              .putIfAbsent(
                '${batch.ownerKey}\u001F${batch.generation}',
                () => [],
              )
              .add(entry.opaqueId);
        }
      }
      for (final group in resolved.entries) {
        final parts = group.key.split('\u001F');
        try {
          await _ledger.removeEntries(
            ownerKey: parts[0],
            generation: parts[1],
            opaqueIds: group.value,
          );
        } on CalendarSyncException catch (error) {
          failures.add(_scanFailureFor(error.kind));
        }
      }
    }

    final remainingLedger = await _tryResidualCount();
    // 完成以「冻结预览完整」+ 同一 generation 临界区原子提交为准：generation 变化 /
    // store.clear 失败都绝不报 complete、清绑定或置 off（保留 pending 与预览供重试）。
    var complete =
        !aborted &&
        postComplete &&
        preview.complete &&
        preview.reason == null &&
        residual == 0 &&
        failures.isEmpty &&
        remainingLedger == 0;
    if (complete) {
      final commit = await _queue.run(() async {
        await _ensureLoadedLocked();
        if (!_isCurrent(generation)) {
          return (ok: false, stale: true, fail: null);
        }
        try {
          await _store.clear();
        } on CalendarSyncException catch (error) {
          return (ok: false, stale: false, fail: _scanFailureFor(error.kind));
        }
        _state = CalendarSyncControlState.off;
        _ownerKey = null;
        _calendarId = null;
        _generation++;
        _latestScan = null;
        notifyListeners();
        return (ok: true, stale: false, fail: null);
      });
      complete = commit.ok;
      aborted = aborted || commit.stale;
      if (commit.fail != null) failures.add(commit.fail!);
    }

    return CalendarLegacyCleanupResult(
      deletedCount: deletedCount,
      residualCount: residual,
      complete: complete,
      failures: Set<CalendarLegacyCleanupFailure>.unmodifiable(failures),
      aborted: aborted,
    );
  }

  /// 放弃当前预览（Issue #48）：仅当可 dismiss（0 残留 + 账本空）才回 [off]，
  /// 否则保持 [cleanupPending]，**绝不**虚假清账本。
  Future<void> dismissLegacyCleanupPreview(
    CalendarLegacyCleanupScan preview,
  ) async {
    await _queue.run(_ensureLoadedLocked);
    await _queue.run(() async {
      await _ensureLoadedLocked();
      if (!identical(_latestScan, preview) ||
          _latestScan?.token != preview.token) {
        return;
      }
      _latestScan = null;
      final remaining = await _tryResidualCount();
      if (preview.dismissible && remaining == 0) {
        try {
          await _store.clear();
        } on CalendarSyncException {
          return;
        }
        _state = CalendarSyncControlState.off;
        _ownerKey = null;
        _calendarId = null;
        _generation++;
        notifyListeners();
      }
    });
  }

  Future<bool> _drainBeforeCleanup() async {
    final hook = _beforeCleanupDrain;
    if (hook == null) return true;
    try {
      await hook();
      return true;
    } catch (error) {
      AppLogger.instance.warn(
        '日历清理：drain 钩子异常（${error.runtimeType}），按未知残留保守处理',
      );
      return false;
    }
  }

  CalendarLegacyCleanupResult _cleanupAbort(
    CalendarLegacyCleanupFailure failure, {
    bool aborted = false,
  }) => CalendarLegacyCleanupResult(
    deletedCount: 0,
    residualCount: 0,
    complete: false,
    failures: <CalendarLegacyCleanupFailure>{failure},
    aborted: aborted,
  );

  CalendarLegacyCleanupScan _failedScan(CalendarLegacyCleanupFailure reason) {
    final scan = CalendarLegacyCleanupScan(
      token: CalendarSyncOpaqueId.generate(),
      calendars: const <CalendarLegacyCleanupCalendarPreview>[],
      complete: false,
      reason: reason,
      totalKnownOwnedCount: 0,
      recordedOrphanCount: 0,
      dismissible: false,
      candidates: const <LegacyCleanupCandidate>[],
    );
    _latestScan = scan;
    return scan;
  }

  static CalendarLegacyCleanupFailure _scanFailureFor(
    CalendarSyncFailureKind kind,
  ) => switch (kind) {
    CalendarSyncFailureKind.permissionDenied =>
      CalendarLegacyCleanupFailure.permissionDenied,
    CalendarSyncFailureKind.providerUnavailable =>
      CalendarLegacyCleanupFailure.providerUnavailable,
    CalendarSyncFailureKind.calendarUnavailable =>
      CalendarLegacyCleanupFailure.calendarUnavailable,
    CalendarSyncFailureKind.ledgerUnavailable =>
      CalendarLegacyCleanupFailure.ledgerUnavailable,
    CalendarSyncFailureKind.ledgerCorrupted =>
      CalendarLegacyCleanupFailure.ledgerCorrupted,
    _ => CalendarLegacyCleanupFailure.providerUnavailable,
  };

  static CalendarLegacyCleanupFailure? _scanFailureForDiscovery(
    CalendarOwnedDiscoveryReason? reason,
  ) => switch (reason) {
    null => null,
    CalendarOwnedDiscoveryReason.permissionDenied =>
      CalendarLegacyCleanupFailure.permissionDenied,
    CalendarOwnedDiscoveryReason.scanLimit =>
      CalendarLegacyCleanupFailure.scanLimit,
    CalendarOwnedDiscoveryReason.calendarUnavailable =>
      CalendarLegacyCleanupFailure.calendarUnavailable,
    CalendarOwnedDiscoveryReason.unavailable =>
      CalendarLegacyCleanupFailure.providerUnavailable,
  };

  // ── 内部 ────────────────────────────────────────────────────────────

  /// 同 isolate 串行队列：临界区内 read/modify/write 不被其他转移交错。
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

  /// 该 owner 是否在**其他**日历仍有账本归属（C2：换日历开启前的安全闸）。
  Future<bool> _hasOtherCalendarBindings(
    String ownerKey,
    int calendarId,
  ) async {
    try {
      final ledger = await _ledger.reload();
      for (final batch in ledger.batchesFor(ownerKey)) {
        if (batch.calendarId != calendarId && batch.entries.isNotEmpty) {
          return true;
        }
      }
    } on CalendarSyncException {
      // 账本不可读：保守拒绝（未知归属下不换日历写入）。
      return true;
    }
    return false;
  }

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
