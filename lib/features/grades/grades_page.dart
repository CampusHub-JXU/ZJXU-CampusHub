import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/zhengfang_auth.dart';
import '../../shared/widgets/app_dropdown.dart';
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

class GradesPage extends StatefulWidget {
  const GradesPage({super.key});

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
      final grades = await GradesService.instance.fetchGrades(
        studentId,
        forceRefresh: forceRefresh,
      );
      if (mounted) {
        setState(() => _grades = grades);
        _ensureSelectedTerm();
        _staggerController.forward(from: 0);
      }
    } on GradesAuthExpiredException {
      if (!mounted) return;
      setState(() {
        _loggedIn = false;
        _error = _grades.isEmpty ? null : '登录状态已失效，请重新登录后刷新成绩';
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

  Widget _buildLoginBody() => AuthRequiredView(
    title: '登录后查看成绩',
    message: '成绩查询依赖教务系统会话，登录后即可同步最新成绩。',
    buttonLabel: '登录教务系统',
    onAction: () => _presentLoginPrompt(force: true),
    icon: Icons.school_outlined,
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
                childAspectRatio: 1.02,
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.35),
          width: 0.8,
        ),
      ),
      child: Row(
        children: [
          _StatCell(
            label: 'GPA',
            value: _weightedGpa.toStringAsFixed(2),
            accent: cs.primary,
          ),
          _Divider(),
          _StatCell(
            label: '已获学分',
            value: _totalCredits.toStringAsFixed(1),
            accent: cs.primary,
          ),
          _Divider(),
          _StatCell(label: '课程数', value: '$_courseCount', accent: cs.tertiary),
          _Divider(),
          _StatCell(
            label: '均分',
            value: _avgScore.toStringAsFixed(1),
            accent: cs.tertiary,
          ),
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
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: cs.errorContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                Icons.cloud_off_rounded,
                color: cs.onErrorContainer,
                size: 28,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '加载失败',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: () => _fetchGrades(forceRefresh: true),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final cs = Theme.of(context).colorScheme;
    return Center(
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
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                Icons.school_outlined,
                color: cs.onSurfaceVariant,
                size: 28,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '暂无成绩数据',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              '暂未录入成绩',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
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
      color: Theme.of(
        context,
      ).colorScheme.outlineVariant.withValues(alpha: 0.3),
    );
  }
}
