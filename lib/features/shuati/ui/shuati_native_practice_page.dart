/// 原生练习页：支持五种模式、题型筛选、题数限制、断点恢复、收藏、答题卡、
/// 自动前进（650ms）、错题重做与逐项解析。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_app_bar.dart';
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../../shared/widgets/app_filter_chips.dart';
import '../../../shared/widgets/app_status_tag.dart';
import '../domain/answer_judge.dart';
import '../domain/practice_attempt.dart';
import '../domain/practice_selection.dart';
import '../domain/practice_session.dart';
import '../domain/shuati_models.dart';
import '../persistence/shuati_store.dart';
import 'shuati_ai_section.dart';
import 'shuati_services.dart';

enum _SheetFilter {
  all('全部'),
  choice('选择'),
  judge('判断'),
  written('填空简答');

  const _SheetFilter(this.label);

  final String label;

  bool matches(Question q) => switch (this) {
    _SheetFilter.all => true,
    _SheetFilter.choice => q.type.isChoice,
    _SheetFilter.judge => q.type == QuestionType.judge,
    _SheetFilter.written => q.type.isSelfGraded,
  };
}

class ShuatiNativePracticePage extends StatefulWidget {
  const ShuatiNativePracticePage({
    super.key,
    required this.bankId,
    required this.mode,
    this.typeFilter,
    this.examCount,
    this.randomCount,
    this.resume = false,
  });

  final String bankId;
  final PracticeMode mode;
  final QuestionType? typeFilter;
  final int? examCount;
  final int? randomCount;
  final bool resume;

  @override
  State<ShuatiNativePracticePage> createState() =>
      _ShuatiNativePracticePageState();
}

class _ShuatiNativePracticePageState extends State<ShuatiNativePracticePage> {
  ShuatiStore? _store;
  PracticeSession? _session;
  Object? _error;
  int _index = 0;
  bool _finished = false;
  bool _saving = false;
  bool _togglingFavorite = false;
  Timer? _autoAdvanceTimer;
  final Set<String> _favoritedIds = {};
  final Map<int, QuestionState> _states = {};
  final Map<int, AnswerStatus> _results = {};
  final TextEditingController _blankController = TextEditingController();

  bool get _showAnswer => widget.mode != PracticeMode.exam;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _autoAdvanceTimer?.cancel();
    _blankController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    _autoAdvanceTimer?.cancel();
    setState(() => _error = null);
    try {
      final store = await ShuatiServices.instance.store();
      final options = PracticeLoadOptions(
        examCount: widget.examCount,
        randomCount: widget.randomCount,
        typeFilter: widget.typeFilter,
      );
      final session = widget.resume
          ? await store.resumeOrLoadPracticeSession(
              widget.bankId,
              widget.mode,
              typeFilter: widget.typeFilter,
              options: options,
            )
          : await store.loadPracticeSession(
              widget.bankId,
              widget.mode,
              options: options,
            );
      final favIds = await store.favorites.questionIds(widget.bankId);
      if (!mounted) return;
      setState(() {
        _store = store;
        _session = session;
        _favoritedIds
          ..clear()
          ..addAll(favIds);
        _results
          ..clear()
          ..addAll(session.results);
        _states
          ..clear()
          ..addAll(session.questionStates);
        _index = session.startIndex;
        if (session.questions.isNotEmpty) {
          _syncInput();
        } else {
          _blankController.clear();
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Question get _question => _session!.questions[_index];

  QuestionState get _state => _states[_index] ?? const QuestionState.initial();

  void _syncInput() {
    final q = _question;
    if (q.type.isSelfGraded &&
        _state.blankInput.isEmpty &&
        _state.userAnswer.isNotEmpty) {
      _blankController.text = _state.userAnswer.join('\n');
    } else {
      _blankController.text = _state.blankInput;
    }
  }

  void _saveSessionProgress(int index) {
    final session = _session;
    final store = _store;
    if (session == null || store == null || session.questions.isEmpty) return;
    unawaited(
      store.saveLastPracticeSession(
        bankId: widget.bankId,
        mode: widget.mode,
        currentIndex: index,
        questionIds: [for (final q in session.questions) q.id],
        typeFilter: widget.typeFilter,
      ),
    );
  }

  void _goTo(int index) {
    _autoAdvanceTimer?.cancel();
    if (index == _index) return;
    setState(() {
      _index = index;
      _syncInput();
    });
    _saveSessionProgress(index);
  }

  void _toggle(String option) {
    final next = toggleOption(
      _question.type,
      _state.userAnswer,
      option,
      submitted: _state.submitted,
    );
    setState(() => _states[_index] = _state.copyWith(userAnswer: next));
  }

  Future<void> _toggleFavorite() async {
    final store = _store;
    final session = _session;
    if (store == null ||
        session == null ||
        session.questions.isEmpty ||
        _togglingFavorite) {
      return;
    }
    final questionId = _question.id;
    setState(() => _togglingFavorite = true);
    try {
      final isNowFavorite = await store.toggleFavorite(
        widget.bankId,
        questionId,
      );
      if (!mounted) return;
      setState(() {
        if (isNowFavorite) {
          _favoritedIds.add(questionId);
        } else {
          _favoritedIds.remove(questionId);
        }
      });
    } finally {
      if (mounted) setState(() => _togglingFavorite = false);
    }
  }

  Future<void> _apply(AttemptDecision decision) async {
    _autoAdvanceTimer?.cancel();
    final index = _index;
    final question = _question;
    setState(() => _states[index] = decision.state);
    final status = decision.persist;
    final store = _store;
    if (status == null || store == null) return;
    setState(() => _saving = true);
    try {
      final id = await store.savePracticeAnswer(
        PracticeRecord(
          bankId: widget.bankId,
          questionId: question.id,
          userAnswer: decision.persistedAnswer,
          status: status,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
        existingId: decision.state.recordId,
      );
      if (!mounted) return;
      setState(() {
        _states[index] = decision.state.copyWith(recordId: id);
        _results[index] = status;
      });
      _saveSessionProgress(index);

      if (decision.autoAdvance && !_finished) {
        final session = _session;
        if (session != null) {
          final navigator = PracticeNavigator(
            mode: widget.mode,
            total: session.questions.length,
            results: _results,
            randomCount: widget.randomCount,
          );
          if (!navigator.nextDisabled(index)) {
            final target = navigator.next(index);
            _autoAdvanceTimer = Timer(kAutoAdvanceDelay, () {
              if (!mounted || _finished || _index != index) return;
              _goTo(target);
            });
          }
        }
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _submit() {
    final state = _state.copyWith(blankInput: _blankController.text);
    _apply(
      submitAnswer(
        question: _question,
        state: state,
        showAnswerImmediately: _showAnswer,
      ),
    );
  }

  void _selfGrade(AnswerStatus grade) {
    _apply(
      selfGrade(
        state: _state,
        grade: grade,
        showAnswerImmediately: _showAnswer,
      ),
    );
  }

  void _redoCurrent() {
    _autoAdvanceTimer?.cancel();
    setState(() {
      _states[_index] = redo();
      _results.remove(_index);
      _syncInput();
    });
  }

  Future<void> _showAnswerSheet() async {
    final session = _session;
    if (session == null || session.questions.isEmpty) return;
    var filter = _SheetFilter.all;
    await AppFeedback.sheet<void>(
      context,
      scrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final cs = Theme.of(context).colorScheme;
          final text = context.appText;
          final indices = [
            for (final (i, q) in session.questions.indexed)
              if (filter.matches(q)) i,
          ];
          final sheetMaxHeight = MediaQuery.sizeOf(context).height * 0.55;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('答题卡', style: text.section),
                      const Spacer(),
                      Text(
                        '${_results.length}/${session.questions.length}',
                        style: text.meta,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppFilterChips<_SheetFilter>(
                    padding: EdgeInsets.zero,
                    options: [
                      for (final f in _SheetFilter.values)
                        AppFilterOption(f, f.label),
                    ],
                    selected: filter,
                    onSelected: (next) => setSheetState(() => filter = next),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: sheetMaxHeight),
                    child: indices.isEmpty
                        ? const AppEmptyView(
                            title: '该题型下没有题目',
                            icon: Icons.filter_list_off_outlined,
                          )
                        : GridView.builder(
                            shrinkWrap: true,
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 56,
                                  mainAxisSpacing: AppSpacing.sm,
                                  crossAxisSpacing: AppSpacing.sm,
                                ),
                            itemCount: indices.length,
                            itemBuilder: (context, pos) {
                              final qIndex = indices[pos];
                              final status = _results[qIndex];
                              final isCurrent = qIndex == _index;
                              final (bg, fg) = switch (status) {
                                AnswerStatus.correct => (
                                  cs.primaryContainer,
                                  cs.onPrimaryContainer,
                                ),
                                AnswerStatus.wrong => (
                                  cs.errorContainer,
                                  cs.onErrorContainer,
                                ),
                                _ => (
                                  cs.surfaceContainerHighest,
                                  cs.onSurfaceVariant,
                                ),
                              };
                              return Material(
                                color: bg,
                                shape: RoundedSuperellipseBorder(
                                  borderRadius: AppRadius.cellBorder,
                                  side: isCurrent
                                      ? BorderSide(color: cs.primary, width: 2)
                                      : BorderSide.none,
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: InkWell(
                                  onTap: () {
                                    Navigator.of(sheetContext).pop();
                                    _goTo(qIndex);
                                  },
                                  child: Center(
                                    child: Text(
                                      '${qIndex + 1}',
                                      style: text.rowTitle.copyWith(color: fg),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final hasQuestions =
        session != null && session.questions.isNotEmpty && !_finished;
    final isFavorite = hasQuestions && _favoritedIds.contains(_question.id);
    final cs = Theme.of(context).colorScheme;
    final titleText = widget.typeFilter == null
        ? widget.mode.label
        : '${widget.mode.label} · ${widget.typeFilter!.label}';

    return Scaffold(
      appBar: AppAppBar(
        title: Text(titleText),
        actions: hasQuestions
            ? [
                IconButton(
                  tooltip: isFavorite ? '取消收藏' : '收藏题目',
                  icon: Icon(
                    isFavorite
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    color: isFavorite ? cs.primary : null,
                  ),
                  onPressed: _togglingFavorite ? null : _toggleFavorite,
                ),
                IconButton(
                  tooltip: '答题卡',
                  icon: const Icon(Icons.grid_view_outlined),
                  onPressed: _showAnswerSheet,
                ),
              ]
            : null,
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_error != null) {
      return AppErrorView(message: '无法加载题目', onRetry: _load);
    }
    final session = _session;
    if (session == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (session.questions.isEmpty) {
      return const AppEmptyView(title: '没有可练习的题目', icon: Icons.inbox_outlined);
    }
    final total = session.questions.length;
    final stats = computeStats(_results, total);
    if (_finished) return _buildFinished(context, stats, total);
    final navigator = PracticeNavigator(
      mode: widget.mode,
      total: total,
      results: _results,
      randomCount: widget.randomCount,
    );
    final showFinish = navigator.showFinish(stats);
    return Column(
      children: [
        LinearProgressIndicator(value: stats.answered / total),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.pageMargin,
              AppSpacing.lg,
              AppSpacing.pageMargin,
              AppSpacing.xl,
            ),
            children: _buildQuestion(context, total),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                OutlinedButton(
                  onPressed: navigator.prevDisabled(_index)
                      ? null
                      : () => _goTo(navigator.previous(_index)),
                  child: const Text('上一题'),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      '${_index + 1}/$total',
                      style: context.appText.secondary,
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: showFinish
                      ? () {
                          _autoAdvanceTimer?.cancel();
                          setState(() => _finished = true);
                        }
                      : navigator.nextDisabled(_index)
                      ? null
                      : () => _goTo(navigator.next(_index)),
                  child: Text(showFinish ? '结束' : '下一题'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFinished(BuildContext context, PracticeStats stats, int total) {
    final text = context.appText;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${stats.accuracy}%', style: text.overview),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '共 $total 题 · 正确 ${stats.correct} · 错误 ${stats.wrong}',
              style: text.secondary,
            ),
            const SizedBox(height: AppSpacing.xl),
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.sm,
              alignment: WrapAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: () => setState(() => _finished = false),
                  child: const Text('回顾题目'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('返回'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildQuestion(BuildContext context, int total) {
    final q = _question;
    final state = _state;
    final text = context.appText;
    final cs = Theme.of(context).colorScheme;
    final revealed = state.submitted && _showAnswer;
    final optExplanations = q.optionExplanations ?? const <String, String>{};

    final children = <Widget>[
      Row(
        children: [
          AppStatusTag(q.type.label),
          const Spacer(),
          Text('第 ${_index + 1} / $total 题', style: text.meta),
        ],
      ),
      const SizedBox(height: AppSpacing.md),
      Text(q.question, style: Theme.of(context).textTheme.bodyLarge),
      const SizedBox(height: AppSpacing.lg),
    ];

    if (!q.isPracticeReady) {
      children.add(
        Text(
          '这道题的数据不完整，暂时无法作答。',
          style: text.secondary.copyWith(color: cs.error),
        ),
      );
      return children;
    }

    if (q.type.isSelfGraded) {
      children.add(
        TextField(
          controller: _blankController,
          enabled: !state.submitted,
          minLines: q.type == QuestionType.short ? 4 : 2,
          maxLines: 8,
          decoration: const InputDecoration(hintText: '请输入答案'),
        ),
      );
    } else {
      final entries = q.type == QuestionType.judge
          ? const [('true', '正确'), ('false', '错误')]
          : [
              for (final e in (q.options ?? const <String, String>{}).entries)
                if (e.value.trim().isNotEmpty) (e.key, e.value),
            ];
      for (final (key, label) in entries) {
        final selected = state.userAnswer.contains(key);
        final isCorrect = q.answer.contains(key);
        Color? color = selected ? cs.secondaryContainer : null;
        if (revealed) {
          if (isCorrect) {
            color = cs.primaryContainer;
          } else if (selected) {
            color = cs.errorContainer;
          } else {
            color = null;
          }
        }
        final optExplain = revealed ? (optExplanations[key]?.trim() ?? '') : '';
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Material(
              color: color ?? cs.surfaceContainerHighest,
              shape: RoundedSuperellipseBorder(
                borderRadius: AppRadius.tileBorder,
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: state.submitted ? null : () => _toggle(key),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.md,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (q.type != QuestionType.judge) ...[
                            Text(key, style: text.rowTitle),
                            const SizedBox(width: AppSpacing.md),
                          ],
                          Expanded(child: Text(label, style: text.listTitle)),
                        ],
                      ),
                      if (optExplain.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.xs),
                        Text(optExplain, style: text.meta),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }

    children.add(const SizedBox(height: AppSpacing.md));

    if (!state.submitted) {
      children.add(
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: const Text('提交答案'),
        ),
      );
    } else if (!_showAnswer) {
      children.add(Text('答案已提交', style: text.secondary));
    } else if (q.type.isSelfGraded) {
      children
        ..add(Text('参考答案', style: text.label))
        ..add(const SizedBox(height: AppSpacing.xs))
        ..add(Text(q.answer.join(' / '), style: text.listTitle))
        ..add(const SizedBox(height: AppSpacing.md))
        ..add(
          SegmentedButton<AnswerStatus>(
            showSelectedIcon: false,
            emptySelectionAllowed: true,
            segments: const [
              ButtonSegment(value: AnswerStatus.correct, label: Text('我答对了')),
              ButtonSegment(value: AnswerStatus.wrong, label: Text('我答错了')),
            ],
            selected: state.status.isDecided
                ? {state.status}
                : const <AnswerStatus>{},
            onSelectionChanged: _saving
                ? null
                : (selection) {
                    if (selection.isEmpty) return;
                    _selfGrade(selection.first);
                  },
          ),
        );
    } else {
      final correct = checkAnswer(q, state.userAnswer) == AnswerStatus.correct;
      children.add(
        Text(
          correct ? '回答正确' : '回答错误，正确答案：${q.answer.join(', ')}',
          style: text.rowTitle.copyWith(color: correct ? cs.primary : cs.error),
        ),
      );
    }

    if (widget.mode == PracticeMode.wrong && state.submitted) {
      children
        ..add(const SizedBox(height: AppSpacing.md))
        ..add(
          OutlinedButton(
            onPressed: _saving ? null : _redoCurrent,
            child: const Text('重做本题'),
          ),
        );
    }

    final explanation = q.explanation?.trim() ?? '';
    if (revealed && explanation.isNotEmpty) {
      children
        ..add(const SizedBox(height: AppSpacing.lg))
        ..add(Text('解析', style: text.label))
        ..add(const SizedBox(height: AppSpacing.xs))
        ..add(Text(explanation, style: text.secondary));
    }

    if (revealed) {
      children
        ..add(const SizedBox(height: AppSpacing.lg))
        ..add(
          ShuatiAiSection(
            key: ValueKey('ai-${q.id}'),
            question: q,
            userAnswer: _userAnswerText(q, state),
          ),
        );
    }
    return children;
  }

  /// 传给「追问 AI」的作答文本：填空 / 简答取输入框内容，其余取已选项。
  String? _userAnswerText(Question q, QuestionState state) {
    if (q.type.isSelfGraded) {
      final text = state.blankInput.trim();
      if (text.isNotEmpty) return text;
    }
    return state.userAnswer.isEmpty ? null : state.userAnswer.join('、');
  }
}
