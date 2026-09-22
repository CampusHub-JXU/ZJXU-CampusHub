import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/zhengfang_auth.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_dropdown.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/app_search_field.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/network_error_toast.dart';
import 'grades_model.dart';
import 'grades_service.dart';
import 'grades_term_resolver.dart';
import 'widgets/grades_distribution_card.dart';
import 'widgets/grades_grade_card.dart';
import '../../shared/widgets/app_app_bar.dart';

typedef GradesFetcher = Future<List<GradeEntry>> Function(
  String studentId, {
  bool forceRefresh,
});

class GradesPage extends StatefulWidget {
  const GradesPage({super.key, this.fetchGrades});

  final GradesFetcher? fetchGrades;

  @override
  State<GradesPage> createState() => _GradesPageState();
}

class _GradesPageState extends State<GradesPage>
    with SingleTickerProviderStateMixin {
  bool _loggedIn = false;
  bool _loading = false;
  String? _error;
  List<GradeEntry> _grades = [];
  bool _loginPromptShown = false;
  bool _loginPromptInFlight = false;

  /// 最近一次教务过期是否由「自动登录已暂停」触发；仅影响未登录引导文案。
  bool _automaticLoginPaused = false;

  String? _selectedTermKey;

  final _searchController = TextEditingController();
  String _query = '';

  late final AnimationController _staggerController;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loggedIn = ZhengfangAuth.instance.isLoggedIn;
    ZhengfangAuth.instance.addListener(_handleAuthChanged);

    _staggerController = AnimationController(
      duration: const Duration(milliseconds: 420),
      vsync: this,
    );

    if (_loggedIn) {
      _fetchGrades();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_presentLoginPrompt());
      });
    }
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    ZhengfangAuth.instance.removeListener(_handleAuthChanged);
    _staggerController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final nextQuery = _searchController.text.trim();
    if (nextQuery == _query) return;
    setState(() => _query = nextQuery);
  }

  void _handleAuthChanged() {
    final nextLoggedIn = ZhengfangAuth.instance.isLoggedIn;
    if (!mounted || nextLoggedIn == _loggedIn) return;

    setState(() {
      _loggedIn = nextLoggedIn;
      if (!nextLoggedIn) {
        _error = _grades.isEmpty ? null : '登录状态已失效，请重新登录后刷新成绩';
        // 暂停标记由随后的过期异常分支重新写入；普通登出保持非暂停文案。
        _automaticLoginPaused = false;
      }
    });

    if (!nextLoggedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_presentLoginPrompt(force: true));
      });
    }
  }

  Future<void> _fetchGrades({bool forceRefresh = false}) async {
    final studentId = ZhengfangAuth.instance.currentStudentId ?? '';
    final hasExistingData = _grades.isNotEmpty;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fetchGrades =
          widget.fetchGrades ?? GradesService.instance.fetchGrades;
      final grades = await fetchGrades(studentId, forceRefresh: forceRefresh);
      if (mounted) {
        setState(() => _grades = grades);
        _ensureSelectedTerm();
        _staggerController.forward(from: 0);
      }
    } on GradesAuthExpiredException catch (e) {
      if (!mounted) return;
      setState(() {
        _loggedIn = false;
        _error = _grades.isEmpty ? null : '登录状态已失效，请重新登录后刷新成绩';
        _automaticLoginPaused = e.automaticLoginPaused;
      });
      NetworkErrorToast.show(context, const GradesAuthExpiredException());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_presentLoginPrompt(force: true));
      });
    } catch (e) {
      if (!mounted) return;
      if (hasExistingData) {
        NetworkErrorToast.show(context, e);
      } else {
        setState(() => _error = '获取成绩失败：$e');
        NetworkErrorToast.show(context, e);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onLoginSuccess() {
    setState(() {
      _loggedIn = true;
      _error = null;
      // 手动登录成功即重新武装自动登录，清除暂停文案。
      _automaticLoginPaused = false;
    });
    _fetchGrades(forceRefresh: true);
  }

  Future<void> _presentLoginPrompt({bool force = false}) async {
    if (!mounted || _loginPromptInFlight || _loggedIn) return;
    if (!force && _loginPromptShown) return;

    _loginPromptShown = true;
    _loginPromptInFlight = true;
    final loggedIn = await showAcademicSystemLoginModal(context);
    _loginPromptInFlight = false;
    if (!mounted || !loggedIn) return;
    _onLoginSuccess();
  }

  // ── 学期切换 ───────────────────────────────────────────────────────────────

  List<({String academicYear, String semester})> get _availableTerms =>
      GradesTermResolver.availableTerms(_grades);

  List<AppDropdownItem<String>> get _dropdownItems {
    final terms = _availableTerms;
    if (terms.isEmpty) return const [];
    return [
      AppDropdownItem(
        value: GradesTermResolver.allTermKey,
        label: '全部学期',
        icon: Icons.list_alt_rounded,
      ),
      for (final t in terms)
        AppDropdownItem(
          value: '${t.academicYear}|${t.semester}',
          label: GradesTermResolver.labelOf(t.academicYear, t.semester),
          icon: Icons.school_outlined,
        ),
    ];
  }

  void _ensureSelectedTerm() {
    _selectedTermKey = GradesTermResolver.pickDefault(
      _grades,
      previousKey: _selectedTermKey,
    );
  }

  void _onTermChanged(String? key) {
    if (key == null || key == _selectedTermKey) return;
    _searchController.clear();
    setState(() {
      _selectedTermKey = key;
      _query = '';
    });
  }

  List<GradeEntry> get _gradesForSelectedTerm =>
      GradesTermResolver.filterByTermKey(_grades, _selectedTermKey);

  // ── GPA ──────────────────────────────────────────────────────────────────────

  double get _weightedGpa {
    final grades = _gradesForSelectedTerm;
    double totalPoints = 0;
    double totalCredits = 0;
    for (final g in grades) {
      if (g.gpaPoints > 0) {
        totalPoints += g.gpaPoints * g.credits;
        totalCredits += g.credits;
      }
    }
    return totalCredits > 0 ? totalPoints / totalCredits : 0;
  }

  double get _totalCredits => _gradesForSelectedTerm.fold(
    0.0,
    (sum, g) => sum + (g.gpaPoints > 0 ? g.credits : 0),
  );

  int get _courseCount => _gradesForSelectedTerm.length;

  double get _avgScore {
    final grades = _gradesForSelectedTerm;
    if (grades.isEmpty) return 0;
    double total = 0;
    int count = 0;
    for (final g in grades) {
      final score = double.tryParse(g.percentageScore);
      if (score != null) {
        total += score;
        count++;
      }
    }
    return count > 0 ? total / count : 0;
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(
        title: const Text('成绩查询'),
        actions: _loggedIn
            ? [
                IconButton(
                  icon: _loading
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        )
                      : const Icon(Icons.refresh),
                  onPressed: _loading
                      ? null
                      : () => _fetchGrades(forceRefresh: true),
                  tooltip: '刷新',
                ),
              ]
            : null,
      ),
      body: _loggedIn ? _buildGradesBody() : _buildLoginBody(),
    );
  }

  Widget _buildLoginBody() => buildGradesLoginView(
    automaticLoginPaused: _automaticLoginPaused,
    onAction: () => _presentLoginPrompt(force: true),
  );

  Widget _buildGradesBody() {
    if (_loading && _grades.isEmpty) return _buildLoadingState();
    if (_error != null) return _buildErrorState();
    if (_grades.isEmpty) return _buildEmptyState();

    final termGrades = _gradesForSelectedTerm;
    final filteredGrades = _query.isEmpty
        ? termGrades
        : termGrades.where((g) {
            final q = _query.toLowerCase();
            return g.courseName.toLowerCase().contains(q) ||
                g.assessmentMethod.toLowerCase().contains(q) ||
                g.examType.toLowerCase().contains(q);
          }).toList();

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: AppDropdown<String>(
                    value: _selectedTermKey,
                    items: _dropdownItems,
                    onChanged: _onTermChanged,
                    expanded: true,
                    prefixIcon: Icons.calendar_view_week_rounded,
                  ),
                ),
              ],
            ),
          ),
        ),
        // ── 紧凑统计行 ──
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: _buildStatsRow(),
          ),
        ),
        // ── 分布卡 ──
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: GradesDistributionCard(grades: termGrades),
            ),
          ),
        ),
        // ── 搜索框 ──
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: AppSearchField(
              controller: _searchController,
              hintText: '搜索课程',
              onChanged: (_) {},
              onClear: () => _searchController.clear(),
            ),
          ),
        ),
        // ── 成绩网格 ──
        if (filteredGrades.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  '没有匹配"$_query"的成绩',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                childAspectRatio: 1.5,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final grade = filteredGrades[index];
                final interval = Interval(
                  (index * 0.04).clamp(0.0, 0.6),
                  ((index * 0.04) + 0.4).clamp(0.0, 1.0),
                  curve: Curves.easeOutCubic,
                );
                final fadeAnim = CurvedAnimation(
                  parent: _staggerController,
                  curve: interval,
                );
                return FadeTransition(
                  opacity: fadeAnim,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, 0.06),
                      end: Offset.zero,
                    ).animate(fadeAnim),
                    child: GradesGradeCard(grade: grade),
                  ),
                );
              }, childCount: filteredGrades.length),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  /// 紧凑统计行：GPA | 学分 | 课程数 | 均分 四列横排。
  Widget _buildStatsRow() {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      radius: AppRadius.cardAlt,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        children: [
          _StatCell(
            label: 'GPA',
            value: _weightedGpa.toStringAsFixed(2),
            accent: cs.primary,
          ),
          _Divider(),
          _StatCell(
            label: '学分',
            value: _totalCredits.toStringAsFixed(1),
            accent: cs.primary,
          ),
          _Divider(),
          _StatCell(
            label: '均分',
            value: _avgScore.toStringAsFixed(1),
            accent: cs.tertiary,
          ),
          _Divider(),
          _StatCell(label: '课程', value: '$_courseCount', accent: cs.tertiary),
        ],
      ),
    );
  }

  // ── States ───────────────────────────────────────────────────────────────────

  Widget _buildLoadingState() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(strokeWidth: 3, color: cs.primary),
          ),
          const SizedBox(height: 16),
          Text(
            '正在获取成绩…',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return AppErrorView(
      message: _error,
      onRetry: () => _fetchGrades(forceRefresh: true),
    );
  }

  Widget _buildEmptyState() {
    return const AppEmptyView(
      title: '暂无成绩数据',
      message: '暂未录入成绩',
      icon: Icons.school_outlined,
    );
  }
}

/// 紧凑统计单元。
class _StatCell extends StatelessWidget {
  const _StatCell({
    required this.label,
    required this.value,
    required this.accent,
  });

  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                height: 1.1,
                color: accent,
                letterSpacing: -0.5,
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              fontSize: 10.5,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 0.8,
      height: 28,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      color: Theme.of(context).colorScheme.outlineVariant
          .withValues(alpha: 0.3),
    );
  }
}

/// 未登录引导视图；[automaticLoginPaused] 为 true 时切换为「需要手动登录」文案。
@visibleForTesting
Widget buildGradesLoginView({
  required bool automaticLoginPaused,
  required VoidCallback onAction,
}) => AuthRequiredView(
  title: automaticLoginPaused ? '需要手动登录' : '登录后查看成绩',
  message: automaticLoginPaused
      ? '自动登录已暂停（多次登录失败），请手动登录一次；登录成功后会自动重新开启自动登录。'
      : '成绩查询依赖教务系统会话，登录后即可同步最新成绩。',
  buttonLabel: '登录教务系统',
  onAction: onAction,
  icon: Icons.school_outlined,
);
