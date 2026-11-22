/// 题目指纹 / 去重 hash（PWA `src/domain/questionFingerprint.ts`）。
///
/// **必须与 PWA 逐位一致**：旧用户的备份里已经带着 PWA 算好的
/// `contentHash` / `answerHash`，原生再次导入同一题库时靠它们判重。
/// 因此规范化规则、选项排序、拼接分隔符、SHA-256 十六进制输出都原样照搬。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'js_compat.dart';
import 'shuati_models.dart';

final RegExp _whitespaceRun = RegExp(r'\s+');
final RegExp _cjkPunctuation = RegExp('[，。；：]');

String _normalizeText(String s) {
  final collapsed = jsTrim(s).replaceAll(_whitespaceRun, ' ');
  return collapsed.replaceAllMapped(_cjkPunctuation, (m) {
    switch (m[0]) {
      case '，':
        return ',';
      case '。':
        return '.';
      case '；':
        return ';';
      case '：':
        return ':';
    }
    return m[0]!;
  });
}

/// 内容键：`type \n 规范化题干 \n 选项(按 key localeCompare 升序, k:v 以 | 连接)`。
String buildContentKey(Question q) {
  final options = q.options;
  var optionPart = '';
  if (options != null) {
    final entries = options.entries.toList()
      ..sort((a, b) => jsLocaleCompare(a.key, b.key));
    optionPart = entries
        .map((e) => '${e.key}:${_normalizeText(e.value)}')
        .join('|');
  }
  return [q.type.name, _normalizeText(q.question), optionPart].join('\n');
}

/// 答案键：答案按 UTF-16 码元序排序后以逗号连接（**不** trim / 不转小写）。
String buildAnswerKey(Question q) {
  final sorted = [...q.answer]..sort();
  return sorted.join(',');
}

/// SHA-256（UTF-8）→ 64 位小写十六进制。
String sha256Hex(String text) => sha256.convert(utf8.encode(text)).toString();

/// 为题目补 `contentHash` / `answerHash`（覆盖已有值，与 PWA 一致）。
Question attachQuestionHash(Question q) => q.copyWith(
  contentHash: sha256Hex(buildContentKey(q)),
  answerHash: sha256Hex(buildAnswerKey(q)),
);

/// PWA `attachQuestionHashes`。
List<Question> attachQuestionHashes(List<Question> questions) => [
  for (final q in questions) attachQuestionHash(q),
];
