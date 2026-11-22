/// 练习会话模型：断点续练位置、已答状态恢复、题间导航、统计
/// （PWA `practiceService.ts` + `practiceSessionStore.ts` + `PracticePage.tsx` 里的纯逻辑）。
library;

import 'dart:convert';

import 'practice_selection.dart';
import 'shuati_models.dart';

// ============ 单题状态 / 会话 ============

/// PWA `QuestionState`：一道题在当前会话里的作答状态。
class QuestionState {
  const QuestionState({
    required this.userAnswer,
    required this.submitted,
    required this.status,
    this.blankInput = '',
    this.recordId,
  });

  /// 初始（未作答）状态。
  const QuestionState.initial()
    : userAnswer = const [],
      blankInput = '',
      submitted = false,
      status = AnswerStatus.unanswered,
      recordId = null;

  final List<String> userAnswer;
  final String blankInput;
  final bool submitted;
  final AnswerStatus status;
  final int? recordId;

  QuestionState copyWith({
    List<String>? userAnswer,
    String? blankInput,
    bool? submitted,
    AnswerStatus? status,
    int? recordId,
    bool clearRecordId = false,
  }) {
    return QuestionState(
      userAnswer: userAnswer ?? this.userAnswer,
      blankInput: blankInput ?? this.blankInput,
      submitted: submitted ?? this.submitted,
      status: status ?? this.status,
      recordId: clearRecordId ? null : (recordId ?? this.recordId),
    );
  }
}

/// PWA `PracticeSession`。`results` / `questionStates` 以**题单下标**为键。
class PracticeSession {
  const PracticeSession({
    required this.questions,
    required this.results,
    required this.questionStates,
    required this.startIndex,
  });

  final List<Question> questions;
  final Map<int, AnswerStatus> results;
  final Map<int, QuestionState> questionStates;
  final int startIndex;
}

/// 从作答记录恢复进度（PWA `restoreFromRecords`）。
///
/// 每题只取最新记录；`wrong`（错题本）模式只恢复 `results`、**不**恢复
/// `questionStates`（允许重新作答）；考试模式调用方不应使用本函数（不恢复历史）。
PracticeSession restoreFromRecords({
  required PracticeMode mode,
  required List<Question> questions,
  required List<PracticeRecord> records,
}) {
  if (records.isEmpty) {
    return PracticeSession(
      questions: questions,
      results: const {},
      questionStates: const {},
      startIndex: 0,
    );
  }

  final idToIndex = <String, int>{
    for (final (i, q) in questions.indexed) q.id: i,
  };
  final latest = latestRecordsByQuestion(records);

  final results = <int, AnswerStatus>{};
  final states = <int, QuestionState>{};
  for (final entry in latest.entries) {
    final idx = idToIndex[entry.key];
    if (idx == null) continue;
    final record = entry.value;
    results[idx] = record.status;
    if (mode == PracticeMode.wrong) continue;
    states[idx] = QuestionState(
      userAnswer: record.userAnswer,
      submitted: true,
      status: record.status,
      recordId: record.id,
    );
  }

  return PracticeSession(
    questions: questions,
    results: results,
    questionStates: states,
    startIndex: determineStartIndex(mode, questions.length, results),
  );
}

/// 顺序 / 随机：第一道「没有结果」的题；全部有结果则停在最后一题；其它模式 0。
///
/// 与 PWA 一致，`results[i]` 只要存在（含 `unanswered` 这个会被 JS 视为真值的字符串）
/// 就算已处理。题单为空时 PWA 返回 -1，这里钳到 0 以免越界。
int determineStartIndex(
  PracticeMode mode,
  int total,
  Map<int, AnswerStatus> results,
) {
  if (mode == PracticeMode.sequential || mode == PracticeMode.random) {
    for (var i = 0; i < total; i++) {
      if (results[i] == null) return i;
    }
    return total > 0 ? total - 1 : 0;
  }
  return 0;
}

// ============ 统计 ============

/// PWA `PracticeStats`。
class PracticeStats {
  const PracticeStats({
    required this.answered,
    required this.correct,
    required this.wrong,
    required this.accuracy,
    required this.isFinished,
  });

  final int answered;
  final int correct;
  final int wrong;

  /// 0..100 的整数百分比（四舍五入，无作答为 0）。
  final int accuracy;
  final bool isFinished;
}

/// PWA `computeStats`：只统计下标在 `[0, total)` 且状态为 correct / wrong 的结果。
PracticeStats computeStats(Map<int, AnswerStatus> results, int totalQuestions) {
  var correct = 0;
  var wrong = 0;
  for (final entry in results.entries) {
    if (entry.key < 0 || entry.key >= totalQuestions) continue;
    if (entry.value == AnswerStatus.correct) correct++;
    if (entry.value == AnswerStatus.wrong) wrong++;
  }
  final answered = correct + wrong;
  final accuracy = answered > 0 ? (correct / answered * 100).round() : 0;
  return PracticeStats(
    answered: answered,
    correct: correct,
    wrong: wrong,
    accuracy: accuracy,
    isFinished: answered >= totalQuestions,
  );
}

// ============ 题间导航 ============

/// 自动前进延迟（PWA `QuestionCard.scheduleAutoAdvance`）。
const Duration kAutoAdvanceDelay = Duration(milliseconds: 650);

/// 答对且立即展示答案（非考试）时才自动前进；回看已答题（状态由记录恢复）不会触发，
/// 因为只有「本次保存记录成功」之后才调用。
bool shouldAutoAdvance(
  AnswerStatus status, {
  required bool showAnswerImmediately,
}) => status == AnswerStatus.correct && showAnswerImmediately;

/// PWA `PracticePage` 的上一题 / 下一题规则。
///
/// 「全量随机」（random 且无 randomCount）只在**未答题**之间跳转（找不到则原地不动）；
/// 随机抽题（有 randomCount）与其它模式线性移动并钳在 `[0, length-1]`。
class PracticeNavigator {
  const PracticeNavigator({
    required this.mode,
    required this.total,
    required this.results,
    this.randomCount,
  });

  final PracticeMode mode;
  final int total;
  final Map<int, AnswerStatus> results;
  final int? randomCount;

  bool get isRandomSample => mode == PracticeMode.random && randomCount != null;
  bool get _skipsAnswered => mode == PracticeMode.random && !isRandomSample;

  bool _isAnswered(int i) => results[i]?.isDecided ?? false;

  int? _findUnanswered(int from, int direction) {
    for (var i = from + direction; i >= 0 && i < total; i += direction) {
      if (!_isAnswered(i)) return i;
    }
    return null;
  }

  int next(int current) => _move(current, 1);
  int previous(int current) => _move(current, -1);

  int _move(int current, int direction) {
    if (_skipsAnswered) return _findUnanswered(current, direction) ?? current;
    final maxIndex = total > 0 ? total - 1 : 0;
    return (current + direction).clamp(0, maxIndex);
  }

  bool prevDisabled(int current) =>
      _skipsAnswered ? _findUnanswered(current, -1) == null : current == 0;

  bool nextDisabled(int current) => _skipsAnswered
      ? _findUnanswered(current, 1) == null
      : current >= total - 1;

  /// 考试 / 随机抽题全部答完后，「下一题」变成「结束」。
  bool showFinish(PracticeStats stats) =>
      (mode == PracticeMode.exam || isRandomSample) && stats.isFinished;
}

// ============ 会话 id 与续练 ============

/// `${bankId}:${mode}:${typeFilter|all}`。
String scopedSessionId(
  String bankId,
  PracticeMode mode,
  QuestionType? typeFilter,
) => '$bankId:${mode.name}:${typeFilter?.name ?? 'all'}';

/// 旧版（无题型维度）`${bankId}:${mode}`；仅在无题型过滤时作为回退读取。
String legacyScopedSessionId(String bankId, PracticeMode mode) =>
    '$bankId:${mode.name}';

/// 全局「最近一次」会话 id。
const String lastSessionId = 'last';

/// 解析 `?resume=1` 时用哪条会话（PWA `PracticePage.load`）：
/// 优先 scoped；否则全局 `last` 且 bank / mode / typeFilter 三者都相同。
PracticeSessionRecord? pickResumeSession({
  required String bankId,
  required PracticeMode mode,
  required QuestionType? typeFilter,
  required PracticeSessionRecord? scoped,
  required PracticeSessionRecord? globalLast,
}) {
  if (scoped != null) return scoped;
  if (globalLast != null &&
      globalLast.bankId == bankId &&
      globalLast.mode == mode &&
      globalLast.typeFilter == typeFilter) {
    return globalLast;
  }
  return null;
}

/// 用保存的 `questionIds` 复原题单与起始位置；全部题都已不存在 / 无 id 返回 `null`
/// （调用方应回退到正常加载）。random 模式从不续练（PWA 总是重建完整题单）。
PracticeSession? resumePracticeSession({
  required PracticeMode mode,
  required PracticeSessionRecord? saved,
  required List<Question> availableQuestions,
  required List<PracticeRecord> records,
}) {
  if (mode == PracticeMode.random || saved == null) return null;
  if (saved.questionIds.isEmpty) return null;

  final byId = {for (final q in availableQuestions) q.id: q};
  final ordered = [
    for (final id in saved.questionIds)
      if (byId[id] case final Question q) q,
  ];
  if (ordered.isEmpty) return null;

  final restoredIndex = saved.currentIndex.clamp(0, ordered.length - 1);
  final restored = restoreFromRecords(
    mode: mode,
    questions: ordered,
    records: records,
  );
  return PracticeSession(
    questions: ordered,
    results: restored.results,
    questionStates: restored.questionStates,
    startIndex: restoredIndex,
  );
}

// ============ localStorage 顺序进度兜底（仅迁移 / 兼容） ============

/// PWA `SavedProgress`（localStorage `practice-progress-${bankId}-${mode}`）。
class SavedProgress {
  const SavedProgress({required this.currentIndex, required this.results});

  final int currentIndex;
  final Map<int, AnswerStatus> results;
}

/// PWA `loadSavedProgress` 的纯解析部分。仅顺序模式；JSON 损坏 / 结构不对返回 `null`，
/// `currentIndex` 取整并钳到 ≥ 0，`results` 只保留非负整数键且值为 correct / wrong。
///
/// 原生练习以 DB 记录 + 会话表为准，**不再写** localStorage；本函数只服务将来的
/// 「旧 WebView 数据迁移」阶段读取旧 key。
SavedProgress? parseSavedProgress(String? raw, PracticeMode mode) {
  if (mode != PracticeMode.sequential || raw == null) return null;
  final Object? parsed;
  try {
    parsed = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (parsed is! Map) return null;
  final index = parsed['currentIndex'];
  final results = parsed['results'];
  if (index is! num || results is! Map) return null;
  final normalized = <int, AnswerStatus>{};
  for (final entry in results.entries) {
    final key = entry.key;
    final idx = key is String ? int.tryParse(key) : null;
    if (idx == null || idx < 0) continue;
    final status = AnswerStatus.tryParse(entry.value);
    if (status != null && status.isDecided) normalized[idx] = status;
  }
  final floored = index.isFinite ? index.floor() : 0;
  return SavedProgress(
    currentIndex: floored < 0 ? 0 : floored,
    results: normalized,
  );
}
