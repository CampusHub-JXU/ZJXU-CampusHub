/// 错题本规则。
///
/// PWA 有两套概念，**必须区分**：
///
/// 1. **永久错题本**（`wrongQuestions` 表，`practiceAnswerService` 写入）——
///    当前 UI 真正使用的：每次保存一条 `wrong` 记录就 upsert 一行并 `wrongCount + 1`；
///    **之后答对不会移除**（`removeWrongQuestion` 仅在显式调用时才删，PWA UI 里没有入口）。
///    见 [markWrong]、[sortWrongQuestionEntries]。
/// 2. **「按最新一次作答」的派生错题**（`domain/wrongQuestion.ts`）——
///    PWA 目前只有单测在用，生产路径不用；保留为 [getCurrentWrongQuestionIds]
///    供迁移 / 校验使用。
library;

import 'js_compat.dart';
import 'shuati_models.dart';

/// 每道题以最新一次**有效**作答（correct / wrong）为准，最新为 wrong 才算错题。
///
/// 记录先按 `timestamp` 再按 `id` 升序处理；`unanswered` 不覆盖之前的状态。
/// 返回顺序为各题「最后一次有效作答」的首次出现顺序（与 JS `Map` 插入序一致）。
List<String> getCurrentWrongQuestionIds(List<PracticeRecord> records) {
  final ordered = stableSorted<PracticeRecord>(records, (a, b) {
    final byTime = a.timestamp.compareTo(b.timestamp);
    if (byTime != 0) return byTime;
    return (a.id ?? 0).compareTo(b.id ?? 0);
  });
  final latest = <String, AnswerStatus>{};
  for (final record in ordered) {
    if (record.status.isDecided) {
      latest[record.questionId] = record.status;
    }
  }
  return [
    for (final entry in latest.entries)
      if (entry.value == AnswerStatus.wrong) entry.key,
  ];
}

/// 对永久错题本的一次「答错」标记（PWA `markWrongQuestion` 的纯函数部分）。
///
/// - 无既有行：新建 `wrongCount = 1`，`firstWrongAt = lastWrongAt = timestamp`；
/// - 有既有行：`lastWrongAt = timestamp`，`wrongCount = max(1, 旧值 || 1) + 1`，
///   `lastRecordId` **被本次值覆盖**（PWA 传 `undefined` 时同样清空）。
PermanentWrongQuestion markWrong({
  required String bankId,
  required String questionId,
  required int timestamp,
  PermanentWrongQuestion? existing,
  int? lastRecordId,
}) {
  if (existing == null) {
    return PermanentWrongQuestion(
      bankId: bankId,
      questionId: questionId,
      firstWrongAt: timestamp,
      lastWrongAt: timestamp,
      wrongCount: 1,
      lastRecordId: lastRecordId,
    );
  }
  final previous = existing.wrongCount <= 0 ? 1 : existing.wrongCount;
  return PermanentWrongQuestion(
    id: existing.id,
    bankId: existing.bankId,
    questionId: existing.questionId,
    firstWrongAt: existing.firstWrongAt,
    lastWrongAt: timestamp,
    wrongCount: previous + 1,
    lastRecordId: lastRecordId,
  );
}

/// 永久错题排序：最近答错在前，同时间按自增 id 倒序。
List<PermanentWrongQuestion> sortWrongQuestionEntries(
  Iterable<PermanentWrongQuestion> entries,
) {
  return stableSorted<PermanentWrongQuestion>(entries, (a, b) {
    final byTime = b.lastWrongAt.compareTo(a.lastWrongAt);
    if (byTime != 0) return byTime;
    return (b.id ?? 0).compareTo(a.id ?? 0);
  });
}

final RegExp _whitespaceRun = RegExp(r'\s+');

/// PWA `wrongQuestionService.normalizeSearchText`。
String normalizeSearchText(String value) =>
    jsTrim(value).toLowerCase().replaceAll(_whitespaceRun, ' ');

/// 搜索范围：题干、答案、标签、各选项文本（空白折叠后包含查询，忽略大小写）。
bool matchesWrongQuery(Question question, String query) {
  final normalizedQuery = normalizeSearchText(query);
  if (normalizedQuery.isEmpty) return true;
  final searchable = [
    question.question,
    question.answer.join(' '),
    ...?question.tags,
    ...?question.options?.values,
  ].join(' ');
  return normalizeSearchText(searchable).contains(normalizedQuery);
}

/// 错题本列表项：题目 + 永久错题条目。
class WrongQuestionListItem {
  const WrongQuestionListItem({required this.question, required this.entry});

  final Question question;
  final PermanentWrongQuestion entry;
}
