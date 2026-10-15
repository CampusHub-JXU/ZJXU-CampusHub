part of 'second_classroom_page.dart';

/// 招募状态只映射主题 container 色调：招募中 → secondaryContainer，
/// 已招满 → tertiaryContainer，其余中性。
AppStatusTone _recruitmentTone(SecondClassroomActivity activity) {
  return switch (activity.recruitmentLabel) {
    '招募中' => AppStatusTone.positive,
    '已招满' => AppStatusTone.attention,
    _ => AppStatusTone.neutral,
  };
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
                  _ActivityDetailImage(
                    imageUrl: imageUrl,
                    statusLabel: activity.recruitmentLabel,
                    statusTone: _recruitmentTone(activity),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    activity.title,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (activity.categoryName.isNotEmpty)
                        AppStatusTag(activity.categoryName),
                      if (detail.hasCredit)
                        AppStatusTag(
                          '${_formatCreditHours(activity.creditHours)} 学时',
                        ),
                      if (detail.isFavorite) const AppStatusTag('已收藏'),
                      if (activity.isRegistered)
                        const AppStatusTag('已报名', tone: AppStatusTone.positive),
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
                    const PlainSectionHeader('活动简介'),
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
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        0,
        AppSpacing.pageMargin,
        AppSpacing.lg,
      ),
      // 内容（订阅列表 + 通知说明）整体滚动，短屏 / 大字号下不溢出；高度仍受
      // 底部弹层自身的可用空间约束。
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.78,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PlainSectionHeader(
                activities.isEmpty ? '已订阅活动名' : '已订阅活动名 · ${activities.length}',
              ),
              if (activities.isEmpty)
                const AppEmptyView(
                  title: '暂无订阅活动',
                  message: '在活动卡片上点击铃铛，即可订阅同名活动的开招提醒',
                  icon: Icons.notifications_off_outlined,
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: activities.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, index) {
                    final activity = activities[index];
                    return AppListTile(
                      title: activity.title,
                      meta: '同名活动开始招募时提醒',
                      onTap: () => onOpen(activity),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline_rounded),
                        tooltip: '取消开招提醒',
                        onPressed: () => onRemove(activity),
                      ),
                    );
                  },
                ),
              const SizedBox(height: AppSpacing.md),
              const PlainSectionHeader('开招提醒'),
              const PlainListGroup(
                children: [_NotificationChannelSettingsRow()],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '订阅按同名活动匹配，后台大约每 1 小时联网检测一次，系统调度可能延后，'
                '不保证在活动刚开招的瞬间提醒。顶部横幅是否出现，还取决于系统通知权限、'
                '本渠道的重要程度与厂商（如 HyperOS）设置，App 无法代为开启。',
                style: context.appText.meta.copyWith(
                  color: cs.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 第二课堂订阅弹层底部的系统通知入口：如实展示权限 / 渠道状态，并直达本应用
/// 「第二课堂活动提醒」渠道设置。跳转成功不代表已授权，也不保证出现横幅
/// （见 design-guidelines「系统设置快捷入口只表示打开设置页」）。
class _NotificationChannelSettingsRow extends StatefulWidget {
  const _NotificationChannelSettingsRow();

  @override
  State<_NotificationChannelSettingsRow> createState() =>
      _NotificationChannelSettingsRowState();
}

class _NotificationChannelSettingsRowState
    extends State<_NotificationChannelSettingsRow>
    with WidgetsBindingObserver {
  bool _checking = true;

  /// 真实权限查询结果；null 表示不支持或查询失败，状态未知。
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统设置返回后重新查询真实状态，不沿用旧值。
    if (state == AppLifecycleState.resumed) unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    bool? enabled;
    try {
      enabled = await AppNotificationService.instance
          .notificationPermissionStatus();
    } catch (_) {
      enabled = null;
    }
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _checking
        ? '检查通知状态…'
        : switch (_enabled) {
            true => '点按打开「第二课堂活动提醒」通知渠道，可自行开启横幅 / 悬浮通知',
            false => '系统通知权限未开启，开招提醒不会显示；点按前往系统设置开启',
            null => '通知状态未知，点按前往系统设置查看',
          };
    return PlainListRow(
      title: '通知横幅设置',
      subtitle: subtitle,
      onTap: _openChannelSettings,
    );
  }

  Future<void> _openChannelSettings() async {
    final result = await SystemSettingsLauncher.instance.open(
      SystemSettingsTarget.notificationChannel,
      channelId: AppNotificationService.secondClassroomChannelId,
    );
    if (!mounted) return;
    // 命中渠道页不提示；降级 / 失败时说明真实打开的页面。
    final message = switch (result) {
      SystemSettingsOpenResult.target => null,
      SystemSettingsOpenResult.appDetails => '未能直达该通知渠道，已打开应用详情页，请在「通知」中手动查找',
      SystemSettingsOpenResult.settings => '未能直达该通知渠道，已打开系统设置首页，请手动查找',
      SystemSettingsOpenResult.unavailable => '未能打开系统设置，请手动前往系统「应用管理」调整',
    };
    if (message != null) AppFeedback.toast(context, message);
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
            style: context.appText.secondary,
          ),
        ),
      ],
    );
  }
}

class _ActivityCover extends StatelessWidget {
  const _ActivityCover({
    required this.imageUrl,
    required this.size,
    this.statusLabel,
    this.statusTone = AppStatusTone.neutral,
  });

  final String imageUrl;
  final double size;
  final String? statusLabel;
  final AppStatusTone statusTone;

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
                child: AppStatusTag(statusLabel!, tone: statusTone),
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

/// 无缓存首次加载：静态骨架（搜索框 + chip 行 + 三张活动卡）。
class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.md,
        AppSpacing.pageMargin,
        AppSpacing.xl,
      ),
      children: [
        const SkeletonBox(height: 52, radius: AppRadius.input),
        const SizedBox(height: AppSpacing.md),
        const Row(
          children: [
            SkeletonBox(width: 56, height: 32, radius: 16),
            SizedBox(width: AppSpacing.sm),
            SkeletonBox(width: 80, height: 32, radius: 16),
            SizedBox(width: AppSpacing.sm),
            SkeletonBox(width: 80, height: 32, radius: 16),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        const RefreshStatusLine(refreshing: true, loadingLabel: '正在同步活动…'),
        const SizedBox(height: AppSpacing.md),
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.md),
          const SkeletonBox(height: 128, radius: AppRadius.card),
        ],
      ],
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
            statusTone: _recruitmentTone(activity),
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
                        style: context.appText.rowTitle.copyWith(height: 1.3),
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
                    style: context.appText.meta,
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
    final barColor = full ? cs.tertiary : cs.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              capacity > 0 ? '$enrolled/$capacity 人' : '$enrolled 人已报名',
              style: context.appText.secondary.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const Spacer(),
            if (creditHours > 0)
              AppStatusTag('${_formatCreditHours(creditHours)} 学时'),
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
