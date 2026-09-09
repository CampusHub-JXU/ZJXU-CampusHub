part of 'second_classroom_page.dart';

Color _recruitmentColor(
  BuildContext context,
  SecondClassroomActivity activity,
) {
  final cs = Theme.of(context).colorScheme;
  return switch (activity.recruitmentLabel) {
    '招募中' => const Color(0xFF168A52),
    '活动预热' => cs.primary,
    '已招满' => const Color(0xFFE08A00),
    _ => cs.onSurfaceVariant,
  };
}

String _syncStatusText({
  required int activityCount,
  required DateTime? updatedAt,
  required bool showingCache,
  required bool syncing,
}) {
  if (syncing && showingCache) {
    return '正在后台同步，当前显示缓存 $activityCount 个活动';
  }
  if (syncing) {
    return '正在同步完整活动列表';
  }
  final updated = updatedAt == null
      ? ''
      : ' · ${updatedAt.month}月${updatedAt.day}日 ${_formatTime(updatedAt)}';
  if (showingCache) {
    return '本地缓存 $activityCount 个活动$updated';
  }
  return '已同步 $activityCount 个活动$updated';
}

class _ActivityDetailSheet extends StatelessWidget {
  const _ActivityDetailSheet({
    required this.detail,
    required this.imageUrl,
    required this.subscribed,
    required this.busy,
    required this.onToggleSubscription,
    required this.onOpenInWeChat,
  });

  final SecondClassroomActivityDetail detail;
  final String imageUrl;
  final bool subscribed;
  final bool busy;
  final Future<void> Function() onToggleSubscription;
  final VoidCallback onOpenInWeChat;

  @override
  Widget build(BuildContext context) {
    final activity = detail.activity;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 0, 18, 18 + bottomInset),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.86,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: ListView(
                shrinkWrap: true,
                children: [
                  _ActivityCoverBanner(
                    imageUrl: imageUrl,
                    statusLabel: activity.recruitmentLabel,
                    statusColor: _recruitmentColor(context, activity),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    activity.title,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (activity.categoryName.isNotEmpty)
                        _TinyBadge(label: activity.categoryName),
                      if (detail.hasCredit)
                        _TinyBadge(
                          label:
                              '${_formatCreditHours(activity.creditHours)} 学时',
                        ),
                      if (detail.isFavorite) const _TinyBadge(label: '已收藏'),
                      if (activity.isRegistered)
                        const _TinyBadge(
                          label: '已报名',
                          color: Color(0xFF168A52),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  _DetailSection(
                    children: [
                      _DetailRow(
                        icon: Icons.event_available_outlined,
                        label: '报名时间',
                        value: _formatRange(
                          activity.registrationStartAt,
                          activity.registrationEndAt,
                        ),
                      ),
                      _DetailRow(
                        icon: Icons.schedule_outlined,
                        label: '活动时间',
                        value: _formatRange(
                          activity.activityStartAt,
                          activity.activityEndAt,
                        ),
                      ),
                      _DetailRow(
                        icon: Icons.place_outlined,
                        label: '活动地点',
                        value: activity.location.isEmpty
                            ? '地点待确认'
                            : activity.location,
                      ),
                      _DetailRow(
                        icon: Icons.people_outline_rounded,
                        label: '名额',
                        value: activity.capacity > 0
                            ? '${activity.enrolledCount}/${activity.capacity} 人'
                            : '${activity.enrolledCount} 人已报名',
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _DetailSection(
                    children: [
                      _DetailRow(
                        icon: Icons.groups_outlined,
                        label: '主办组织',
                        value: activity.organizerName.isEmpty
                            ? '暂无'
                            : activity.organizerName,
                      ),
                      _DetailRow(
                        icon: Icons.how_to_reg_outlined,
                        label: '报名方式',
                        value: detail.signUpMode.isEmpty
                            ? '暂无'
                            : detail.signUpMode,
                      ),
                      _DetailRow(
                        icon: Icons.school_outlined,
                        label: '学院限制',
                        value: detail.limitedCollege.isEmpty
                            ? '不限'
                            : detail.limitedCollege,
                      ),
                      _DetailRow(
                        icon: Icons.badge_outlined,
                        label: '年级限制',
                        value: detail.limitedGrade.isEmpty
                            ? '不限'
                            : detail.limitedGrade,
                      ),
                      _DetailRow(
                        icon: Icons.person_outline_rounded,
                        label: '联系人',
                        value: [
                          activity.contactName,
                          activity.contactPhone,
                        ].where((item) => item.isNotEmpty).join('  '),
                      ),
                    ],
                  ),
                  if (activity.summary.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text(
                      '活动简介',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      activity.summary,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                        height: 1.55,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy ? null : onToggleSubscription,
                    icon: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            subscribed
                                ? Icons.notifications_off_outlined
                                : Icons.notifications_active_outlined,
                          ),
                    label: Text(subscribed ? '取消开招提醒' : '订阅同名活动开招提醒'),
                  ),
                ),
                const SizedBox(width: 10),
                Tooltip(
                  message: '微信版',
                  child: Material(
                    color: cs.secondaryContainer.withValues(alpha: 0.85),
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      splashFactory: InkRipple.splashFactory,
                      onTap: onOpenInWeChat,
                      child: const SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(Icons.open_in_new_rounded),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionSheet extends StatelessWidget {
  const _SubscriptionSheet({
    required this.activities,
    required this.onOpen,
    required this.onRemove,
  });

  final List<SecondClassroomActivity> activities;
  final ValueChanged<SecondClassroomActivity> onOpen;
  final ValueChanged<SecondClassroomActivity> onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '已订阅活动名',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                if (activities.isNotEmpty)
                  Text(
                    '${activities.length} 个',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (activities.isEmpty)
              const Expanded(
                child: AppEmptyView(
                  title: '暂无订阅活动',
                  message: '在活动卡片上点击铃铛，即可订阅同名活动的开招提醒',
                  icon: Icons.notifications_off_outlined,
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: activities.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final activity = activities[index];
                    return AppCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      onTap: () => onOpen(activity),
                      child: Row(
                        children: [
                          AppIconBadge(
                            icon: Icons.notifications_active_outlined,
                            accentColor: cs.primary,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  activity.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '同名活动开始招募时提醒',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline_rounded),
                            tooltip: '取消开招提醒',
                            onPressed: () => onRemove(activity),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(children: children),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final resolvedValue = value.trim().isEmpty ? '暂无' : value.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: cs.primary),
          const SizedBox(width: 9),
          SizedBox(
            width: 68,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              resolvedValue,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: cs.onSurfaceVariant),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _TinyBadge extends StatelessWidget {
  const _TinyBadge({required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final badgeColor = color ?? cs.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: badgeColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: badgeColor, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _CoverBadge extends StatelessWidget {
  const _CoverBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityCover extends StatelessWidget {
  const _ActivityCover({
    required this.imageUrl,
    required this.size,
    this.statusLabel,
    this.statusColor,
  });

  final String imageUrl;
  final double size;
  final String? statusLabel;
  final Color? statusColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: cs.surfaceContainerHighest),
            _coverImage(cs, 30),
            if (statusLabel != null && statusLabel!.isNotEmpty)
              Positioned(
                left: 6,
                bottom: 6,
                child: _CoverBadge(
                  label: statusLabel!,
                  color: statusColor ?? cs.primary,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _coverImage(ColorScheme cs, double iconSize) {
    if (imageUrl.isEmpty) {
      return Icon(
        Icons.workspace_premium_outlined,
        color: cs.primary,
        size: iconSize,
      );
    }
    return Image.network(
      imageUrl,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) => Icon(
        Icons.workspace_premium_outlined,
        color: cs.primary,
        size: iconSize,
      ),
    );
  }
}

class _ActivityCoverBanner extends StatelessWidget {
  const _ActivityCoverBanner({
    required this.imageUrl,
    this.statusLabel,
    this.statusColor,
  });

  final String imageUrl;
  final String? statusLabel;
  final Color? statusColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: cs.surfaceContainerHighest),
            if (imageUrl.isEmpty)
              Icon(
                Icons.workspace_premium_outlined,
                color: cs.primary,
                size: 44,
              )
            else
              Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Icon(
                  Icons.workspace_premium_outlined,
                  color: cs.primary,
                  size: 44,
                ),
              ),
            if (statusLabel != null && statusLabel!.isNotEmpty)
              Positioned(
                left: 12,
                top: 12,
                child: _CoverBadge(
                  label: statusLabel!,
                  color: statusColor ?? cs.primary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(strokeWidth: 3, color: cs.primary),
          ),
          const SizedBox(height: 16),
          Text(
            '正在加载第二课堂活动',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return AppErrorView(
      title: '第二课堂活动加载失败',
      message: message,
      onRetry: onRetry,
    );
  }
}

class _EmptyActivityState extends StatelessWidget {
  const _EmptyActivityState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 48),
      child: AppEmptyView(
        title: '没有匹配的活动',
        message: '试试调整筛选条件或更换关键词',
        icon: Icons.event_busy_outlined,
      ),
    );
  }
}

String _formatRange(DateTime? start, DateTime? end) {
  if (start == null && end == null) return '时间待定';
  if (start == null) return _formatDateTime(end);
  if (end == null) return _formatDateTime(start);
  if (start.year == end.year &&
      start.month == end.month &&
      start.day == end.day) {
    return '${_formatDateTime(start)}-${_formatTime(end)}';
  }
  return '${_formatDateTime(start)} 至 ${_formatDateTime(end)}';
}

String _formatDateTime(DateTime? value) {
  if (value == null) return '时间待定';
  return '${value.month}月${value.day}日 ${_formatTime(value)}';
}

String _formatTime(DateTime value) {
  return '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}

String _formatCreditHours(double value) {
  if (value == value.truncateToDouble()) return value.toInt().toString();
  return value.toStringAsFixed(1);
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({
    required this.activity,
    required this.imageUrl,
    required this.subscribed,
    required this.loading,
    required this.onTap,
    required this.onSubscribe,
  });

  final SecondClassroomActivity activity;
  final String imageUrl;
  final bool subscribed;
  final bool loading;
  final VoidCallback onTap;
  final VoidCallback onSubscribe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final capacity = activity.capacity;
    final enrolled = activity.enrolledCount;
    final progress = capacity > 0 ? (enrolled / capacity).clamp(0.0, 1.0) : 0.0;
    final subtitle = [
      activity.categoryName,
      activity.organizerName,
    ].where((item) => item.isNotEmpty).join(' · ');

    return AppCard(
      padding: const EdgeInsets.all(12),
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ActivityCover(
            imageUrl: imageUrl,
            size: 104,
            statusLabel: activity.recruitmentLabel,
            statusColor: _recruitmentColor(context, activity),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        activity.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    _SubscribeButton(
                      subscribed: subscribed,
                      loading: loading,
                      onPressed: onSubscribe,
                    ),
                  ],
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 9),
                _MetaLine(
                  icon: Icons.event_available_outlined,
                  text:
                      '报名 ${_formatRange(activity.registrationStartAt, activity.registrationEndAt)}',
                ),
                const SizedBox(height: 4),
                _MetaLine(
                  icon: Icons.place_outlined,
                  text: activity.location.isEmpty ? '地点待确认' : activity.location,
                ),
                const SizedBox(height: 10),
                _EnrollmentBar(
                  enrolled: enrolled,
                  capacity: capacity,
                  progress: progress,
                  creditHours: activity.creditHours,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SubscribeButton extends StatelessWidget {
  const _SubscribeButton({
    required this.subscribed,
    required this.loading,
    required this.onPressed,
  });

  final bool subscribed;
  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (loading) {
      return const SizedBox(
        width: 36,
        height: 36,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return IconButton(
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      icon: Icon(
        subscribed
            ? Icons.notifications_active_rounded
            : Icons.notifications_none_rounded,
        size: 21,
      ),
      tooltip: subscribed ? '取消开招提醒' : '订阅开招提醒',
      color: subscribed ? cs.primary : cs.onSurfaceVariant,
      onPressed: onPressed,
    );
  }
}

class _EnrollmentBar extends StatelessWidget {
  const _EnrollmentBar({
    required this.enrolled,
    required this.capacity,
    required this.progress,
    required this.creditHours,
  });

  final int enrolled;
  final int capacity;
  final double progress;
  final double creditHours;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final full = capacity > 0 && enrolled >= capacity;
    final barColor = full ? const Color(0xFFE08A00) : cs.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              capacity > 0 ? '$enrolled/$capacity 人' : '$enrolled 人已报名',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            if (creditHours > 0)
              _TinyBadge(label: '${_formatCreditHours(creditHours)} 学时'),
          ],
        ),
        if (capacity > 0) ...[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: cs.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(barColor),
            ),
          ),
        ],
      ],
    );
  }
}
