/// 判分（PWA `src/domain/answerJudge.ts`）。
library;

import 'js_compat.dart';
import 'shuati_models.dart';

/// 比较用户答案和正确答案。
///
/// - 大小写不敏感（`trim` + `toLowerCase`）；
/// - 多选顺序无关（两边都排序）；
/// - 空白项被忽略；用户答案规范化后为空 → [AnswerStatus.unanswered]；
/// - 题库答案缺失 / 为空时只要用户答案非空即 [AnswerStatus.wrong]，不抛错。
AnswerStatus checkAnswer(Question question, List<String>? userAnswer) {
  final user = normalizeAnswers(userAnswer);
  if (user.isEmpty) return AnswerStatus.unanswered;

  final correct = normalizeAnswers(question.answer);
  if (correct.length != user.length) return AnswerStatus.wrong;
  for (var i = 0; i < correct.length; i++) {
    if (correct[i] != user[i]) return AnswerStatus.wrong;
  }
  return AnswerStatus.correct;
}

/// `String(a).trim().toLowerCase()`，丢弃空串，再按 UTF-16 码元序排序
/// （与 JS 默认 `Array.prototype.sort` 一致）。
List<String> normalizeAnswers(List<String>? answers) {
  if (answers == null) return const [];
  final normalized = <String>[];
  for (final answer in answers) {
    final value = jsTrim(answer).toLowerCase();
    if (value.isNotEmpty) normalized.add(value);
  }
  normalized.sort();
  return normalized;
}
