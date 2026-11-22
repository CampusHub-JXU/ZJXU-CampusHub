/// 导入题目的规范化（PWA `importService.ts` 的 `normalizeQuestion` 及其辅助函数）。
library;

import '../domain/js_compat.dart';
import '../domain/question_text_parser.dart'
    show ParsedQuestion, inferParsedQuestionType, normalizeExplanationKey;
import '../domain/question_type.dart';
import '../domain/shuati_models.dart';

/// 各解析器的统一中间表示（PWA `RawQuestion`）。
class RawQuestion {
  const RawQuestion({
    required this.question,
    required this.answer,
    this.id,
    this.type,
    this.optionsMap,
    this.optionsList,
    this.explanation,
    this.optionExplanationsMap,
    this.optionExplanationsList,
    this.tags,
  });

  /// 由文本解析结果构造（PWA `parsed.map(q => ({..., type: q.type || inferQuestionType(q)}))`）。
  factory RawQuestion.fromParsed(ParsedQuestion q) => RawQuestion(
    question: q.question,
    optionsMap: q.options,
    answer: q.answer,
    explanation: q.explanation,
    optionExplanationsMap: q.optionExplanations,
    type: (q.type ?? inferParsedQuestionType(q)).name,
  );

  final String? id;

  /// 原始 `type` 字符串；只有恰为 5 个规范取值之一才被采信。
  final String? type;
  final String question;

  /// `{A: "xxx"}` 形态。
  final Map<String, String>? optionsMap;

  /// `["A. xxx", "B. yyy"]` 或 `["xxx", "yyy"]` 形态。
  final List<String>? optionsList;
  final List<String> answer;
  final String? explanation;
  final Map<String, String>? optionExplanationsMap;
  final List<String>? optionExplanationsList;
  final List<String>? tags;
}

final RegExp _answerPrefix = RegExp(
  r'^(答案|正确答案|answer|答)\s*[：:]\s*',
  caseSensitive: false,
);
final RegExp _trailingPunct = RegExp(r'[。.;；]+$');
final RegExp _answerSeparator = RegExp(r'[、，,\s]');
final RegExp _ascii = RegExp(r'[A-Za-z]');
final RegExp _optionPrefix = RegExp(r'^([A-Za-z])[.、．:：\s]\s*(.*)');

String _normalizeAnswerText(String raw) => jsTrim(
  jsTrim(raw).replaceFirst(_answerPrefix, '').replaceAll(_trailingPunct, ''),
);

/// PWA `parseAnswerText(raw, hasOptions)`：
/// 判断题字面量 → `['true']` / `['false']`；有选项 → 逐字母拆分并大写；否则整体作为答案文本。
List<String> parseAnswerText(String raw, bool hasOptions) {
  final cleaned = _normalizeAnswerText(raw);
  if (cleaned.isEmpty) return const [];

  final judge = parseJudgeLiteral(cleaned);
  if (judge != null) return [judge];

  if (!hasOptions) return [cleaned];

  final compact = cleaned.replaceAll(_answerSeparator, '');
  return [
    for (final ch in compact.split(''))
      if (_ascii.hasMatch(ch)) ch.toUpperCase(),
  ];
}

Map<String, String>? _normalizeOptionExplanations(RawQuestion raw) {
  final entries = <MapEntry<String, String>>[];
  final list = raw.optionExplanationsList;
  final map = raw.optionExplanationsMap;
  if (list != null) {
    for (final (i, value) in list.indexed) {
      entries.add(MapEntry(String.fromCharCode(65 + i), value));
    }
  } else if (map != null) {
    entries.addAll(map.entries);
  } else {
    return null;
  }
  final normalized = <String, String>{};
  for (final e in entries) {
    final value = jsTrim(e.value);
    if (value.isEmpty) continue;
    normalized[normalizeExplanationKey(e.key)] = value;
  }
  return normalized.isEmpty ? null : normalized;
}

Map<String, String>? _normalizeOptions(RawQuestion raw) {
  final list = raw.optionsList;
  if (list != null) {
    final options = <String, String>{};
    for (final (i, opt) in list.indexed) {
      final match = _optionPrefix.firstMatch(opt);
      if (match != null) {
        options[match[1]!.toUpperCase()] = match[2]!;
      } else {
        options[String.fromCharCode(65 + i)] = opt;
      }
    }
    return options;
  }
  final map = raw.optionsMap;
  if (map != null) {
    return {for (final e in map.entries) e.key.toUpperCase(): e.value};
  }
  return null;
}

/// PWA `normalizeQuestion(raw, bankId)`。
///
/// - 答案：逐项 `trim` 并丢空；
/// - 选项：数组形态按 `A.` / `A、` 前缀取键，无前缀则按下标 A、B、C…；Map 形态键转大写；
/// - 题型：`raw.type` 为规范取值才采信，否则 [inferQuestionType]；
/// - 单 / 多选答案转大写；判断题答案经 [parseAnswerText] 规范成 `true` / `false`；
/// - id：沿用 `raw.id`，缺省由 [newId] 生成；`tags` 缺省为空数组。
Question normalizeQuestion(
  RawQuestion raw,
  String bankId, {
  required String Function() newId,
}) {
  var answer = [
    for (final a in raw.answer)
      if (jsTrim(a).isNotEmpty) jsTrim(a),
  ];

  final options = _normalizeOptions(raw);

  final type =
      QuestionType.tryParse(raw.type) ??
      inferQuestionType(answer, options: options, question: raw.question);
  if (type == QuestionType.single || type == QuestionType.multiple) {
    answer = [for (final a in answer) a.toUpperCase()];
  } else if (type == QuestionType.judge) {
    answer = parseAnswerText(answer.isEmpty ? '' : answer[0], false);
  }

  final rawId = raw.id;
  return Question(
    id: rawId != null && rawId.isNotEmpty ? rawId : newId(),
    bankId: bankId,
    type: type,
    question: raw.question,
    options: options,
    answer: answer,
    explanation: raw.explanation,
    optionExplanations: _normalizeOptionExplanations(raw),
    tags: raw.tags ?? const [],
  );
}
