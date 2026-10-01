import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/zhengfang_auth.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/app_list_tile.dart';
import '../../shared/widgets/app_status_tag.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/network_error_toast.dart';
import '../../shared/widgets/plain_list.dart';
import '../../shared/widgets/refresh_status_line.dart';
import '../../shared/widgets/skeleton_box.dart';
import 'exam_model.dart';
import 'exam_service.dart';
import '../../shared/widgets/app_app_bar.dart';

typedef ExamFetcher = Future<List<ExamEntry>> Function({bool forceRefresh});

class ExamPage extends StatefulWidget {
  const ExamPage({super.key, this.fetchExams});

  /// 测试注入点：默认走 [ExamService.instance.fetchExams]。
  final ExamFetcher? fetchExams;

  @override
  State<ExamPage> createState() => _ExamPageState();
}

class _ExamPageState extends State<ExamPage> {
  bool _loggedIn = false;
  bool _loading = false;

  /// 后台刷新在途（有无数据都算），驱动 [RefreshStatusLine]。
  bool _refreshing = false;

  /// 最近一次刷新失败但保留了既有数据。
  bool _refreshFailed = false;

  /// 上次成功获取的时间；状态行只展示这个时间，不以缓存冒充本次成功。
  DateTime? _updatedAt;
  String? _error;
  List<ExamEntry> _exams = [];
  bool _loginPromptShown = false;
  bool _loginPromptInFlight = false;

  /// 最近一次教务过期是否由「自动登录已暂停」触发；仅影响未登录引导文案。
  bool _automaticLoginPaused = false;

  /// 页面状态归属的教务账号（学号）；账号变化（含登出）即清空页面数据，
  /// 绝不让上一个账号的考试残留给下一个账号看到。
  String? _identityOwner;

  /// 状态归属账号对应的 auth 身份修订号；同账号重登也会推进该值，
  /// 用于作废重登前发起的在途抓取。
  int _identityRevision = 0;

  /// 页面内抓取代际：身份变化或发起新抓取时递增，只接纳最新一代结果。
  int _fetchGeneration = 0;

  static String? _normalizeOwner(String? raw) {
    final trimmed = raw?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  @override
  void initState() {
    super.initState();
    final auth = ZhengfangAuth.instance;
    _loggedIn = auth.isLoggedIn;
    _identityOwner = _loggedIn ? _normalizeOwner(auth.currentStudentId) : null;
    _identityRevision = auth.sessionRevision;
    auth.addListener(_handleAuthChanged);
    if (_loggedIn) {
      _loadCachedThenFetch();
    } else {
      // Show cached data even when not logged in (session may have expired).
      final hasCachedExams = _showCachedIfAvailable();
      if (!hasCachedExams) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(_presentLoginPrompt());
        });
      }
    }
  }

  /// Show cached data immediately, then fetch fresh data in the background.
  void _loadCachedThenFetch() {
    final cached = ExamService.instance.cachedExams;
    if (cached != null && cached.isNotEmpty) {
      _exams = cached;
      _updatedAt = ExamService.instance.updatedAt;
    }
    _fetchExams();
  }

  bool _showCachedIfAvailable() {
    final cached = ExamService.instance.cachedExams;
    if (cached != null && cached.isNotEmpty) {
      _exams = cached;
      _updatedAt = ExamService.instance.updatedAt;
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    ZhengfangAuth.instance.removeListener(_handleAuthChanged);
    super.dispose();
  }

  /// 只接纳「最新一代 + 身份仍与抓取发起时一致」的抓取结果。
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

  /// 登出 / 会话失效：页面不得继续持有上一个账号的考试。
  ///
  /// 此处不推进 [_fetchGeneration]：随后到达的过期异常仍属于刚结束的这次
  /// 未登录引导（用于还原「自动登录已暂停」文案），而它的数据结果会因
  /// 身份不匹配被 [_acceptFetchResult] 拒绝。
  void _applySignedOut(int revision) {
    setState(() {
      _loggedIn = false;
      _identityOwner = null;
      _identityRevision = revision;
      _exams = [];
      _updatedAt = null;
      _loading = false;
      _refreshing = false;
      _refreshFailed = false;
      _error = null;
      // 暂停标记由随后的过期异常分支重新写入；普通登出保持非暂停文案。
      _automaticLoginPaused = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_presentLoginPrompt(force: true));
    });
  }

  /// 账号切换（A→B 或登出后重新登录为他人）：清空旧账号数据并拉取新数据。
  void _applyOwnerChanged(String owner, int revision) {
    setState(() {
      _loggedIn = true;
      _identityOwner = owner;
      _identityRevision = revision;
      _fetchGeneration++;
      _exams = [];
      _updatedAt = null;
      _loading = false;
      _refreshing = false;
      _refreshFailed = false;
      _error = null;
      _automaticLoginPaused = false;
    });
    unawaited(_fetchExams());
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
    unawaited(_fetchExams(forceRefresh: true));
  }

  Future<void> _fetchExams({bool forceRefresh = false}) async {
    final auth = ZhengfangAuth.instance;
    final owner = _normalizeOwner(auth.currentStudentId);
    if (!auth.isLoggedIn || owner == null || owner != _identityOwner) {
      // 身份未就绪或已被切换：不发起抓取，等身份同步完成后再刷新。
      return;
    }
    final revision = auth.sessionRevision;
    final generation = ++_fetchGeneration;
    final hasExistingData = _exams.isNotEmpty;

    setState(() {
      _loading = _exams.isEmpty; // 无数据时才显示骨架
      _refreshing = true;
      _refreshFailed = false;
      _error = null;
    });
    try {
      final exams =
          await (widget.fetchExams?.call(forceRefresh: forceRefresh) ??
              ExamService.instance.fetchExams(forceRefresh: forceRefresh));
      if (!_acceptFetchResult(generation, owner, revision)) return;
      setState(() {
        _exams = exams;
        _updatedAt = widget.fetchExams == null
            ? (ExamService.instance.updatedAt ?? DateTime.now())
            : DateTime.now();
      });
    } on ExamAuthExpiredException catch (e) {
      // 过期结果只对「发起时的身份」有效：换号/重登后的迟到过期不得影响
      // 新会话的引导文案。
      if (!mounted) return;
      if (generation != _fetchGeneration) return;
      // 会话过期即身份不可信：清空旧账号数据并回到未登录引导。
      setState(() {
        _loggedIn = false;
        _identityOwner = null;
        _identityRevision = ZhengfangAuth.instance.sessionRevision;
        _exams = [];
        _updatedAt = null;
        _loading = false;
        _error = '登录状态已过期，请重新登录';
        _automaticLoginPaused = e.automaticLoginPaused;
      });
      NetworkErrorToast.show(context, ExamAuthExpiredException());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_presentLoginPrompt(force: true));
      });
    } catch (e) {
      if (!mounted) return;
      if (!_acceptFetchResult(generation, owner, revision)) return;
      if (hasExistingData) {
        // 同账号既有数据仍然有效：保留展示，状态行标「刷新失败」+ toast。
        setState(() => _refreshFailed = true);
        NetworkErrorToast.show(context, e);
      } else {
        setState(() => _error = '获取考试信息失败：$e');
        NetworkErrorToast.show(context, e);
      }
    } finally {
      if (mounted && generation == _fetchGeneration) {
        setState(() {
          _loading = false;
          _refreshing = false;
        });
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
        _exams = [];
        _updatedAt = null;
        _loading = false;
      }
    });
    if (!alreadyRefreshing) {
      unawaited(_fetchExams(forceRefresh: true));
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

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(
        title: const Text('考试安排'),
        actions: (_loggedIn || _exams.isNotEmpty)
            ? [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _loggedIn
                      ? () => _fetchExams(forceRefresh: true)
                      : () => _presentLoginPrompt(force: true),
                ),
              ]
            : null,
      ),
      body: (_loggedIn || _exams.isNotEmpty)
          ? _buildExamBody()
          : _buildLoginBody(),
    );
  }

  Widget _buildLoginBody() => buildExamLoginView(
    automaticLoginPaused: _automaticLoginPaused,
    onAction: () => _presentLoginPrompt(force: true),
  );

  Widget _buildExamBody() {
    if (_error != null && _exams.isEmpty) {
      return AppErrorView(message: _error, onRetry: _fetchExams);
    }
    if (_exams.isEmpty) {
      return _loading
          ? _buildSkeleton()
          : const AppEmptyView(title: '暂无考试信息', icon: Icons.quiz_outlined);
    }

    final upcoming = _exams.where((e) => e.hasDate && !e.isPast).toList();
    final past = _exams.where((e) => e.isPast).toList();
    final undated = _exams.where((e) => !e.hasDate).toList();

    return RefreshIndicator(
      onRefresh: () => _fetchExams(forceRefresh: true),
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
            loadingLabel: '正在获取考试…',
          ),
          ..._buildSection('即将到来', upcoming, _upcomingTile),
          ..._buildSection('时间待定', undated, (e) => _detailTile(e)),
          ..._buildSection('已结束', past, (e) => _detailTile(e, dimmed: true)),
        ],
      ),
    );
  }

  /// 分区：`PlainSectionHeader`「标题 · 数量」+ 单列行，行距 8。
  List<Widget> _buildSection(
    String title,
    List<ExamEntry> exams,
    Widget Function(ExamEntry exam) tile,
  ) {
    if (exams.isEmpty) return const [];
    return [
      const SizedBox(height: AppSpacing.lg),
      PlainSectionHeader('$title · ${exams.length}'),
      for (final (index, exam) in exams.indexed) ...[
        if (index > 0) const SizedBox(height: AppSpacing.sm),
        tile(exam),
      ],
    ];
  }

  Widget _upcomingTile(ExamEntry exam) {
    final days = exam.daysUntil;
    return AppListTile(
      title: exam.courseName,
      details: [
        _dateLine(exam),
        '${exam.location} ${exam.campus}'.trim(),
        if (exam.seatNumber.isNotEmpty) '座号 ${exam.seatNumber}',
      ],
      trailing: AppStatusTag(
        days == 0 ? '今天' : '$days天后',
        tone: AppStatusTone.positive,
      ),
    );
  }

  Widget _detailTile(ExamEntry exam, {bool dimmed = false}) {
    return AppListTile(
      title: exam.courseName,
      dimmed: dimmed,
      titleTrailing: exam.isRetake
          ? const AppStatusTag('重修', tone: AppStatusTone.attention)
          : null,
      details: [
        if (exam.hasDate) _dateLine(exam),
        exam.location.isEmpty
            ? '地点待定'
            : '${exam.location} ${exam.campus}'.trim(),
        if (exam.seatNumber.isNotEmpty) '座号 ${exam.seatNumber}',
        if (exam.examName.isNotEmpty) exam.examName,
      ],
    );
  }

  static String _dateLine(ExamEntry exam) =>
      '${exam.examDate!.month}/${exam.examDate!.day} '
      '${exam.weekdayLabel} ${exam.timeRange}';

  /// 无缓存首次加载：状态行 + 3 条骨架行，替代整页 spinner。
  Widget _buildSkeleton() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.sm,
        AppSpacing.pageMargin,
        AppSpacing.xl,
      ),
      children: [
        const RefreshStatusLine(refreshing: true, loadingLabel: '正在获取考试…'),
        const SizedBox(height: AppSpacing.lg),
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.sm),
          const SkeletonBox(height: 88, radius: 16),
        ],
      ],
    );
  }
}

/// 未登录引导视图；[automaticLoginPaused] 为 true 时切换为「需要手动登录」文案。
///
/// 独立函数便于在测试中直接验证两种文案（页面未登录态会自动拉起登录弹窗，
/// 不便整体 pump）。
@visibleForTesting
Widget buildExamLoginView({
  required bool automaticLoginPaused,
  required VoidCallback onAction,
}) => AcademicLoginRequiredView(
  automaticLoginPaused: automaticLoginPaused,
  title: '登录后查看考试安排',
  message: '考试信息依赖教务系统会话，登录后即可同步考试时间与地点。',
  onAction: onAction,
  icon: Icons.quiz_outlined,
);
