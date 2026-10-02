import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/app_filter_chips.dart';
import '../../shared/widgets/app_search_field.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/network_error_toast.dart';
import '../../shared/widgets/refresh_status_line.dart';
import '../../shared/widgets/skeleton_box.dart';
import 'grades_model.dart';
import 'grades_service.dart';
import 'grades_summary.dart';
import 'grades_term_resolver.dart';
import 'widgets/grades_course_row.dart';
import 'widgets/grades_distribution_bar.dart';
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

  /// AppBar 搜索图标展开的搜索框；关闭即清空关键字。
  bool _searchOpen = false;

  /// 课程列表排序（纯前端本地状态，不落盘）。
  GradesSortMode _sortMode = GradesSortMode.score;

  /// 当前展示数据的上次成功更新时间（状态行用）。
  DateTime? _updatedAt;

  /// 有数据时最近一次刷新是否失败（保留旧数据，仅状态行提示）。
  bool _refreshFailed = false;

  late final AnimationController _staggerController;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    final auth = ZhengfangAuth.instance;
    _loggedIn = auth.isLoggedIn;
    _identityOwner = auth.verifiedStudentId;
    _identityRevision = auth.sessionRevision;
    auth.addListener(_handleAuthChanged);

    _staggerController = AnimationController(
      duration: const Duration(milliseconds: 420),
      vsync: this,
    );

    if (_loggedIn) {
      _seedFromCache();
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

  /// 首帧同步读服务缓存（owner/epoch 已由 [GradesService.cachedGrades] 校验），
  /// 进页即见上次成绩，随后的 [_fetchGrades] 只在后台补齐。
  void _seedFromCache() {
    if (widget.fetchGrades != null || _identityOwner == null) return;
    final service = GradesService.instance;
    final cached = service.cachedGrades;
    if (cached == null || cached.isEmpty) return;
    _grades = cached;
    _updatedAt = service.updatedAt;
    _ensureSelectedTerm();
    _staggerController.value = 1;
  }

  void _onSearchChanged() {
    final nextQuery = _searchController.text.trim();
    if (nextQuery == _query) return;
    setState(() => _query = nextQuery);
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
    _searchOpen = false;
    _updatedAt = null;
    _refreshFailed = false;
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
        auth.verifiedStudentId == owner;
  }

  void _handleAuthChanged() {
    if (!mounted) return;
    final auth = ZhengfangAuth.instance;
    final nextLoggedIn = auth.isLoggedIn;
    final nextOwner = auth.verifiedStudentId;
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
    final owner = auth.verifiedStudentId;
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
      _refreshFailed = false;
    });
    try {
      final fetchGrades =
          widget.fetchGrades ?? GradesService.instance.fetchGrades;
      final grades = await fetchGrades(owner, forceRefresh: forceRefresh);
      if (!_acceptFetchResult(generation, owner, revision)) return;
      setState(() {
        _grades = grades;
        _updatedAt = widget.fetchGrades == null
            ? (GradesService.instance.updatedAt ?? DateTime.now())
            : DateTime.now();
      });
      _ensureSelectedTerm();
      // 只有从空到有数据时播入场动画；刷新替换数据不重播，避免闪烁。
      if (!hasExistingData) _staggerController.forward(from: 0);
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
        setState(() => _refreshFailed = true);
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
    final owner = auth.verifiedStudentId;
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

  bool get _allTermsSelected =>
      _selectedTermKey == GradesTermResolver.allTermKey;

  List<GradeEntry> get _gradesForSelectedTerm =>
      GradesTermResolver.filterByTermKey(_grades, _selectedTermKey);

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _query = '';
        // _query 已归零，listener 不会重复 setState。
        _searchController.clear();
      }
    });
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final searching = _searchOpen && _loggedIn;
    return Scaffold(
      appBar: AppAppBar(
        // 与通知页一致：搜索展开时标题位换成紧凑搜索胶囊，图标切为关闭。
        centerTitle: searching ? false : null,
        titleSpacing: searching ? 0 : null,
        title: searching
            ? AppSearchField(
                controller: _searchController,
                hintText: '搜索课程、考核方式',
                compact: true,
                autofocus: true,
                onChanged: (_) {},
                onClear: () => _searchController.clear(),
              )
            : const Text('成绩'),
        actions: _loggedIn
            ? [
                IconButton(
                  icon: Icon(
                    _searchOpen ? Icons.close_rounded : Icons.search_rounded,
                  ),
                  onPressed: _grades.isEmpty ? null : _toggleSearch,
                  tooltip: _searchOpen ? '关闭搜索' : '搜索',
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
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
    if (_error != null) return _buildErrorState();
    if (_grades.isEmpty) {
      return _loading ? _buildSkeleton() : _buildEmptyState();
    }

    final termGrades = _gradesForSelectedTerm;
    final summary = computeGradesSummary(termGrades);
    final q = _query.toLowerCase();
    final filteredGrades = sortGrades(
      _query.isEmpty
          ? termGrades
          : termGrades.where((g) {
              return g.courseName.toLowerCase().contains(q) ||
                  g.assessmentMethod.toLowerCase().contains(q) ||
                  g.examType.toLowerCase().contains(q);
            }).toList(),
      _sortMode,
    );
    final cs = Theme.of(context).colorScheme;

    return RefreshIndicator(
      onRefresh: () => _fetchGrades(forceRefresh: true),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _buildTermChips()),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: _buildOverview(summary),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: GradesDistributionBar(bandCounts: summary.bandCounts),
            ),
          ),
          if (_loading || _updatedAt != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: RefreshStatusLine(
                  updatedAt: _updatedAt,
                  refreshing: _loading,
                  failed: _refreshFailed,
                  loadingLabel: '正在获取成绩…',
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '课程',
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  TextButton(
                    key: const Key('grades_sort_toggle'),
                    onPressed: () => setState(() => _sortMode = _sortMode.next),
                    child: Text(_sortMode.label),
                  ),
                ],
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
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              sliver: SliverList.separated(
                itemCount: filteredGrades.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final grade = filteredGrades[index];
                  // drive 不在父动画上登记监听；每行每次重建 new 一个
                  // CurvedAnimation 会往 _staggerController 累积状态监听且
                  // 从不释放（切学期 / 搜索输入都会重建）。
                  final fadeAnim = _staggerController.drive(
                    CurveTween(
                      curve: Interval(
                        (index * 0.04).clamp(0.0, 0.6),
                        ((index * 0.04) + 0.4).clamp(0.0, 1.0),
                        curve: AppMotion.standard,
                      ),
                    ),
                  );
                  return FadeTransition(
                    opacity: fadeAnim,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, 0.06),
                        end: Offset.zero,
                      ).animate(fadeAnim),
                      child: GradesCourseRow(
                        grade: grade,
                        termLabel: _allTermsSelected
                            ? GradesTermResolver.shortLabelOf(
                                grade.academicYear,
                                grade.semester,
                              )
                            : null,
                      ),
                    ),
                  );
                },
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  /// 横向可滑的学期 chip：最新在前，「全部」固定末尾。
  Widget _buildTermChips() {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: AppFilterChips<String?>(
        options: [
          for (final t in _availableTerms)
            AppFilterOption(
              '${t.academicYear}|${t.semester}',
              GradesTermResolver.shortLabelOf(t.academicYear, t.semester),
            ),
          const AppFilterOption(GradesTermResolver.allTermKey, '全部'),
        ],
        selected: _selectedTermKey,
        onSelected: (key) {
          if (key != null) _onTermChanged(key);
        },
      ),
    );
  }

  /// 无卡片概览：左 GPA 大字，右 学分 / 均分 / 课程 三列。
  /// [summary] 为 null 时（无缓存首次加载）数字显示 `--`。
  Widget _buildOverview(GradesSummary? summary) {
    final cs = Theme.of(context).colorScheme;
    final hasGpa = summary != null && summary.credits > 0;
    final avg = summary?.averageScore;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          flex: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _allTermsSelected ? '总绩点' : '学期绩点',
                style: context.appText.meta,
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  hasGpa ? summary.gpa.toStringAsFixed(2) : '--',
                  style: context.appText.overview.copyWith(
                    color: hasGpa ? cs.primary : cs.outlineVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          flex: 6,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                _OverviewStat(
                  label: '学分',
                  value: summary == null
                      ? '--'
                      : summary.credits.toStringAsFixed(1),
                ),
                _OverviewStat(
                  label: '均分',
                  value: avg == null ? '--' : avg.toStringAsFixed(1),
                ),
                _OverviewStat(
                  label: '课程',
                  value: summary == null ? '--' : '${summary.courseCount}',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── States ───────────────────────────────────────────────────────────────────

  /// 无缓存首次加载：概览 `--` + 分布骨架 + 3 条骨架行，替代整页 spinner。
  Widget _buildSkeleton() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _buildOverview(null),
        const SizedBox(height: 14),
        const SkeletonBox(height: 8, radius: 4),
        const SizedBox(height: 8),
        const RefreshStatusLine(refreshing: true, loadingLabel: '正在获取成绩…'),
        const SizedBox(height: 16),
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          const SkeletonBox(height: 64, radius: 16),
        ],
      ],
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

/// 概览右侧的小统计列：`meta` 标签 + `titleMedium` 等宽值。
class _OverviewStat extends StatelessWidget {
  const _OverviewStat({required this.label, required this.value});

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

/// 未登录引导视图；[automaticLoginPaused] 为 true 时切换为「需要手动登录」文案。
@visibleForTesting
Widget buildGradesLoginView({
  required bool automaticLoginPaused,
  required VoidCallback onAction,
}) => AcademicLoginRequiredView(
  automaticLoginPaused: automaticLoginPaused,
  title: '登录后查看成绩',
  message: '成绩查询依赖教务系统会话，登录后即可同步最新成绩。',
  onAction: onAction,
  icon: Icons.school_outlined,
);
