import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/plain_list.dart';
import '../../shared/widgets/refresh_status_line.dart';
import '../../shared/widgets/skeleton_box.dart';
import 'physical_test_model.dart';
import 'physical_test_service.dart';

typedef PhysicalTestSnapshotFetcher = Future<PhysicalTestSnapshot> Function();

/// 体测成绩原生页面。
///
/// 接入 [PhysicalTestService] 原生数据服务：
/// * 未登录：展示统一认证原生登录引导 [AuthRequiredView]，唤起登录弹窗 [showUnifiedAuthLoginModal]；
/// * 登录成功 / 账号切换：自动拉取对应账号体测成绩，登出立即清除历史成绩；
/// * 有数据：按学年卡片展示体测记录与单项明细；
/// * 无数据：中性空态 [AppEmptyView]；
/// * 失败：错误态 [AppErrorView] 并支持重试；
/// * 严禁挂载任何 WebView、CAS H5 页面或凭据快速填充。
class PhysicalTestPage extends StatefulWidget {
  const PhysicalTestPage({super.key, this.snapshotFetcher});

  static const titleText = '体测成绩';

  /// 测试注入；为空时走 [PhysicalTestService.fetchSnapshot]。
  final PhysicalTestSnapshotFetcher? snapshotFetcher;

  @override
  State<PhysicalTestPage> createState() => _PhysicalTestPageState();
}

class _PhysicalTestPageState extends State<PhysicalTestPage> {
  bool _loading = true;
  bool _authRequired = false;
  String? _error;
  PhysicalTestSnapshot? _snapshot;
  String? _currentAccount;

  int _authEpoch = 0;
  int _loadId = 0;

  @override
  void initState() {
    super.initState();
    _currentAccount = UnifiedAuthService.instance.currentAccount;
    UnifiedAuthService.instance.addListener(_onAuthChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    UnifiedAuthService.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    _authEpoch++;
    final auth = UnifiedAuthService.instance;
    final isLoggedIn = auth.isLoggedIn;
    final newAccount = auth.currentAccount;

    if (!isLoggedIn || newAccount == null || newAccount.isEmpty) {
      _currentAccount = null;
      if (mounted) {
        setState(() {
          _snapshot = null;
          _authRequired = true;
          _loading = false;
          _error = null;
        });
      }
      return;
    }

    if (newAccount != _currentAccount) {
      _currentAccount = newAccount;
      if (mounted) {
        setState(() {
          _snapshot = null;
          _authRequired = false;
          _error = null;
        });
        unawaited(_load(forceRefresh: true));
      }
      return;
    }

    if (_authRequired && mounted) {
      unawaited(_load());
    }
  }

  Future<void> _presentLoginPrompt() async {
    final loggedIn = await showUnifiedAuthLoginModal(
      context,
      title: '登录统一认证',
      description: '登录后可查看体测成绩',
    );
    if (loggedIn && mounted) {
      await _load(forceRefresh: true);
    }
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final loadId = ++_loadId;
    final currentEpoch = _authEpoch;

    setState(() {
      _loading = true;
      _error = null;
      _authRequired = false;
    });

    try {
      final snapshot = widget.snapshotFetcher != null
          ? await widget.snapshotFetcher!()
          : await PhysicalTestService.instance.fetchSnapshot(
              forceRefresh: forceRefresh,
            );

      if (!mounted || loadId != _loadId || currentEpoch != _authEpoch) {
        return;
      }

      setState(() {
        _snapshot = snapshot;
        _authRequired = false;
        _error = null;
      });
    } on CasAuthExpiredException {
      if (!mounted || loadId != _loadId || currentEpoch != _authEpoch) {
        return;
      }
      setState(() {
        _snapshot = null;
        _authRequired = true;
        _error = null;
      });
    } catch (error, stackTrace) {
      AppLogger.instance.network(
        LogLevel.warn,
        '体测成绩加载失败',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted || loadId != _loadId || currentEpoch != _authEpoch) {
        return;
      }
      setState(() {
        _error = '体测成绩加载失败，请稍后重试';
      });
    } finally {
      if (mounted && loadId == _loadId && currentEpoch == _authEpoch) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(
        title: const Text(PhysicalTestPage.titleText),
        actions: [
          if (!_loading && !_authRequired && _error == null)
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: '刷新',
              onPressed: () => _load(forceRefresh: true),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _snapshot == null && !_authRequired && _error == null) {
      return _buildSkeleton();
    }

    if (_authRequired) {
      return AuthRequiredView(
        title: '需要统一认证后继续',
        message: '登录统一身份认证后可查看体测成绩',
        buttonLabel: '登录统一认证',
        icon: Icons.directions_run_outlined,
        onAction: _presentLoginPrompt,
      );
    }

    final error = _error;
    if (error != null) {
      return AppErrorView(
        message: error,
        onRetry: () => _load(forceRefresh: true),
      );
    }

    final records = _snapshot?.records ?? const <PhysicalTestRecord>[];
    if (records.isEmpty) {
      return AppEmptyView(
        title: '暂无体测成绩',
        icon: Icons.directions_run_outlined,
        message: _snapshot?.message,
        actionLabel: '刷新',
        onAction: () => _load(forceRefresh: true),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(forceRefresh: true),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageMargin,
          AppSpacing.sm,
          AppSpacing.pageMargin,
          AppSpacing.xl,
        ),
        itemCount: records.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
        itemBuilder: (context, index) => _buildRecordCard(records[index]),
      ),
    );
  }

  /// 每个学年一组：标题行「学年 · 总分 · 等级」+ 键值行（左项目、右成绩）。
  Widget _buildRecordCard(PhysicalTestRecord record) {
    final cs = Theme.of(context).colorScheme;
    final label = context.appText.label;
    final summary = [
      record.totalScore,
      record.grade,
    ].where((value) => value.isNotEmpty).join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    record.academicYear.isEmpty ? '体测记录' : record.academicYear,
                    style: label,
                  ),
                ),
                if (summary.isNotEmpty)
                  Text(summary, style: label.copyWith(color: cs.primary)),
              ],
            ),
          ),
        ),
        if (record.items.isNotEmpty)
          PlainListGroup(
            children: [for (final item in record.items) _buildItemRow(item)],
          ),
      ],
    );
  }

  Widget _buildItemRow(PhysicalTestItem item) {
    final trailing = [
      item.result,
      if (item.score.isNotEmpty) '${item.score} 分',
      item.level,
    ].where((value) => value.isNotEmpty).join(' · ');

    return PlainListRow(
      title: item.name.isEmpty ? '未命名项目' : item.name,
      value: trailing.isEmpty ? null : trailing,
    );
  }

  /// 无缓存首次加载：一组骨架，替代整页 spinner。
  Widget _buildSkeleton() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.sm,
        AppSpacing.pageMargin,
        AppSpacing.xl,
      ),
      children: const [
        RefreshStatusLine(refreshing: true, loadingLabel: '正在获取体测成绩…'),
        SizedBox(height: AppSpacing.md),
        SkeletonBox(width: 96, height: 12),
        SizedBox(height: AppSpacing.sm),
        SkeletonBox(height: 208, radius: 16),
      ],
    );
  }
}
