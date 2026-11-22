/// 导入的「纯计算」阶段：字节 → 规范化、带 hash 的 [Question] 列表。
///
/// 全部是顶层纯函数 + 可跨 isolate 传递的简单对象，因此 [runImportParse] 可以把
/// 数千题的解码 / 解析 / SHA-256 放进后台 isolate，不阻塞 UI 线程。
/// 不碰数据库：去重与落库在 `ShuatiImportService` 里。
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../domain/question_fingerprint.dart';
import '../domain/question_text_parser.dart';
import '../domain/shuati_models.dart';
import 'import_models.dart';
import 'office_readers.dart';
import 'question_normalizer.dart';
import 'raw_question_parsers.dart';
import 'safe_zip.dart';
import 'text_decoding.dart';

/// 题库文件大小上限（字节）。
const int kMaxImportFileBytes = 25 * 1024 * 1024;

/// 单个文件最多解析的条目数。
const int kMaxImportQuestions = 50000;

/// 报告里最多保留的逐条拒绝样例。
const int kMaxRejectionSamples = 50;

/// 解析请求（可跨 isolate）。
class ImportParseRequest {
  const ImportParseRequest({
    required this.bytes,
    required this.fileName,
    required this.format,
    required this.bankId,
    this.bankNameOverride,
  });

  final Uint8List bytes;
  final String fileName;
  final ShuatiImportFormat format;

  /// 题目归属的题库 id（新建或同源既有）。
  final String bankId;
  final String? bankNameOverride;
}

/// 解析结果（可跨 isolate）。失败时 [failureCode] 非空，其余字段为空值。
class ImportParseResult {
  const ImportParseResult({
    this.questions = const [],
    this.bankName = '',
    this.parsedCount = 0,
    this.rejections = const [],
    this.rejectionCounts = const {},
    this.invalid = 0,
    this.withoutAnswer = 0,
    this.decodedAsGbk = false,
    this.lossyDecoding = false,
    this.failureCode,
    this.failureMessage,
  });

  const ImportParseResult.failure(ShuatiImportFailureCode code, String message)
    : questions = const [],
      bankName = '',
      parsedCount = 0,
      rejections = const [],
      rejectionCounts = const {},
      invalid = 0,
      withoutAnswer = 0,
      decodedAsGbk = false,
      lossyDecoding = false,
      failureCode = code,
      failureMessage = message;

  final List<Question> questions;
  final String bankName;
  final int parsedCount;
  final List<ImportRejection> rejections;
  final Map<ImportRejectionReason, int> rejectionCounts;
  final int invalid;
  final int withoutAnswer;
  final bool decodedAsGbk;
  final bool lossyDecoding;
  final ShuatiImportFailureCode? failureCode;
  final String? failureMessage;
}

/// 在后台 isolate（或当前 isolate，测试用）里解析。
Future<ImportParseResult> runImportParse(
  ImportParseRequest request, {
  bool useIsolate = true,
}) {
  if (!useIsolate) return Future.value(parseImportBytes(request));
  return Isolate.run(() => parseImportBytes(request));
}

/// PWA `importFromFile` 的解析 + 规范化 + 哈希部分（见 docs/shuati-native-parity.md §4）。
ImportParseResult parseImportBytes(ImportParseRequest req) {
  try {
    return _parse(req);
  } on ShuatiImportFailure catch (e) {
    return ImportParseResult.failure(e.code, e.message);
  } on SafeZipException catch (e) {
    return ImportParseResult.failure(
      ShuatiImportFailureCode.corruptArchive,
      '文件已损坏或不是有效的 Office 文档（${e.message}）',
    );
  }
}

ImportParseResult _parse(ImportParseRequest req) {
  if (req.bytes.isEmpty) {
    throw const ShuatiImportFailure(ShuatiImportFailureCode.emptyFile, '文件为空');
  }
  if (req.bytes.length > kMaxImportFileBytes) {
    throw const ShuatiImportFailure(
      ShuatiImportFailureCode.fileTooLarge,
      '文件过大（上限 25 MB）',
    );
  }

  var decodedAsGbk = false;
  var lossy = false;
  String? jsonName;
  var rawQuestions = <RawQuestion>[];
  final rejections = <ImportRejection>[];
  final rejectionCounts = <ImportRejectionReason, int>{};
  var parsedCount = 0;

  void noteRejection(int index, ImportRejectionReason reason) {
    rejectionCounts[reason] = (rejectionCounts[reason] ?? 0) + 1;
    if (rejections.length < kMaxRejectionSamples) {
      rejections.add(ImportRejection(index, reason));
    }
  }

  DecodedText decode() {
    final d = decodeTextBytes(req.bytes);
    decodedAsGbk = d.usedGbk;
    lossy = d.lossy;
    return d;
  }

  switch (req.format) {
    case ShuatiImportFormat.json:
      final text = decode().text;
      final Object? data;
      try {
        data = jsonDecode(text);
      } on FormatException catch (e) {
        throw ShuatiImportFailure(
          ShuatiImportFailureCode.invalidJson,
          'JSON 格式不正确：${e.message}',
        );
      }
      final outcome = parseJsonQuestions(data);
      rawQuestions = outcome.questions;
      jsonName = outcome.bankName;
      parsedCount = outcome.total;
      for (final r in outcome.rejections) {
        noteRejection(r.index, r.reason);
      }
    case ShuatiImportFormat.csv:
      rawQuestions = parseRows(parseCsvRows(decode().text));
      parsedCount = rawQuestions.length;
    case ShuatiImportFormat.xlsx:
      rawQuestions = parseRows(readXlsxFirstSheetRows(req.bytes));
      parsedCount = rawQuestions.length;
    case ShuatiImportFormat.docx:
      final text = extractDocxRawText(req.bytes);
      rawQuestions = [
        for (final q in parseTextToQuestions(text)) RawQuestion.fromParsed(q),
      ];
      parsedCount = rawQuestions.length;
    case ShuatiImportFormat.txt:
    case ShuatiImportFormat.md:
      final text = decode().text;
      final parsed = parseTextToQuestions(text);
      rawQuestions = parsed.isNotEmpty
          ? [for (final q in parsed) RawQuestion.fromParsed(q)]
          : parseLegacyTextQuestions(text);
      parsedCount = rawQuestions.length;
  }

  if (rawQuestions.isEmpty) {
    throw const ShuatiImportFailure(
      ShuatiImportFailureCode.noQuestionsParsed,
      '未能从文件中解析出任何题目',
    );
  }
  if (rawQuestions.length > kMaxImportQuestions) {
    throw const ShuatiImportFailure(
      ShuatiImportFailureCode.fileTooLarge,
      '题目数量过多（单个文件上限 50000 题）',
    );
  }

  const uuid = Uuid();
  final questions = <Question>[];
  var withoutAnswer = 0;
  for (final (i, raw) in rawQuestions.indexed) {
    try {
      final q = attachQuestionHash(
        normalizeQuestion(raw, req.bankId, newId: uuid.v4),
      );
      if (q.answer.isEmpty) withoutAnswer++;
      questions.add(q);
    } on Object {
      noteRejection(i, ImportRejectionReason.unexpectedError);
    }
  }
  if (questions.isEmpty) {
    throw const ShuatiImportFailure(
      ShuatiImportFailureCode.noQuestionsParsed,
      '未能从文件中解析出任何题目',
    );
  }

  final override = req.bankNameOverride;
  final name = override != null && override.isNotEmpty
      ? override
      : (jsonName ?? _stripExtension(req.fileName, req.format));

  return ImportParseResult(
    questions: questions,
    bankName: name.isEmpty ? '导入题库' : name,
    parsedCount: parsedCount,
    rejections: rejections,
    rejectionCounts: rejectionCounts,
    invalid: rejectionCounts.values.fold(0, (a, b) => a + b),
    withoutAnswer: withoutAnswer,
    decodedAsGbk: decodedAsGbk,
    lossyDecoding: lossy,
  );
}

/// 题库名默认取文件名去扩展名（PWA 逐格式的 `fileName.replace(...)`）。
String _stripExtension(String fileName, ShuatiImportFormat format) {
  final pattern = switch (format) {
    ShuatiImportFormat.json => RegExp(r'\.json$', caseSensitive: false),
    ShuatiImportFormat.csv => RegExp(r'\.csv$', caseSensitive: false),
    ShuatiImportFormat.xlsx => RegExp(r'\.xlsx?$', caseSensitive: false),
    ShuatiImportFormat.docx => RegExp(r'\.docx$', caseSensitive: false),
    ShuatiImportFormat.txt ||
    ShuatiImportFormat.md => RegExp(r'\.(txt|md)$', caseSensitive: false),
  };
  return fileName.replaceFirst(pattern, '');
}
