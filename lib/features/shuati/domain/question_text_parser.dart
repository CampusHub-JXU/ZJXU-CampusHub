/// 纯文本题库解析器（PWA `src/domain/questionParser.ts` 的 1:1 移植，纯函数）。
///
/// 供 `.docx`（提取出的纯文本）/ `.txt` / `.md` 导入使用。支持格式：
///
/// ```text
/// 1、题目内容（ ）。正确答案：A
/// A、 选项A
/// B、 选项B
///
/// 1、题目内容。答案：B A、选项A B、选项B ...
/// ```
library;

import 'js_compat.dart';
import 'question_type.dart';
import 'shuati_models.dart';

/// 解析出的题目（尚未规范化 / 未赋 id）。
class ParsedQuestion {
  const ParsedQuestion({
    required this.question,
    required this.answer,
    this.options,
    this.explanation,
    this.optionExplanations,
    this.type,
  });

  final String question;
  final Map<String, String>? options;
  final List<String> answer;
  final String? explanation;
  final Map<String, String>? optionExplanations;
  final QuestionType? type;
}

const String _answerKeyword = r'(?:\(?正确\)?答案|答案|answer|答)';
const String _explainKeyword = r'(?:解析|解释|说明|分析)';

final RegExp _questionNumberPattern = RegExp(
  r'^(?:第\s*)?\d+\s*(?:[.、．)）]|题)\s*',
);
final RegExp _answerPattern = RegExp(
  '$_answerKeyword'
  r'\s*[：:]\s*(.*?)(?=\s+[A-Za-z][.、．:：]\s|\s*'
  '$_explainKeyword'
  r'\s*[：:]|$)',
  caseSensitive: false,
);
final RegExp _explanationPattern = RegExp(
  '$_explainKeyword'
  r'\s*[：:]\s*(.*)$',
  caseSensitive: false,
);
final RegExp _answerTail = RegExp(
  '$_answerKeyword'
  r'\s*[：:]\s*(.+)',
  caseSensitive: false,
);
final RegExp _chapterHeading = RegExp(r'^[一二三四五六七八九十]+[、.．]\s*$');
final RegExp _optionLine = RegExp(r'^([A-Za-z])[.、．:：]\s*(.*)');
final RegExp _explanationLine = RegExp(r'^(解析|解释|说明|分析)\s*[：:]\s*(.*)');
final RegExp _inlineOption = RegExp(
  r'(^|\s)([A-Za-z])[.、．:：]\s*(.*?)(?=\s+[A-Za-z][.、．:：]\s|\s*(?:\(?正确\)?答案|答案|answer|答|解析|解释|说明|分析)\s*[：:]|$)',
);
final RegExp _leadingKeyExplanation = RegExp(
  r'^(?:选项\s*)?([A-Za-z]|正确|错误|对|错|true|false)\s*(?:项)?\s*(?:解析|解释|说明|分析)\s*[：:]\s*(.*)$',
  caseSensitive: false,
);
final RegExp _trailingKeyExplanation = RegExp(
  r'^(?:解析|解释|说明|分析)\s*(?:选项\s*)?([A-Za-z]|正确|错误|对|错|true|false)\s*[：:]\s*(.*)$',
  caseSensitive: false,
);
final RegExp _trailingPunctuation = RegExp(r'[。.;；]+$');
final RegExp _answerSeparators = RegExp(r'[、，,\s]+');
final RegExp _upperRun = RegExp(r'^[A-Z]{2,}$');
final RegExp _singleUpper = RegExp(r'^[A-Z]$');

// ============ 主入口 ============

/// PWA `parseTextToQuestions`。
///
/// 题干 < 4 个 UTF-16 码元、或没有答案的题被丢弃；章节标题行（`一、`）跳过。
List<ParsedQuestion> parseTextToQuestions(String text) {
  final lines = text
      .split('\n')
      .map(jsTrim)
      .where((l) => l.isNotEmpty)
      .toList(growable: false);

  final blocks = <List<String>>[];
  var currentBlock = <String>[];

  for (final line in lines) {
    if (_chapterHeading.hasMatch(line)) continue;

    final isNewQuestion = _questionNumberPattern.hasMatch(line);
    if (isNewQuestion && currentBlock.isNotEmpty) {
      blocks.add(currentBlock);
      currentBlock = [line];
    } else if (isNewQuestion) {
      currentBlock = [line];
    } else {
      currentBlock.add(line);
    }
  }
  if (currentBlock.isNotEmpty) blocks.add(currentBlock);

  final questions = <ParsedQuestion>[];
  for (final block in blocks) {
    final q = _parseBlock(block);
    if (q != null &&
        q.question.length >= 4 &&
        q.answer.isNotEmpty &&
        q.answer[0] != '') {
      questions.add(q);
    }
  }
  return questions;
}

// ============ 单个题目块 ============

ParsedQuestion? _parseBlock(List<String> lines) {
  if (lines.isEmpty) return null;

  final firstLine = lines[0];
  final parts = firstLine.split('\t');
  final questionPart = jsTrim(parts[0]);
  final answerPart = parts.length > 1 ? jsTrim(parts[1]) : '';

  var questionText = jsTrim(
    questionPart.replaceFirst(_questionNumberPattern, ''),
  );

  final options = <String, String>{};
  final optionExplanations = <String, String>{};
  var answerLine = '';
  var explanationLine = '';

  if (answerPart.isNotEmpty) {
    final m = _answerTail.firstMatch(answerPart);
    if (m != null) answerLine = jsTrim(m[1]!);
  }

  final inlineAnswer = _extractAnswer(questionText);
  if (answerLine.isEmpty && inlineAnswer.answer.isNotEmpty) {
    answerLine = inlineAnswer.answer;
  }
  questionText = inlineAnswer.text;

  final inlineExplanation = _extractExplanation(questionText);
  if (inlineExplanation.explanation.isNotEmpty) {
    explanationLine = inlineExplanation.explanation;
  }
  questionText = inlineExplanation.text;

  final inlineOptions = _extractInlineOptions(questionText);
  options.addAll(inlineOptions.options);
  questionText = inlineOptions.text;

  if (questionText.isEmpty) return null;

  for (var i = 1; i < lines.length; i++) {
    var line = lines[i];

    final lineAnswer = _extractAnswer(line);
    if (answerLine.isEmpty && lineAnswer.answer.isNotEmpty) {
      answerLine = lineAnswer.answer;
    }
    line = lineAnswer.text;

    final optionExplanation = _extractOptionExplanation(line);
    if (optionExplanation.key.isNotEmpty &&
        optionExplanation.explanation.isNotEmpty) {
      optionExplanations[optionExplanation.key] = optionExplanation.explanation;
      continue;
    }

    final lineExplanation = _extractExplanation(line);
    if (lineExplanation.explanation.isNotEmpty) {
      explanationLine = lineExplanation.explanation;
    }
    line = lineExplanation.text;

    final lineOptions = _extractInlineOptions(line);
    if (lineOptions.options.isNotEmpty) {
      options.addAll(lineOptions.options);
      continue;
    }

    final optMatch = _optionLine.firstMatch(line);
    if (optMatch != null) {
      options[optMatch[1]!.toUpperCase()] = jsTrim(optMatch[2]!);
      continue;
    }

    if (answerLine.isEmpty) {
      final ansMatch = _answerTail.firstMatch(line);
      if (ansMatch != null) {
        answerLine = jsTrim(ansMatch[1]!);
        continue;
      }
    }

    final expMatch = _explanationLine.firstMatch(line);
    if (expMatch != null) {
      explanationLine = jsTrim(expMatch[2]!);
      continue;
    }
  }

  final answer = _parseAnswer(answerLine);
  final cleaned = _cleanQuestion(questionText);

  return ParsedQuestion(
    question: cleaned,
    answer: answer.isNotEmpty ? answer : const [''],
    options: options.isNotEmpty ? options : null,
    explanation: explanationLine.isNotEmpty ? explanationLine : null,
    optionExplanations: optionExplanations.isNotEmpty
        ? optionExplanations
        : null,
  );
}

// ============ 答案 ============

List<String> _parseAnswer(String raw) {
  if (raw.isEmpty) return const [];

  final cleaned = jsTrim(raw.replaceAll(_trailingPunctuation, ''));

  final judge = parseJudgeLiteral(cleaned);
  if (judge != null) return [judge];

  if (_upperRun.hasMatch(cleaned)) {
    return (cleaned.split('')..sort());
  }

  final letters = <String>[];
  for (final part in cleaned.split(_answerSeparators)) {
    final upper = jsTrim(part).toUpperCase();
    if (_singleUpper.hasMatch(upper)) letters.add(upper);
  }
  if (letters.isNotEmpty) {
    return (letters.toSet().toList()..sort());
  }

  return [cleaned];
}

// ============ 题干清理 ============

String _cleanQuestion(String input) {
  var text = input;
  text = text.replaceAll(RegExp(r'[（(]\s*[）)]'), '____');
  text = text.replaceAll(RegExp(r'_{3,}'), '____');
  text = text.replaceFirst(RegExp(r'[（(]\s*$'), '');
  text = text.replaceFirst(RegExp(r'[。.，,]+$'), '');
  text = text
      .replaceAll('&quot;', '"')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
  return jsTrim(text);
}

({String text, String answer}) _extractAnswer(String text) {
  final match = _answerPattern.firstMatch(text);
  if (match == null) return (text: text, answer: '');
  return (
    text: jsTrim(text.replaceFirst(_answerPattern, '')),
    answer: jsTrim(match[1]!.replaceAll(_trailingPunctuation, '')),
  );
}

({String text, String explanation}) _extractExplanation(String text) {
  final match = _explanationPattern.firstMatch(text);
  if (match == null) return (text: text, explanation: '');
  return (
    text: jsTrim(text.replaceFirst(_explanationPattern, '')),
    explanation: jsTrim(match[1]!),
  );
}

/// 选项解析的键规范化：判断题的 正确/对/true/T/√/是 → `true`，错误/错/false/F/×/否 → `false`，
/// 其余转大写（PWA `normalizeExplanationKey`，导入服务共用）。
String normalizeExplanationKey(String raw) {
  final value = jsTrim(raw).toLowerCase();
  if (RegExp(r'^(正确|对|true|t|√|是)$').hasMatch(value)) return 'true';
  if (RegExp(r'^(错误|错|false|f|×|否)$').hasMatch(value)) return 'false';
  return jsTrim(raw).toUpperCase();
}

/// 一行是否为「A解析：…」/「解析A：…」形式的选项解析，返回 `(key, explanation)`；
/// 都不匹配返回空串对（PWA `extractOptionExplanation` / `extractOptionExplanationLine`）。
({String key, String explanation}) extractOptionExplanationLine(String text) {
  final leading = _leadingKeyExplanation.firstMatch(text);
  if (leading != null) {
    return (
      key: normalizeExplanationKey(leading[1]!),
      explanation: jsTrim(leading[2]!),
    );
  }
  final trailing = _trailingKeyExplanation.firstMatch(text);
  if (trailing != null) {
    return (
      key: normalizeExplanationKey(trailing[1]!),
      explanation: jsTrim(trailing[2]!),
    );
  }
  return (key: '', explanation: '');
}

({String key, String explanation}) _extractOptionExplanation(String text) =>
    extractOptionExplanationLine(text);

({String text, Map<String, String> options}) _extractInlineOptions(
  String text,
) {
  final options = <String, String>{};
  final cleaned = text.replaceAllMapped(_inlineOption, (m) {
    final leading = m[1]!;
    final key = m[2]!;
    final optionText = jsTrim(m[3]!);
    if (optionText.isEmpty) return m[0]!;
    options[key.toUpperCase()] = optionText;
    return leading.isNotEmpty ? ' ' : '';
  });
  return (text: jsTrim(cleaned), options: options);
}

// ============ 推断题型（ParsedQuestion 重载） ============

/// PWA `inferQuestionType(q: ParsedQuestion)`。
QuestionType inferParsedQuestionType(ParsedQuestion q) =>
    inferQuestionType(q.answer, options: q.options, question: q.question);
