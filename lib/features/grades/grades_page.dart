import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_theme_controller.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/login_shell.dart';
import 'grades_model.dart';
import 'grades_service.dart';

class GradesPage extends StatefulWidget {
  const GradesPage({super.key});

  @override
  State<GradesPage> createState() => _GradesPageState();
}

class _GradesPageState extends State<GradesPage> {
  bool _loggedIn = false;
  bool _loading = false;
  String? _error;
  List<GradeEntry> _grades = [];
  bool _loginPromptShown = false;
  bool _loginPromptInFlight = false;

  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loggedIn = ZhengfangAuth.instance.isLoggedIn;
    ZhengfangAuth.instance.addListener(_handleAuthChanged);
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

  Future<void> _fetchGrades() async {
    final studentId = ZhengfangAuth.instance.currentStudentId ?? '';
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final grades = await GradesService.instance.fetchGrades(studentId);
      if (mounted) setState(() => _grades = grades);
    } catch (e) {
      if (mounted) setState(() => _error = '获取成绩失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onLoginSuccess() {
    setState(() {
      _loggedIn = true;
      _error = null;
    });
    _fetchGrades();
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

  // ── GPA ──────────────────────────────────────────────────────────────────────

  double get _weightedGpa {
    double totalPoints = 0;
    double totalCredits = 0;
    for (final g in _grades) {
      if (g.gpaPoints > 0) {
        totalPoints += g.gpaPoints * g.credits;
        totalCredits += g.credits;
      }
    }
    return totalCredits > 0 ? totalPoints / totalCredits : 0;
  }

  double get _totalCredits =>
      _grades.fold(0.0, (sum, g) => sum + (g.gpaPoints > 0 ? g.credits : 0));

  int get _courseCount => _grades.length;

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('成绩查询'),
        actions: _loggedIn
            ? [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _fetchGrades,
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
    if (_loading) return _buildLoadingState();
    if (_error != null) return _buildErrorState();
    if (_grades.isEmpty) return _buildEmptyState();

    final filteredGrades = _query.isEmpty
        ? _grades
        : _grades.where((g) {
            final q = _query.toLowerCase();
            return g.courseName.toLowerCase().contains(q) ||
                g.assessmentMethod.toLowerCase().contains(q) ||
                g.examType.toLowerCase().contains(q);
          }).toList();

    final grouped = _groupFilteredGrades(filteredGrades);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: _GpaSummaryCard(
              gpa: _weightedGpa,
              totalCredits: _totalCredits,
              courseCount: _courseCount,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: _DistributionCard(grades: _grades),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: _GradesSearchField(
              controller: _searchController,
              hasQuery: _query.isNotEmpty,
              onClear: () => _searchController.clear(),
            ),
          ),
        ),
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
          for (final entry in grouped.entries) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: _SemesterHeader(
                  label: entry.key,
                  courseCount: entry.value.length,
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.15,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _GradeCard(grade: entry.value[index]),
                  childCount: entry.value.length,
                ),
              ),
            ),
          ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Map<String, List<GradeEntry>> _groupFilteredGrades(List<GradeEntry> grades) {
    final grouped = <String, List<GradeEntry>>{};
    for (final g in grades) {
      final key = '${g.academicYear} 第${g.semester}学期';
      grouped.putIfAbsent(key, () => []).add(g);
    }
    return grouped;
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
              onPressed: _fetchGrades,
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
              '当前学期暂未录入成绩',
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

// ── Search Field ──────────────────────────────────────────────────────────────

class _GradesSearchField extends StatelessWidget {
  const _GradesSearchField({
    required this.controller,
    required this.hasQuery,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool hasQuery;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return TextField(
      controller: controller,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: '搜索课程',
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: hasQuery
            ? IconButton(
                onPressed: onClear,
                icon: const Icon(Icons.close_rounded),
                tooltip: '清除搜索',
              )
            : null,
        filled: true,
        fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cs.primary, width: 1.4),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
    );
  }
}

// ── Distribution Card ─────────────────────────────────────────────────────────

class _DistributionCard extends StatelessWidget {
  const _DistributionCard({required this.grades});

  final List<GradeEntry> grades;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final distribution = _buildDistribution();
    final total = grades.length;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.4),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '成绩分布',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 80,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final entry in distribution.entries) ...[
                  Expanded(
                    child: _DistBar(
                      label: entry.key,
                      count: entry.value,
                      total: total,
                      color: _barColor(entry.key),
                    ),
                  ),
                  if (entry.key != distribution.keys.last)
                    const SizedBox(width: 6),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Map<String, int> _buildDistribution() {
    int excellent = 0, good = 0, medium = 0, pass = 0, fail = 0;
    for (final g in grades) {
      final score = double.tryParse(g.percentageScore) ?? 0;
      if (score >= 90) {
        excellent++;
      } else if (score >= 80) {
        good++;
      } else if (score >= 70) {
        medium++;
      } else if (score >= 60) {
        pass++;
      } else {
        fail++;
      }
    }
    return {'优': excellent, '良': good, '中': medium, '及格': pass, '不及格': fail};
  }

  Color _barColor(String label) {
    switch (label) {
      case '优':
        return const Color(0xFF16A34A);
      case '良':
        return const Color(0xFF2563EB);
      case '中':
        return const Color(0xFFF59E0B);
      case '及格':
        return const Color(0xFFF97316);
      case '不及格':
        return const Color(0xFFDC2626);
      default:
        return const Color(0xFF9CA3AF);
    }
  }
}

class _DistBar extends StatelessWidget {
  const _DistBar({
    required this.label,
    required this.count,
    required this.total,
    required this.color,
  });

  final String label;
  final int count;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final fraction = total > 0 ? count / total : 0.0;
    final barHeight = fraction > 0 ? fraction.clamp(0.06, 1.0) : 0.0;
    final cs = Theme.of(context).colorScheme;

    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          count > 0 ? '$count' : '',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: color.withValues(alpha: 0.85),
            height: 1,
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: barHeight,
              widthFactor: 1,
              child: Container(
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

// ── GPA Summary Card ──────────────────────────────────────────────────────────

class _GpaSummaryCard extends StatelessWidget {
  const _GpaSummaryCard({
    required this.gpa,
    required this.totalCredits,
    required this.courseCount,
  });

  final double gpa;
  final double totalCredits;
  final int courseCount;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = AppThemeController.instance.resolveIconColor(
      context,
      cs.primary,
    );
    final darkAccent = _shiftColor(accent, lightness: -0.08);
    final foreground = _contrastOn(accent);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent.withValues(alpha: 0.92), darkAccent],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  totalCredits.toStringAsFixed(1),
                  style: TextStyle(
                    fontSize: 44,
                    height: 1,
                    fontWeight: FontWeight.w900,
                    color: foreground,
                    letterSpacing: -1.5,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '已获学分',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: foreground.withValues(alpha: 0.6),
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _SummaryStat(
                  label: 'GPA',
                  value: gpa.toStringAsFixed(2),
                  foreground: foreground,
                ),
                _SummaryStat(
                  label: '课程数',
                  value: '$courseCount',
                  foreground: foreground,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _shiftColor(Color color, {required double lightness}) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness + lightness).clamp(0.1, 0.9))
        .toColor();
  }

  Color _contrastOn(Color background) {
    return background.computeLuminance() > 0.45 ? Colors.black : Colors.white;
  }
}

class _SummaryStat extends StatelessWidget {
  const _SummaryStat({
    required this.label,
    required this.value,
    required this.foreground,
  });

  final String label;
  final String value;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: foreground,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: foreground.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Semester Header ───────────────────────────────────────────────────────────

class _SemesterHeader extends StatelessWidget {
  const _SemesterHeader({required this.label, required this.courseCount});

  final String label;
  final int courseCount;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '$courseCount门',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Grade Card (Grid Cell) ────────────────────────────────────────────────────

class _GradeCard extends StatelessWidget {
  const _GradeCard({required this.grade});

  final GradeEntry grade;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final scoreColor = _scoreColor();

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.4),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Score accent bar
          Container(
            height: 3,
            decoration: BoxDecoration(
              color: scoreColor.withValues(alpha: 0.75),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Course name
                Text(
                  grade.courseName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 8),
                // Score
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      grade.grade,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        height: 1,
                        color: scoreColor,
                        letterSpacing: -0.8,
                      ),
                    ),
                    if (grade.credits > 0) ...[
                      const SizedBox(width: 6),
                      Text(
                        '${_formatCredits(grade.credits)}学分',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: scoreColor.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                // Info chips (conditional)
                Wrap(
                  spacing: 5,
                  runSpacing: 4,
                  children: [
                    if (grade.gpaPoints > 0)
                      _InfoChip(
                        label: 'GPA ${grade.gpaPoints.toStringAsFixed(1)}',
                      ),
                    if (grade.assessmentMethod.isNotEmpty)
                      _InfoChip(label: grade.assessmentMethod),
                    if (grade.assessmentMethod.isEmpty &&
                        grade.examType.isNotEmpty)
                      _InfoChip(label: grade.examType),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _scoreColor() {
    final score = double.tryParse(grade.percentageScore) ?? 0;
    if (score >= 90) return const Color(0xFF16A34A);
    if (score >= 80) return const Color(0xFF2563EB);
    if (score >= 70) return const Color(0xFFF59E0B);
    if (score >= 60) return const Color(0xFFF97316);
    return const Color(0xFFDC2626);
  }

  String _formatCredits(double value) {
    if (value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(1);
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: cs.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          fontSize: 10,
        ),
      ),
    );
  }
}
