import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/zhengfang_auth.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/network_error_toast.dart';
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
    }
    _fetchExams();
  }

  bool _showCachedIfAvailable() {
    final cached = ExamService.instance.cachedExams;
    if (cached != null && cached.isNotEmpty) {
      _exams = cached;
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
      _loading = false;
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
      _loading = false;
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
      _loading = _exams.isEmpty; // Only show spinner if no cached data
      _error = null;
    });
    try {
      final exams =
          await (widget.fetchExams?.call(forceRefresh: forceRefresh) ??
              ExamService.instance.fetchExams(forceRefresh: forceRefresh));
      if (!_acceptFetchResult(generation, owner, revision)) return;
      setState(() => _exams = exams);
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
        // 同账号既有数据仍然有效：保留展示，只用 toast 提示本次失败。
        NetworkErrorToast.show(context, e);
      } else {
        setState(() => _error = '获取考试信息失败：$e');
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
        _exams = [];
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
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _exams.isEmpty) {
      return AppErrorView(message: _error, onRetry: _fetchExams);
    }
    if (_exams.isEmpty) {
      return const AppEmptyView(title: '暂无考试信息', icon: Icons.quiz_outlined);
    }

    final upcoming = _exams.where((e) => e.hasDate && !e.isPast).toList();
    final past = _exams.where((e) => e.isPast).toList();
    final undated = _exams.where((e) => !e.hasDate).toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (upcoming.isNotEmpty) ...[
          _buildSectionHeader(context, '即将到来', upcoming.length),
          const SizedBox(height: 8),
          for (final exam in upcoming) ...[
            _ExamCountdownCard(exam: exam),
            const SizedBox(height: 10),
          ],
        ],
        if (undated.isNotEmpty) ...[
          _buildSectionHeader(context, '时间待定', undated.length),
          const SizedBox(height: 8),
          for (final exam in undated) ...[
            _ExamDetailCard(exam: exam),
            const SizedBox(height: 10),
          ],
        ],
        if (past.isNotEmpty) ...[
          _buildSectionHeader(context, '已结束', past.length),
          const SizedBox(height: 8),
          for (final exam in past) ...[
            _ExamDetailCard(exam: exam, dimmed: true),
            const SizedBox(height: 10),
          ],
        ],
      ],
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title, int count) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 4,
          height: 18,
          decoration: BoxDecoration(
            color: cs.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
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
}) => AuthRequiredView(
  title: automaticLoginPaused ? '需要手动登录' : '登录后查看考试安排',
  message: automaticLoginPaused
      ? '自动登录已暂停（多次登录失败），请手动登录一次；登录成功后会自动重新开启自动登录。'
      : '考试信息依赖教务系统会话，登录后即可同步考试时间与地点。',
  buttonLabel: '登录教务系统',
  onAction: onAction,
  icon: Icons.quiz_outlined,
);

// ── Countdown Card (upcoming exams) ───────────────────────────────────────

class _ExamCountdownCard extends StatelessWidget {
  const _ExamCountdownCard({required this.exam});
  final ExamEntry exam;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    exam.courseName,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                _CountdownChip(days: exam.daysUntil),
              ],
            ),
            const SizedBox(height: 10),
            _InfoRow(
              icon: Icons.calendar_today,
              text:
                  '${exam.examDate!.month}/${exam.examDate!.day} '
                  '${exam.weekdayLabel} ${exam.timeRange}',
            ),
            const SizedBox(height: 4),
            _InfoRow(
              icon: Icons.location_on_outlined,
              text: '${exam.location} ${exam.campus}',
            ),
            if (exam.seatNumber.isNotEmpty) ...[
              const SizedBox(height: 4),
              _InfoRow(
                icon: Icons.event_seat_outlined,
                text: '座号 ${exam.seatNumber}',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CountdownChip extends StatelessWidget {
  const _CountdownChip({required this.days});
  final int days;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final label = days == 0 ? '今天' : '$days天后';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: cs.onSecondaryContainer,
        ),
      ),
    );
  }
}

// ── Detail Card (past / undated exams) ────────────────────────────────────

class _ExamDetailCard extends StatelessWidget {
  const _ExamDetailCard({required this.exam, this.dimmed = false});
  final ExamEntry exam;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textColor = dimmed ? cs.onSurfaceVariant : cs.onSurface;
    final secondaryColor = dimmed
        ? cs.onSurfaceVariant.withValues(alpha: 0.6)
        : cs.onSurfaceVariant;

    return Card(
      elevation: 0,
      color: dimmed ? cs.surfaceContainerHighest.withValues(alpha: 0.3) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: dimmed ? BorderSide.none : BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    exam.courseName,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                ),
                if (exam.isRetake)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: cs.tertiaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '重修',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onTertiaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (exam.hasDate) ...[
              _InfoRow(
                icon: Icons.access_time,
                text:
                    '${exam.examDate!.month}/${exam.examDate!.day} '
                    '${exam.weekdayLabel} ${exam.timeRange}',
                color: secondaryColor,
              ),
              const SizedBox(height: 4),
            ],
            _InfoRow(
              icon: Icons.location_on_outlined,
              text: exam.location.isEmpty
                  ? '地点待定'
                  : '${exam.location} ${exam.campus}',
              color: secondaryColor,
            ),
            if (exam.seatNumber.isNotEmpty) ...[
              const SizedBox(height: 4),
              _InfoRow(
                icon: Icons.event_seat_outlined,
                text: '座号 ${exam.seatNumber}',
                color: secondaryColor,
              ),
            ],
            if (exam.examName.isNotEmpty) ...[
              const SizedBox(height: 4),
              _InfoRow(
                icon: Icons.description_outlined,
                text: exam.examName,
                color: secondaryColor,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Info Row ──────────────────────────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final effectiveColor =
        color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Icon(icon, size: 14, color: effectiveColor),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 13, color: effectiveColor),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
