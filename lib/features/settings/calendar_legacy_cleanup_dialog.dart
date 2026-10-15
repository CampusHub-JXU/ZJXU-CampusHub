import 'package:flutter/material.dart';

import '../../core/calendar/calendar_sync_control.dart';
import '../../core/theme/app_typography.dart';

/// 用户对「遗留日程扫描结果」预览的选择（Issue #48 遗留清理）。
///
/// 由 [CalendarLegacyCleanupPreviewSheet] 经 [Navigator.pop] 返回，调用方据此
/// 决定是否删除、申请权限或重新扫描。**任何非 [cleanup] 分支都不删除任何事件**，
/// 并必须用**同一**预览对象调用 `dismissLegacyCleanupPreview`。
enum CalendarLegacyCleanupDecision {
  /// 用户确认删除本次扫描已确认的自有日程。
  cleanup,

  /// 用户要求授予日历读写权限后重新扫描。
  requestPermission,

  /// 用户要求重新扫描（旧预览随即作废）。
  rescan,

  /// 用户取消 / 关闭（保持 `cleanupPending`，不删除）。
  dismiss,
}

/// 固定失败枚举 → 用户可读文案（不含账号 / 课程 / 日历 id 等任何标识）。
String legacyCleanupFailureLabel(CalendarLegacyCleanupFailure failure) =>
    switch (failure) {
      CalendarLegacyCleanupFailure.providerUnavailable => '系统日历暂不可用',
      CalendarLegacyCleanupFailure.permissionDenied => '日历权限被拒绝',
      CalendarLegacyCleanupFailure.scanLimit => '遗留日程数量超过扫描上限',
      CalendarLegacyCleanupFailure.calendarUnavailable => '部分日历无法读取',
      CalendarLegacyCleanupFailure.ledgerUnavailable => '本地记录读取失败',
      CalendarLegacyCleanupFailure.ledgerCorrupted => '本地记录已损坏',
      CalendarLegacyCleanupFailure.pendingUnreconciled => '部分写入结果尚未确认',
      CalendarLegacyCleanupFailure.invalidPreview => '扫描已过期',
      CalendarLegacyCleanupFailure.aborted => '操作已中断',
    };

/// 是否存在**已确认可写**的清理候选（`writable == true` 且该日历上有自有事件）。
///
/// 只读日历（`writable == false`）与归属未知（`writable == null`）都**不**计入，
/// 因此不会出现「标着无法清理却给出删除按钮」的自相矛盾。
bool canCleanupLegacyPreview(CalendarLegacyCleanupScan scan) => scan.calendars
    .any((calendar) => calendar.writable == true && calendar.ownedCount > 0);

/// provider 中已无带 marker 的自有事件，但本地仍有过期记录（`!dismissible`）。
///
/// 该情形没有可删除的系统事件，只因本地记录未清而无法回到关闭态；需要用户确认后
/// 仅**清除过期记录**（core 不写 provider）。缺此入口会让用户卡在 `cleanupPending`，
/// 因此单独提供动作，而不放宽 [canCleanupLegacyPreview]。
bool hasOnlyStaleLocalRecords(CalendarLegacyCleanupScan scan) =>
    scan.complete &&
    !scan.hasResidual &&
    !scan.dismissible &&
    !canCleanupLegacyPreview(scan);

/// 是否存在**已确认属于本应用、但本应用无权删除**的遗留日程：只读日历
/// （`writable == false`）或归属未知（`writable == null`）上仍有自有事件。
///
/// 只统计带当前应用标记的事件（`ownedCount`）；不把「未带标记 / 其他应用」的事件
/// 计入，也不做标题 / 账号枚举。
bool hasNonDeletableOwned(CalendarLegacyCleanupScan scan) => scan.calendars.any(
  (calendar) => calendar.writable != true && calendar.ownedCount > 0,
);

/// 存在只读日历上的自有事件（`writable == false`，access < CONTRIBUTOR）。
bool hasReadOnlyOwned(CalendarLegacyCleanupScan scan) => scan.calendars.any(
  (calendar) => calendar.writable == false && calendar.ownedCount > 0,
);

/// 存在归属未知日历上的自有事件（`writable == null`，元数据缺失 / 查询失败）。
bool hasUnknownOwnershipOwned(CalendarLegacyCleanupScan scan) => scan.calendars
    .any((calendar) => calendar.writable == null && calendar.ownedCount > 0);

/// 只读日历的手动处理指引：如实说明本应用删不掉，并指向系统日历 / 日历提供方。
///
/// 只读来源可能属于其他日历提供方或系统账户，本应用无法代其删除，因此**不承诺**
/// 用户一定能在 App 内删掉，只引导到系统日历或提供方处理。
const String kReadOnlyManualHint =
    '请在系统日历中查看上方日历；只读日历需先恢复可写权限或联系日历提供方处理。'
    '处理后重新扫描，确认遗留已解决再开启同步。';

/// 归属未知日历的手动处理指引：不承诺重新授权后一定变为可写。
const String kUnknownOwnershipManualHint = '重新授权或确认日历可访问后，再扫描。';

/// 遗留未解决前同步保持关闭（不因可删项删完就自动开启）。
const String kSyncStaysDisabledHint = '同步会保持关闭，直到重新扫描确认遗留已解决。';

/// 预览首行结论：扫描不完整时**绝不**说「未发现遗留」，避免被读成「已清干净」。
String _summaryLine(CalendarLegacyCleanupScan scan) {
  if (scan.hasResidual) {
    return '发现 ${scan.totalKnownOwnedCount} 条带当前应用标记的遗留日程';
  }
  return scan.complete ? '未发现带当前应用标记的遗留日程' : '已扫描到的范围没有遗留日程，但扫描不完整';
}

/// 「遗留日程扫描结果」预览弹层（Issue #48）。
///
/// 只呈现 core 已经聚合好的**数量与展示名**：不读取课表、不生成事件、不展示
/// 学号 / 日历 id / eventId / opaqueId。列表用有界 [ListView.builder]，日历数
/// 上限由 core 收敛（≤ 300）。返回值见 [CalendarLegacyCleanupDecision]。
class CalendarLegacyCleanupPreviewSheet extends StatelessWidget {
  const CalendarLegacyCleanupPreviewSheet({super.key, required this.scan});

  /// 动作按钮统一 48 高点击区，窄屏 / 大字号 / 深浅色下都可点。
  static final ButtonStyle _actionStyle = TextButton.styleFrom(
    minimumSize: const Size(0, 48),
  );

  final CalendarLegacyCleanupScan scan;

  @override
  Widget build(BuildContext context) {
    final text = context.appText;
    final cs = Theme.of(context).colorScheme;
    final canCleanup = canCleanupLegacyPreview(scan);
    final staleOnly = hasOnlyStaleLocalRecords(scan);
    final incomplete = !scan.complete;
    final reason = scan.reason;
    final permissionDenied =
        reason == CalendarLegacyCleanupFailure.permissionDenied;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.8;

    final headerBlock = Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(incomplete ? '扫描结果（不完整）' : '扫描结果', style: text.rowTitle),
          const SizedBox(height: 6),
          Text(_summaryLine(scan), style: text.listTitle),
          if (scan.recordedOrphanCount > 0) ...[
            const SizedBox(height: 2),
            Text(
              '其中 ${scan.recordedOrphanCount} 条未被本地记录确认',
              style: text.secondary,
            ),
          ],
        ],
      ),
    );

    final reasonBlock = incomplete
        ? Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              '扫描不完整：${legacyCleanupFailureLabel(reason ?? CalendarLegacyCleanupFailure.providerUnavailable)}。'
              '下列结果仅为已确认部分，不代表全部遗留都已列出。',
              style: text.meta.copyWith(color: cs.error),
            ),
          )
        : null;

    // 全部正文（标题 / 原因 / 日历行 / 脚注 / 指引）放进**同一个**有界懒加载列表：
    // 窄屏 + 大字号 + 较长文案时正文整体滚动，不再撑破弹层（动作行仍固定底部）。
    // 日历行仍由 [ListView.builder] 按需构建。
    final leading = <Widget>[
      headerBlock,
      ?reasonBlock,
      if (scan.calendars.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 4),
          child: Text('没有可展示的日历条目。', style: text.secondary),
        ),
    ];

    final trailing = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
        child: Text(
          '未带当前应用标记的事件（其他应用，或无法确认归属的副本）不会被扫描或计数，'
          '也不能自动清理；如需处理请在系统日历中核对。',
          style: text.meta,
        ),
      ),
      if (canCleanup || staleOnly)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
          child: Text(
            staleOnly
                ? '系统日历中已无带当前应用标记的事件，但本地仍有过期记录；'
                      '确认后仅清除这些记录，不写入系统日历。'
                : incomplete
                ? '仅清理本次扫描确认的部分，其他未确认的范围仍会保留。'
                : '将删除本次扫描确认的、本应用写入的全部遗留日程（含历史账号），'
                      '不影响其他应用或系统日历中的其他事件。',
            style: text.meta,
          ),
        ),
      if (hasNonDeletableOwned(scan))
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasReadOnlyOwned(scan))
                Text(kReadOnlyManualHint, style: text.secondary),
              if (hasUnknownOwnershipOwned(scan)) ...[
                if (hasReadOnlyOwned(scan)) const SizedBox(height: 2),
                Text(kUnknownOwnershipManualHint, style: text.secondary),
              ],
              const SizedBox(height: 2),
              Text(kSyncStaysDisabledHint, style: text.meta),
            ],
          ),
        ),
    ];

    final itemCount = leading.length + scan.calendars.length + trailing.length;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: itemCount,
              itemBuilder: (context, index) {
                if (index < leading.length) return leading[index];
                final calendarIndex = index - leading.length;
                if (calendarIndex < scan.calendars.length) {
                  return _CalendarPreviewTile(
                    calendar: scan.calendars[calendarIndex],
                  );
                }
                return trailing[calendarIndex - scan.calendars.length];
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 4,
                children: [
                  TextButton(
                    style: _actionStyle,
                    onPressed: () =>
                        Navigator.of(context)
                            .pop(CalendarLegacyCleanupDecision.dismiss),
                    child: const Text('取消'),
                  ),
                  if (permissionDenied)
                    TextButton(
                      style: _actionStyle,
                      onPressed: () => Navigator.of(context)
                          .pop(CalendarLegacyCleanupDecision.requestPermission),
                      child: const Text('授予日历权限'),
                    )
                  else if (incomplete)
                    TextButton(
                      style: _actionStyle,
                      onPressed: () =>
                          Navigator.of(context)
                              .pop(CalendarLegacyCleanupDecision.rescan),
                      child: const Text('重新扫描'),
                    ),
                  if (canCleanup || staleOnly)
                    TextButton(
                      style: _actionStyle.copyWith(
                        foregroundColor: WidgetStatePropertyAll<Color>(
                          cs.error,
                        ),
                      ),
                      onPressed: () =>
                          Navigator.of(context)
                              .pop(CalendarLegacyCleanupDecision.cleanup),
                      child: Text(staleOnly ? '清除过期记录' : '清理已确认的日程'),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个日历的只读预览行：展示名（缺省「日历」）+ 分项数量 + 可清理性说明。
class _CalendarPreviewTile extends StatelessWidget {
  const _CalendarPreviewTile({required this.calendar});

  final CalendarLegacyCleanupCalendarPreview calendar;

  @override
  Widget build(BuildContext context) {
    final text = context.appText;
    final rawName = calendar.displayName?.trim();
    final name = (rawName == null || rawName.isEmpty) ? '日历' : rawName;
    final status = switch (calendar.writable) {
      false => '只读日历，不能清理',
      null => '归属日历状态未确认，不能清理',
      true => null,
    };
    return ListTile(
      title: Text(name, style: text.listTitle),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '已记账 ${calendar.recordedCount} · 未确认 ${calendar.orphanCount} · '
            '共 ${calendar.ownedCount} 条',
            style: text.secondary,
          ),
          if (status != null) Text(status, style: text.meta),
        ],
      ),
      isThreeLine: status != null,
    );
  }
}
