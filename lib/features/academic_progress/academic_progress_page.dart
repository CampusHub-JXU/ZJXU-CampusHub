import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/zhengfang_auth.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/app_filter_chips.dart';
import '../../shared/widgets/app_list_tile.dart';
import '../../shared/widgets/app_status_tag.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/network_error_toast.dart';
import '../../shared/widgets/plain_list.dart';
import '../../shared/widgets/refresh_status_line.dart';
import '../../shared/widgets/skeleton_box.dart';
import 'academic_progress_model.dart';
import 'academic_progress_service.dart';

typedef AcademicProgressFetcher = Future<AcademicProgressReport> Function({
  bool forceRefresh,
});

/// 状态筛选：「全部」按学分要求树展示，其余平铺该状态的课程。
enum _StatusFilter {
  tree('按类别'),
  notTaken('未修'),
  studying('在修'),
  failed('未过'),
  passed('已修');

  const _StatusFilter(this.label);

  final String label;

  bool matches(CourseStudyStatus status) => switch (this) {
    tree => true,
    notTaken => status == CourseStudyStatus.notTaken,
    studying => status == CourseStudyStatus.studying,
    failed => status == CourseStudyStatus.failed,
    passed => status.countsAsPassed,
  };
}

/// 学生学业情况查询的原生页面（替代正方 H5 `xsxyqk_cxXsxyqkIndex`）。
class AcademicProgressPage extends StatefulWidget {
  const AcademicProgressPage({super.key, this.fetchReport});

  /// 测试注入点：默认走 [AcademicProgressService.fetchReport]。
  final AcademicProgressFetcher? fetchReport;

  @override
  State<AcademicProgressPage> createState() => _AcademicProgressPageState();
}

class _AcademicProgressPageState extends State<AcademicProgressPage> {
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

  _StatusFilter _filter = _StatusFilter.tree;
  final Set<String> _expanded = {};

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
      _fetch();
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
        _expanded.clear();
      }
    });
    unawaited(_fetch(forceRefresh: !ownerChanged));
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
    if (!mounted || _loginPromptInFlight || _loggedIn) return;
    if (!force && _loginPromptShown) return;
    _loginPromptShown = true;
    _loginPromptInFlight = true;
    final loggedIn = await showAcademicSystemLoginModal(context);
    _loginPromptInFlight = false;
    if (!mounted || !loggedIn) return;
    _handleAuthChanged();
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hasData = _report != null;
    return Scaffold(
      appBar: AppAppBar(
        title: const Text('学业情况'),
        actions: (_loggedIn || hasData)
            ? [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: '刷新',
                  onPressed: _loggedIn
                      ? () => _fetch(forceRefresh: true)
                      : () => _presentLoginPrompt(force: true),
                ),
              ]
            : null,
      ),
      body: (_loggedIn || hasData) ? _buildBody() : _buildLoginBody(),
    );
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

    return RefreshIndicator(
      onRefresh: () => _fetch(forceRefresh: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageMargin,
          AppSpacing.sm,
          AppSpacing.pageMargin,
          AppSpacing.xl,
        ),
        children: [
          RefreshStatusLine(
            updatedAt: _updatedAt,
            refreshing: _refreshing,
            failed: _refreshFailed,
            loadingLabel: '正在获取学业情况…',
          ),
          const SizedBox(height: AppSpacing.md),
          AcademicProgressOverview(summary: report.summary),
          const SizedBox(height: AppSpacing.lg),
          AppFilterChips<_StatusFilter>(
            padding: EdgeInsets.zero,
            options: [
              for (final f in _StatusFilter.values)
                AppFilterOption(f, _filterLabel(report, f)),
            ],
            selected: _filter,
            onSelected: (f) => setState(() => _filter = f),
          ),
          if (_filter == _StatusFilter.tree)
            ..._buildTree(report)
          else
            ..._buildFlatList(report),
        ],
      ),
    );
  }

  String _filterLabel(AcademicProgressReport report, _StatusFilter filter) {
    if (filter == _StatusFilter.tree) return filter.label;
    final count = report.allCourses
        .where((c) => filter.matches(c.status))
        .length;
    return '${filter.label} $count';
  }

  List<Widget> _buildTree(AcademicProgressReport report) {
    final widgets = <Widget>[];
    for (final root in report.roots) {
      // 主修根节点本身只是容器：展开为其子类别分区。
      final sections = root.children.isNotEmpty ? root.children : [root];
      for (final section in sections) {
        widgets
          ..add(const SizedBox(height: AppSpacing.lg))
          ..add(_SectionHeader(node: section));
        final leaves = section.children.isEmpty ? [section] : section.children;
        for (final (index, leaf) in leaves.indexed) {
          if (index > 0) widgets.add(const SizedBox(height: AppSpacing.sm));
          widgets.add(_buildLeaf(leaf));
        }
      }
    }
    return widgets;
  }

  Widget _buildLeaf(RequirementNode node) {
    final expanded = _expanded.contains(node.id);
    final hasCourses = node.courses.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppListTile(
          title: node.name,
          titleTrailing: _creditTag(node),
          meta: _nodeMeta(node),
          details: [
            if (node.needsCourses || hasCourses)
              '共 ${node.courseTotal} 门 · 通过 ${node.passedTotal} 门',
            if (node.id == RequirementNode.innovationId && !hasCourses)
              '尚无数据信息',
          ],
          trailing: hasCourses
              ? Icon(expanded ? Icons.expand_less : Icons.expand_more)
              : null,
          onTap: hasCourses
              ? () => setState(() {
                  if (!_expanded.remove(node.id)) _expanded.add(node.id);
                })
              : null,
        ),
        if (expanded)
          for (final course in node.courses) ...[
            const SizedBox(height: AppSpacing.xs),
            Padding(
              padding: const EdgeInsets.only(left: AppSpacing.md),
              child: _CourseTile(course: course),
            ),
          ],
      ],
    );
  }

  List<Widget> _buildFlatList(AcademicProgressReport report) {
    final courses = report.allCourses
        .where((c) => _filter.matches(c.status))
        .toList();
    if (courses.isEmpty) {
      return const [
        SizedBox(height: AppSpacing.xl),
        AppEmptyView(title: '没有这类课程', icon: Icons.fact_check_outlined),
      ];
    }
    final credits = courses.fold<double>(0, (sum, c) => sum + c.credits);
    return [
      const SizedBox(height: AppSpacing.lg),
      PlainSectionHeader(
        '${_filter.label} · ${courses.length} 门 · ${_fmt(credits)} 学分',
      ),
      for (final (index, course) in courses.indexed) ...[
        if (index > 0) const SizedBox(height: AppSpacing.sm),
        _CourseTile(course: course),
      ],
    ];
  }

  static String? _nodeMeta(RequirementNode node) {
    final parts = <String>[
      if (node.requiredCredits != null)
        '要求 ${_fmt(node.requiredCredits!)} · 获得 ${_fmt(node.earnedCredits ?? 0)}'
            '${(node.missingCredits ?? 0) > 0 ? ' · 还差 ${_fmt(node.missingCredits!)}' : ''} 学分',
      if (node.requiredCount != null)
        '要求 ${node.requiredCount} 门 · 达到 ${node.metCount ?? 0} 门',
    ];
    return parts.isEmpty ? null : parts.join('；');
  }

  static Widget? _creditTag(RequirementNode node) =>
      switch (node.creditStatus) {
        CreditStatus.notMet => const AppStatusTag(
          '未满',
          tone: AppStatusTone.attention,
        ),
        CreditStatus.met => const AppStatusTag(
          '已满',
          tone: AppStatusTone.positive,
        ),
        CreditStatus.exceeded => const AppStatusTag(
          '超出',
          tone: AppStatusTone.positive,
        ),
        CreditStatus.none => null,
      };

  Widget _buildSkeleton() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.sm,
        AppSpacing.pageMargin,
        AppSpacing.xl,
      ),
      children: [
        const RefreshStatusLine(refreshing: true, loadingLabel: '正在获取学业情况…'),
        const SizedBox(height: AppSpacing.md),
        const AcademicProgressOverview(summary: null),
        const SizedBox(height: AppSpacing.lg),
        for (var i = 0; i < 4; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.sm),
          const SkeletonBox(height: 72, radius: 16),
        ],
      ],
    );
  }
}

String _fmt(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(1);

/// 分区标题：类别名 + 学分进度条。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.node});

  final RequirementNode node;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final req = node.requiredCredits;
    final earned = node.earnedCredits ?? 0;
    final title = req == null
        ? node.name
        : '${node.name} · ${_fmt(earned)}/${_fmt(req)} 学分';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlainSectionHeader(title),
        if (req != null && req > 0) ...[
          const SizedBox(height: AppSpacing.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (earned / req).clamp(0, 1).toDouble(),
              minHeight: 6,
              backgroundColor: cs.surfaceContainerHighest,
            ),
          ),
        ],
        if (node.children.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              '子项关系：${node.relation.label}',
              style: context.appText.meta,
            ),
          ),
        const SizedBox(height: AppSpacing.sm),
      ],
    );
  }
}

/// 单门课程行。
class _CourseTile extends StatelessWidget {
  const _CourseTile({required this.course});

  final AcademicProgressCourse course;

  @override
  Widget build(BuildContext context) {
    final meta = [
      '${_fmt(course.credits)} 学分',
      if (course.nature.isNotEmpty) course.nature,
      if (course.category.isNotEmpty) course.category,
      if (!course.inPlan) '计划外',
    ].join(' · ');
    final score = course.displayScore;
    return AppListTile(
      title: course.courseName,
      titleTrailing: AppStatusTag(
        course.status.label,
        tone: switch (course.status) {
          CourseStudyStatus.failed => AppStatusTone.danger,
          CourseStudyStatus.studying => AppStatusTone.attention,
          CourseStudyStatus.notTaken ||
          CourseStudyStatus.unknown => AppStatusTone.neutral,
          _ => AppStatusTone.positive,
        },
      ),
      meta: meta,
      details: [
        if (course.scoreTerm.isNotEmpty)
          '${course.scoreTerm}'
              '${course.gradePoint != null ? ' · 绩点 ${course.gradePoint}' : ''}',
        if (course.makeupScore.isNotEmpty) '补考 ${course.makeupScore}',
        if (course.retakeScore.isNotEmpty) '重修 ${course.retakeScore}',
        if (course.scoreTerm.isEmpty && course.suggestedTerm.isNotEmpty)
          '建议 ${course.suggestedTerm} 修读',
      ],
      dimmed: course.status == CourseStudyStatus.notTaken,
      trailing: score.isEmpty
          ? null
          : Text(score, style: context.appText.rowValue),
    );
  }
}

/// 顶部概览：GPA 大字 + 计划内门数。[summary] 为 null 时显示 `--`。
class AcademicProgressOverview extends StatelessWidget {
  const AcademicProgressOverview({super.key, required this.summary});

  final AcademicProgressSummary? summary;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = summary;
    final gpa = s?.gpa;
    String n(int? v) => v == null ? '--' : '$v';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('主修 GPA', style: context.appText.meta),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      gpa ?? '--',
                      style: context.appText.overview.copyWith(
                        color: gpa != null ? cs.primary : cs.outlineVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 7,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    _Stat(label: '通过', value: n(s?.planPassed)),
                    _Stat(label: '未通过', value: n(s?.planFailed)),
                    _Stat(label: '在读', value: n(s?.studying)),
                    _Stat(label: '未修', value: n(s?.planNotTaken)),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (s != null && s.planTotal != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            [
              '计划总课程 ${s.planTotal} 门',
              if (s.outsidePassed != null || s.outsideFailed != null)
                '计划外通过 ${n(s.outsidePassed)} 门、未通过 ${n(s.outsideFailed)} 门',
            ].join(' · '),
            style: context.appText.meta,
          ),
        ],
        if (s != null && s.statTime.isNotEmpty)
          Text('统计截至 ${s.statTime}', style: context.appText.meta),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, maxLines: 1, style: context.appText.meta),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: cs.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
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
