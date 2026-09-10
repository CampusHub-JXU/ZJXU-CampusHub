import 'package:flutter/material.dart';

import '../../../core/notice/notice_model.dart';
import '../../../core/notice/notice_relevance.dart';
import '../../../core/notice/notice_sync_store.dart';
import '../../../core/profile/user_profile_controller.dart';
import '../../../shared/widgets/copy_text_feedback.dart';

/// 首页「校园公告」区块：紧随资产行、功能区之前。
///
/// 降噪简化形态：只保留「标题行 + 单行标题列表 + 查看全部」三级文字，
/// 不再使用未读圆点缩进列与逐行日期——未读信号收敛到标题行的
/// 「N 条未读」一处，未读条目仅以字重微调区分；排序为日期倒序 +
/// 明确不相关条目沉底。视觉权重低于资产行，禁止卡片底。
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
    final notices = NoticeRelevance.orderByRelevanceThenDate(
      head.latest,
      UserProfileController.instance.effectiveEnrollmentYear,
    ).toList(growable: false);

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
        const SizedBox(height: 4),
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

    return InkWell(
      onTap: onTap,
      onLongPress: notice.url.isEmpty
          ? null
          : () => copyTextWithFeedback(context, notice.url),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: SizedBox(
          width: double.infinity,
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
