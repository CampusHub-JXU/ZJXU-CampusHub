import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_icon_badge.dart';
import '../../shared/widgets/app_tile_surface.dart';
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
        title: const Text('畅行嘉大'),
        actions: _loggedIn
            ? [
                IconButton(
                  tooltip: '刷新',
                  onPressed: _loadingContent
                      ? null
                      : () => _loadDashboard(showGlobalLoading: true),
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  tooltip: '退出登录',
                  onPressed: _logout,
                  icon: const Icon(Icons.logout),
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

  /// FR-5: 未登录时的简化重试态（图标 + 文案 + 重试按钮），不显示装饰性中间页。
  Widget _buildAuthPendingBody({Key? key}) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      key: key,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                child: Icon(
                  Icons.directions_walk_outlined,
                  color: cs.onSurfaceVariant,
                  size: 28,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                '畅行嘉大',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                _error ?? '正在连接校园通行服务…',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
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
          _buildProfileHero(profile),
          const SizedBox(height: 12),
          _buildStatsRow(),
          const SizedBox(height: 16),
          _buildSectionHeader(
            '快速办理',
            trailing: '${ChangxingFormType.values.length} 项',
          ),
          const SizedBox(height: 10),
          _buildQuickActions(),
          const SizedBox(height: 20),
          _buildSectionHeader('我的申请', trailing: '${_applications.length} 条'),
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
            ..._applications.map(_buildApplicationCard),
        ],
      ),
    );
  }

  Widget _buildProfileHero(ChangxingUserProfile profile) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final latest = _latestApplication;
    final subtitle = latest == null
        ? '暂无最近申请'
        : '${latest.typeLabel} · ${latest.statusLabel}';

    return AppCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIconBadge(
                icon: Icons.badge_outlined,
                accentColor: cs.primary,
                size: AppIconBadgeSize.large,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.name.isEmpty ? '未命名用户' : profile.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      profile.jobNo.isEmpty ? '学号未同步' : profile.jobNo,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (_loadingContent)
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: cs.primary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChangxingInfoPill(
                icon: Icons.phone_outlined,
                label: profile.phone.isEmpty ? '联系电话 -' : profile.phone,
              ),
              ChangxingInfoPill(
                icon: Icons.emergency_outlined,
                label: profile.emergencyContact.isEmpty
                    ? '紧急联系人 -'
                    : '${profile.emergencyContact} ${profile.emergencyPhone}',
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(AppRadius.badge),
            ),
            child: Row(
              children: [
                Icon(Icons.history, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (latest?.upTime != null)
                  Text(
                    _fmt(latest!.upTime),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            title: '未读消息',
            value: _unreadCount.toString(),
            icon: Icons.mark_chat_unread_outlined,
            color: cs.primary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildStatCard(
            title: '办理中',
            value: _pendingCount.toString(),
            icon: Icons.pending_actions_outlined,
            color: cs.tertiary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildStatCard(
            title: '申请总数',
            value: _applications.length.toString(),
            icon: Icons.assignment_outlined,
            color: cs.secondary,
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return SizedBox(
      height: 94,
      child: AppCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 19, color: color),
            const Spacer(),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, {String? trailing}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Row(
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const Spacer(),
        if (trailing != null)
          Text(
            trailing,
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }

  Widget _buildQuickActions() {
    final cs = Theme.of(context).colorScheme;
    final actionMeta =
        <ChangxingFormType, ({IconData icon, String hint, Color color})>{
          ChangxingFormType.leaveRequest: (
            icon: Icons.event_note_outlined,
            hint: '临时请假',
            color: cs.primary,
          ),
          ChangxingFormType.leaveSchool: (
            icon: Icons.directions_walk_outlined,
            hint: '离校出行',
            color: cs.secondary,
          ),
          ChangxingFormType.backSchool: (
            icon: Icons.how_to_reg_outlined,
            hint: '返校确认',
            color: cs.tertiary,
          ),
          ChangxingFormType.overtime: (
            icon: Icons.schedule_outlined,
            hint: '晚归补登',
            color: _themeAccent(cs.primary, hueOffset: 72, colorScheme: cs),
          ),
        };

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth >= 560 ? 4 : 2;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: ChangxingFormType.values.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            // 与首页功能区 wide 瓦片同档行高，单行内容不显肥厚。
            mainAxisExtent: 76,
          ),
          itemBuilder: (context, index) {
            final action = ChangxingFormType.values[index];
            final meta = actionMeta[action]!;
            return _buildActionTile(
              title: action.actionLabel,
              hint: meta.hint,
              icon: meta.icon,
              color: meta.color,
              onTap: () => _openForm(action),
            );
          },
        );
      },
    );
  }

  Widget _buildActionTile({
    required String title,
    required String hint,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return AppTileSurface(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      child: Row(
        children: [
          AppIconBadge(
            icon: icon,
            accentColor: color,
            size: AppIconBadgeSize.large,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, size: 20),
        ],
      ),
    );
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

  Widget _buildApplicationCard(ChangxingApplication item) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final color = _statusColor(cs, item.status);
    final typeIcon = _typeIcon(item.type);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppIconBadge(
                  icon: typeIcon,
                  accentColor: color,
                  size: AppIconBadgeSize.large,
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
                          fontWeight: FontWeight.w800,
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
                ChangxingStatusBadge(label: item.statusLabel, color: color),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (item.departmentName.isNotEmpty)
                  ChangxingDetailChip(label: '班级', value: item.departmentName),
                if (item.userJobNo.isNotEmpty)
                  ChangxingDetailChip(label: '学号', value: item.userJobNo),
                if (item.userPhone.isNotEmpty)
                  ChangxingDetailChip(label: '电话', value: item.userPhone),
                if (item.startTime != null)
                  ChangxingDetailChip(label: '开始', value: _fmt(item.startTime)),
                if (item.endTime != null)
                  ChangxingDetailChip(label: '结束', value: _fmt(item.endTime)),
                if (item.trafficTool.isNotEmpty)
                  ChangxingDetailChip(label: '交通', value: item.trafficTool),
                if (item.shouldShowRemark)
                  ChangxingDetailChip(label: '审批', value: item.remark),
                if (item.upTime != null)
                  ChangxingDetailChip(label: '更新', value: _fmt(item.upTime)),
              ],
            ),
            if (item.descr.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                item.descr,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
              ),
            ],
            if (item.type == 3) ...[
              if (item.backStatus != 0) ...[
                if (item.emergencyContact.isNotEmpty)
                  _buildDetailLine('紧急联系人', item.emergencyContact),
                if (item.emergencyPhone.isNotEmpty)
                  _buildDetailLine('联系人电话', item.emergencyPhone),
                if (item.notBackReason.isNotEmpty)
                  _buildDetailLine('不返校原因', item.notBackReason),
              ],
            ],
            if (item.canEdit) ...[
              const SizedBox(height: 12),
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
      ),
    );
  }

  Widget _buildDetailLine(String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        '$label：$value',
        style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
      ),
    );
  }

  Color _themeAccent(
    Color base, {
    required double hueOffset,
    required ColorScheme colorScheme,
  }) {
    final hsl = HSLColor.fromColor(base);
    final isDark = colorScheme.brightness == Brightness.dark;
    return hsl
        .withHue((hsl.hue + hueOffset) % 360.0)
        .withSaturation((hsl.saturation * 0.86).clamp(0.42, 0.92))
        .withLightness(isDark ? 0.66 : 0.42)
        .toColor();
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

  IconData _typeIcon(int type) {
    switch (type) {
      case 1:
        return Icons.event_note_outlined;
      case 2:
        return Icons.directions_walk_outlined;
      case 3:
        return Icons.how_to_reg_outlined;
      case 4:
        return Icons.schedule_outlined;
      default:
        return Icons.assignment_outlined;
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
