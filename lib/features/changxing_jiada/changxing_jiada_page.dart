import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'changxing_jiada_model.dart';
import 'changxing_jiada_service.dart';

class ChangxingJiadaPage extends StatefulWidget {
  const ChangxingJiadaPage({super.key});

  @override
  State<ChangxingJiadaPage> createState() => _ChangxingJiadaPageState();
}

class _ChangxingJiadaPageState extends State<ChangxingJiadaPage> {
  final _accountCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _captchaCtrl = TextEditingController();

  bool _rememberPassword = false;
  bool _initializing = true;
  bool _loadingContent = false;
  bool _loggingIn = false;
  String? _error;
  Uint8List? _captchaBytes;

  ChangxingUserProfile? _profile;
  int _unreadCount = 0;
  List<ChangxingApplication> _applications = [];

  ChangxingJiadaService get _service => ChangxingJiadaService.instance;

  bool get _loggedIn => _service.hasToken && _profile != null;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _accountCtrl.dispose();
    _passwordCtrl.dispose();
    _captchaCtrl.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    final remembered = await _service.loadRememberedCredentials();
    if (remembered != null) {
      _accountCtrl.text = remembered.$1;
      _passwordCtrl.text = remembered.$2;
      _rememberPassword = true;
    }

    await _service.restoreSession();
    await _refreshCaptcha(silent: true);

    if (_service.hasToken) {
      await _loadDashboard(showGlobalLoading: false);
    }

    if (!mounted) return;
    setState(() {
      _initializing = false;
    });
  }

  Future<void> _refreshCaptcha({bool silent = false}) async {
    try {
      final bytes = await _service.fetchCaptcha();
      if (!mounted) return;
      setState(() => _captchaBytes = bytes);
    } catch (e) {
      if (!silent && mounted) {
        _showSnackBar('获取验证码失败：$e');
      }
    }
  }

  Future<void> _login() async {
    final account = _accountCtrl.text.trim();
    final password = _passwordCtrl.text;
    final captcha = _captchaCtrl.text.trim();
    if (account.isEmpty || password.isEmpty || captcha.isEmpty) {
      _showSnackBar('请填写账号、密码和验证码');
      return;
    }

    setState(() {
      _loggingIn = true;
      _error = null;
    });

    try {
      await _service.login(
        account,
        password,
        captcha,
        rememberPassword: _rememberPassword,
      );
      _captchaCtrl.clear();
      await _loadDashboard(showGlobalLoading: false);
    } on ChangxingLoginFailure catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      await _refreshCaptcha(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '登录失败：$e');
      await _refreshCaptcha(silent: true);
    } finally {
      if (mounted) {
        setState(() => _loggingIn = false);
      }
    }
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
      await _refreshCaptcha(silent: true);
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
      _captchaCtrl.clear();
    });
    await _refreshCaptcha(silent: true);
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
                  onPressed: _loadingContent
                      ? null
                      : () => _loadDashboard(showGlobalLoading: true),
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(onPressed: _logout, icon: const Icon(Icons.logout)),
              ]
            : null,
      ),
      body: _loggedIn ? _buildDashboardBody() : _buildLoginBody(),
    );
  }

  Widget _buildLoginBody() {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: cs.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '畅行嘉大原生版登录\n账号为校园一卡通号',
            style: TextStyle(
              fontSize: 14,
              color: cs.onPrimaryContainer,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _accountCtrl,
          decoration: const InputDecoration(
            labelText: '账号',
            hintText: '请输入一卡通账号',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordCtrl,
          obscureText: true,
          decoration: const InputDecoration(labelText: '密码', hintText: '请输入密码'),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _captchaCtrl,
                decoration: const InputDecoration(
                  labelText: '验证码',
                  hintText: '请输入验证码',
                ),
              ),
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: () => _refreshCaptcha(),
              child: Container(
                width: 130,
                height: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.outlineVariant),
                  color: cs.surfaceContainerHighest,
                ),
                clipBehavior: Clip.antiAlias,
                child: _captchaBytes == null
                    ? Center(
                        child: Text(
                          '点击刷新',
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      )
                    : Image.memory(
                        _captchaBytes!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Checkbox(
              value: _rememberPassword,
              onChanged: (value) {
                setState(() => _rememberPassword = value ?? false);
              },
            ),
            const Text('记住密码'),
            const Spacer(),
            TextButton(
              onPressed: () async {
                await _service.clearRememberedCredentials();
                if (!mounted) return;
                setState(() => _rememberPassword = false);
              },
              child: const Text('清除已保存密码'),
            ),
          ],
        ),
        if ((_error ?? '').isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: cs.error, fontSize: 13)),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _loggingIn ? null : _login,
          child: _loggingIn
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('登录畅行嘉大'),
        ),
      ],
    );
  }

  Widget _buildDashboardBody() {
    final profile = _profile!;
    if (_loadingContent && _applications.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: () => _loadDashboard(showGlobalLoading: false),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildProfileCard(profile),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildStatCard(
                  title: '未读消息',
                  value: _unreadCount.toString(),
                  icon: Icons.mark_chat_unread_outlined,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildStatCard(
                  title: '我的申请',
                  value: _applications.length.toString(),
                  icon: Icons.assignment_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildQuickActions(),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                '我的申请',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              if ((_error ?? '').isNotEmpty)
                Text(
                  _error!,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_applications.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '暂无申请记录',
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            ..._applications.map(_buildApplicationCard),
        ],
      ),
    );
  }

  Widget _buildProfileCard(ChangxingUserProfile profile) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            profile.name.isEmpty ? '未命名用户' : profile.name,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '学号：${profile.jobNo.isEmpty ? '-' : profile.jobNo}',
            style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            '联系电话：${profile.phone.isEmpty ? '-' : profile.phone}',
            style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            '紧急联系人：${profile.emergencyContact.isEmpty ? '-' : profile.emergencyContact} '
            '${profile.emergencyPhone.isEmpty ? '' : profile.emergencyPhone}',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard({
    required String title,
    required String value,
    required IconData icon,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  title,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions() {
    final actions = <(String, IconData)>[
      ('请假申请', Icons.event_note_outlined),
      ('离校登记', Icons.directions_walk_outlined),
      ('返校登记', Icons.how_to_reg_outlined),
      ('超时登记', Icons.schedule_outlined),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: actions
          .map(
            (action) => OutlinedButton.icon(
              onPressed: () => _showSnackBar('${action.$1}原生表单开发中'),
              icon: Icon(action.$2, size: 16),
              label: Text(action.$1),
            ),
          )
          .toList(),
    );
  }

  Widget _buildApplicationCard(ChangxingApplication item) {
    final cs = Theme.of(context).colorScheme;
    final color = _statusColor(item.status);
    final statusBg = color.withValues(alpha: 0.12);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${item.userName.isEmpty ? "未知用户" : item.userName} · ${item.typeLabel}',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  item.statusLabel,
                  style: TextStyle(
                    fontSize: 12,
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (item.departmentName.isNotEmpty) _line('班级', item.departmentName),
          if (item.userJobNo.isNotEmpty) _line('学号', item.userJobNo),
          if (item.userPhone.isNotEmpty) _line('联系方式', item.userPhone),
          if (item.startTime != null) _line('开始时间', _fmt(item.startTime)),
          if (item.endTime != null) _line('结束时间', _fmt(item.endTime)),
          if (item.type == 3) ...[
            if (item.backStatus != 0) ...[
              if (item.emergencyContact.isNotEmpty)
                _line('紧急联系人', item.emergencyContact),
              if (item.emergencyPhone.isNotEmpty)
                _line('联系人电话', item.emergencyPhone),
              if (item.notBackReason.isNotEmpty)
                _line('不返校原因', item.notBackReason),
            ] else ...[
              if (item.trafficTool.isNotEmpty) _line('交通工具', item.trafficTool),
            ],
          ],
          if (item.descr.isNotEmpty) _line('${item.typeLabel}事由', item.descr),
          if (item.shouldShowRemark) _line('审批备注', item.remark),
          if (item.upTime != null) _line('更新时间', _fmt(item.upTime)),
        ],
      ),
    );
  }

  Widget _line(String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
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
        return Colors.orange.shade700;
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

  String _fmt(DateTime? dateTime) {
    if (dateTime == null) return '-';
    final local = dateTime.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}/${two(local.month)}/${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
