import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/auth/zhengfang_auth.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../../shared/widgets/app_list_tile.dart';
import '../../../shared/widgets/app_status_tag.dart';
import '../../../shared/widgets/auth_required_view.dart';
import '../../../shared/widgets/detail_readout.dart';
import '../../../shared/widgets/login_shell.dart';
import '../../../shared/widgets/network_error_toast.dart';
import '../../../shared/widgets/plain_list.dart';
import '../../../shared/widgets/refresh_status_line.dart';
import '../../../shared/widgets/skeleton_box.dart';
import 'academic_progress_model.dart';
import 'academic_progress_service.dart';
import 'requirement_tree_canvas.dart';

typedef AcademicProgressFetcher = Future<AcademicProgressReport> Function({
  bool forceRefresh,
});

/// 学生学业情况查询的原生视图（替代正方 H5 `xsxyqk_cxXsxyqkIndex`）。
///
/// 只保留两项核心内容：教务口径的主修 GPA 读数 + 可拖动缩放培养方案树
/// （[RequirementTreeCanvas]）。不再提供平铺课程列表、状态筛选或视图切换。
///
/// 不自带 Scaffold：作为成绩页「学业进度」分段嵌入 `GradesPage`。AppBar 按钮由
/// 宿主经 [AcademicProgressViewState.buildAppBarActions] 取得；按钮相关状态
/// 变化时回调 [onChromeChanged]，让宿主重建 AppBar。
class AcademicProgressView extends StatefulWidget {
  const AcademicProgressView({
    super.key,
    this.fetchReport,
    this.onChromeChanged,
    this.active = true,
  });

  /// 是否为宿主当前可见的分段；不可见时不自动弹登录框，避免与成绩分段叠弹。
  final bool active;

  /// 测试注入点：默认走 [AcademicProgressService.fetchReport]。
  final AcademicProgressFetcher? fetchReport;

  final VoidCallback? onChromeChanged;

  @override
  State<AcademicProgressView> createState() => AcademicProgressViewState();
}

class AcademicProgressViewState extends State<AcademicProgressView> {
  bool _loggedIn = false;
  bool _loading = false;
  bool _refreshing = false;
  bool _refreshFailed = false;
  DateTime? _updatedAt;
  String? _error;
  AcademicProgressReport? _report;
  bool _loginPromptShown = false;
  bool _loginPromptInFlight = false;
  bool _automaticLoginPaused = false;

  /// 页面数据归属的教务账号与身份修订号；变化即清空 / 作废在途结果。
  String? _identityOwner;
  int _identityRevision = 0;
  int _fetchGeneration = 0;

  @override
  void initState() {
    super.initState();
    final auth = ZhengfangAuth.instance;
    _loggedIn = auth.isLoggedIn;
    _identityOwner = auth.verifiedStudentId;
    _identityRevision = auth.sessionRevision;
    auth.addListener(_handleAuthChanged);
    _report = AcademicProgressService.instance.cachedReport;
    _updatedAt = _report == null
        ? null
        : AcademicProgressService.instance.updatedAt;
    if (_loggedIn) {
      if (_report == null && widget.fetchReport == null) {
        unawaited(_restoreThenFetch());
      } else {
        _fetch();
      }
    } else if (_report == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_presentLoginPrompt());
      });
    }
  }

  @override
  void dispose() {
    ZhengfangAuth.instance.removeListener(_handleAuthChanged);
    super.dispose();
  }

  bool _acceptFetchResult(int generation, String owner, int revision) {
    if (!mounted || generation != _fetchGeneration) return false;
    final auth = ZhengfangAuth.instance;
    return _loggedIn &&
        _identityOwner == owner &&
        _identityRevision == revision &&
        auth.isLoggedIn &&
        auth.sessionRevision == revision &&
        auth.verifiedStudentId == owner;
  }

  void _handleAuthChanged() {
    if (!mounted) return;
    final auth = ZhengfangAuth.instance;
    final nextOwner = auth.verifiedStudentId;
    final nextRevision = auth.sessionRevision;
    if (auth.isLoggedIn == _loggedIn &&
        nextOwner == _identityOwner &&
        nextRevision == _identityRevision) {
      return;
    }
    if (nextOwner == null) {
      // 登出 / 会话失效：不得继续持有上一个账号的学业数据。
      setState(() {
        _loggedIn = false;
        _identityOwner = null;
        _identityRevision = nextRevision;
        _report = null;
        _updatedAt = null;
        _loading = false;
        _refreshing = false;
        _refreshFailed = false;
        _error = null;
        _automaticLoginPaused = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_presentLoginPrompt(force: true));
      });
      return;
    }
    final ownerChanged = nextOwner != _identityOwner;
    setState(() {
      _loggedIn = true;
      _identityOwner = nextOwner;
      _identityRevision = nextRevision;
      _fetchGeneration++;
      _error = null;
      _automaticLoginPaused = false;
      if (ownerChanged) {
        _report = null;
        _updatedAt = null;
      }
    });
    unawaited(_fetch(forceRefresh: !ownerChanged));
  }

  /// 冷启动后内存缓存为空：先从磁盘恢复（owner / epoch 由服务校验），
  /// 有缓存即先展示，再按 TTL 决定是否联网——学业明细是逐个末节点串行
  /// POST，没有这一步每次重启后首次进页都要整页骨架等全部请求跑完。
  Future<void> _restoreThenFetch() async {
    final owner = _identityOwner;
    final revision = _identityRevision;
    final service = AcademicProgressService.instance;
    await service.restoreCache();
    // 恢复期间身份变化已由 [_handleAuthChanged] 接管刷新，这里不再插手。
    if (!mounted ||
        !_loggedIn ||
        _identityOwner != owner ||
        _identityRevision != revision) {
      return;
    }
    final cached = service.cachedReport;
    if (_report == null && cached != null) {
      setState(() {
        _report = cached;
        _updatedAt = service.updatedAt;
      });
    }
    await _fetch();
  }

  Future<void> _fetch({bool forceRefresh = false}) async {
    final auth = ZhengfangAuth.instance;
    final owner = auth.verifiedStudentId;
    if (!auth.isLoggedIn || owner == null || owner != _identityOwner) return;
    final revision = auth.sessionRevision;
    final generation = ++_fetchGeneration;
    final hasExistingData = _report != null;

    setState(() {
      _loading = _report == null;
      _refreshing = true;
      _refreshFailed = false;
      _error = null;
    });
    try {
      final report =
          await (widget.fetchReport?.call(forceRefresh: forceRefresh) ??
              AcademicProgressService.instance.fetchReport(
                forceRefresh: forceRefresh,
              ));
      if (!_acceptFetchResult(generation, owner, revision)) return;
      setState(() {
        _report = report;
        _updatedAt = widget.fetchReport == null
            ? (AcademicProgressService.instance.updatedAt ?? DateTime.now())
            : DateTime.now();
      });
    } on AcademicProgressAuthExpiredException catch (e) {
      if (!mounted || generation != _fetchGeneration) return;
      setState(() {
        _loggedIn = false;
        _identityOwner = null;
        _identityRevision = ZhengfangAuth.instance.sessionRevision;
        _report = null;
        _updatedAt = null;
        _loading = false;
        _error = '登录状态已过期，请重新登录';
        _automaticLoginPaused = e.automaticLoginPaused;
      });
      NetworkErrorToast.show(context, e);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_presentLoginPrompt(force: true));
      });
    } catch (e) {
      if (!mounted) return;
      if (!_acceptFetchResult(generation, owner, revision)) return;
      if (hasExistingData) {
        setState(() => _refreshFailed = true);
      } else {
        setState(() => _error = '获取学业情况失败：$e');
      }
      NetworkErrorToast.show(context, e);
    } finally {
      if (mounted && generation == _fetchGeneration) {
        setState(() {
          _loading = false;
          _refreshing = false;
        });
      }
    }
  }

  Future<void> _presentLoginPrompt({bool force = false}) async {
    if (!mounted || _loginPromptInFlight || _loggedIn || !widget.active) {
      return;
    }
    if (!force && _loginPromptShown) return;
    _loginPromptShown = true;
    _loginPromptInFlight = true;
    final loggedIn = await showAcademicSystemLoginModal(context);
    _loginPromptInFlight = false;
    if (!mounted || !loggedIn) return;
    _handleAuthChanged();
  }

  // ── Build ─────────────────────────────────────────────────────────────

  /// 上一次通知宿主时的 AppBar 相关状态（登录 / 有数据）。
  (bool, bool)? _notifiedChrome;

  /// 宿主 AppBar 上的按钮：仅刷新；未登录且无数据时为空。
  List<Widget> buildAppBarActions() {
    final hasData = _report != null;
    if (!_loggedIn && !hasData) return const [];
    return [
      IconButton(
        icon: const Icon(Icons.refresh),
        tooltip: '刷新',
        onPressed: _loggedIn
            ? () => _fetch(forceRefresh: true)
            : () => _presentLoginPrompt(force: true),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final hasData = _report != null;
    final chrome = (_loggedIn, hasData);
    if (chrome != _notifiedChrome) {
      _notifiedChrome = chrome;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onChromeChanged?.call();
      });
    }
    return (_loggedIn || hasData) ? _buildBody() : _buildLoginBody();
  }

  Widget _buildLoginBody() => buildAcademicProgressLoginView(
    automaticLoginPaused: _automaticLoginPaused,
    onAction: () => _presentLoginPrompt(force: true),
  );

  Widget _buildBody() {
    final report = _report;
    if (report == null) {
      if (_error != null) {
        return AppErrorView(
          message: _error,
          onRetry: () => _fetch(forceRefresh: true),
        );
      }
      return _loading || _refreshing
          ? _buildSkeleton()
          : const AppEmptyView(
              title: '暂无学业数据',
              icon: Icons.fact_check_outlined,
            );
    }

    // 主修 GPA 读数与培养方案 Graph 同屏：读数占内容高度，Graph 吃掉剩余
    // 全部视口（Expanded + ClipRect），因此画布始终有实际可交互的尺寸。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pageMargin,
            AppSpacing.sm,
            AppSpacing.pageMargin,
            AppSpacing.sm,
          ),
          child: AcademicProgressOverview(
            summary: report.summary,
            statusLine: RefreshStatusLine(
              updatedAt: _updatedAt,
              refreshing: _refreshing,
              failed: _refreshFailed,
              loadingLabel: '正在获取学业情况…',
            ),
          ),
        ),
        Expanded(
          child: ClipRect(
            child: RequirementTreeCanvas(
              roots: report.roots,
              onLeafTap: _showLeafCourses,
            ),
          ),
        ),
      ],
    );
  }

  /// 末节点按需明细：只展示该培养方案节点的要求 / 已获学分与课程修读状态，
  /// 不复刻完整成绩页（不显示成绩 / 补考 / 重修数字）。
  void _showLeafCourses(RequirementNode node) {
    if (node.courses.isEmpty) {
      AppFeedback.toast(
        context,
        node.id == RequirementNode.innovationId ? '尚无数据信息' : '该类别暂无课程',
      );
      return;
    }
    final summary = _requirementSummary(node);
    AppFeedback.sheet<void>(
      context,
      builder: (context) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageMargin,
          0,
          AppSpacing.pageMargin,
          AppSpacing.xl,
        ),
        children: [
          PlainSectionHeader(node.name),
          if (summary != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(summary, style: context.appText.meta),
            ),
          for (final (index, course) in node.courses.indexed) ...[
            if (index > 0) const SizedBox(height: AppSpacing.sm),
            AppListTile(
              title: course.courseName,
              titleTrailing: AppStatusTag(
                course.status.label,
                tone: _statusTone(course.status),
              ),
              dimmed: course.status == CourseStudyStatus.notTaken,
            ),
          ],
        ],
      ),
    );
  }

  /// 节点要求 / 已获学分与门次的紧凑摘要；无任何要求元数据时返回 null。
  static String? _requirementSummary(RequirementNode node) {
    final parts = <String>[];
    final req = node.requiredCredits;
    if (req != null) {
      final earned = node.earnedCredits ?? 0;
      final missing = node.missingCredits ?? 0;
      parts.add(
        '要求 ${_fmt(req)} 学分 · 已获 ${_fmt(earned)} 学分'
        '${missing > 0 ? ' · 还差 ${_fmt(missing)} 学分' : ''}',
      );
    }
    if (node.requiredCount != null) {
      parts.add('要求 ${node.requiredCount} 门 · 达到 ${node.metCount ?? 0} 门');
    }
    parts.add('共 ${node.courseTotal} 门 · 通过 ${node.passedTotal} 门');
    return parts.join('；');
  }

  Widget _buildSkeleton() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.pageMargin,
            AppSpacing.sm,
            AppSpacing.pageMargin,
            AppSpacing.sm,
          ),
          child: AcademicProgressOverview(
            summary: null,
            statusLine: RefreshStatusLine(
              refreshing: true,
              loadingLabel: '正在获取学业情况…',
            ),
          ),
        ),
        const Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.pageMargin,
              0,
              AppSpacing.pageMargin,
              AppSpacing.xl,
            ),
            child: SkeletonBox(height: double.infinity, radius: 16),
          ),
        ),
      ],
    );
  }
}

String _fmt(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(1);

AppStatusTone _statusTone(CourseStudyStatus status) => switch (status) {
  CourseStudyStatus.failed => AppStatusTone.danger,
  CourseStudyStatus.studying => AppStatusTone.attention,
  CourseStudyStatus.notTaken ||
  CourseStudyStatus.unknown => AppStatusTone.neutral,
  _ => AppStatusTone.positive,
};

/// 顶部概览：教务培养方案口径的主修 GPA 读数（[DetailReadout]）+ 刷新状态行
/// + 一行说明两个分段的 GPA 口径不同。无平铺列表 / 门数瓦片 / 状态筛选。
///
/// [summary] 为 null（骨架）时数字显示 `--`，不猜算也不填 0。
class AcademicProgressOverview extends StatelessWidget {
  const AcademicProgressOverview({
    super.key,
    required this.summary,
    this.statusLine,
  });

  final AcademicProgressSummary? summary;

  /// 读数下方的刷新状态行（[RefreshStatusLine]）。
  final Widget? statusLine;

  /// 说明本读数与「课程成绩」分段的计算口径差异，避免把两个不同来源的值
  /// 当成同一个 GPA。教务未给出时明确占位，不擅自标为「累计 GPA」。
  static const String _sourceNote =
      '教务培养方案统计口径；「课程成绩」按所选学期（选「全部」则跨学期）计算，两者可能不同。';

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final gpa = s?.gpa;
    final statTime = s != null && s.statTime.isNotEmpty
        ? '统计截至 ${s.statTime}'
        : '';
    final notes = s == null
        ? ''
        : [_sourceNote, statTime].where((t) => t.isNotEmpty).join('\n');
    return Padding(
      // 与校园卡读数一致：比页边距多缩进 8。
      padding: const EdgeInsets.only(left: AppSpacing.sm, top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DetailReadout(
            label: '主修平均学分绩点',
            valueText: gpa ?? '--',
            muted: gpa == null,
          ),
          if (statusLine != null) ...[
            const SizedBox(height: AppSpacing.xs),
            statusLine!,
          ],
          if (notes.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(notes, style: context.appText.meta.copyWith(height: 1.4)),
          ],
        ],
      ),
    );
  }
}

/// 未登录引导视图。
@visibleForTesting
Widget buildAcademicProgressLoginView({
  required bool automaticLoginPaused,
  required VoidCallback onAction,
}) => AcademicLoginRequiredView(
  automaticLoginPaused: automaticLoginPaused,
  title: '登录后查看学业情况',
  message: '学业情况依赖教务系统会话，登录后即可查看培养方案学分进度与修读状态。',
  onAction: onAction,
  icon: Icons.fact_check_outlined,
);
