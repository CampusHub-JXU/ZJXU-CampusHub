import 'dart:async';

import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';
import '../notification/app_notification_service.dart';
import 'notice_fetch_service.dart';
import 'notice_model.dart';
import 'notice_sync_store.dart';

/// 同步触发类型：决定节流策略与播报资格。
enum NoticeSyncTrigger {
  /// WorkManager 周期任务。
  background,

  /// App 回前台 / 冷启动 warm-up 的自动补查。
  foregroundAuto,

  /// 页面内下拉刷新：绕过时间节流，但不弹系统通知。
  manualRefresh,

  /// 统一认证登录成功后重试：绕过时间节流。
  afterLogin,
}

/// 一轮同步的结果摘要（诊断与测试断言用）。
@immutable
class NoticeSyncOutcome {
  const NoticeSyncOutcome({
    required this.skipped,
    this.fetchStatus,
    this.freshCount = 0,
    this.notified = false,
  });

  /// 被节流跳过（资格领取失败），本轮未做任何事。
  final bool skipped;

  /// 抓取状态；skipped 时为 null。
  final NoticeFetchStatus? fetchStatus;

  /// 接受的新增条目数（去重后）。
  final int freshCount;

  /// 本轮是否成功发出聚合通知。
  final bool notified;

  bool get ok => !skipped && fetchStatus == NoticeFetchStatus.ok;
}

/// 教务处通知同步状态机：前台补查与后台周期任务共用的唯一同步入口。
///
/// 流程（详见 docs/notice-sync-prd.md §4.3）：锁内资格领取 → 锁外抓取 →
/// 锁内合并提交 → 播报资格领取（待播报队列，不依赖本轮新增）→ 锁外发送 →
/// 确认 / 回滚。网络、通知发送等慢操作一律在锁外。
class NoticeSyncService {
  NoticeSyncService._();

  static final NoticeSyncService instance = NoticeSyncService._();

  /// 分页硬上限（防失控；两次检查间新增超过 2 页会漏，见 PRD 已知限制）。
  static const int _backfillMaxPage = 2;

  /// 新增达到该数量时触发第二页补抓。
  static const int _backfillTriggerThreshold = 10;

  /// 夜间静音窗：本地时间 23:00–07:00，只入库不发系统通知。
  static const int _quietStartHour = 23;
  static const int _quietEndHour = 7;

  static const int _aggregateNotificationId = 300;
  static const String aggregatePayload = 'notice-center';

  /// 通知发送与权限查询的可注入替身（测试用）。
  @visibleForTesting
  Future<bool> Function()? debugNotificationsEnabled;

  @visibleForTesting
  Future<bool> Function({
    required int id,
    required String title,
    required String body,
    required String payload,
  })?
  debugShowNotification;

  /// 时间源注入（静音窗与节流判定的测试钩子）。
  @visibleForTesting
  DateTime Function()? debugNow;

  DateTime _now() => (debugNow ?? DateTime.now)();

  Future<NoticeSyncOutcome> sync({required NoticeSyncTrigger trigger}) async {
    final store = NoticeSyncStore.instance;
    final now = _now();

    final claim = await store.claimSync(
      now: now,
      force:
          trigger == NoticeSyncTrigger.manualRefresh ||
          trigger == NoticeSyncTrigger.afterLogin,
    );
    if (claim == NoticeSyncClaim.blocked) {
      return const NoticeSyncOutcome(skipped: true);
    }

    final firstPage = await NoticeService.instance.fetchNoticesRaw(page: 1);
    if (!firstPage.isOk) {
      // 业务数据零改动；lastAttemptAt 已在领取时记录（退避依据）。
      return NoticeSyncOutcome(skipped: false, fetchStatus: firstPage.status);
    }

    final baselineBuilt = store.state.baselineBuilt;
    final NoticeSyncCommit commit;
    if (!baselineBuilt) {
      commit = await _buildBaselineCommit(firstPage, now);
    } else {
      commit = await _buildIncrementalCommit(firstPage, now);
    }

    final commitResult = await store.commitSync(commit);

    final notified = await _notifyPending(trigger);
    return NoticeSyncOutcome(
      skipped: false,
      fetchStatus: NoticeFetchStatus.ok,
      freshCount: commitResult.acceptedFresh.length,
      notified: notified,
    );
  }

  /// 首启基线：抓取最多 2 页，条目进收件箱 + 快照（**可见但不打扰**——
  /// 无未读、无弹窗；初版只进快照导致首装后收件箱永远为空，已废弃）。
  /// 第二页失败时首页照常完成基线，游标留给下轮补录。
  Future<NoticeSyncCommit> _buildBaselineCommit(
    NoticeFetchResult firstPage,
    DateTime now,
  ) async {
    final totalPages = firstPage.totalPages ?? 0;
    final hasSecondPage = totalPages >= _backfillMaxPage;
    final secondPage = hasSecondPage
        ? await NoticeService.instance.fetchNoticesRaw(page: _backfillMaxPage)
        : null;

    return NoticeSyncCommit(
      baselineNotices: [
        ...firstPage.notices,
        if (secondPage != null && secondPage.isOk) ...secondPage.notices,
      ],
      baselineComplete: true,
      backfillCursor: secondPage != null && !secondPage.isOk
          ? _backfillMaxPage
          : null,
      markSuccess: true,
      now: now,
    );
  }

  /// 增量同步：首页差集为新增；补录游标存在或新增异常多时抓第二页。
  Future<NoticeSyncCommit> _buildIncrementalCommit(
    NoticeFetchResult firstPage,
    DateTime now,
  ) async {
    final snapshot = NoticeSyncStore.instance.state;
    final fresh = firstPage.notices
        .where((n) => !snapshot.snapshotIds.containsKey(n.id))
        .toList(growable: false);

    var cursor = snapshot.pendingBackfillPage;
    if (cursor == null &&
        (fresh.length >= _backfillTriggerThreshold ||
            (fresh.isNotEmpty && fresh.length == firstPage.notices.length))) {
      cursor = _backfillMaxPage;
    }

    var historic = const <Notice>[];
    var clearCursor = false;
    if (cursor != null) {
      final page = await NoticeService.instance.fetchNoticesRaw(page: cursor);
      if (page.isOk) {
        historic = page.notices;
        clearCursor = true;
      }
      // 失败：保留游标，下轮重试（不依赖首页是否有新增）。
    }

    return NoticeSyncCommit(
      freshNotices: fresh,
      historicNotices: historic,
      // 补录成功清除游标；失败持久化游标，下轮重试（不依赖首页新增）。
      backfillCursor: clearCursor ? null : cursor,
      clearBackfillCursor: clearCursor,
      markSuccess: true,
      now: now,
    );
  }

  /// 播报：从待播报队列领取（非空才发，静音/无权限/页面刷新时保留队列），
  /// 发送成功确认、失败回滚。补发不依赖本轮是否有新增。
  Future<bool> _notifyPending(NoticeSyncTrigger trigger) async {
    final canNotify =
        trigger != NoticeSyncTrigger.manualRefresh &&
        !_isQuietHour(_now()) &&
        await _notificationsEnabled();

    final store = NoticeSyncStore.instance;
    final batch = await store.claimNotifyBatch(canNotify: canNotify);
    if (batch.isEmpty) return false;

    final sent = await _showAggregateNotice(batch);
    if (sent) {
      await store.confirmNotified(batch);
      return true;
    }
    await store.rollbackNotifyBatch(batch);
    return false;
  }

  Future<bool> _showAggregateNotice(List<Notice> batch) async {
    final buffer = StringBuffer('新增 ${batch.length} 条：');
    buffer.write(batch.take(3).map((n) => n.title).join('、'));
    if (batch.length > 3) {
      buffer.write(' 等其余 ${batch.length - 3} 条');
    }

    try {
      final show = debugShowNotification;
      if (show != null) {
        await show(
          id: _aggregateNotificationId,
          title: '教务处通知更新',
          body: buffer.toString(),
          payload: aggregatePayload,
        );
      } else {
        await AppNotificationService.instance.showNoticeUpdateNotification(
          id: _aggregateNotificationId,
          title: '教务处通知更新',
          body: buffer.toString(),
          payload: aggregatePayload,
        );
      }
      return true;
    } catch (error, stackTrace) {
      AppLogger.instance.log(
        LogLevel.warn,
        LogCategory.general,
        '教务处通知聚合提醒发送失败，已回滚待播报队列',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  bool _isQuietHour(DateTime now) =>
      now.hour >= _quietStartHour || now.hour < _quietEndHour;

  Future<bool> _notificationsEnabled() async {
    final stub = debugNotificationsEnabled;
    if (stub != null) return stub();
    try {
      return await AppNotificationService.instance.areNotificationsEnabled();
    } catch (_) {
      // 权限查询失败按无权限处理：数据照常入库，播报由队列延后。
      return false;
    }
  }
}
