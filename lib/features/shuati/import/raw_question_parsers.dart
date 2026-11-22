/// 各文件格式 → [RawQuestion]（PWA `importService.ts` 的 JSON / CSV / 表格 / 旧文本解析）。
library;

import '../domain/js_compat.dart';
import '../domain/question_text_parser.dart' show extractOptionExplanationLine;
import '../domain/question_type.dart';
import '../domain/shuati_models.dart';
import 'import_models.dart';
import 'question_normalizer.dart';

// ============ JSON ============

/// JSON 解析结果。
class JsonParseOutcome {
  const JsonParseOutcome({
    required this.questions,
    required this.rejections,
    required this.total,
    this.bankName,
  });

  final List<RawQuestion> questions;
  final List<ImportRejection> rejections;

  /// 源数组元素总数。
  final int total;

  /// `{ name, questions: [...] }` 形态里的 `name`。
  final String? bankName;
}

/// PWA `importFromFile` 的 JSON 分支：根为数组，或含 `questions` 数组的对象
/// （此时 `name` 可作题库名）。其它形态抛 [ShuatiImportFailure]。
///
/// 与 PWA 的差异（有意）：PWA 遇到非对象元素 / 缺题干会直接抛 `TypeError` 让整个导入失败；
/// 这里只跳过该条并记入 [ImportRejection]。
JsonParseOutcome parseJsonQuestions(Object? data) {
  List<Object?> items;
  String? name;
  if (data is List) {
    items = data;
  } else if (data is Map && data['questions'] is List) {
    items = (data['questions'] as List).cast<Object?>();
    final n = data['name'];
    if (n is String && n.isNotEmpty) name = n;
  } else {
    throw const ShuatiImportFailure(
      ShuatiImportFailureCode.invalidJsonShape,
      'JSON 格式不正确，需要是数组或包含 questions 字段的对象',
    );
  }

  final questions = <RawQuestion>[];
  final rejections = <ImportRejection>[];
  for (final (i, item) in items.indexed) {
    final result = _rawFromJson(item);
    if (result.raw != null) {
      questions.add(result.raw!);
    } else {
      rejections.add(ImportRejection(i, result.reason!));
    }
  }
  return JsonParseOutcome(
    questions: questions,
    rejections: rejections,
    total: items.length,
    bankName: name,
  );
}

({RawQuestion? raw, ImportRejectionReason? reason}) _rawFromJson(Object? item) {
  if (item is! Map) {
    return (raw: null, reason: ImportRejectionReason.notAnObject);
  }
  final question = jsonScalarToString(item['question']);
  if (question == null || jsTrim(question).isEmpty) {
    return (raw: null, reason: ImportRejectionReason.missingQuestionText);
  }

  final options = item['options'];
  Map<String, String>? optionsMap;
  List<String>? optionsList;
  if (options is Map) {
    optionsMap = _scalarMap(options);
    if (optionsMap == null) {
      return (raw: null, reason: ImportRejectionReason.invalidOptions);
    }
  } else if (options is List) {
    optionsList = _scalarList(options, strict: true);
    if (optionsList == null) {
      return (raw: null, reason: ImportRejectionReason.invalidOptions);
    }
  } else if (options != null) {
    return (raw: null, reason: ImportRejectionReason.invalidOptions);
  }

  final answerRaw = item['answer'];
  final List<String> answer;
  if (answerRaw is List) {
    answer = _scalarList(answerRaw, strict: false) ?? const [];
  } else {
    final s = jsonScalarToString(answerRaw);
    answer = s == null ? const [] : [s];
  }

  final idRaw = item['id'];
  final id = idRaw is String || idRaw is num ? jsonScalarToString(idRaw) : null;

  final explanations = item['optionExplanations'] ?? item['explanations'];
  Map<String, String>? explMap;
  List<String>? explList;
  if (explanations is Map) {
    explMap = _scalarMap(explanations, strict: false);
  } else if (explanations is List) {
    explList = _scalarList(explanations, strict: false);
  }

  final tags = item['tags'];
  return (
    raw: RawQuestion(
      id: id != null && id.isNotEmpty ? id : null,
      type: item['type'] is String ? item['type'] as String : null,
      question: question,
      optionsMap: optionsMap,
      optionsList: optionsList,
      answer: answer,
      explanation: item['explanation'] is String
          ? item['explanation'] as String
          : null,
      optionExplanationsMap: explMap,
      optionExplanationsList: explList,
      tags: tags is List ? _scalarList(tags, strict: false) : null,
    ),
    reason: null,
  );
}

Map<String, String>? _scalarMap(
  Map<dynamic, dynamic> map, {
  bool strict = true,
}) {
  final result = <String, String>{};
  for (final e in map.entries) {
    final key = e.key;
    if (key is! String) continue;
    final text = jsonScalarToString(e.value);
    if (text == null) {
      if (strict) return null;
      continue;
    }
    result[key] = text;
  }
  return result;
}

List<String>? _scalarList(List<dynamic> list, {required bool strict}) {
  final result = <String>[];
  for (final item in list) {
    final text = jsonScalarToString(item);
    if (text == null) {
      if (strict) return null;
      continue;
    }
    result.add(text);
  }
  return result;
}

// ============ CSV ============

/// PWA `parseCSVRows`：逗号分隔、双引号包裹、`""` 转义、`\n` 换行，**丢弃所有 `\r`**。
/// 末尾行仅在含非空白单元格时保留。
List<List<String>> parseCsvRows(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    final next = i + 1 < text.length ? text[i + 1] : null;

    if (inQuotes) {
      if (char == '"' && next == '"') {
        field.write('"');
        i++;
      } else if (char == '"') {
        inQuotes = false;
      } else {
        field.write(char);
      }
      continue;
    }

    if (char == '"') {
      inQuotes = true;
    } else if (char == ',') {
      row.add(field.toString());
      field.clear();
    } else if (char == '\n') {
      row.add(field.toString());
      rows.add(row);
      row = <String>[];
      field.clear();
    } else if (char != '\r') {
      field.write(char);
    }
  }

  row.add(field.toString());
  if (row.any((cell) => jsTrim(cell).isNotEmpty)) rows.add(row);
  return rows;
}

// ============ 表格行（CSV / Excel 共用） ============

final RegExp _optionHeader = RegExp(r'^(?:选项)?([A-Za-z])$');
final RegExp _cnOptionExplainHeader1 = RegExp(
  r'^(?:选项\s*)?([A-Za-z])\s*(?:项)?\s*(?:解析|解释|说明|分析)$',
);
final RegExp _cnOptionExplainHeader2 = RegExp(
  r'^(?:解析|解释|说明|分析)\s*(?:选项\s*)?([A-Za-z])$',
);
final RegExp _enOptionExplainHeader1 = RegExp(
  r'^(?:option[\s_-]*)?([a-z])[\s_-]*(?:explanation|analysis)$',
);
final RegExp _enOptionExplainHeader2 = RegExp(
  r'^(?:explanation|analysis)[\s_-]*(?:option[\s_-]*)?([a-z])$',
);

String? _parseOptionExplanationHeader(String headerCell) {
  final cell = jsTrim(headerCell);
  final cn =
      _cnOptionExplainHeader1.firstMatch(cell) ??
      _cnOptionExplainHeader2.firstMatch(cell);
  if (cn != null) return cn[1]!.toUpperCase();
  final lower = cell.toLowerCase();
  final en =
      _enOptionExplainHeader1.firstMatch(lower) ??
      _enOptionExplainHeader2.firstMatch(lower);
  return en?[1]!.toUpperCase();
}

/// PWA `parseRows`。[data] 的单元格可为 `null`（空）/ 字符串；调用方负责把数字等转成
/// JS 风格字符串。
///
/// 表头判定：首行任一单元格（小写后）含 `question` / `题目` / `题干` / `answer` / `答案`；
/// 无表头时列约定为 `题干, 选项A.., 答案, 解析`（**答案 / 解析取最后两列**，所以无表头文件
/// 必须同时有这两列）。选项列：表头里的 `A` / `选项A`，无表头时第 2 列起到答案列之前。
List<RawQuestion> parseRows(List<List<String?>> data) {
  final rows = [
    for (final row in data) [for (final cell in row) jsTrim(cell ?? '')],
  ].where((row) => row.any((cell) => cell.isNotEmpty)).toList();
  if (rows.isEmpty) return const [];

  final header = [for (final cell in rows[0]) cell.toLowerCase()];
  final hasHeader = header.any(
    (cell) =>
        cell.contains('question') ||
        cell.contains('题目') ||
        cell.contains('题干') ||
        cell.contains('answer') ||
        cell.contains('答案'),
  );
  final startIndex = hasHeader ? 1 : 0;

  int findHeaderIndex(List<RegExp> patterns) {
    if (!hasHeader) return -1;
    return header.indexWhere((cell) => patterns.any((p) => p.hasMatch(cell)));
  }

  final questionIdxRaw = findHeaderIndex([
    RegExp('question'),
    RegExp('题目'),
    RegExp('题干'),
  ]);
  final questionIdx = questionIdxRaw < 0 ? 0 : questionIdxRaw;
  final answerHeaderIdx = findHeaderIndex([RegExp('answer'), RegExp('答案')]);
  final explanationHeaderIdx = findHeaderIndex([
    RegExp('explanation'),
    RegExp('解析'),
    RegExp('解释'),
    RegExp('分析'),
  ]);
  final typeHeaderIdx = findHeaderIndex([RegExp(r'^type$'), RegExp('题型')]);

  final optionHeaderMap = <int, String>{};
  final optionExplanationHeaderMap = <int, String>{};
  if (hasHeader) {
    for (final (index, cell) in rows[0].indexed) {
      final normalized = jsTrim(cell);
      final match = _optionHeader.firstMatch(normalized);
      if (match != null) optionHeaderMap[index] = match[1]!.toUpperCase();
      final key = _parseOptionExplanationHeader(normalized);
      if (key != null) optionExplanationHeaderMap[index] = key;
    }
  }

  final questions = <RawQuestion>[];
  for (var i = startIndex; i < rows.length; i++) {
    final cols = rows[i];
    if (cols.length < 2) continue;

    String cell(int index) =>
        index >= 0 && index < cols.length ? cols[index] : '';

    final answerIdx = answerHeaderIdx >= 0 ? answerHeaderIdx : cols.length - 2;
    final explanationIdx = explanationHeaderIdx >= 0
        ? explanationHeaderIdx
        : cols.length - 1;
    final question = cell(questionIdx);
    if (question.isEmpty) continue;

    final options = <String, String>{};
    final optionExplanations = <String, String>{};

    if (optionHeaderMap.isNotEmpty) {
      for (final e in optionHeaderMap.entries) {
        final value = cell(e.key);
        if (value.isNotEmpty) options[e.value] = value;
      }
    } else {
      for (var j = 1; j < answerIdx; j++) {
        final value = cell(j);
        if (value.isNotEmpty) options[String.fromCharCode(64 + j)] = value;
      }
    }

    for (final e in optionExplanationHeaderMap.entries) {
      final value = cell(e.key);
      if (value.isNotEmpty) optionExplanations[e.value] = value;
    }

    final answer = parseAnswerText(cell(answerIdx), options.isNotEmpty);
    final explanation = cell(explanationIdx);
    final typeFromHeader = typeHeaderIdx >= 0 ? cell(typeHeaderIdx) : null;
    final type =
        QuestionType.tryParse(typeFromHeader)?.name ??
        inferQuestionType(
          answer,
          options: options.isNotEmpty ? options : null,
          question: question,
        ).name;

    questions.add(
      RawQuestion(
        question: question,
        optionsMap: options.isNotEmpty ? options : null,
        answer: answer.isNotEmpty ? answer : const [''],
        explanation: explanation.isNotEmpty ? explanation : null,
        optionExplanationsMap: optionExplanations.isNotEmpty
            ? optionExplanations
            : null,
        type: type,
      ),
    );
  }
  return questions;
}

// ============ 旧文本解析（txt / md 兜底） ============

final RegExp _legacyBlockSplit = RegExp(r'\n\s*(?=\d+[.、．)）]\s)');
final RegExp _legacyNumberPrefix = RegExp(r'^\d+[.、．)）]\s*');
final RegExp _legacyOption = RegExp(r'^([A-Za-z])[.、．:：\s]\s*(.*)');
final RegExp _legacyAnswer = RegExp(r'^(答案|正确答案)[：:]\s*(.*)');
final RegExp _legacyExplanation = RegExp(r'^(解析|解释|分析)[：:]\s*(.*)');

/// PWA `importService.parseTextQuestions`：`parseTextToQuestions` 一道题都没解析出来时
/// 对 txt / md 的兜底（要求独占一行的 `答案：` / `A.` 选项等）。
List<RawQuestion> parseLegacyTextQuestions(String text) {
  final questions = <RawQuestion>[];
  final blocks = text
      .split(_legacyBlockSplit)
      .where((b) => jsTrim(b).isNotEmpty);

  for (final block in blocks) {
    final lines = jsTrim(block)
        .split('\n')
        .map(jsTrim)
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) continue;

    final question = lines[0].replaceFirst(_legacyNumberPrefix, '');

    final options = <String, String>{};
    final optionExplanations = <String, String>{};
    var answerLine = '';
    var explanationLine = '';
    final otherLines = <String>[];

    for (var i = 1; i < lines.length; i++) {
      final line = lines[i];
      final optMatch = _legacyOption.firstMatch(line);
      final ansMatch = _legacyAnswer.firstMatch(line);
      final expMatch = _legacyExplanation.firstMatch(line);
      final optionExp = extractOptionExplanationLine(line);

      if (optMatch != null) {
        options[optMatch[1]!.toUpperCase()] = optMatch[2]!;
      } else if (ansMatch != null) {
        answerLine = ansMatch[2]!;
      } else if (optionExp.key.isNotEmpty && optionExp.explanation.isNotEmpty) {
        optionExplanations[optionExp.key] = optionExp.explanation;
      } else if (expMatch != null) {
        explanationLine = expMatch[2]!;
      } else {
        otherLines.add(line);
      }
    }

    var answer = const <String>[];
    if (answerLine.isNotEmpty) {
      answer = parseAnswerText(answerLine, options.isNotEmpty);
    }

    var type = QuestionType.single;
    if (answer.length == 1 && (answer[0] == 'true' || answer[0] == 'false')) {
      type = QuestionType.judge;
    } else if (answer.length > 1) {
      type = QuestionType.multiple;
    } else if (options.isEmpty) {
      type = answer.isNotEmpty ? QuestionType.blank : QuestionType.short;
    }

    if (question.isNotEmpty) {
      final explanation = explanationLine.isNotEmpty
          ? explanationLine
          : (otherLines.isNotEmpty ? otherLines.join('\n') : null);
      questions.add(
        RawQuestion(
          question: question,
          answer: answer.isNotEmpty ? answer : const [''],
          explanation: explanation,
          type: type.name,
          optionsMap: options.isNotEmpty ? options : null,
          optionExplanationsMap: optionExplanations.isNotEmpty
              ? optionExplanations
              : null,
        ),
      );
    }
  }
  return questions;
}
