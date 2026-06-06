import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/zhengfang_auth.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/login_shell.dart';
import 'exam_model.dart';
import 'exam_service.dart';

class ExamPage extends StatefulWidget {
  const ExamPage({super.key});

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

  @override
  void initState() {
    super.initState();
    _loggedIn = ZhengfangAuth.instance.isLoggedIn;
    ZhengfangAuth.instance.addListener(_handleAuthChanged);
    if (_loggedIn) {
      _loadCachedThenFetch();
    } else {
      // Show cached data even when not logged in (session may have expired).
      _showCachedIfAvailable();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_presentLoginPrompt());
      });
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

  void _showCachedIfAvailable() {
    final cached = ExamService.instance.cachedExams;
    if (cached != null && cached.isNotEmpty) {
      setState(() => _exams = cached);
    }
  }

  @override
  void dispose() {
    ZhengfangAuth.instance.removeListener(_handleAuthChanged);
    super.dispose();
  }

  void _handleAuthChanged() {
    final nextLoggedIn = ZhengfangAuth.instance.isLoggedIn;
    if (!mounted || nextLoggedIn == _loggedIn) return;

    setState(() {
      _loggedIn = nextLoggedIn;
      if (!nextLoggedIn) {
        _error = _exams.isEmpty ? null : '登录状态已失效，请重新登录后刷新考试信息';
      }
    });

    if (!nextLoggedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_presentLoginPrompt(force: true));
      });
    }
  }

  Future<void> _fetchExams({bool forceRefresh = false}) async {
    setState(() {
      _loading = _exams.isEmpty; // Only show spinner if no cached data
      _error = null;
    });
    try {
      final exams = await ExamService.instance.fetchExams(
        forceRefresh: forceRefresh,
      );
      if (mounted) setState(() => _exams = exams);
    } on ExamAuthExpiredException {
      if (!mounted) return;
      setState(() => _error = '登录状态已过期，请重新登录');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_presentLoginPrompt(force: true));
      });
    } catch (e) {
      if (mounted) setState(() => _error = '获取考试信息失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onLoginSuccess() {
    setState(() {
      _loggedIn = true;
      _error = null;
    });
    _fetchExams();
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
      appBar: AppBar(
        title: const Text('考试安排'),
        actions: _loggedIn
            ? [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _fetchExams(forceRefresh: true),
                ),
              ]
            : null,
      ),
      body: _loggedIn ? _buildExamBody() : _buildLoginBody(),
    );
  }

  Widget _buildLoginBody() => AuthRequiredView(
    title: '登录后查看考试安排',
    message: '考试信息依赖教务系统会话，登录后即可同步考试时间与地点。',
    buttonLabel: '登录教务系统',
    onAction: () => _presentLoginPrompt(force: true),
    icon: Icons.quiz_outlined,
  );

  Widget _buildExamBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _fetchExams, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_exams.isEmpty) {
      return const Center(child: Text('暂无考试信息'));
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
