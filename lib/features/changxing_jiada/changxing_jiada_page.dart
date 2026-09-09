import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_icon_badge.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/network_error_toast.dart';
import 'changxing_jiada_model.dart';
import 'changxing_jiada_service.dart';
import 'changxing_jiada_widgets.dart';

class ChangxingJiadaPage extends StatefulWidget {
  const ChangxingJiadaPage({super.key});

  @override
  State<ChangxingJiadaPage> createState() => _ChangxingJiadaPageState();
}

class _ChangxingJiadaPageState extends State<ChangxingJiadaPage> {
  bool _initializing = true;
  bool _loadingContent = false;
  bool _loggingIn = false;
  String? _error;

  ChangxingUserProfile? _profile;
  int _unreadCount = 0;
  List<ChangxingApplication> _applications = [];

  ChangxingJiadaService get _service => ChangxingJiadaService.instance;

  bool get _loggedIn => _service.hasToken && _profile != null;

  int get _pendingCount => _applications
      .where((item) => item.status == 0 || item.status == 1 || item.status == 5)
      .length;

  ChangxingApplication? get _latestApplication {
    if (_applications.isEmpty) return null;
    final sorted = [..._applications]
      ..sort((a, b) {
        final left =
            a.upTime ?? a.startTime ?? DateTime.fromMillisecondsSinceEpoch(0);
        final right =
            b.upTime ?? b.startTime ?? DateTime.fromMillisecondsSinceEpoch(0);
        return right.compareTo(left);
      });
    return sorted.first;
  }

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _service.restoreSession();
    if (_service.hasToken) {
      await _loadDashboard(showGlobalLoading: false);
    } else {
      // FR-5: 无 token 时自动尝试 CAS SSO，不显示"一键登录"中间页。
      await _loginViaCas();
    }

    if (!mounted) return;
    setState(() {
      _initializing = false;
    });
  }

  Future<void> _loadDashboard({required bool showGlobalLoading}) async {
    if (showGlobalLoading) {
      setState(() => _loadingContent = true);
    }

    try {
      final results = await Future.wait<dynamic>([
        _service.fetchUserProfile(),
        _service.fetchUnreadCount(),
        _service.fetchApplications(),
      ]);
      if (!mounted) return;
      setState(() {
        _profile = results[0] as ChangxingUserProfile;
        _unreadCount = results[1] as int;
        _applications = results[2] as List<ChangxingApplication>;
        _error = null;
      });
    } on ChangxingAuthExpiredException catch (e) {
      if (!mounted) return;
      setState(() {
        _profile = null;
        _applications = [];
        _unreadCount = 0;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '加载数据失败：$e');
    } finally {
      if (showGlobalLoading && mounted) {
        setState(() => _loadingContent = false);
      }
    }
  }

  Future<void> _logout() async {
    await _service.logout();
    if (!mounted) return;
    setState(() {
      _profile = null;
      _applications = [];
      _unreadCount = 0;
      _error = null;
    });
  }

  Future<void> _loginViaCas({bool allowUnifiedAuthPrompt = true}) async {
    setState(() {
      _loggingIn = true;
      _error = null;
    });

    try {
      await _service.loginViaCas();
      if (!mounted) return;
      await _loadDashboard(showGlobalLoading: false);
    } on ChangxingNeedUnifiedAuthException {
      if (!mounted) return;
      if (!allowUnifiedAuthPrompt) {
        setState(() => _error = '需要先完成一卡通统一认证后重试');
        NetworkErrorToast.show(context, ChangxingNeedUnifiedAuthException());
        return;
      }
      // FR-5: 自动弹统一认证 Modal，成功后重试一次。
      final loggedIn = await showUnifiedAuthLoginModal(
        context,
        title: '登录一卡通',
        description: '畅行嘉大仅支持校园网内直连访问，请连接校园网后完成统一认证',
        barrierDismissible: false,
      );
      if (!mounted || !loggedIn) return;
      await _loginViaCas(allowUnifiedAuthPrompt: false);
    } on ChangxingCasLoginException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      NetworkErrorToast.show(context, e);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '登录失败：$e');
      NetworkErrorToast.show(context, e);
    } finally {
      if (mounted) {
        setState(() => _loggingIn = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return Scaffold(
        appBar: AppAppBar(title: const Text('畅行嘉大')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppAppBar(
        title: Text(
          '畅行嘉大',
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        actions: _loggedIn
            ? [
                IconButton(
                  tooltip: '刷新',
                  onPressed: _loadingContent
                      ? null
                      : () => _loadDashboard(showGlobalLoading: true),
                  icon: const Icon(Icons.refresh, size: 20),
                ),
                IconButton(
                  tooltip: '退出登录',
                  onPressed: _logout,
                  icon: const Icon(Icons.logout, size: 20),
                ),
              ]
            : null,
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: _loggedIn
            ? _buildDashboardBody(key: const ValueKey('dashboard'))
            : _buildAuthPendingBody(key: const ValueKey('auth-pending')),
      ),
    );
  }

  /// FR-5: 未登录时的简化重试态，不显示装饰性中间页。
  Widget _buildAuthPendingBody({Key? key}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return SafeArea(
      key: key,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIconBadge(
                icon: Icons.directions_walk_outlined,
                accentColor: cs.primary,
                size: AppIconBadgeSize.large,
              ),
              const SizedBox(height: 16),
              Text(
                '畅行嘉大',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _error ?? '正在连接校园通行服务…',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _loggingIn
                    ? null
                    : () => _loginViaCas(allowUnifiedAuthPrompt: true),
                icon: _loggingIn
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 18),
                label: Text(_loggingIn ? '登录中...' : '重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDashboardBody({Key? key}) {
    final profile = _profile!;

    return RefreshIndicator(
      key: key,
      onRefresh: () => _loadDashboard(showGlobalLoading: false),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          _buildProfileCard(profile),
          const SizedBox(height: 22),
          ChangxingSectionHeading(
            title: '快速办理',
            trailing: '${ChangxingFormType.values.length} 项',
          ),
          const SizedBox(height: 10),
          _buildActionCard(),
          const SizedBox(height: 22),
          ChangxingSectionHeading(
            title: '我的申请',
            trailing: '${_applications.length} 条',
          ),
          if ((_error ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            ChangxingErrorBanner(message: _error!),
          ],
          const SizedBox(height: 10),
          if (_loadingContent && _applications.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_applications.isEmpty)
            const ChangxingEmptyApplications()
          else
            for (final item in _applications) ...[
              _buildApplicationCard(item),
              const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }

  Widget _buildProfileCard(ChangxingUserProfile profile) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final trimmedName = profile.name.trim();
    final initial = trimmedName.isEmpty ? '通' : trimmedName.substring(0, 1);
    final latest = _latestApplication;

    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 25,
                backgroundColor: cs.primaryContainer,
                child: Text(
                  initial,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      trimmedName.isEmpty ? '未命名用户' : trimmedName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      profile.jobNo.isEmpty ? '学号未同步' : profile.jobNo,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ChangxingInfoGrid(
            items: [
              (
                label: '联系电话',
                value: profile.phone.isEmpty ? '—' : profile.phone,
              ),
              (
                label: '紧急联系人',
                value: profile.emergencyContact.isEmpty
                    ? '—'
                    : '${profile.emergencyContact}  ${profile.emergencyPhone}',
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(height: 1, thickness: 1, color: cs.outlineVariant),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: ChangxingMetric(value: _unreadCount, label: '未读消息'),
              ),
              const _MetricDivider(),
              Expanded(
                child: ChangxingMetric(value: _pendingCount, label: '办理中'),
              ),
              const _MetricDivider(),
              Expanded(
                child: ChangxingMetric(
                  value: _applications.length,
                  label: '申请总数',
                ),
              ),
            ],
          ),
          if (latest != null) ...[
            const SizedBox(height: 14),
            Divider(height: 1, thickness: 1, color: cs.outlineVariant),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  '最近申请',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${latest.typeLabel} · ${latest.statusLabel}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (latest.upTime != null)
                  Text(
                    _fmt(latest.upTime),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionCard() {
    final cs = Theme.of(context).colorScheme;
    final actions = ChangxingFormType.values;
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < actions.length; i++) ...[
            ChangxingActionRow(
              icon: _actionIcon(actions[i]),
              title: actions[i].actionLabel,
              hint: _actionHint(actions[i]),
              onTap: () => _openForm(actions[i]),
            ),
            if (i < actions.length - 1)
              Divider(
                height: 1,
                thickness: 1,
                indent: 64,
                endIndent: 16,
                color: cs.outlineVariant,
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildApplicationCard(ChangxingApplication item) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final color = _statusColor(cs, item.status);

    final specs = <({String label, String value})>[
      if (item.departmentName.isNotEmpty)
        (label: '班级', value: item.departmentName),
      if (item.userJobNo.isNotEmpty) (label: '学号', value: item.userJobNo),
      if (item.userPhone.isNotEmpty) (label: '电话', value: item.userPhone),
      if (item.startTime != null) (label: '开始', value: _fmt(item.startTime)),
      if (item.endTime != null) (label: '结束', value: _fmt(item.endTime)),
      if (item.trafficTool.isNotEmpty) (label: '交通', value: item.trafficTool),
      if (item.shouldShowRemark) (label: '审批', value: item.remark),
      if (item.type == 3 && item.backStatus != 0) ...[
        if (item.emergencyContact.isNotEmpty)
          (label: '紧急联系人', value: item.emergencyContact),
        if (item.emergencyPhone.isNotEmpty)
          (label: '联系人电话', value: item.emergencyPhone),
        if (item.notBackReason.isNotEmpty)
          (label: '不返校原因', value: item.notBackReason),
      ],
      if (item.upTime != null) (label: '更新', value: _fmt(item.upTime)),
    ];

    return AppCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppIconBadge(
                icon: _actionIcon(
                  item.formType ?? ChangxingFormType.leaveRequest,
                ),
                accentColor: color,
                size: AppIconBadgeSize.medium,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.typeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.userName.isEmpty ? '未知用户' : item.userName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              ChangxingStatusChip(label: item.statusLabel, color: color),
            ],
          ),
          if (specs.isNotEmpty) ...[
            const SizedBox(height: 14),
            Divider(height: 1, thickness: 1, color: cs.outlineVariant),
            const SizedBox(height: 14),
            ChangxingInfoGrid(items: specs),
          ],
          if (item.descr.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              item.descr,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ],
          if (item.canEdit) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: () {
                  final type = item.formType;
                  if (type == null) return;
                  _openForm(type, applicationId: item.id);
                },
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('编辑申请'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _actionHint(ChangxingFormType action) {
    switch (action) {
      case ChangxingFormType.leaveRequest:
        return '临时请假';
      case ChangxingFormType.leaveSchool:
        return '离校出行';
      case ChangxingFormType.backSchool:
        return '返校确认';
      case ChangxingFormType.overtime:
        return '晚归补登';
    }
  }

  IconData _actionIcon(ChangxingFormType action) {
    switch (action) {
      case ChangxingFormType.leaveRequest:
        return Icons.event_note_outlined;
      case ChangxingFormType.leaveSchool:
        return Icons.directions_walk_outlined;
      case ChangxingFormType.backSchool:
        return Icons.how_to_reg_outlined;
      case ChangxingFormType.overtime:
        return Icons.schedule_outlined;
    }
  }

  Future<void> _openForm(
    ChangxingFormType formType, {
    int? applicationId,
  }) async {
    final Map<String, dynamic> query = applicationId == null
        ? <String, dynamic>{}
        : <String, dynamic>{'id': '$applicationId'};
    final result = await context.pushNamed<bool>(
      formType.routeName,
      queryParameters: query,
    );
    if (result == true && mounted) {
      await _loadDashboard(showGlobalLoading: false);
    }
  }

  Color _statusColor(ColorScheme cs, int status) {
    switch (status) {
      case 0:
      case 1:
        return cs.tertiary;
      case 2:
        return cs.error;
      case 3:
        return cs.onSurfaceVariant;
      case 4:
      case 6:
        return cs.primary;
      case 5:
        return cs.secondary;
      default:
        return cs.onSurfaceVariant;
    }
  }

  String _fmt(DateTime? dateTime) {
    if (dateTime == null) return '-';
    final local = dateTime.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}/${two(local.month)}/${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _MetricDivider extends StatelessWidget {
  const _MetricDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 32,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}
