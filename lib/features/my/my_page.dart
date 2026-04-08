import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../schedule/schedule_service.dart';

class MyPage extends StatefulWidget {
  const MyPage({super.key});

  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {
  bool _campusLoggedIn = false;
  bool _academicLoggedIn = false;
  bool _hasScheduleCache = false;
  DateTime? _scheduleUpdatedAt;

  @override
  void initState() {
    super.initState();
    UnifiedAuthService.instance.addListener(_onAuthChanged);
    ZhengfangAuth.instance.addListener(_onAuthChanged);
    _refreshStatus();
  }

  @override
  void dispose() {
    UnifiedAuthService.instance.removeListener(_onAuthChanged);
    ZhengfangAuth.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (!mounted) return;
    _refreshStatus();
  }

  void _refreshStatus() {
    final term = ScheduleService.instance.getCurrentTermContext();
    final snapshot = ScheduleService.instance.preferredSnapshot(
      termContext: term,
    );
    setState(() {
      _campusLoggedIn = UnifiedAuthService.instance.isLoggedIn;
      _academicLoggedIn = ZhengfangAuth.instance.isLoggedIn;
      _hasScheduleCache = snapshot?.hasData ?? false;
      _scheduleUpdatedAt = snapshot?.lastUpdatedAt;
    });
  }

  Future<void> _openCampusCardAction() async {
    if (_campusLoggedIn) {
      await context.pushNamed('campus-card');
      if (!mounted) return;
      _refreshStatus();
      return;
    }
    await context.pushNamed('unified-auth-login');
    if (!mounted) return;
    _refreshStatus();
  }

  Future<void> _openAcademicAction() async {
    if (_academicLoggedIn) {
      await context.pushNamed('schedule');
      if (!mounted) return;
      _refreshStatus();
      return;
    }
    await context.pushNamed('academic-system-login');
    if (!mounted) return;
    _refreshStatus();
  }

  Future<void> _reloginCampus() async {
    await context.pushNamed('unified-auth-login');
    if (!mounted) return;
    _refreshStatus();
  }

  Future<void> _reloginAcademic() async {
    await context.pushNamed('academic-system-login');
    if (!mounted) return;
    _refreshStatus();
  }

  String _formatTime(DateTime? value) {
    if (value == null) return '未缓存';
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$month-$day $hour:$minute';
  }

  String _academicSubtitle() {
    if (_academicLoggedIn) {
      if (_hasScheduleCache) {
        return '已登录 · 课表更新 ${_formatTime(_scheduleUpdatedAt)}';
      }
      return '已登录 · 课表未缓存';
    }
    if (_hasScheduleCache) {
      return '未登录 · 课表缓存 ${_formatTime(_scheduleUpdatedAt)}';
    }
    return '未登录 · 课表未缓存';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                        AppColors.primary.withValues(alpha: 0.45),
                        cs.surfaceContainerHigh,
                      ]
                    : [AppColors.primary.withValues(alpha: 0.16), Colors.white],
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.10)
                    : Colors.white.withValues(alpha: 0.72),
              ),
            ),
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '校园服务账户中心',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '统一管理一卡通、教务登录状态与应用设置',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _AccountStatusCard(
            icon: Icons.account_balance_wallet_outlined,
            iconColor: AppColors.primary,
            title: '一卡通',
            subtitle: _campusLoggedIn ? '已登录' : '未登录',
            primaryActionLabel: _campusLoggedIn ? '进入服务' : '登录',
            onPrimaryAction: _openCampusCardAction,
            secondaryActionLabel: _campusLoggedIn ? '重新登录' : null,
            onSecondaryAction: _campusLoggedIn ? _reloginCampus : null,
          ),
          const SizedBox(height: 12),
          _AccountStatusCard(
            icon: Icons.school_outlined,
            iconColor: AppColors.info,
            title: '教务系统',
            subtitle: _academicSubtitle(),
            primaryActionLabel: _academicLoggedIn ? '进入服务' : '登录',
            onPrimaryAction: _openAcademicAction,
            secondaryActionLabel: _academicLoggedIn ? '重新登录' : null,
            onSecondaryAction: _academicLoggedIn ? _reloginAcademic : null,
          ),
          const SizedBox(height: 18),
          Card(
            child: ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('设置'),
              subtitle: const Text('主题、学期、网络与调试选项'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await context.pushNamed('settings');
                if (!mounted) return;
                _refreshStatus();
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountStatusCard extends StatelessWidget {
  const _AccountStatusCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.primaryActionLabel,
    required this.onPrimaryAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final String primaryActionLabel;
  final VoidCallback onPrimaryAction;
  final String? secondaryActionLabel;
  final VoidCallback? onSecondaryAction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: iconColor, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                FilledButton(
                  onPressed: onPrimaryAction,
                  child: Text(primaryActionLabel),
                ),
                if (secondaryActionLabel != null &&
                    onSecondaryAction != null) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: onSecondaryAction,
                    child: Text(secondaryActionLabel!),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
