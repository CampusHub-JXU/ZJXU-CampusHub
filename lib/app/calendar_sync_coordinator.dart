import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/auth/zhengfang_auth.dart';
import '../core/calendar/calendar_event_ledger_store.dart';
import '../core/calendar/calendar_reminder_settings.dart';
import '../core/calendar/calendar_sync_channel.dart';
import '../core/calendar/calendar_sync_control.dart';
import '../core/calendar/calendar_sync_models.dart';
import '../core/logging/app_logger.dart';
import '../core/semester/current_term_resolver.dart';
import '../core/semester/schedule_term_context.dart';
import '../core/semester/semester_calendar.dart';
import '../core/system_surface/campus_data_change_bus.dart';
import '../core/academic/schedule_cache_snapshot.dart';
import '../features/schedule/schedule_service.dart';
import 'calendar_event_projector.dart';

/// 一次前台同步运行的最终去向（供 UI/测试观察，不含业务数据）。
enum CalendarSyncRunOutcome {
  /// 尚未运行。
  idle,

  /// 无需写入（关闭 / 非前台 / 未确认学期 / 无快照 / 无可信投影 / 无变化）。
  noWork,

  /// 身份/前台在运行中失效，或存在未复核 pending，已安全中止。
  blocked,

  /// 完成本轮差量（可能含 0 次删除）。
  synced,

  /// provider / 账本异常，已保留 pending，未做后续删除。
  failed,
}

/// 当前已验证正方身份的快照（由调用方从 [ZhengfangAuth] 直接读取）。
@immutable
class CalendarSyncIdentity {
  const CalendarSyncIdentity({
    required this.isLoggedIn,
    required this.revision,
    this.ownerKey,
  });

  final bool isLoggedIn;
  final String? ownerKey;
  final int revision;
}

typedef CalendarSyncIdentityReader = CalendarSyncIdentity Function();

typedef CalendarSyncSnapshotLoader = ScheduleCacheSnapshot? Function({
  required String ownerKey,
  required ScheduleTermContext term,
});

typedef CalendarSyncTermReader = ScheduleTermContext? Function();

typedef CalendarSyncClock = DateTime Function();

typedef CalendarSyncReminderReader = int Function();

typedef CalendarSyncProjector = List<ProjectedCourseOccurrence> Function({
  required ScheduleCacheSnapshot snapshot,
  required String verifiedOwner,
  required ScheduleTermContext confirmedCurrentTerm,
  required DateTime semesterStartDate,
  required DateTime now,
  required int reminderMinutes,
});

/// projector 的 businessKey 字段分隔符（unit separator）。
///
/// 与 `calendar_event_projector.dart` 的私有常量 lockstep：businessKey 形如
/// `<version>\u001F<term.key>\u001F...`，学期键独占一个字段；课程字段里的分隔符
/// 会被 projector 清洗为空格，因此 `\u001F<term.key>\u001F` 只可能匹配学期字段。
/// `test/app/calendar_sync_coordinator_test.dart` 用真实 projector 输出守卫该假设。
const String calendarBusinessKeyFieldSeparator = '\u001F';

/// 该 businessKey 是否属于 [term]（用于只差量当前学期、保留历史学期）。
bool calendarBusinessKeyBelongsToTerm(
  String businessKey,
  ScheduleTermContext term,
) => businessKey.contains(
  '$calendarBusinessKeyFieldSeparator${term.key}$calendarBusinessKeyFieldSeparator',
);

/// 生产身份读取：直接读正方会话（不做任何网络请求）。
CalendarSyncIdentity _readProductionIdentity() {
  final auth = ZhengfangAuth.instance;
  return CalendarSyncIdentity(
    isLoggedIn: auth.isLoggedIn,
    ownerKey: auth.currentStudentId,
    revision: auth.sessionRevision,
  );
}

/// 生产快照读取：只读当前已验证 owner 的本地快照（不触发网络）。
ScheduleCacheSnapshot? _loadProductionSnapshot({
  required String ownerKey,
  required ScheduleTermContext term,
}) => ScheduleService.instance.preferredSnapshot(
  termContext: term,
  studentId: ownerKey,
);

/// 生产提醒提前量读取：读持久化设置单例（内存态，默认 20；不触网络/磁盘）。
int _readProductionReminderMinutes() =>
    CalendarReminderSettings.instance.reminderMinutes;

/// 课表 → 系统日历同步的前台协调器（仅主引擎前台，零后台注册）。
///
/// 触发源（由 [start] 安装，测试可调用同名公开方法）：
/// - 正方身份变化 → [onAuthIdentityChanged]（先 `pauseIfOwnerMismatch` 再同步）；
/// - [CampusDataChangeBus.revision] → [onCampusDataChanged]；
/// - 学期开学日变化 → [onSemesterStartChanged]；
/// - [CalendarSyncControl] 状态变化 → [onControlStateChanged]；
/// - `CalendarReminderSettings` 提前量变化 → 前台触发一轮（按新提前量 upsert）；
/// - 生命周期 → [onAppResumed] / [onAppInactive]。
///
/// 安全边界：
/// - 默认关闭零写入；只有 `control` 处于 `enabled` 且绑定当前已验证 owner +
///   revision 时才写；
/// - 只读 `CurrentTermResolver.knownCurrentTerm`（不做网络解析、不日期 fallback）；
/// - 只读当前已验证 owner 的 `ScheduleService.preferredSnapshot`；
/// - `projectCurrentTermCalendarEvents` 全量 fail-closed，任何不可证情况不做删除；
/// - 每个 await 之后都复核「本轮 token + 前台 + 直接读到的正方身份 +
///   `control.canWriteFor(owner, revision)`」，未通过只保留 pending；
/// - 先 `reconcilePending`，失败或仍有 pending 不开始差量；
/// - 新记录先 `beginPendingBatch` 落盘 → `upsertEventBatch` → 仅当前代
///   `commitBatch`；provider 失败保留 pending 供下次真实 query 恢复；
/// - 只删除「当前学期」内本 App 自己的陈旧事件（历史学期全部保留），
///   `deletedIds` 才 `removeEntries`，`notDeleted` 留账本；
/// - 绝不把学号 / 课程名 / businessKey 发给 native 或写日志。
class CalendarSyncCoordinator {
  CalendarSyncCoordinator._(
    this._channel,
    this._discovery,
    this._control,
    this._ledger,
    this._readIdentity,
    this._loadSnapshot,
    this._readKnownCurrentTerm,
    this._clock,
    this._readSemesterStartDate,
    this._projector,
    this._readReminderMinutes,
  );

  /// 测试/注入构造：替换通道、控制、账本与所有环境读取回调。
  @visibleForTesting
  static CalendarSyncCoordinator debugNew({
    required CalendarSyncChannel channel,
    required CalendarSyncControl control,
    required CalendarEventLedgerStore ledger,
    required CalendarSyncIdentityReader readIdentity,
    required CalendarSyncSnapshotLoader loadSnapshot,
    required CalendarSyncTermReader readKnownCurrentTerm,
    required CalendarSyncClock clock,
    required CalendarSyncClock readSemesterStartDate,
    CalendarSyncProjector projector = projectCurrentTermCalendarEvents,
    CalendarSyncReminderReader reminderMinutesReader =
        _readProductionReminderMinutes,
    CalendarOwnedEventDiscovery? discovery,
  }) => CalendarSyncCoordinator._(
    channel,
    discovery ?? defaultCalendarOwnedEventDiscovery,
    control,
    ledger,
    readIdentity,
    loadSnapshot,
    readKnownCurrentTerm,
    clock,
    readSemesterStartDate,
    projector,
    reminderMinutesReader,
  );

  /// 生产单例：默认通道 + 共享控制/账本 + 直接读正方身份 / 课表 / 学期 / 设置。
  static final CalendarSyncCoordinator instance = CalendarSyncCoordinator._(
    defaultCalendarSyncChannel,
    defaultCalendarOwnedEventDiscovery,
    CalendarSyncControl.instance,
    CalendarEventLedgerStore.instance,
    _readProductionIdentity,
    _loadProductionSnapshot,
    () => CurrentTermResolver.instance.knownCurrentTerm,
    DateTime.now,
    () => SemesterCalendar.instance.semesterStartDate.value,
    projectCurrentTermCalendarEvents,
    _readProductionReminderMinutes,
  );

  final CalendarSyncChannel _channel;
  final CalendarOwnedEventDiscovery _discovery;
  final CalendarSyncControl _control;
  final CalendarEventLedgerStore _ledger;
  final CalendarSyncIdentityReader _readIdentity;
  final CalendarSyncSnapshotLoader _loadSnapshot;
  final CalendarSyncTermReader _readKnownCurrentTerm;
  final CalendarSyncClock _clock;
  final CalendarSyncClock _readSemesterStartDate;
  final CalendarSyncProjector _projector;
  final CalendarSyncReminderReader _readReminderMinutes;

  /// 最近一次运行去向；UI 可监听（不含业务数据）。
  final ValueNotifier<CalendarSyncRunOutcome> outcome =
      ValueNotifier<CalendarSyncRunOutcome>(CalendarSyncRunOutcome.idle);

  bool _started = false;
  bool _foreground = true;
  Future<void>? _activeRun;
  bool _rerunRequested = false;
  int _runToken = 0;

  /// 安装生产监听（幂等）。必须早于暖启动数据变化，以便及时响应。
  void start() {
    if (_started) return;
    _started = true;
    ZhengfangAuth.instance.addListener(_onAuthChanged);
    CampusDataChangeBus.instance.revision.addListener(_onDataChanged);
    SemesterCalendar.instance.semesterStartDate.addListener(_onDataChanged);
    _control.addListener(_onControlChanged);
    // 提醒提前量变化：前台触发一轮 diff，让已归属事件按新提前量 upsert。
    // 关闭 / 未登录 / 非前台时仍走既有零写入门禁，不产生任何系统日历写入。
    CalendarReminderSettings.instance.addListener(_onReminderChanged);
    // 安装清理 drain 钩子：控制层在清理临界区之外调用它，让在途写入先落地。
    _control.setBeforeCleanupDrain(stopAndDrainForCleanup);
    _foreground = true;
    _requestSync();
  }

  /// 清理前排空（Issue #48）：失效在途轮次、抑制补跑、等待当前轮结束。
  ///
  /// 由 [CalendarSyncControl] 在清理临界区**之外**调用（避免与内部串行队列死锁）。
  /// 返回后本轮 `_run` 已结束：其写入要么已完成、要么已在下一个 await 边界失效，
  /// 控制层因此可安全地只读扫描 / 精确删除。
  Future<void> stopAndDrainForCleanup() async {
    _runToken++;
    _rerunRequested = false;
    final active = _activeRun;
    if (active == null) return;
    try {
      await active;
    } catch (_) {
      // 本轮异常已由 _run 内部兜底；这里只需确保它已结束。
    }
  }

  /// 前台恢复：允许启动新写并主动触发一轮。
  void onAppResumed() {
    _foreground = true;
    _requestSync();
  }

  /// 退到后台/失焦：禁止启动新写，并让在途轮次在下一个 await 边界失效。
  void onAppInactive() {
    _foreground = false;
    _runToken++;
  }

  /// 正方身份变化：**同步**失效在途旧轮（避免其在排队/await 期间继续写），
  /// 再按新身份同步控制态（换号暂停/同号重登恢复）并触发新一轮。
  Future<void> onAuthIdentityChanged() {
    _runToken++;
    return _pauseThenRequest();
  }

  void onCampusDataChanged() => _requestSync();

  void onSemesterStartChanged() => _requestSync();

  /// 控制态变化：非 enabled（暂停/清理中）**同步**失效在途轮次；enabled 时触发。
  void onControlStateChanged() {
    if (_control.state != CalendarSyncControlState.enabled) {
      _runToken++;
      return;
    }
    _requestSync();
  }

  /// 手动触发（测试与内部复用）。
  void requestSync() => _requestSync();

  void _onAuthChanged() => unawaited(onAuthIdentityChanged());
  void _onDataChanged() => _requestSync();
  void _onControlChanged() => onControlStateChanged();
  void _onReminderChanged() => _requestSync();

  /// 当前已验证 owner：未登录 / 空白一律为 null（= 无身份，控制层据此进入
  /// 「等待身份」而不是暂停；只有非空且不同于绑定 owner 才算换号）。
  static String? _verifiedOwner(CalendarSyncIdentity identity) {
    if (!identity.isLoggedIn) return null;
    final owner = identity.ownerKey?.trim();
    return owner == null || owner.isEmpty ? null : owner;
  }

  Future<void> _pauseThenRequest() async {
    try {
      final identity = _readIdentity();
      await _control.pauseIfOwnerMismatch(
        ownerKey: _verifiedOwner(identity),
        revision: identity.revision,
      );
    } catch (error) {
      _logSafe(LogLevel.warn, '日历同步：身份同步失败（${error.runtimeType}），已跳过');
    }
    _requestSync();
  }

  void _requestSync() {
    if (!_foreground) return;
    if (_activeRun != null) {
      // 单轮并发去重：当前轮结束后再补跑一次。
      _rerunRequested = true;
      return;
    }
    final run = _run();
    _activeRun = run;
    unawaited(
      run.whenComplete(() {
        if (!identical(_activeRun, run)) return;
        _activeRun = null;
        if (_rerunRequested && _foreground) {
          _rerunRequested = false;
          _requestSync();
        }
      }),
    );
  }

  /// 测试钩子：等待当前（及被合并补跑的）轮次全部结束。
  @visibleForTesting
  Future<void> waitForIdle() async {
    while (_activeRun != null) {
      await _activeRun;
    }
  }

  @visibleForTesting
  Future<void>? get debugActiveRun => _activeRun;

  Future<void> _run() async {
    final token = ++_runToken;
    try {
      await _control.load();
      // 仅复核本轮 token + 前台；身份缺失（登出 / 过期 / 冷启动未恢复）不在此提前
      // 返回，交给下面显式的「等待身份」分支同步控制层并如实报告 noWork。
      if (token != _runToken || !_foreground) return;

      final identity = _readIdentity();
      final verifiedOwner = _verifiedOwner(identity);
      await _control.pauseIfOwnerMismatch(
        ownerKey: verifiedOwner,
        revision: identity.revision,
      );
      // 教务未登录 / 会话过期 / 冷启动尚未恢复：控制层保持 enabled（等待身份），
      // 但本轮绝不写日历；同一 owner 重新登录后由身份变化触发下一轮。
      if (verifiedOwner == null) {
        _setOutcome(CalendarSyncRunOutcome.noWork);
        return;
      }
      if (!_stillValid(token, null)) return;
      if (!_control.isWritable) {
        _setOutcome(CalendarSyncRunOutcome.noWork);
        return;
      }

      final owner = verifiedOwner;
      final calendarId = _control.calendarId;
      if (calendarId == null || calendarId <= 0) {
        _setOutcome(CalendarSyncRunOutcome.noWork);
        return;
      }

      // 本轮不可变身份三元组：owner + revision + calendarId。此后每个 await
      // 前后都与当前直接读到的 auth / 控制绑定做同三元组比较——换号并对 B
      // 显式 enable 后，旧 A 轮次因 owner/calendar 不符立即失效，不得继续
      // 操作 A 日历。
      final run = _RunIdentity(
        ownerKey: owner,
        revision: identity.revision,
        calendarId: calendarId,
      );
      if (!_stillValid(token, run)) return;

      // 只认已确认当前学期；绝不用日期 fallback 假装已确认。
      final term = _readKnownCurrentTerm();
      if (term == null) {
        _setOutcome(CalendarSyncRunOutcome.noWork);
        return;
      }

      final snapshot = _loadSnapshot(ownerKey: owner, term: term);
      if (snapshot == null) {
        _setOutcome(CalendarSyncRunOutcome.noWork);
        return;
      }

      final List<ProjectedCourseOccurrence> desired;
      try {
        desired = _projector(
          snapshot: snapshot,
          verifiedOwner: owner,
          confirmedCurrentTerm: term,
          semesterStartDate: _readSemesterStartDate(),
          now: _clock(),
          reminderMinutes: _readReminderMinutes(),
        );
      } on CalendarProjectionException catch (error) {
        // 只记结构性原因，绝不记课程/学号。
        _logSafe(LogLevel.info, '日历同步投影 fail-closed：${error.reason.name}');
        _setOutcome(CalendarSyncRunOutcome.noWork);
        return;
      }
      if (!_stillValid(token, run)) return;

      // 全 owner pending 复核：失败或仍有 pending 不开始差量。
      final CalendarSyncReconcileResult reconcile;
      try {
        reconcile = await _control.reconcilePending();
      } on CalendarSyncException catch (error) {
        _logSafe(LogLevel.warn, '日历同步：pending 复核异常（${error.kind.name}），已中止本轮');
        _setOutcome(CalendarSyncRunOutcome.failed);
        return;
      }
      if (!_stillValid(token, run)) return;
      if (reconcile.hasFailure || reconcile.pendingRemaining > 0) {
        _logSafe(
          LogLevel.info,
          '日历同步：仍有未复核 pending（${reconcile.pendingRemaining}），本轮不差量',
        );
        _setOutcome(CalendarSyncRunOutcome.blocked);
        return;
      }

      CalendarEventLedgerSnapshot ledgerSnapshot;
      try {
        ledgerSnapshot = await _ledger.reload();
      } on CalendarSyncException catch (error) {
        _logSafe(LogLevel.warn, '日历同步：账本读取失败（${error.kind.name}），已中止本轮');
        _setOutcome(CalendarSyncRunOutcome.failed);
        return;
      }
      if (!_stillValid(token, run)) return;

      final result = await _applyDiff(
        token: token,
        run: run,
        term: term,
        desired: desired,
        ledgerSnapshot: ledgerSnapshot,
      );
      _setOutcome(result);
    } catch (error) {
      // 兜底：只记运行时类型，绝不把原始异常/堆栈（可能含课程内容）写日志。
      _logSafe(LogLevel.warn, '日历同步：未预期异常（${error.runtimeType}），已安全中止');
      _setOutcome(CalendarSyncRunOutcome.failed);
    }
  }

  Future<CalendarSyncRunOutcome> _applyDiff({
    required int token,
    required _RunIdentity run,
    required ScheduleTermContext term,
    required List<ProjectedCourseOccurrence> desired,
    required CalendarEventLedgerSnapshot ledgerSnapshot,
  }) async {
    final owner = run.ownerKey;
    final calendarId = run.calendarId;
    // 当前 owner + 目标日历的全部映射（含老批次）；同键取最新且有 eventId 的一条。
    final byKey =
        <String, List<({CalendarEventLedgerEntry entry, String generation})>>{};
    for (final batch in ledgerSnapshot.batchesFor(owner)) {
      if (batch.calendarId != calendarId) continue;
      for (final entry in batch.entries.values) {
        byKey.putIfAbsent(entry.businessKey, () => []).add((
          entry: entry,
          generation: batch.generation,
        ));
      }
    }

    final chosen =
        <String, ({CalendarEventLedgerEntry entry, String generation})>{};
    for (final item in byKey.entries) {
      final list = item.value;
      final withEvent = list
          .where((x) => x.entry.eventId != null)
          .toList(growable: false);
      final pick = withEvent.isNotEmpty ? withEvent.last : list.last;
      chosen[item.key] = pick;
    }

    final desiredKeys = <String>{
      for (final occurrence in desired) occurrence.businessKey,
    };

    final newPairs =
        <({ProjectedCourseOccurrence occurrence, String opaqueId})>[];
    final updates =
        <
          ({
            ProjectedCourseOccurrence occurrence,
            CalendarEventLedgerEntry entry,
            String generation,
          })
        >[];
    for (final occurrence in desired) {
      final pick = chosen[occurrence.businessKey];
      if (pick == null) {
        newPairs.add((
          occurrence: occurrence,
          opaqueId: CalendarSyncOpaqueId.generate(),
        ));
        continue;
      }
      // reconcile 已保证无 pending；异常情况一律 fail closed。
      if (pick.entry.eventId == null) {
        _logSafe(LogLevel.info, '日历同步：存在未复核映射，本轮不差量');
        return CalendarSyncRunOutcome.blocked;
      }
      updates.add((
        occurrence: occurrence,
        entry: pick.entry,
        generation: pick.generation,
      ));
    }

    // 需要删除的陈旧项：当前学期 + 本 owner/日历，且不是「期望集合中被选中的
    // 那条映射」（未期望项或重复映射）。历史学期一律保留。
    final stale = <({CalendarEventLedgerEntry entry, String generation})>[];
    for (final item in byKey.entries) {
      if (!calendarBusinessKeyBelongsToTerm(item.key, term)) continue;
      final isDesired = desiredKeys.contains(item.key);
      final pickOpaqueId = chosen[item.key]?.entry.opaqueId;
      for (final candidate in item.value) {
        if (isDesired && candidate.entry.opaqueId == pickOpaqueId) continue;
        if (candidate.entry.eventId == null) continue;
        stale.add(candidate);
      }
    }

    // C1：本轮要新建键时，先只读扫描当前日历，确认没有「账本未记录的自有事件」。
    // 有未记账自有事件（或扫描不完整）即 fail closed，绝不新建 opaque，避免叠加重复。
    if (newPairs.isNotEmpty) {
      final accounted = await _guardAgainstUnaccountedOwnEvents(
        token: token,
        run: run,
        ledgerSnapshot: ledgerSnapshot,
      );
      if (!_stillValid(token, run)) return CalendarSyncRunOutcome.blocked;
      if (!accounted) {
        _logSafe(LogLevel.info, '日历同步：当前日历存在未记账的自有事件，本轮不新建（fail closed）');
        return CalendarSyncRunOutcome.blocked;
      }
    }

    var deletedCount = 0;

    // Phase A：新记录先落盘 → native upsert → 仅当前代 commit。
    for (final chunk in _chunk(newPairs, CalendarSyncProtocol.maxBatchEvents)) {
      if (!_stillValid(token, run)) return CalendarSyncRunOutcome.blocked;

      final CalendarEventLedgerBatch batch;
      try {
        batch = await _ledger.beginPendingBatch(
          ownerKey: owner,
          calendarId: calendarId,
          plans: <CalendarSyncEventPlan>[
            for (final pair in chunk)
              pair.occurrence.toEventPlan(opaqueId: pair.opaqueId),
          ],
          now: _clock(),
        );
      } on CalendarSyncException catch (error) {
        _logSafe(LogLevel.warn, '日历同步：pending 落盘失败（${error.kind.name}），已中止本轮');
        return CalendarSyncRunOutcome.failed;
      }
      if (!_stillValid(token, run)) return CalendarSyncRunOutcome.blocked;

      final CalendarSyncBatchResult upsert;
      try {
        upsert = await _channel.upsertEventBatch(
          calendarId: calendarId,
          events: <CalendarSyncEventDraft>[
            for (final pair in chunk)
              pair.occurrence.toEventDraft(opaqueId: pair.opaqueId),
          ],
        );
      } on CalendarSyncException catch (error) {
        _logSafe(LogLevel.warn, '日历同步：新增事件写入失败（${error.kind.name}），保留 pending');
        return CalendarSyncRunOutcome.failed;
      }
      if (!_stillValid(token, run)) return CalendarSyncRunOutcome.blocked;

      final CalendarEventLedgerCommitResult commit;
      try {
        commit = await _ledger.commitBatch(
          ownerKey: owner,
          generation: batch.generation,
          eventIds: upsert.eventIds,
        );
      } on CalendarSyncException catch (error) {
        _logSafe(
          LogLevel.warn,
          '日历同步：eventId 登记失败（${error.kind.name}），保留 pending',
        );
        return CalendarSyncRunOutcome.failed;
      }
      if (!_stillValid(token, run)) return CalendarSyncRunOutcome.blocked;
      // 完整校验 commit 结果：拒绝 / unknown / stale 一律 fail closed，绝不删除。
      final expectedOpaqueIds = <String>[
        for (final pair in chunk) pair.opaqueId,
      ];
      if (!commit.accepted ||
          commit.unknownOpaqueIds.isNotEmpty ||
          !commit.appliedOpaqueIds.toSet().containsAll(expectedOpaqueIds)) {
        _logSafe(
          LogLevel.warn,
          '日历同步：eventId 登记未被接受（${commit.status.name}），本轮不做删除',
        );
        return CalendarSyncRunOutcome.failed;
      }
    }

    // Phase B：已有映射按业务键覆盖（同 opaqueId update，覆盖用户手改属性）；
    // provider 若返回重建后的新 eventId，则受约束回写账本原批次。
    for (final chunk in _chunk(updates, CalendarSyncProtocol.maxBatchEvents)) {
      if (!_stillValid(token, run)) return CalendarSyncRunOutcome.blocked;

      final CalendarSyncBatchResult upsert;
      try {
        upsert = await _channel.upsertEventBatch(
          calendarId: calendarId,
          events: <CalendarSyncEventDraft>[
            for (final update in chunk)
              update.occurrence.toEventDraft(opaqueId: update.entry.opaqueId),
          ],
        );
      } on CalendarSyncException catch (error) {
        _logSafe(LogLevel.warn, '日历同步：既有事件更新失败（${error.kind.name}），本轮不做删除');
        return CalendarSyncRunOutcome.failed;
      }
      if (!_stillValid(token, run)) return CalendarSyncRunOutcome.blocked;

      for (final update in chunk) {
        final providerNewId = upsert.eventIds[update.entry.opaqueId];
        final ledgerOldId = update.entry.eventId!;
        if (providerNewId == null || providerNewId == ledgerOldId) continue;
        final bool rebound;
        try {
          rebound = await _ledger.reassignEventId(
            ownerKey: owner,
            generation: update.generation,
            opaqueId: update.entry.opaqueId,
            expectedOldEventId: ledgerOldId,
            providerVerifiedNewEventId: providerNewId,
          );
        } on CalendarSyncException catch (error) {
          _logSafe(
            LogLevel.warn,
            '日历同步：eventId 重绑定失败（${error.kind.name}），本轮不做删除',
          );
          return CalendarSyncRunOutcome.failed;
        }
        // guard 失效（换号/关闭）时不继续；账本原批次 CAS 未满足也 fail closed。
        if (!_stillValid(token, run)) return CalendarSyncRunOutcome.blocked;
        if (!rebound) {
          _logSafe(LogLevel.warn, '日历同步：eventId 重绑定被拒绝，本轮不做删除');
          return CalendarSyncRunOutcome.failed;
        }
      }
    }

    // 全部可信写入完成且身份仍有效，才允许删除陈旧项。
    if (!_stillValid(token, run)) return CalendarSyncRunOutcome.blocked;

    var notDeletedCount = 0;
    for (final chunk in _chunk(stale, CalendarSyncProtocol.maxBatchEvents)) {
      if (!_stillValid(token, run)) return CalendarSyncRunOutcome.blocked;

      final CalendarSyncDeleteResult deleteResult;
      try {
        deleteResult = await _channel.deleteOwnedEventsByIds(
          calendarId: calendarId,
          events: <CalendarSyncOwnedEvent>[
            for (final item in chunk)
              CalendarSyncOwnedEvent(
                opaqueId: item.entry.opaqueId,
                eventId: item.entry.eventId!,
              ),
          ],
        );
      } on CalendarSyncException catch (error) {
        _logSafe(LogLevel.warn, '日历同步：陈旧事件删除失败（${error.kind.name}），保留账本');
        return CalendarSyncRunOutcome.failed;
      }

      final deletedIds = deleteResult.deletedIds.toSet();
      final byGeneration = <String, List<String>>{};
      for (final item in chunk) {
        if (deletedIds.contains(item.entry.eventId)) {
          byGeneration
              .putIfAbsent(item.generation, () => <String>[])
              .add(item.entry.opaqueId);
        }
      }
      for (final group in byGeneration.entries) {
        try {
          deletedCount += await _ledger.removeEntries(
            ownerKey: owner,
            generation: group.key,
            opaqueIds: group.value,
          );
        } on CalendarSyncException catch (error) {
          _logSafe(LogLevel.warn, '日历同步：已删除项账本移除失败（${error.kind.name}）');
          return CalendarSyncRunOutcome.failed;
        }
      }
      notDeletedCount += chunk.length - deletedIds.length;
      // 删除已发生：确认项已 removeEntries；此处再校验一次，guard 失效则不继续
      // 删除后续 chunk。
      if (!_stillValid(token, run)) return CalendarSyncRunOutcome.blocked;
    }

    if (notDeletedCount > 0) {
      _logSafe(LogLevel.info, '日历同步：$notDeletedCount 项未删除（已留账本，可重试）');
    }
    _logSafe(
      LogLevel.debug,
      '日历同步完成：新增/更新 ${newPairs.length + updates.length}，删除 $deletedCount',
    );
    return CalendarSyncRunOutcome.synced;
  }

  /// C1 守卫：当前日历是否存在**账本未记录**的自有事件（或扫描不完整）。
  ///
  /// 返回 false 表示必须 fail closed（不新建键）。只读扫描，绝不写 provider。
  Future<bool> _guardAgainstUnaccountedOwnEvents({
    required int token,
    required _RunIdentity run,
    required CalendarEventLedgerSnapshot ledgerSnapshot,
  }) async {
    final scan = await _discovery.scanOwnedEvents(calendarId: run.calendarId);
    if (!_stillValid(token, run)) return false;
    if (!scan.complete) return false;
    final accounted = <String>{
      for (final batch in ledgerSnapshot.batchesFor(run.ownerKey))
        if (batch.calendarId == run.calendarId)
          for (final entry in batch.entries.values) entry.opaqueId,
    };
    for (final event in scan.events) {
      if (!accounted.contains(event.opaqueId)) return false;
    }
    return true;
  }

  /// 二重校验：本轮 token + 前台 + 直接读到的正方身份 + 控制绑定。
  ///
  /// [run] 非空时必须与**本轮捕获的三元组**（owner + revision + calendarId）
  /// 完全一致：换号并对 B 显式 enable 后，即使当前 B 可写，旧 A 轮次也会因
  /// owner/calendar 不符而失效。identity 由调用方直接读正方会话。
  bool _stillValid(int token, _RunIdentity? run) {
    if (token != _runToken) return false;
    if (!_foreground) return false;
    final identity = _readIdentity();
    if (!identity.isLoggedIn) return false;
    final owner = identity.ownerKey?.trim();
    if (owner == null || owner.isEmpty) return false;
    if (run != null) {
      if (owner != run.ownerKey) return false;
      if (identity.revision != run.revision) return false;
      if (_control.ownerKey != run.ownerKey) return false;
      if (_control.calendarId != run.calendarId) return false;
    }
    return _control.canWriteFor(ownerKey: owner, revision: identity.revision);
  }

  void _setOutcome(CalendarSyncRunOutcome value) {
    if (outcome.value != value) outcome.value = value;
  }

  /// 只记结构性信息（消息里仅含 [CalendarSyncFailureKind] / runtimeType），
  /// **绝不**把原始异常对象、堆栈或业务键传给日志——日历异常可能含课程内容。
  void _logSafe(LogLevel level, String message) {
    AppLogger.instance.log(level, LogCategory.general, message);
  }

  static Iterable<List<T>> _chunk<T>(List<T> items, int size) sync* {
    for (var start = 0; start < items.length; start += size) {
      final end = start + size < items.length ? start + size : items.length;
      yield items.sublist(start, end);
    }
  }
}

/// 单轮不可变身份三元组：owner + revision + calendarId。
@immutable
class _RunIdentity {
  const _RunIdentity({
    required this.ownerKey,
    required this.revision,
    required this.calendarId,
  });

  final String ownerKey;
  final int revision;
  final int calendarId;
}
