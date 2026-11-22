/// 首页 / 题库页统计（PWA `HomePage.tsx` / `BanksPage.tsx` 里的纯计算）。
///
/// 注意口径：**正确率按所有有效作答记录计**（同一题多次作答都计入），
/// 而「已答题数」按 (题库, 题目) 去重；练习页自己的正确率（[computeStats]）则按
/// 当前题单每题一个结果。三者口径不同是 PWA 的既有行为，这里不改。
library;

import 'practice_selection.dart';
import 'shuati_models.dart';

int _roundPercent(num numerator, num denominator) =>
    (numerator / denominator * 100).round();

/// 首页「总体进度 / 正确率 / 近 7 天」。
class HomeStats {
  const HomeStats({
    required this.totalQuestions,
    required this.answered,
    required this.accuracy,
    required this.bankCount,
    required this.completionPct,
    required this.dailyAccuracy,
  });

  final int totalQuestions;
  final int answered;

  /// 无任何有效作答时为 `null`（首页隐藏正确率）。
  final int? accuracy;
  final int bankCount;
  final int completionPct;
  final List<DailyAccuracy> dailyAccuracy;
}

/// 近 7 天某一天的正确率（无作答为 0）。
class DailyAccuracy {
  const DailyAccuracy(this.label, this.value);

  /// `M/D`（本地时区）。
  final String label;
  final int value;
}

/// PWA `HomePage.homeStats`。
HomeStats computeHomeStats({
  required List<QuestionBank> banks,
  required List<PracticeRecord> records,
  DateTime? now,
}) {
  final total = banks.fold<int>(0, (sum, b) => sum + b.questionCount);
  final decided = records.where((r) => r.status.isDecided).toList();
  final correct = decided.where((r) => r.status == AnswerStatus.correct).length;
  final wrong = decided.where((r) => r.status == AnswerStatus.wrong).length;
  final answered = {for (final r in decided) '${r.bankId}:${r.questionId}'}
      .length;
  return HomeStats(
    totalQuestions: total,
    answered: answered,
    accuracy: correct + wrong > 0
        ? _roundPercent(correct, correct + wrong)
        : null,
    bankCount: banks.length,
    completionPct: total > 0 ? _roundPercent(answered, total) : 0,
    dailyAccuracy: computeDailyAccuracy(records, now: now),
  );
}

/// PWA `computeDailyAccuracy`：最近 7 天（含今天），按本地日期 `M/D` 分桶。
List<DailyAccuracy> computeDailyAccuracy(
  List<PracticeRecord> records, {
  DateTime? now,
}) {
  final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  String label(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month}/${d.day}';
  }

  final labels = [for (var i = 6; i >= 0; i--) label(nowMs - i * 86400000)];
  final correct = {for (final l in labels) l: 0};
  final wrong = {for (final l in labels) l: 0};
  for (final r in records) {
    final key = label(r.timestamp);
    if (!correct.containsKey(key)) continue;
    if (r.status == AnswerStatus.correct) correct[key] = correct[key]! + 1;
    if (r.status == AnswerStatus.wrong) wrong[key] = wrong[key]! + 1;
  }
  return [
    for (final l in labels)
      DailyAccuracy(
        l,
        correct[l]! + wrong[l]! > 0
            ? _roundPercent(correct[l]!, correct[l]! + wrong[l]!)
            : 0,
      ),
  ];
}

/// 题库卡片上的统计（PWA `BanksPage.BankCard.stats`）。
class BankStats {
  const BankStats({
    required this.wrong,
    required this.uniqueAnswered,
    required this.progress,
    required this.accuracy,
  });

  /// 错误**作答次数**（不是错题数）。
  final int wrong;
  final int uniqueAnswered;
  final int progress;
  final int? accuracy;
}

BankStats computeBankStats(QuestionBank bank, List<PracticeRecord> records) {
  final own = records
      .where((r) => r.bankId == bank.id && r.status.isDecided)
      .toList();
  final correct = own.where((r) => r.status == AnswerStatus.correct).length;
  final wrong = own.where((r) => r.status == AnswerStatus.wrong).length;
  final unique = {for (final r in own) r.questionId}.length;
  return BankStats(
    wrong: wrong,
    uniqueAnswered: unique,
    progress: bank.questionCount > 0
        ? _roundPercent(unique, bank.questionCount)
        : 0,
    accuracy: correct + wrong > 0
        ? _roundPercent(correct, correct + wrong)
        : null,
  );
}

/// 练习模式选择面板的数据（PWA `BanksPage` 的 mode sheet）。
class PracticeModeSummary {
  const PracticeModeSummary({
    required this.typeCounts,
    required this.totalCount,
    required this.answeredCount,
    required this.unansweredCount,
    required this.examOptions,
    required this.randomOptions,
  });

  final Map<QuestionType, int> typeCounts;
  final int totalCount;
  final int answeredCount;
  final int unansweredCount;

  /// 可选考试题数：`[20,50,100]` 中小于总数的，再加「全部」。
  final List<int> examOptions;

  /// 可选随机题数：`[10,20,50,100]` 中小于未做题数的，再加「全部未做」。
  final List<int> randomOptions;
}

PracticeModeSummary summarizeForModes({
  required List<Question> questions,
  required List<PracticeRecord> records,
  QuestionType? selectedType,
}) {
  final typeCounts = <QuestionType, int>{};
  for (final q in questions) {
    typeCounts[q.type] = (typeCounts[q.type] ?? 0) + 1;
  }
  final scoped = selectedType == null
      ? questions
      : questions.where((q) => q.type == selectedType).toList();
  final answeredIds = answeredQuestionIds(records);
  final total = scoped.length;
  final answered = scoped.where((q) => answeredIds.contains(q.id)).length;
  final unanswered = total - answered < 0 ? 0 : total - answered;

  List<int> options(List<int> base, int limit) {
    final result = <int>[...base.where((n) => n < limit)];
    if (limit > 0) result.add(limit);
    return result.toSet().toList();
  }

  return PracticeModeSummary(
    typeCounts: typeCounts,
    totalCount: total,
    answeredCount: answered,
    unansweredCount: unanswered,
    examOptions: options(const [20, 50, 100], total),
    randomOptions: options(const [10, 20, 50, 100], unanswered),
  );
}

/// 自定义随机题数输入的钳制：`[1, max(1, unanswered)]`，非整数向下取整，0/空按 1。
int clampCustomRandomCount(num draft, int unansweredCount) {
  final floored = draft.isFinite ? draft.floor() : 1;
  final lower = floored < 1 ? 1 : floored;
  final upper = unansweredCount < 1 ? 1 : unansweredCount;
  return lower > upper ? upper : lower;
}
