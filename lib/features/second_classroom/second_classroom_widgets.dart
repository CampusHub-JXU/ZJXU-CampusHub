part of 'second_classroom_page.dart';

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
    final cs = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 0, 18, 18 + bottomInset),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.84,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: ListView(
                shrinkWrap: true,
                children: [
                  _ActivityCover(imageUrl: imageUrl, size: 172),
                  const SizedBox(height: 16),
                  Text(
                    activity.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
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
                      _TinyBadge(label: activity.recruitmentLabel),
                      if (detail.hasCredit)
                        _TinyBadge(
                          label:
                              '${_formatCreditHours(activity.creditHours)} 学时',
                        ),
                      if (detail.isFavorite) const _TinyBadge(label: '已收藏'),
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
                    const SizedBox(height: 16),
                    Text(
                      '活动简介',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      activity.summary,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                ],
              ),
            ),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '已订阅活动名',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            if (activities.isEmpty)
              const Expanded(child: Center(child: Text('暂无订阅活动')))
            else
              Expanded(
                child: ListView.separated(
                  itemCount: activities.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final activity = activities[index];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        activity.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '同名活动开始招募时提醒',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => onOpen(activity),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline_rounded),
                        tooltip: '取消开招提醒',
                        onPressed: () => onRemove(activity),
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

class _SyncStatusLine extends StatelessWidget {
  const _SyncStatusLine({
    required this.activityCount,
    required this.updatedAt,
    required this.showingCache,
    required this.syncing,
  });

  final int activityCount;
  final DateTime? updatedAt;
  final bool showingCache;
  final bool syncing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final icon = syncing
        ? Icons.sync_rounded
        : showingCache
        ? Icons.storage_outlined
        : Icons.check_circle_outline_rounded;
    final text = _statusText();
    return Row(
      children: [
        Icon(icon, size: 15, color: cs.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  String _statusText() {
    if (syncing && showingCache) {
      return '正在后台同步完整列表，当前显示本地缓存 $activityCount 个活动';
    }
    if (syncing) {
      return '正在同步完整活动列表';
    }
    final updated = updatedAt == null
        ? ''
        : '，${updatedAt!.month}月${updatedAt!.day}日 ${_formatTime(updatedAt!)}';
    if (showingCache) {
      return '当前显示本地缓存 $activityCount 个活动$updated';
    }
    return '已同步完整列表 $activityCount 个活动$updated';
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(14),
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
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: cs.primary),
          const SizedBox(width: 9),
          SizedBox(
            width: 68,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              resolvedValue,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
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
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
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
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: badgeColor,
          fontWeight: FontWeight.w700,
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
          CircularProgressIndicator(color: cs.primary),
          const SizedBox(height: 16),
          const Text('正在加载第二课堂活动'),
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
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(height: 14),
            Text(
              '第二课堂活动加载失败',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyActivityState extends StatelessWidget {
  const _EmptyActivityState();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(Icons.event_busy_outlined, size: 42, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            '没有匹配的活动',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
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
