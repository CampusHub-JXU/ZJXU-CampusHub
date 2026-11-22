/// 题型推断与判断题答案规范化（PWA `questionParser.ts` 的 `inferQuestionType`
/// 与 `importService.ts` 的 `parseAnswerText` 判断题分支）。
library;

import 'js_compat.dart';
import 'shuati_models.dart';

final RegExp _trueLiteral = RegExp(
  r'^(对|正确|√|T|true|是)$',
  caseSensitive: false,
);
final RegExp _falseLiteral = RegExp(
  r'^(错|不正确|错误|×|F|false|否)$',
  caseSensitive: false,
);

/// 判断题答案文本 → `'true'` / `'false'`；不是判断题字面量返回 `null`。
String? parseJudgeLiteral(String cleaned) {
  if (_trueLiteral.hasMatch(cleaned)) return 'true';
  if (_falseLiteral.hasMatch(cleaned)) return 'false';
  return null;
}

/// 解析备份 / JSON 里的 `type` 字段。
///
/// **与 PWA 一致**：只认 5 个规范取值（区分大小写）。README 里写的旧别名
/// `fill` / `text` 在 PWA 源码里并不存在映射，会落到 [inferQuestionType]
/// 重新推断（有选项 → 单/多选；含 `____` / `（）` → 填空；否则简答）。
QuestionType? parseQuestionTypeStrict(Object? raw) =>
    QuestionType.tryParse(raw);

/// PWA `inferQuestionType(answer, options?, question?)`。
///
/// 判断题：答案恰为一个 `'true'` / `'false'`；有（非空）选项：多答案为多选、
/// 否则单选；题干含 `____` / `（  ）`（两个空格）/ `（）` 为填空；其余为简答。
QuestionType inferQuestionType(
  List<String> answer, {
  Map<String, String>? options,
  String question = '',
}) {
  if (answer.length == 1 && (answer[0] == 'true' || answer[0] == 'false')) {
    return QuestionType.judge;
  }
  if (options != null && options.isNotEmpty) {
    return answer.length > 1 ? QuestionType.multiple : QuestionType.single;
  }
  if (_looksLikeBlank(question)) return QuestionType.blank;
  return QuestionType.short;
}

bool _looksLikeBlank(String question) =>
    question.contains('____') ||
    question.contains('（  ）') ||
    question.contains('（）');

/// 填空 / 简答题用户输入 → 提交答案（空白输入 → 空答案，不可提交）。
List<String> blankInputToAnswer(String input) {
  final trimmed = jsTrim(input);
  return trimmed.isEmpty ? const [] : [trimmed];
}
