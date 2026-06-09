import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/login_shell.dart';
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

  /// 是否需要先登录一卡通（CAS 未登录时显示统一认证提示）
  bool _needUnifiedAuth = false;

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
      _needUnifiedAuth = false;
    });
  }

  Future<void> _loginViaCas() async {
    setState(() {
      _loggingIn = true;
      _error = null;
    });

    try {
      await _service.loginViaCas();
      if (!mounted) return;
      setState(() => _needUnifiedAuth = false);
      await _loadDashboard(showGlobalLoading: false);
    } on ChangxingNeedUnifiedAuthException {
      if (!mounted) return;
      setState(() => _needUnifiedAuth = true);
    } on ChangxingCasLoginException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '登录失败：$e');
    } finally {
      if (mounted) {
        setState(() => _loggingIn = false);
      }
    }
  }

  Future<void> _promptCasLogin() async {
    final loggedIn = await showUnifiedAuthLoginModal(
      context,
      title: '登录一卡通',
      description: '畅行嘉大仅支持校园网内直连访问，请连接校园网后完成统一认证',
      barrierDismissible: false,
    );
    if (!mounted || !loggedIn) return;
    setState(() => _needUnifiedAuth = false);
    await _loginViaCas();
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return Scaffold(
        appBar: AppBar(title: const Text('畅行嘉大')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
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
            : _buildLoginBody(key: const ValueKey('login')),
      ),
    );
  }

  Widget _buildLoginBody({Key? key}) {
    final needsUnifiedAuth = _needUnifiedAuth;
    return SafeArea(
      key: key,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final minHeight = constraints.maxHeight > 44
              ? constraints.maxHeight - 44
              : 0.0;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minHeight),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildLoginPanel(needsUnifiedAuth: needsUnifiedAuth),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLoginPanel({required bool needsUnifiedAuth}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final title = needsUnifiedAuth ? '需要统一认证' : '同步校园通行身份';
    final message = needsUnifiedAuth
        ? '请先完成一卡通统一认证，再进入畅行嘉大办理申请。'
        : '使用已保存的一卡通会话进入畅行嘉大，查看申请进度并快速发起办理。';
    final buttonLabel = needsUnifiedAuth ? '登录统一认证' : '一键登录畅行嘉大';

    return Container(
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildPassMark(needsUnifiedAuth: needsUnifiedAuth),
          const SizedBox(height: 24),
          Text(
            title,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              height: 1.12,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: const [
              ChangxingLoginPill(icon: Icons.wifi_tethering, label: '校园网'),
              ChangxingLoginPill(
                icon: Icons.verified_user_outlined,
                label: '统一认证',
              ),
              ChangxingLoginPill(
                icon: Icons.assignment_outlined,
                label: '通行申请',
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 18),
            ChangxingErrorBanner(message: _error!),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _loggingIn
                ? null
                : needsUnifiedAuth
                ? _promptCasLogin
                : _loginViaCas,
            icon: _loggingIn
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(needsUnifiedAuth ? Icons.login : Icons.north_east),
            label: Text(_loggingIn ? '登录中...' : buttonLabel),
          ),
          const SizedBox(height: 12),
          Text(
            '若刚完成统一认证仍失败，请保持校园网连接后重试一次。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPassMark({required bool needsUnifiedAuth}) {
    final cs = Theme.of(context).colorScheme;
    final accent = needsUnifiedAuth ? cs.tertiary : cs.primary;
    return Container(
      height: 154,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: cs.surfaceContainerHigh,
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Container(
              width: 4,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          Align(
            alignment: Alignment.topLeft,
            child: Text(
              '校园通行',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Align(
            alignment: Alignment.center,
            child: Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                color: cs.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: cs.outlineVariant),
              ),
              child: Icon(
                needsUnifiedAuth
                    ? Icons.lock_open_outlined
                    : Icons.directions_walk_outlined,
                color: accent,
                size: 38,
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomRight,
            child: Text(
              needsUnifiedAuth ? '需要认证' : '已就绪',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
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
          _buildSectionHeader('快速办理', trailing: '4 项'),
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

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: cs.surfaceContainerLowest,
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(Icons.badge_outlined, color: cs.primary),
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
              borderRadius: BorderRadius.circular(14),
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
    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            title: '未读消息',
            value: _unreadCount.toString(),
            icon: Icons.mark_chat_unread_outlined,
            color: const Color(0xFF1D7D72),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildStatCard(
            title: '办理中',
            value: _pendingCount.toString(),
            icon: Icons.pending_actions_outlined,
            color: const Color(0xFFD88413),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildStatCard(
            title: '申请总数',
            value: _applications.length.toString(),
            icon: Icons.assignment_outlined,
            color: const Color(0xFF3F6FB5),
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
    return Container(
      height: 94,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.48)),
      ),
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
    final actionMeta =
        <ChangxingFormType, ({IconData icon, String hint, Color color})>{
          ChangxingFormType.leaveRequest: (
            icon: Icons.event_note_outlined,
            hint: '临时请假',
            color: const Color(0xFF8B1A2D),
          ),
          ChangxingFormType.leaveSchool: (
            icon: Icons.directions_walk_outlined,
            hint: '离校出行',
            color: const Color(0xFF1D7D72),
          ),
          ChangxingFormType.backSchool: (
            icon: Icons.how_to_reg_outlined,
            hint: '返校确认',
            color: const Color(0xFF3F6FB5),
          ),
          ChangxingFormType.overtime: (
            icon: Icons.schedule_outlined,
            hint: '晚归补登',
            color: const Color(0xFFD88413),
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
            mainAxisExtent: 96,
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
    final cs = theme.colorScheme;
    return Material(
      color: cs.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.45),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 22),
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
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 20),
            ],
          ),
        ),
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
    final color = _statusColor(item.status);
    final typeIcon = _typeIcon(item.type);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.46)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(typeIcon, size: 21, color: color),
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

  Color _statusColor(int status) {
    switch (status) {
      case 0:
      case 1:
        return const Color(0xFFD88413);
      case 2:
        return Colors.red.shade700;
      case 3:
        return Colors.grey.shade600;
      case 4:
      case 6:
        return Colors.green.shade700;
      case 5:
        return Colors.blue.shade700;
      default:
        return Colors.grey.shade700;
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
