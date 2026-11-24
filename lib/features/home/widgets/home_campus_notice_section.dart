import 'package:material_ui/material_ui.dart';

import '../../../core/notice/notice_model.dart';
import '../../../core/notice/notice_relevance.dart';
import '../../../core/notice/notice_sync_store.dart';
import '../../../core/profile/user_profile_controller.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_theme_controller.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_surface_style.dart';
import '../../../shared/widgets/app_tile_surface.dart';
import '../../../shared/widgets/copy_text_feedback.dart';

/// 首页「今日公告」卡片：并入「今天」区块下方，仅展示当日新增公告。
///
/// 视觉对齐 [HomeTodayAgendaCards]：外框采用 `AppHardTileShell(radius: AppRadius.card)`
/// 配合 `AppTileSurface(blurred: false)`；仅保留发布日期与 [now] 同日（年月日一致）
/// 的公告，无今日新增条目时整块收起不占位。
class HomeCampusNoticeSection extends StatelessWidget {
  const HomeCampusNoticeSection({
    super.key,
    required this.head,
    required this.onTapNotice,
    required this.onTapAll,
    this.now,
  });

  final NoticeInboxHead head;
  final ValueChanged<Notice> onTapNotice;
  final VoidCallback onTapAll;
  final DateTime? now;

  static bool _isSameCalendarDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final referenceNow = now ?? DateTime.now();
    final todayItems = head.latest
        .where((notice) {
          final parsed = notice.parsedDate;
          return parsed != null && _isSameCalendarDay(parsed, referenceNow);
        })
        .toList(growable: false);
    if (todayItems.isEmpty) return const SizedBox.shrink();

    final notices = NoticeRelevance.orderByRelevanceThenDate(
      todayItems,
      UserProfileController.instance.effectiveEnrollmentYear,
    );

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final primaryTextColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      cs.onSurface,
    );
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(context, cs.onSurfaceVariant);

    return AppHardTileShell(
      radius: AppRadius.card,
      child: AppTileSurface(
        blurred: false,
        borderRadius: AppRadius.cardBorder,
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              button: true,
              label: '查看全部今日公告',
              excludeSemantics: true,
              onTap: onTapAll,
              child: InkWell(
                onTap: onTapAll,
                excludeFromSemantics: true,
                borderRadius: BorderRadius.circular(AppRadius.control),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Text(
                        '今日公告',
                        style: context.appText.group.copyWith(
                          color: secondaryTextColor,
                        ),
                      ),
                      if (head.unreadCount > 0) ...[
                        const SizedBox(width: 6),
                        DecoratedBox(
                          decoration: ShapeDecoration(
                            color: cs.primary.withValues(
                              alpha: isDark ? 0.18 : 0.10,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                AppRadius.tag,
                              ),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Text(
                              '${head.unreadCount} 条未读',
                              style: context.appText.tag.copyWith(
                                color: cs.primary,
                                letterSpacing: 0,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                      const Spacer(),
                      Text(
                        '查看全部',
                        style: context.appText.meta.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: cs.primary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Divider(
              height: 0.5,
              thickness: 0.5,
              color: cs.outlineVariant.withValues(alpha: 0.35),
            ),
            for (final (index, notice) in notices.indexed) ...[
              if (index > 0)
                Divider(
                  height: 0.5,
                  thickness: 0.5,
                  color: cs.outlineVariant.withValues(alpha: 0.35),
                ),
              _NoticeRow(
                notice: notice,
                unread: head.unreadIds.contains(notice.id),
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor,
                isLast: index == notices.length - 1,
                onTap: () => onTapNotice(notice),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({
    required this.notice,
    required this.unread,
    required this.primaryTextColor,
    required this.secondaryTextColor,
    required this.isLast,
    required this.onTap,
  });

  final Notice notice;
  final bool unread;
  final Color primaryTextColor;
  final Color secondaryTextColor;
  final bool isLast;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      label: unread ? '未读公告，${notice.title}' : notice.title,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        onLongPress: notice.url.isEmpty
            ? null
            : () => copyTextWithFeedback(context, notice.url),
        excludeFromSemantics: true,
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: Padding(
          padding: EdgeInsets.only(top: 7, bottom: isLast ? 0 : 7),
          child: Row(
            children: [
              if (unread) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: cs.primary,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
              ],
              Expanded(
                child: Text(
                  notice.title,
                  style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                    fontSize: 14,
                    fontWeight: unread ? FontWeight.w500 : FontWeight.w400,
                    height: 1.35,
                    color: primaryTextColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: secondaryTextColor.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
