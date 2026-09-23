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

  /// 当前页面状态归属的教务账号；账号变化（含登出）即清空页面敏感状态，
  /// 绝不让上一个账号的成绩残留给下一个账号看到。
  String? _identityOwner;

  /// 状态归属账号对应的 auth 身份修订号；同账号重登也会推进该值，
  /// 用于作废重登前发起的在途请求。
  int _identityRevision = 0;

  /// 页面内请求代数：身份变化或发起新请求时递增，只接纳最新一代结果。
  int _fetchGeneration = 0;

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
    final auth = ZhengfangAuth.instance;
    _loggedIn = auth.isLoggedIn;
    _identityOwner = _loggedIn ? _normalizeOwner(auth.currentStudentId) : null;
    _identityRevision = auth.sessionRevision;
    auth.addListener(_handleAuthChanged);

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

  String? _normalizeOwner(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  /// 清空与具体账号绑定的页面状态：成绩、学期选择、搜索词与入场动画。
  ///
  /// 仅在身份归属发生变化时调用；同账号刷新失败仍保留既有数据。
  void _clearIdentityBoundState() {
    _grades = const [];
    _selectedTermKey = null;
    _query = '';
    _error = null;
    _loading = false;
    _staggerController.reset();
    if (_searchController.text.isNotEmpty) {
      // _query 已归零，listener 不会重复 setState。
      _searchController.clear();
    }
  }

  /// 只接纳「最新一代 + 身份仍与请求发起时一致」的请求结果。
  bool _acceptFetchResult(int generation, String owner, int revision) {
    if (!mounted || generation != _fetchGeneration) return false;
    final auth = ZhengfangAuth.instance;
    return _loggedIn &&
        _identityOwner == owner &&
        _identityRevision == revision &&
        auth.isLoggedIn &&
        auth.sessionRevision == revision &&
        _normalizeOwner(auth.currentStudentId) == owner;
  }

  void _handleAuthChanged() {
    if (!mounted) return;
    final auth = ZhengfangAuth.instance;
    final nextLoggedIn = auth.isLoggedIn;
    final nextOwner = nextLoggedIn
        ? _normalizeOwner(auth.currentStudentId)
        : null;
    final nextRevision = auth.sessionRevision;
    final loginChanged = nextLoggedIn != _loggedIn;
    final ownerChanged = nextOwner != _identityOwner;
    final revisionChanged = nextRevision != _identityRevision;
    if (!loginChanged && !ownerChanged && !revisionChanged) return;

    if (nextOwner == null) {
      _applySignedOut(nextRevision);
      return;
    }
    if (ownerChanged) {
      _applyOwnerChanged(nextOwner, nextRevision);
      return;
    }
    _applySameOwnerRelogin(nextRevision);
  }

  /// 登出 / 会话失效：页面不得继续持有上一个账号的成绩。
  void _applySignedOut(int revision) {
    setState(() {
      _loggedIn = false;
      _identityOwner = null;
      _identityRevision = revision;
      _fetchGeneration++;
      _clearIdentityBoundState();
      // 暂停标记由随后的过期异常分支重新写入；普通登出保持非暂停文案。
      _automaticLoginPaused = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_presentLoginPrompt(force: true));
    });
  }

  /// 账号切换（A→B 或登出后重新登录为他人）：清空旧账号状态并拉取新账号数据。
  void _applyOwnerChanged(String owner, int revision) {
    setState(() {
      _loggedIn = true;
      _identityOwner = owner;
      _identityRevision = revision;
      _fetchGeneration++;
      _clearIdentityBoundState();
      _automaticLoginPaused = false;
    });
    unawaited(_fetchGrades());
  }

  /// 同账号重登：账号未变，已展示数据仍属于该账号，保留以避免闪空；
  /// 但身份修订已推进，重登前的在途结果一律作废，并主动刷新。
  void _applySameOwnerRelogin(int revision) {
    setState(() {
      _loggedIn = true;
      _identityRevision = revision;
      _fetchGeneration++;
      _error = null;
      _automaticLoginPaused = false;
    });
    unawaited(_fetchGrades(forceRefresh: true));
  }

  Future<void> _fetchGrades({bool forceRefresh = false}) async {
    final auth = ZhengfangAuth.instance;
    final owner = _normalizeOwner(auth.currentStudentId);
    if (!auth.isLoggedIn || owner == null || owner != _identityOwner) {
      // 身份未就绪或已被切换：不发起请求，等身份同步完成后再刷新。
      return;
    }
    final revision = auth.sessionRevision;
    final generation = ++_fetchGeneration;
    final hasExistingData = _grades.isNotEmpty;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fetchGrades =
          widget.fetchGrades ?? GradesService.instance.fetchGrades;
      final grades = await fetchGrades(owner, forceRefresh: forceRefresh);
      if (!_acceptFetchResult(generation, owner, revision)) return;
      setState(() => _grades = grades);
      _ensureSelectedTerm();
      _staggerController.forward(from: 0);
    } on GradesAuthExpiredException catch (e) {
      // 过期结果只对「发起时的身份」有效；换号/重登后的迟到过期不得影响新会话。
      if (!mounted) return;
      if (!_acceptFetchResult(generation, owner, revision)) return;
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
      if (!_acceptFetchResult(generation, owner, revision)) return;
      if (hasExistingData) {
        NetworkErrorToast.show(context, e);
      } else {
        setState(() => _error = '获取成绩失败：$e');
        NetworkErrorToast.show(context, e);
      }
    } finally {
      if (mounted && generation == _fetchGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  void _onLoginSuccess() {
    final auth = ZhengfangAuth.instance;
    final owner = auth.isLoggedIn
        ? _normalizeOwner(auth.currentStudentId)
        : null;
    if (owner == null) {
      // 登录模态声称成功但身份不完整：按通用身份同步处理，不伪造已登录。
      _handleAuthChanged();
      return;
    }
    final revision = auth.sessionRevision;
    final ownerChanged = owner != _identityOwner;
    // 身份通知回调可能已为同一身份发起刷新，避免重复请求。
    final alreadyRefreshing = !ownerChanged && _loading;
    setState(() {
      _loggedIn = true;
      _identityOwner = owner;
      _identityRevision = revision;
      _error = null;
      // 手动登录成功即重新武装自动登录，清除暂停文案。
      _automaticLoginPaused = false;
      if (ownerChanged) {
        _fetchGeneration++;
        _clearIdentityBoundState();
      }
    });
    if (!alreadyRefreshing) {
      unawaited(_fetchGrades(forceRefresh: true));
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
