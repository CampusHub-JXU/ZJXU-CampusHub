import 'package:flutter/material.dart';

import '../../../core/notice/notice_model.dart';
import '../../../core/notice/notice_relevance.dart';
import '../../../core/notice/notice_sync_store.dart';
import '../../../core/profile/user_profile_controller.dart';

/// 首页底部「校园公告」区块：功能区之后的页面最末。
///
/// 收起形态：最新一条完整展示，第二条只露出约半行即被截断——预览
/// 「下面还有」的信号，完整列表经「查看全部」进通知中心。数据源为
/// 磁盘收件箱（首页零触网），排序为日期倒序 + 明确不相关条目沉底；
/// 未读信号并入块内：行首圆点标记未读、标题行徽标显示未读数——与
/// Hero 通知铃的角标同源同一份状态。视觉权重低于资产行，禁止卡片底。
class HomeCampusNoticeSection extends StatelessWidget {
  const HomeCampusNoticeSection({
    super.key,
    required this.head,
    required this.onTapNotice,
    required this.onTapAll,
  });

  final NoticeInboxHead head;
  final ValueChanged<Notice> onTapNotice;
  final VoidCallback onTapAll;

  /// 收起态预览的条目数：最新 1 条完整 + 第 2 条露半行。
  static const _peekCount = 2;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final notices = NoticeRelevance.orderByRelevanceThenDate(
      head.latest,
      UserProfileController.instance.effectiveEnrollmentYear,
    ).take(_peekCount).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '校园公告',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            if (head.unreadCount > 0)
              Text(
                '${head.unreadCount} 条未读',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: cs.primary,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        // 收起预览：只有一条时不截断；两条及以上把第二行裁掉约一半，
        // 传递「下面还有内容」的视觉暗示。
        if (notices.isNotEmpty)
          ClipRect(
            child: SizedBox(
              height: notices.length >= _peekCount
                  ? _peekHeight(context)
                  : null,
              child: Column(
                children: [
                  for (final notice in notices)
                    _NoticeRow(
                      notice: notice,
                      unread: head.unreadIds.contains(notice.id),
                      onTap: () => onTapNotice(notice),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 4),
        _ViewAllRow(onTap: onTapAll),
      ],
    );
  }

  /// 第一行完整高度 + 第二行约半行（行高随字号缩放，避免大字号下
  /// 第一行本身被裁）。
  static double _peekHeight(BuildContext context) {
    final lineExtent = MediaQuery.textScalerOf(context).scale(14) * 1.4;
    final rowExtent = lineExtent + 22; // 行内上下 padding 各 11
    return rowExtent + rowExtent / 2;
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({
    required this.notice,
    required this.unread,
    required this.onTap,
  });

  final Notice notice;
  final bool unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final date = (notice.date ?? '').trim();

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: [
            const SizedBox(width: 2),
            if (unread) ...[
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: cs.primary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 9),
            ] else
              const SizedBox(width: 16),
            Expanded(
              child: Text(
                notice.title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: unread ? FontWeight.w500 : FontWeight.w400,
                  color: cs.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 10),
            if (date.isNotEmpty)
              Text(
                date,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

class _ViewAllRow extends StatelessWidget {
  const _ViewAllRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Text(
              '查看全部',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: cs.primary,
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.chevron_right, size: 16, color: cs.primary),
          ],
        ),
      ),
    );
  }
}
