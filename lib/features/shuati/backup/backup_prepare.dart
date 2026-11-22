/// 备份文件 → 类型化、已清洗的 [PreparedBackup]（纯计算，可跑在后台 isolate）。
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../domain/question_fingerprint.dart';
import '../domain/question_type.dart';
import '../domain/shuati_models.dart';
import '../import/safe_zip.dart';
import '../import/text_decoding.dart';
import '../shuati_backup_schema.dart';
import 'backup_models.dart';

/// 备份文件（含 zip）输入大小上限；JSON 本身另受 [ShuatiBackupSchema.maxJsonBytes] 约束。
const int kMaxBackupFileBytes = 64 * 1024 * 1024;

/// ZIP 里唯一被读取的条目名（PWA `exportAllAsZip` 的约定）。
const String kBackupJsonEntry = 'backup.json';

/// 清洗后的备份（可跨 isolate）。
class PreparedBackup {
  const PreparedBackup({
    required this.version,
    required this.banks,
    required this.questions,
    required this.records,
    required this.favorites,
    required this.aiExplanations,
    required this.wrongQuestions,
    required this.settings,
    required this.invalid,
    required this.droppedAiSettings,
    required this.typesInferred,
    required this.hashesBackfilled,
    required this.issues,
  });

  final int version;
  final List<QuestionBank> banks;

  /// 按备份里 `questions` 的桶顺序、桶内数组顺序展开。
  final List<Question> questions;
  final List<PracticeRecord> records;
  final List<Favorite> favorites;
  final List<AiExplanationRow> aiExplanations;
  final List<PermanentWrongQuestion> wrongQuestions;

  /// 已剔除 AI / 凭据类 key。
  final List<AppSetting> settings;

  /// 各集合因结构不合法被丢弃的条数（键：`banks` / `questions` / `records` / …）。
  final Map<String, int> invalid;
  final int droppedAiSettings;
  final int typesInferred;
  final int hashesBackfilled;
  final List<ShuatiBackupIssue> issues;
}

/// 读出备份 JSON 文本：zip（取 `backup.json`）或裸 JSON。
///
/// 失败抛 [ShuatiBackupFailure]。判断 zip 看魔数（PWA 看文件名），因此改名的文件也能读。
String readBackupText(Uint8List bytes) {
  if (bytes.length > kMaxBackupFileBytes) {
    throw const ShuatiBackupFailure(ShuatiBackupFailureCode.tooLarge, '备份文件过大');
  }
  if (bytes.isEmpty) {
    throw const ShuatiBackupFailure(
      ShuatiBackupFailureCode.invalidJson,
      '备份文件为空',
    );
  }

  Uint8List jsonBytes;
  if (SafeZipReader.looksLikeZip(bytes)) {
    try {
      final zip = SafeZipReader.open(bytes);
      if (!zip.contains(kBackupJsonEntry)) {
        throw const ShuatiBackupFailure(
          ShuatiBackupFailureCode.missingBackupJson,
          'ZIP 中未找到 backup.json',
        );
      }
      jsonBytes = zip.read(
        kBackupJsonEntry,
        maxBytes: ShuatiBackupSchema.maxJsonBytes,
      );
    } on SafeZipException catch (e) {
      throw ShuatiBackupFailure(
        e.limitExceeded
            ? ShuatiBackupFailureCode.tooLarge
            : ShuatiBackupFailureCode.corruptArchive,
        e.limitExceeded ? '备份内容过大' : '备份 ZIP 已损坏（${e.message}）',
      );
    }
  } else {
    if (bytes.length > ShuatiBackupSchema.maxJsonBytes) {
      throw const ShuatiBackupFailure(
        ShuatiBackupFailureCode.tooLarge,
        '备份 JSON 超过大小上限',
      );
    }
    jsonBytes = bytes;
  }
  return decodeTextBytes(jsonBytes).text;
}

/// 校验并清洗备份文本。在后台 isolate 里跑（[useIsolate]）。
Future<PreparedBackup> prepareBackup(
  String jsonText, {
  bool useIsolate = true,
}) {
  if (!useIsolate) return Future.value(prepareBackupSync(jsonText));
  return Isolate.run(() => prepareBackupSync(jsonText));
}

/// 同步版本：先过 [ShuatiBackupSchema.inspectJson]（fail closed），再逐条清洗。
PreparedBackup prepareBackupSync(String jsonText) {
  final inspection = ShuatiBackupSchema.inspectJson(jsonText);
  if (!inspection.isSupported) {
    final message = inspection.errorMessage ?? '备份无法读取';
    throw ShuatiBackupFailure(
      message.startsWith('备份不是合法 JSON') || message.contains('根节点')
          ? ShuatiBackupFailureCode.invalidJson
          : ShuatiBackupFailureCode.unsupported,
      message,
    );
  }

  final data = jsonDecode(jsonText) as Map<String, Object?>;
  final invalid = <String, int>{};
  void bump(String key) => invalid[key] = (invalid[key] ?? 0) + 1;

  // ---- banks（id 重复保留第一条）----
  final banks = <QuestionBank>[];
  final bankIds = <String>{};
  for (final raw in _list(data['banks'])) {
    final bank = QuestionBank.tryFromJson(raw);
    if (bank == null) {
      bump('banks');
    } else if (bankIds.add(bank.id)) {
      banks.add(bank);
    } else {
      bump('banks');
    }
  }

  // ---- questions ----
  final questions = <Question>[];
  var typesInferred = 0;
  var hashesBackfilled = 0;
  final questionsField = data['questions'];
  if (questionsField is Map) {
    for (final bucket in questionsField.entries) {
      final items = bucket.value;
      if (items is! List) {
        bump('questions');
        continue;
      }
      for (final item in items) {
        if (item is! Map) {
          bump('questions');
          continue;
        }
        final fixed = Map<String, Object?>.from(item);
        if (fixed['bankId'] == null && bucket.key is String) {
          fixed['bankId'] = bucket.key;
        }
        if (QuestionType.tryParse(fixed['type']) == null) {
          final answer = fixed['answer'];
          final options = fixed['options'];
          final text = fixed['question'];
          if (text is String) {
            fixed['type'] = inferQuestionType(
              [
                if (answer is List)
                  for (final a in answer)
                    if (jsonScalarToString(a) case final String s) s,
              ],
              options: options is Map
                  ? {
                      for (final e in options.entries)
                        if (e.key is String &&
                            jsonScalarToString(e.value) != null)
                          e.key as String: jsonScalarToString(e.value)!,
                    }
                  : null,
              question: text,
            ).name;
            typesInferred++;
          }
        }
        var q = Question.tryFromJson(fixed);
        if (q == null) {
          bump('questions');
          continue;
        }
        // PWA：任一 hash 缺失就整体补算。
        if (q.contentHash == null ||
            q.answerHash == null ||
            q.contentHash!.isEmpty ||
            q.answerHash!.isEmpty) {
          q = attachQuestionHash(q);
          hashesBackfilled++;
        }
        questions.add(q);
      }
    }
  }

  // ---- 其它集合 ----
  List<T> parseAll<T>(String key, T? Function(Object?) parse) {
    final out = <T>[];
    for (final raw in _list(data[key])) {
      final value = parse(raw);
      if (value == null) {
        bump(key);
      } else {
        out.add(value);
      }
    }
    return out;
  }

  final records = parseAll('records', PracticeRecord.tryFromJson);
  final favorites = parseAll('favorites', Favorite.tryFromJson);
  final ai = parseAll('aiExplanations', AiExplanationRow.tryFromJson);
  final wrong = parseAll('wrongQuestions', PermanentWrongQuestion.tryFromJson);
  final allSettings = parseAll('settings', AppSetting.tryFromJson);
  final settings = <AppSetting>[];
  var dropped = 0;
  for (final s in allSettings) {
    if (ShuatiBackupSchema.isAiOrSecretSettingKey(s.key)) {
      dropped++;
    } else {
      settings.add(s);
    }
  }

  return PreparedBackup(
    version: inspection.version ?? 1,
    banks: banks,
    questions: questions,
    records: records,
    favorites: favorites,
    aiExplanations: ai,
    wrongQuestions: wrong,
    settings: settings,
    invalid: invalid,
    droppedAiSettings: dropped,
    typesInferred: typesInferred,
    hashesBackfilled: hashesBackfilled,
    issues: inspection.issues,
  );
}

List<Object?> _list(Object? value) =>
    value is List ? value.cast<Object?>() : const [];
