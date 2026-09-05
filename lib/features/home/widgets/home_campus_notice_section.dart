import 'package:flutter/material.dart';

import '../../../core/notice/notice_model.dart';
import '../../../core/notice/notice_sync_store.dart';

/// 首页「校园公告」内容区块：资产行之后、功能区之前。
///
/// 常驻内容块（数据源为磁盘收件箱，首页零触网），收件箱为空时整块消失
/// （由调用方条件渲染）。未读信号并入块内：行首圆点标记未读、标题行
/// 徽标显示未读数——与 Hero 通知铃的角标同源同一份状态，分工为「入口
/// 信号（角标）/ 内容预览（本块）」。视觉权重低于资产行，禁止卡片底。
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final notices = head.latest;

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
        for (final notice in notices)
          _NoticeRow(
            notice: notice,
            unread: head.unreadIds.contains(notice.id),
            onTap: () => onTapNotice(notice),
          ),
        const SizedBox(height: 4),
        _ViewAllRow(onTap: onTapAll),
      ],
    );
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
