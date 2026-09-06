import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../logging/app_logger.dart';
import 'notice_model.dart';

/// 未读摘要：主 isolate 侧红点与新通知块共享的 [ValueListenable] 载荷。
///
/// 后台 isolate 写盘不会跨 isolate 通知，主 isolate 通过 [NoticeSyncStore.reload]
/// 在冷启动 / 回前台 / 进入通知中心时重载刷新。
class NoticeUnreadSummary {
  const NoticeUnreadSummary({required this.count, required this.latest});

  static const NoticeUnreadSummary empty = NoticeUnreadSummary(
    count: 0,
    latest: [],
  );

  final int count;

  /// 最新未读条目（新→旧），最多展示 3 条。
  final List<Notice> latest;
}

/// 首页「校园公告」区块的数据载荷：最新几条收件箱条目（无论已读未读）
/// 加未读标记。与 [NoticeUnreadSummary] 同源，都在 [NoticeSyncStore]
/// 的状态提交点同步更新。
class NoticeInboxHead {
  const NoticeInboxHead({
    required this.latest,
    required this.unreadIds,
    required this.unreadCount,
  });

  static const NoticeInboxHead empty = NoticeInboxHead(
    latest: [],
    unreadIds: {},
    unreadCount: 0,
  );

  /// 最新条目（新→旧），首页固定展示前 3 条。
  final List<Notice> latest;

  /// [latest] 中的未读 id 子集（行首圆点依据）。
  final Set<String> unreadIds;

  /// 全部未读数（标题行徽标，可能大于 latest 内的未读数）。
  final int unreadCount;

  bool get isEmpty => latest.isEmpty;
}

/// 同步状态的不可变快照。
class NoticeSyncSnapshot {
  const NoticeSyncSnapshot({
    required this.snapshotIds,
    required this.inbox,
    required this.unreadIds,
    required this.pendingNotifyIds,
    required this.notifiedIds,
    required this.pendingBackfillPage,
    required this.baselineBuilt,
    this.lastAttemptAt,
    this.lastSuccessfulSyncAt,
  });

  static final NoticeSyncSnapshot empty = NoticeSyncSnapshot(
    snapshotIds: const <String, DateTime>{},
    inbox: const <Notice>[],
    unreadIds: const <String>{},
    pendingNotifyIds: const <String>{},
    notifiedIds: const <String>{},
    pendingBackfillPage: null,
    baselineBuilt: false,
  );

  /// 已知公告全集（id → 首次收录时间）。去重基准，独立持久化，
  /// 不随收件箱裁剪；超出容量按收录时间裁最旧（窗口化去重承诺）。
  final Map<String, DateTime> snapshotIds;

  /// 收件箱条目（新→旧）。
  final List<Notice> inbox;

  final Set<String> unreadIds;

  /// 待播报队列：静音 / 无权限 / 页面刷新时积压于此，后续自动触发补发。
  final Set<String> pendingNotifyIds;

  /// 已成功播报的条目（防重复弹窗）。
  final Set<String> notifiedIds;

  /// 待补录分页游标；null 表示没有欠账。
  final int? pendingBackfillPage;

  final bool baselineBuilt;
  final DateTime? lastAttemptAt;
  final DateTime? lastSuccessfulSyncAt;
}

/// 一轮同步的提交载荷：新条目入 收件箱/未读/快照/待播报，历史补录仅入快照。
class NoticeSyncCommit {
  const NoticeSyncCommit({
    this.freshNotices = const <Notice>[],
    this.baselineNotices = const <Notice>[],
    this.historicNotices = const <Notice>[],
    this.baselineComplete = false,
    this.backfillCursor,
    this.clearBackfillCursor = false,
    this.markSuccess = false,
    required this.now,
  });

  /// 本轮真正的新增条目（调用方已按旧快照算过差集；store 内仍会再次
  /// 去重，并发窗口下可能有别的写者已收录同 id）。
  final List<Notice> freshNotices;

  /// 首启基线条目：进收件箱 + 快照，但**不进未读/待播报**——用户打开
  /// 通知中心与首页立刻能看到当前公告，又不会被历史内容弹窗打扰。
  /// （初版基线只进快照，导致首装后收件箱永远为空，已废弃。）
  final List<Notice> baselineNotices;

  /// 历史补录（page ≥ 2）：只入快照，不进收件箱/未读/待播报。
  final List<Notice> historicNotices;

  /// 首启基线完成标记。
  final bool baselineComplete;

  /// 直接设置补录游标（仅建基线第二页失败时使用）。
  final int? backfillCursor;

  /// 清除补录游标（补录成功后）。
  final bool clearBackfillCursor;

  /// 抓取 ok 时推进 lastSuccessfulSyncAt。
  final bool markSuccess;

  final DateTime now;
}

class NoticeSyncCommitResult {
  const NoticeSyncCommitResult({
    required this.acceptedFresh,
    required this.acceptedBaseline,
    required this.acceptedHistoric,
  });

  /// 去重后真正接受的新增（可能小于提交数：并发写者已收录同 id）。
  final List<Notice> acceptedFresh;
  final List<Notice> acceptedBaseline;
  final List<Notice> acceptedHistoric;
}

enum NoticeSyncClaim { granted, blocked }

/// 同步状态存储。
///
/// 并发模型：主 isolate 与 WorkManager isolate 无共享内存（同进程不同
/// isolate 或跨进程皆然），所有状态读改写通过独立锁文件串行化——
/// 「原子替换」只保护单次写入的完整性，不保护 RMW 过程，因此锁内必须
/// 先重读磁盘（不信任本 isolate 内存镜像），改完临时文件 + rename 写回。
/// 锁实现为 O_EXCL 排他创建 + 持有者 token：按 inode 判冲突，跨进程与
/// 同进程多 isolate 都正确串行化。（fcntl 句柄锁在 Linux 按 process 判
/// 冲突，同进程第二个加锁方不被阻塞——Linux CI 并发用例实证，生产里
/// 主 isolate 与后台 isolate 恰好同进程，故弃用。）
/// 锁内只做内存与文件操作（毫秒级）；网络、platform 通道、通知发送
/// 一律在锁外。锁挂在独立 `.lock` 文件而非状态文件本身：状态文件会被
/// rename 替换，对它持有的锁在替换后失效。残留锁（持有者崩溃、旧版
/// 本遗留的空锁文件）由回收兜底，不会永久阻塞；create 与 token 写入
/// 之间的毫秒级空窗借空锁宽限期与旧版残留区分，防止并发写者互抢新锁
/// （见 [_emptyLockGraceAge]）。
///
/// 调用约束：公开 API 之间不得嵌套调用（同 isolate 内第二次取锁会等待
/// 外层释放 → 死锁）。内部组合只调用 `*_locked` 私有实现。
class NoticeSyncStore {
  NoticeSyncStore._({Future<Directory> Function()? directoryProvider})
    : debugDirectoryProvider = directoryProvider;

  static final NoticeSyncStore instance = NoticeSyncStore._();

  /// 测试专用：创建独立实例。两个实例指向同一目录即构成「双写者」，
  /// 用于锁串行化与交错写入的并发测试。
  @visibleForTesting
  static NoticeSyncStore debugNew({
    required Future<Directory> Function() directoryProvider,
  }) => NoticeSyncStore._(directoryProvider: directoryProvider);

  static const int _schemaVersion = 2;
  static const int _snapshotCap = 2000;
  static const int _inboxCap = 100;
  static const int _notifiedCap = 500;

  static const String stateFileName = 'notice_sync_state.json';
  static const String lockFileName = 'notice_sync_state.lock';

  /// 残留锁回收阈值（有 token 的锁）。锁内只有毫秒级本地 IO（网络在
  /// 锁外），超龄即视为持有者已死。
  static const Duration _staleLockAge = Duration(seconds: 60);

  /// 空锁文件宽限期。create 与 token 写入是两步异步操作，中间存在合法
  /// 的「已创建、尚为空」窗口（毫秒级）；旧版本遗留的空锁文件则永不
  /// 增重。宽限期内视空锁为活跃写者的取锁中态，照常轮询等待——否则
  /// 并发写者会把新锁当旧版残留删掉，双方同时进入临界区（CI 并发用例
  /// 实证：claim 与 notify 各放行两方）。
  static const Duration _emptyLockGraceAge = Duration(milliseconds: 250);
  static const Duration _lockPollMaxDelay = Duration(milliseconds: 50);

  NoticeSyncSnapshot _state = NoticeSyncSnapshot.empty;

  final Random _random = Random();

  final ValueNotifier<NoticeUnreadSummary> unreadSummary =
      ValueNotifier<NoticeUnreadSummary>(NoticeUnreadSummary.empty);

  /// 首页「校园公告」区块载荷（最新 3 条 + 未读标记），与 [unreadSummary]
  /// 在同一状态提交点更新。
  final ValueNotifier<NoticeInboxHead> inboxHead =
      ValueNotifier<NoticeInboxHead>(NoticeInboxHead.empty);

  NoticeSyncSnapshot get state => _state;

  /// 测试替身：注入临时目录，避免碰真实应用支持目录。
  @visibleForTesting
  Future<Directory> Function()? debugDirectoryProvider;

  /// 测试替身：直接注入内存态并走 [unreadSummary] / [inboxHead] 的同一
  /// 提交点。真实文件锁与磁盘 I/O 在 flutter_test 的假异步区永远不会
  /// 完成（页面 initState 里的 reload 会挂到测试超时），预览/组件测试
  /// 用它替代落盘种子。
  @visibleForTesting
  void debugInjectState(NoticeSyncSnapshot snapshot) =>
      _applyStateLocked(snapshot);

  /// 测试替身：置 true 后 [reload] 直接返回当前内存态，跳过锁与磁盘。
  @visibleForTesting
  bool debugReloadNoop = false;

  @visibleForTesting
  void debugReset() {
    _state = NoticeSyncSnapshot.empty;
    unreadSummary.value = NoticeUnreadSummary.empty;
    inboxHead.value = NoticeInboxHead.empty;
    debugDirectoryProvider = null;
    debugReloadNoop = false;
  }

  // ── 读路径 ──────────────────────────────────────────────────────────

  /// 从磁盘无条件重载状态并刷新未读摘要。纯本地操作，不受任何网络节流
  /// 影响——后台 isolate 写盘后主 isolate 靠它获得最新状态。
  Future<NoticeSyncSnapshot> reload() async {
    if (debugReloadNoop) return _state;
    return _withLock(() async {
      final file = await _stateFile();
      final loaded = await _readStateLocked(file);
      _applyStateLocked(loaded);
      return _state;
    });
  }

  // ── 写路径（全部锁内 RMW） ─────────────────────────────────────────

  /// 同步资格领取：锁内原子判定 + 记录尝试时间，并发触发只有一方通过。
  ///
  /// 节流语义：有成功记录时按 [successInterval]（距上次成功）节奏；从未
  /// 成功过时按 [attemptInterval] 退避重试（失败不会永久挡住同步）。
  /// force（手动刷新 / 登录后重试）绕过时间节流但不绕过锁。
  Future<NoticeSyncClaim> claimSync({
    required DateTime now,
    required bool force,
    Duration successInterval = const Duration(hours: 2),
    Duration attemptInterval = const Duration(minutes: 30),
  }) {
    return _withLock(() async {
      final file = await _stateFile();
      var state = await _readStateLocked(file);
      if (!force) {
        final lastSuccess = state.lastSuccessfulSyncAt;
        final bool granted;
        if (lastSuccess != null) {
          granted = now.difference(lastSuccess) >= successInterval;
        } else {
          final lastAttempt = state.lastAttemptAt;
          granted =
              lastAttempt == null ||
              now.difference(lastAttempt) >= attemptInterval;
        }
        if (!granted) {
          return NoticeSyncClaim.blocked;
        }
      }
      state = _copyWith(state, lastAttemptAt: now);
      await _writeStateLocked(file, state);
      _applyStateLocked(state);
      return NoticeSyncClaim.granted;
    });
  }

  /// 提交一轮同步的集合变更（合并语义，幂等）。
  ///
  /// 裁剪联动：收件箱超出容量裁最旧时，被裁条目同步移出未读与待播报
  /// （已不在收件箱的条目不再弹窗、不再计入红点）。
  Future<NoticeSyncCommitResult> commitSync(NoticeSyncCommit commit) {
    return _withLock(() async {
      final file = await _stateFile();
      var state = await _readStateLocked(file);

      final acceptedFresh = <Notice>[];
      final acceptedBaseline = <Notice>[];
      final acceptedHistoric = <Notice>[];
      final snapshotIds = Map<String, DateTime>.of(state.snapshotIds);

      void absorb(List<Notice> notices, List<Notice> accepted) {
        for (final notice in notices) {
          if (snapshotIds.containsKey(notice.id)) continue;
          snapshotIds[notice.id] = commit.now;
          accepted.add(notice);
        }
      }

      absorb(commit.freshNotices, acceptedFresh);
      absorb(commit.baselineNotices, acceptedBaseline);
      absorb(commit.historicNotices, acceptedHistoric);

      // 快照裁最旧（插入序即收录序；LinkedHashMap 保持插入序）。
      while (snapshotIds.length > _snapshotCap) {
        snapshotIds.remove(snapshotIds.keys.first);
      }

      // 收件箱：新条目/基线条目插头部，按 id 去重，裁最旧（尾部）。
      final freshIds = acceptedFresh.map((n) => n.id).toSet();
      final inboxHeadIds = <String>{
        ...freshIds,
        ...acceptedBaseline.map((n) => n.id),
      };
      var inbox = <Notice>[
        ...acceptedFresh,
        ...acceptedBaseline,
        ...state.inbox.where((n) => !inboxHeadIds.contains(n.id)),
      ];
      // 教务处列表页顺序不等于时间序（置顶/补录混排），收件箱统一按
      // 发布日期倒序持久化，首页与通知中心的「最新」才可靠。
      inbox = Notice.sortByDateDescStable(inbox);
      final evicted = <String>{};
      if (inbox.length > _inboxCap) {
        for (final notice in inbox.skip(_inboxCap)) {
          evicted.add(notice.id);
        }
        inbox = inbox.sublist(0, _inboxCap);
      }

      // 复制后修改：快照持有的集合不可原地变更（空快照为 const 集合）。
      // 基线条目只进收件箱与快照：可见、不打扰（无未读、无弹窗）。
      final unread = Set<String>.of(state.unreadIds)
        ..addAll(freshIds)
        ..removeAll(evicted);
      final pending = Set<String>.of(state.pendingNotifyIds)
        ..addAll(freshIds)
        ..removeAll(evicted);
      final notified = Set<String>.of(state.notifiedIds)
          .where(snapshotIds.containsKey)
          .toSet();

      var notifiedSet = notified;
      if (notifiedSet.length > _notifiedCap) {
        // Set 无序，超限保留任意子集即可：仅影响理论边界（极旧 id 重发
        // 的公告可能再弹一次），cap 500 远大于现实积压规模。
        notifiedSet = Set<String>.of(notifiedSet.take(_notifiedCap));
      }

      state = NoticeSyncSnapshot(
        snapshotIds: snapshotIds,
        inbox: inbox,
        unreadIds: unread,
        pendingNotifyIds: pending,
        notifiedIds: notifiedSet,
        pendingBackfillPage: commit.clearBackfillCursor
            ? null
            : (commit.backfillCursor ?? state.pendingBackfillPage),
        baselineBuilt: state.baselineBuilt || commit.baselineComplete,
        lastAttemptAt: state.lastAttemptAt,
        lastSuccessfulSyncAt: commit.markSuccess
            ? commit.now
            : state.lastSuccessfulSyncAt,
      );
      await _writeStateLocked(file, state);
      _applyStateLocked(state);
      return NoticeSyncCommitResult(
        acceptedFresh: acceptedFresh,
        acceptedBaseline: acceptedBaseline,
        acceptedHistoric: acceptedHistoric,
      );
    });
  }

  /// 播报资格领取：锁内一次性取走全部待播报条目并写盘。并发同步中
  /// 只有拿到非空批次的一方播报，杜绝双弹窗。
  /// [canNotify] 为 false（静音 / 无权限 / 页面刷新）时不动队列。
  Future<List<Notice>> claimNotifyBatch({required bool canNotify}) {
    return _withLock(() async {
      final file = await _stateFile();
      final state = await _readStateLocked(file);
      if (!canNotify || state.pendingNotifyIds.isEmpty) return const <Notice>[];

      final pendingIds = state.pendingNotifyIds;
      final batch = state.inbox
          .where((n) => pendingIds.contains(n.id))
          .toList(growable: false);
      // 已被裁剪出收件箱的 pending id 属于脏余量，领取时一并清理。
      final nextState = _copyWith(state, pendingNotifyIds: const <String>{});
      await _writeStateLocked(file, nextState);
      _applyStateLocked(nextState);
      return batch;
    });
  }

  /// 播报成功确认：并入已播报集合（从待播报移除是幂等收尾）。
  Future<void> confirmNotified(Iterable<Notice> batch) {
    return _withLock(() async {
      final file = await _stateFile();
      final state = await _readStateLocked(file);
      if (batch.isEmpty) return;
      final notified = Set<String>.of(state.notifiedIds)
        ..addAll(batch.map((n) => n.id));
      if (notified.length > _notifiedCap) {
        final trimmed = notified.take(_notifiedCap);
        notified
          ..clear()
          ..addAll(trimmed);
      }
      final nextState = _copyWith(
        state,
        notifiedIds: notified,
        pendingNotifyIds: state.pendingNotifyIds
          ..removeAll(batch.map((n) => n.id)),
      );
      await _writeStateLocked(file, nextState);
      _applyStateLocked(nextState);
    });
  }

  /// 播报失败回滚：批次放回待播报队列，下轮重试。
  Future<void> rollbackNotifyBatch(Iterable<Notice> batch) {
    return _withLock(() async {
      final file = await _stateFile();
      final state = await _readStateLocked(file);
      if (batch.isEmpty) return;
      final pending = Set<String>.of(state.pendingNotifyIds)
        ..addAll(batch.map((n) => n.id));
      final nextState = _copyWith(state, pendingNotifyIds: pending);
      await _writeStateLocked(file, nextState);
      _applyStateLocked(nextState);
    });
  }

  /// 标记已读：移出未读；联动移出待播报（已看过内容不再弹窗）。
  Future<void> markRead(Iterable<String> ids) {
    return _withLock(() async {
      final file = await _stateFile();
      final state = await _readStateLocked(file);
      final removed = ids.toSet();
      if (state.unreadIds.intersection(removed).isEmpty &&
          state.pendingNotifyIds.intersection(removed).isEmpty) {
        return;
      }
      final nextState = _copyWith(
        state,
        unreadIds: state.unreadIds..removeAll(removed),
        pendingNotifyIds: state.pendingNotifyIds..removeAll(removed),
      );
      await _writeStateLocked(file, nextState);
      _applyStateLocked(nextState);
    });
  }

  Future<void> markAllRead() {
    return _withLock(() async {
      final file = await _stateFile();
      final state = await _readStateLocked(file);
      if (state.unreadIds.isEmpty && state.pendingNotifyIds.isEmpty) return;
      final nextState = _copyWith(
        state,
        unreadIds: const <String>{},
        pendingNotifyIds: const <String>{},
      );
      await _writeStateLocked(file, nextState);
      _applyStateLocked(nextState);
    });
  }

  // ── 内部 ────────────────────────────────────────────────────────────

  /// O_EXCL 排他创建文件锁：`create(exclusive: true)` 按 inode 原子判
  /// 冲突，跨进程与同进程多 isolate 都正确（fcntl 句柄锁在 Linux 按
  /// process 判冲突，同进程第二加锁方不被阻塞，见类注释）。
  Future<T> _withLock<T>(Future<T> Function() action) async {
    final lockFile = await _lockFile();
    final token = await _acquireFileLock(lockFile);
    try {
      return await action();
    } finally {
      await _releaseFileLock(lockFile, token);
    }
  }

  Future<String> _acquireFileLock(File lockFile) async {
    final token =
        'pid-$pid-${DateTime.now().microsecondsSinceEpoch}-'
        '${identityHashCode(this)}-${_random.nextInt(0x7fffffff)}';
    var delay = const Duration(milliseconds: 1);
    while (true) {
      try {
        await lockFile.create(exclusive: true);
        final raf = await lockFile.open(mode: FileMode.append);
        try {
          await raf.writeString(token);
          await raf.flush();
        } finally {
          await raf.close();
        }
        // 校验锁文件内容仍是自己的 token：token 写入期间锁可能被他人
        // 回收重取（读到别人的 token，或路径已消失）。此时绝不能带着
        // 「假锁」进临界区，回到竞争循环重新取锁即可。追加模式保证误写
        // 只会拼在他人 token 之后，真正的持有者以 startsWith 识别并
        // 正常释放。
        if (await _readTokenSafe(lockFile) == token) return token;
      } on FileSystemException catch (error) {
        if (!_isPathExistsError(error)) rethrow;
        if (await _tryRecoverStaleLock(lockFile)) continue;
      }
      await Future<void>.delayed(delay);
      if (delay < _lockPollMaxDelay) delay *= 2;
    }
  }

  Future<String?> _readTokenSafe(File lockFile) async {
    try {
      return await lockFile.readAsString();
    } on FileSystemException {
      return null;
    }
  }

  bool _isPathExistsError(FileSystemException error) {
    if (error is PathExistsException) return true;
    final code = error.osError?.errorCode;
    // EEXIST (POSIX) / ERROR_ALREADY_EXISTS (Windows)。
    return code == 17 || code == 183;
  }

  /// 残留锁回收：有 token 的锁超龄（持有者已死，如后台任务被系统杀死）
  /// 或空文件超宽限期（旧版本从不写 token，其空锁永不增重）时删除，
  /// 返回 true 供调用方立即重试创建。空文件在宽限期内视为活跃写者的
  /// 取锁中态，不可回收（见 [_emptyLockGraceAge]）。
  Future<bool> _tryRecoverStaleLock(File lockFile) async {
    try {
      final stat = await lockFile.stat();
      final age = DateTime.now().difference(stat.modified);
      final isAged = age >= _staleLockAge;
      final isEmptyAged = stat.size == 0 && age >= _emptyLockGraceAge;
      if (!isAged && !isEmptyAged) return false;
      await lockFile.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _releaseFileLock(File lockFile, String token) async {
    try {
      // 仅当锁内仍是自己的 token 才删除：超龄锁被回收、他人已接手时，
      // 绝不能误删新持有者的锁。startsWith 兼容后来者在我方 token 之后
      // 的误追加（见 [_acquireFileLock] 读校验注释）：文件头是我即仍是
      // 我的锁，正常删除，避免残留到陈旧回收。
      final content = await _readTokenSafe(lockFile);
      if (content != null && content.startsWith(token)) {
        await lockFile.delete();
      }
    } on FileSystemException {
      // 锁已被回收或读取失败：无需处理。
    }
  }

  void _applyStateLocked(NoticeSyncSnapshot state) {
    _state = state;
    final unreadIds = state.unreadIds;
    final latestUnread = state.inbox
        .where((n) => unreadIds.contains(n.id))
        .take(3)
        .toList(growable: false);
    unreadSummary.value = NoticeUnreadSummary(
      count: unreadIds.length,
      latest: latestUnread,
    );

    final latestAll = state.inbox.take(3).toList(growable: false);
    inboxHead.value = NoticeInboxHead(
      latest: latestAll,
      unreadIds: latestAll
          .where((n) => unreadIds.contains(n.id))
          .map((n) => n.id)
          .toSet(),
      unreadCount: unreadIds.length,
    );
  }

  NoticeSyncSnapshot _copyWith(
    NoticeSyncSnapshot state, {
    Map<String, DateTime>? snapshotIds,
    List<Notice>? inbox,
    Set<String>? unreadIds,
    Set<String>? pendingNotifyIds,
    Set<String>? notifiedIds,
    int? pendingBackfillPage,
    bool? baselineBuilt,
    DateTime? lastAttemptAt,
    DateTime? lastSuccessfulSyncAt,
  }) {
    return NoticeSyncSnapshot(
      snapshotIds: snapshotIds ?? state.snapshotIds,
      inbox: inbox ?? state.inbox,
      unreadIds: unreadIds ?? state.unreadIds,
      pendingNotifyIds: pendingNotifyIds ?? state.pendingNotifyIds,
      notifiedIds: notifiedIds ?? state.notifiedIds,
      pendingBackfillPage: pendingBackfillPage ?? state.pendingBackfillPage,
      baselineBuilt: baselineBuilt ?? state.baselineBuilt,
      lastAttemptAt: lastAttemptAt ?? state.lastAttemptAt,
      lastSuccessfulSyncAt: lastSuccessfulSyncAt ?? state.lastSuccessfulSyncAt,
    );
  }

  Future<Directory> _resolveDir() async {
    final override = debugDirectoryProvider;
    if (override != null) return override();
    final support = await getApplicationSupportDirectory();
    return support;
  }

  Future<File> _stateFile() async {
    final dir = await _resolveDir();
    return File('${dir.path}${Platform.pathSeparator}$stateFileName');
  }

  Future<File> _lockFile() async {
    final dir = await _resolveDir();
    // 不预创建：O_EXCL 创建本身是取锁的原子操作。
    return File('${dir.path}${Platform.pathSeparator}$lockFileName');
  }

  Future<NoticeSyncSnapshot> _readStateLocked(File file) async {
    if (!await file.exists()) return NoticeSyncSnapshot.empty;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map || raw['v'] != _schemaVersion) {
        await _safeDelete(file);
        return NoticeSyncSnapshot.empty;
      }
      return _decodeState(raw);
    } catch (error, stackTrace) {
      AppLogger.instance.storage(
        LogLevel.warn,
        '通知同步状态解析失败，已重建',
        error: error,
        stackTrace: stackTrace,
      );
      await _safeDelete(file);
      return NoticeSyncSnapshot.empty;
    }
  }

  NoticeSyncSnapshot _decodeState(Map raw) {
    final snapshotIdsRaw = raw['snapshotIds'];
    final snapshotIds = <String, DateTime>{};
    if (snapshotIdsRaw is Map) {
      snapshotIdsRaw.forEach((key, value) {
        final at = DateTime.tryParse(value?.toString() ?? '');
        if (at != null) snapshotIds[key.toString()] = at;
      });
    }

    final inboxRaw = raw['inbox'];
    final inbox = <Notice>[];
    if (inboxRaw is List) {
      for (final item in inboxRaw) {
        final notice = Notice.fromJson(item);
        if (notice != null) inbox.add(notice);
      }
    }

    Set<String> parseStringSet(Object? value) =>
        value is List ? value.map((e) => e.toString()).toSet() : <String>{};

    return NoticeSyncSnapshot(
      snapshotIds: snapshotIds,
      inbox: inbox,
      unreadIds: parseStringSet(raw['unreadIds']),
      pendingNotifyIds: parseStringSet(raw['pendingNotifyIds']),
      notifiedIds: parseStringSet(raw['notifiedIds']),
      pendingBackfillPage: raw['pendingBackfillPage'] is int
          ? raw['pendingBackfillPage'] as int
          : null,
      baselineBuilt: raw['baselineBuilt'] == true,
      lastAttemptAt: DateTime.tryParse(raw['lastAttemptAt']?.toString() ?? ''),
      lastSuccessfulSyncAt: DateTime.tryParse(
        raw['lastSuccessfulSyncAt']?.toString() ?? '',
      ),
    );
  }

  Future<void> _writeStateLocked(File file, NoticeSyncSnapshot state) async {
    final encoded = jsonEncode(<String, dynamic>{
      'v': _schemaVersion,
      'snapshotIds': state.snapshotIds.map(
        (key, value) => MapEntry(key, value.toIso8601String()),
      ),
      'inbox': state.inbox.map((n) => n.toJson()).toList(),
      'unreadIds': state.unreadIds.toList(),
      'pendingNotifyIds': state.pendingNotifyIds.toList(),
      'notifiedIds': state.notifiedIds.toList(),
      'pendingBackfillPage': state.pendingBackfillPage,
      'baselineBuilt': state.baselineBuilt,
      'lastAttemptAt': state.lastAttemptAt?.toIso8601String(),
      'lastSuccessfulSyncAt': state.lastSuccessfulSyncAt?.toIso8601String(),
    });
    // 每次写入使用独立临时文件名：POSIX rename 语义下，共享临时名会让
    // 并发写者互相搬走对方的文件（ENOENT，Linux CI 实证）；独立命名后
    // rename 仍是对状态文件的原子替换，后写者整体生效。
    final tmp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}'
      '-${_random.nextInt(0x7fffffff)}.tmp',
    );
    await tmp.writeAsString(encoded, flush: true);
    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      await _safeDelete(tmp);
      rethrow;
    }
  }

  static Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
