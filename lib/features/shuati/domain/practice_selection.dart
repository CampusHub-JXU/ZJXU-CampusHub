/// 练习题单选取（PWA `practiceService.loadQuestions` 的纯函数部分）。
///
/// 输入是 repository 已按模式取回的候选题（顺序 / 随机 / 考试 → 整个题库；
/// 错题本 / 收藏 → 对应题 id 的题目），本文件只做：题型过滤 → 错题 / 收藏排序 →
/// 洗牌 → 随机抽题（只从未做题中抽）/ 考试截断。
library;

import 'dart:math' as math;

import 'shuati_models.dart';

/// PWA `loadQuestions` 的 `options`。
class PracticeLoadOptions {
  const PracticeLoadOptions({
    this.examCount,
    this.randomCount,
    this.shuffle,
    this.typeFilter,
  });

  /// 考试题数（仅 exam 模式生效，需为正数才截断）。
  final int? examCount;

  /// 随机练习抽题数（仅 random 模式生效；设置后只从未做题中抽）。
  final int? randomCount;

  /// 显式洗牌开关；`null` 时 random / exam 模式默认洗牌。
  final bool? shuffle;

  final QuestionType? typeFilter;
}

/// Fisher-Yates 洗牌（PWA `shuffleArray`）。[random] 可注入以便测试。
List<T> shuffleList<T>(List<T> input, {math.Random? random}) {
  final rng = random ?? math.Random();
  final result = [...input];
  for (var i = result.length - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final tmp = result[i];
    result[i] = result[j];
    result[j] = tmp;
  }
  return result;
}

/// 每题最新一条记录（`timestamp` 大者胜；同时间戳 `id` 大者胜）。
Map<String, PracticeRecord> latestRecordsByQuestion(
  Iterable<PracticeRecord> records,
) {
  final latest = <String, PracticeRecord>{};
  for (final r in records) {
    final existing = latest[r.questionId];
    if (existing == null ||
        r.timestamp > existing.timestamp ||
        (r.timestamp == existing.timestamp &&
            (r.id ?? 0) > (existing.id ?? 0))) {
      latest[r.questionId] = r;
    }
  }
  return latest;
}

/// 「已做过」的题 id：最新一条记录是 correct / wrong（unanswered 不算）。
Set<String> answeredQuestionIds(Iterable<PracticeRecord> records) => {
  for (final entry in latestRecordsByQuestion(records).entries)
    if (entry.value.status.isDecided) entry.key,
};

/// 按模式选取并排序题单。
///
/// - [candidates]：顺序 / 随机 / 考试 = 题库内全部题（调用方按题库顺序给出）；
///   错题本 / 收藏 = 按 [orderedIds] 取回的题（取回顺序不限，这里会重排）。
/// - [orderedIds]：错题本（最近答错在前）/ 收藏（收藏先后）的 id 顺序。
/// - [records]：本题库的作答记录，仅 `random + randomCount` 用来排除已做题。
List<Question> selectPracticeQuestions({
  required PracticeMode mode,
  required String bankId,
  required List<Question> candidates,
  List<String> orderedIds = const [],
  List<PracticeRecord> records = const [],
  PracticeLoadOptions options = const PracticeLoadOptions(),
  math.Random? random,
}) {
  var qs = [...candidates];

  if (options.typeFilter != null) {
    qs = qs.where((q) => q.type == options.typeFilter).toList();
  }

  if (mode == PracticeMode.wrong || mode == PracticeMode.favorite) {
    final order = <String, int>{
      for (final (i, id) in orderedIds.indexed) id: i,
    };
    qs = qs.where((q) => q.bankId == bankId).toList();
    final indexed = [for (final (i, q) in qs.indexed) (i, q)];
    indexed.sort((a, b) {
      final c = (order[a.$2.id] ?? 0).compareTo(order[b.$2.id] ?? 0);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    qs = [for (final e in indexed) e.$2];
  }

  final shouldShuffle =
      options.shuffle ??
      (mode == PracticeMode.random || mode == PracticeMode.exam);
  if (shouldShuffle && qs.length > 1) {
    qs = shuffleList(qs, random: random);
  }

  final randomCount = options.randomCount;
  if (mode == PracticeMode.random && randomCount != null && randomCount > 0) {
    final answered = answeredQuestionIds(records);
    if (answered.isNotEmpty) {
      qs = qs.where((q) => !answered.contains(q.id)).toList();
    }
    qs = qs.take(randomCount).toList();
  }

  final examCount = options.examCount;
  if (mode == PracticeMode.exam && examCount != null && examCount > 0) {
    qs = qs.take(examCount).toList();
  }

  return qs;
}
