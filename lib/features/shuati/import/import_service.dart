/// 题库文件导入服务（PWA `importService.importFromFile`）：
/// 解析（后台 isolate）→ 去重 → 单事务落库 → 返回类型化报告。
///
/// 两段式用法（Issue #117 预览）：[parseForPreview] 只解析 + 预演去重，
/// 不落库；预览页确认后 [commitPreview] 才写入。`importFile` 是两者的
/// 直通组合，行为与单段式完全一致。
library;

import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/js_compat.dart';
import '../domain/question_fingerprint.dart';
import '../domain/shuati_models.dart';
import '../persistence/shuati_store.dart';
import 'import_models.dart';
import 'import_parse.dart';

class ShuatiImportService {
  ShuatiImportService(
    this.store, {
    DateTime Function()? clock,
    String Function()? newId,
    this.useIsolate = true,
  }) : _clock = clock ?? DateTime.now,
       _newId = newId ?? (() => const Uuid().v4());

  final ShuatiStore store;
  final DateTime Function() _clock;
  final String Function() _newId;

  /// 解析是否放到后台 isolate（生产默认 `true`；个别测试关掉以便断点调试）。
  final bool useIsolate;

  /// 导入一个题库文件。
  ///
  /// [fileName] 用于判断格式、默认题库名和「同源覆盖更新」；[bankName] 非空时覆盖默认名。
  ///
  /// 失败（不支持的格式 / 文件损坏 / 解析不出题目）抛 [ShuatiImportFailure]，库不变。
  /// 成功时写库是**单个事务**：中途任何异常整体回滚，不会留下半个题库。
  Future<ShuatiImportReport> importFile({
    required Uint8List bytes,
    required String fileName,
    String? bankName,
  }) async {
    final preview = await parseForPreview(bytes: bytes, fileName: fileName);
    return commitPreview(
      preview: preview,
      bankName: bankName ?? preview.bankName,
    );
  }

  /// 第一段：解析文件 + 预演去重统计，返回可展示的 [ShuatiImportPreview]。
  ///
  /// **不写库**。预览页据此展示题目、缺答案题索引、重复 / 冲突计数与告警；
  /// 失败同样抛 [ShuatiImportFailure]。
  Future<ShuatiImportPreview> parseForPreview({
    required Uint8List bytes,
    required String fileName,
  }) async {
    final ext = fileName.split('.').last.toLowerCase();
    final format = _resolveFormat(ext);
    final existingBank = format.isReimportable
        ? await store.banks.findBySourceFile(fileName)
        : null;

    final bankId = existingBank?.id ?? _newId();
    final parsed = await runImportParse(
      ImportParseRequest(
        bytes: bytes,
        fileName: fileName,
        format: format,
        bankId: bankId,
      ),
      useIsolate: useIsolate,
    );
    final failure = parsed.failureCode;
    if (failure != null) {
      throw ShuatiImportFailure(failure, parsed.failureMessage ?? '导入失败');
    }

    final dedup = await _dedup(parsed.questions, existingBank != null);

    return ShuatiImportPreview(
      format: format,
      fileName: fileName,
      extension: ext,
      bankName: parsed.bankName,
      bankId: bankId,
      existingBankId: existingBank?.id,
      existingBankName: existingBank?.name,
      questions: parsed.questions,
      parsedCount: parsed.parsedCount,
      invalid: parsed.invalid,
      rejections: parsed.rejections,
      rejectionCounts: parsed.rejectionCounts,
      missingAnswerIndexes: [
        for (final (i, q) in parsed.questions.indexed)
          if (q.answer.isEmpty) i,
      ],
      duplicates: dedup.duplicates,
      conflicts: dedup.conflicts,
      newQuestionCount: dedup.questions.length,
      warnings: [
        if (parsed.decodedAsGbk) ImportWarning.decodedAsGbk,
        if (parsed.lossyDecoding) ImportWarning.lossyDecoding,
        if (parsed.withoutAnswer > 0) ImportWarning.questionsWithoutAnswer,
        if (existingBank == null &&
            dedup.questions.isEmpty &&
            parsed.questions.isNotEmpty)
          ImportWarning.allDuplicates,
      ],
    );
  }

  /// 第二段：把预览确认后的题目写库，返回与 `importFile` 同形的报告。
  ///
  /// - [bankName] 覆盖 [ShuatiImportPreview.bankName]（空白时回退预览名）；
  /// - [overrides] 按 `questions` 下标修正答案 / 解析（预览页勾选 AI 建议）；
  /// - 同源格式按 `preview.fileName` **重新**查找既有题库（预览后可能有变动）；
  /// - 去重、id 冲突重生成、单事务落库与 `importFile` 同一套规则。
  Future<ShuatiImportReport> commitPreview({
    required ShuatiImportPreview preview,
    required String bankName,
    List<ParsedQuestionOverride>? overrides,
  }) async {
    final format = preview.format;
    final ext = preview.extension;
    final existingBank = format.isReimportable
        ? await store.banks.findBySourceFile(preview.fileName)
        : null;
    // 沿用预览期解析出的 bankId：题目行上的 bank_id 与之一致，
    // 重新生成会让新建题库的 questions 外键指向不存在的 bank。
    final bankId = existingBank?.id ?? preview.bankId;

    final input = _applyOverrides(preview.questions, overrides);

    // ---- 去重（PWA 同款：批内 + 仅新题库做跨库）----
    final dedup = await _dedup(input, existingBank != null);
    final unique = dedup.questions;
    final duplicates = dedup.duplicates;
    final conflicts = dedup.conflicts;

    // ---- id 冲突：题目主键全库唯一，撞了就重新生成（PWA 这里会让整次导入失败）----
    final takenIds = await store.questions.idToBankId();
    final batchIds = <String>{};
    var regenerated = 0;
    final finalQuestions = <Question>[];
    for (final q in unique) {
      var next = q;
      while (takenIds.containsKey(next.id) || !batchIds.add(next.id)) {
        next = next.copyWith(id: _newId());
        regenerated++;
      }
      finalQuestions.add(next);
    }

    final trimmedName = jsTrim(bankName);
    final finalBankName = trimmedName.isEmpty ? preview.bankName : trimmedName;
    final now = _clock().millisecondsSinceEpoch;
    QuestionBank? resultBank;
    var updatedQuestions = 0;
    var removed = 0;

    if (existingBank != null) {
      final result = await store.updateBankQuestions(
        existingBank.id,
        finalQuestions,
        now: now,
      );
      resultBank = await store.banks.getBank(existingBank.id);
      updatedQuestions = result.updated;
      removed = result.removed;
    } else if (finalQuestions.isNotEmpty) {
      final bank = QuestionBank(
        id: bankId,
        name: finalBankName,
        createdAt: now,
        updatedAt: now,
        questionCount: finalQuestions.length,
        sourceFileName: format.isReimportable ? preview.fileName : null,
        sourceFileExt: format.isReimportable ? ext : null,
      );
      await store.runInTransaction((tx) async {
        await tx.banks.insertBank(bank);
        await tx.questions.insertAll(finalQuestions);
      });
      resultBank = bank;
    }

    AppLogger.instance.log(
      LogLevel.info,
      LogCategory.storage,
      '刷题助手导入完成：format=${format.name} parsed=${preview.parsedCount} '
      'added=${finalQuestions.length} duplicates=$duplicates conflicts=$conflicts '
      'invalid=${preview.invalid}',
    );

    return ShuatiImportReport(
      format: format,
      bank: resultBank,
      updatedExisting: existingBank != null,
      parsed: preview.parsedCount,
      added: finalQuestions.length,
      duplicates: duplicates,
      conflicts: conflicts,
      invalid: preview.invalid,
      rejections: preview.rejections,
      rejectionCounts: preview.rejectionCounts,
      withoutAnswer: [
        for (final q in finalQuestions)
          if (q.answer.isEmpty) q,
      ].length,
      idsRegenerated: regenerated,
      updatedQuestions: updatedQuestions,
      removedQuestions: removed,
      warnings: [
        for (final w in preview.warnings)
          if (w != ImportWarning.allDuplicates || finalQuestions.isEmpty) w,
        if (regenerated > 0) ImportWarning.idsRegenerated,
        if (existingBank == null && finalQuestions.isEmpty)
          ImportWarning.allDuplicates,
      ],
    );
  }

  /// 识别扩展名；不支持的格式抛 [ShuatiImportFailure]（`.xls` 单独提示）。
  ShuatiImportFormat _resolveFormat(String ext) {
    final format = ShuatiImportFormat.fromExtension(ext);
    if (format != null) return format;
    if (ext == 'xls') {
      throw const ShuatiImportFailure(
        ShuatiImportFailureCode.legacyXls,
        '暂不支持旧版 .xls，请在 Excel 里另存为 .xlsx 后再导入。',
      );
    }
    throw ShuatiImportFailure(
      ShuatiImportFailureCode.unsupportedFormat,
      '不支持的文件格式: $ext。请使用 JSON、CSV、Excel、Word 或文本文件。',
    );
  }

  /// 应用预览页的逐题修正：答案变更会重算 `answerHash`（去重按修正后内容）。
  List<Question> _applyOverrides(
    List<Question> questions,
    List<ParsedQuestionOverride>? overrides,
  ) {
    if (overrides == null || overrides.isEmpty) return questions;
    final result = List<Question>.of(questions);
    for (final o in overrides) {
      if (o.index < 0 || o.index >= result.length) {
        throw ArgumentError.value(
          o.index,
          'overrides',
          '题目下标越界（共 ${result.length} 题）',
        );
      }
      var q = result[o.index];
      final answer = o.answer;
      var answerChanged = false;
      if (answer != null) {
        final cleaned = [
          for (final a in answer)
            if (jsTrim(a).isNotEmpty)
              q.type.isChoice ? jsTrim(a).toUpperCase() : jsTrim(a),
        ];
        q = q.copyWith(answer: cleaned);
        answerChanged = true;
      }
      final explanation = o.explanation;
      if (explanation != null) {
        q = q.copyWith(explanation: jsTrim(explanation));
      }
      if (answerChanged) q = attachQuestionHash(q);
      result[o.index] = q;
    }
    return result;
  }

  /// 去重统计：批内首条记 `contentHash → 题`，同 hash 同答案判重、异答案记冲突；
  /// 新建题库（`isBankUpdate == false`）额外与全库既有题对比。
  Future<({List<Question> questions, int duplicates, int conflicts})> _dedup(
    List<Question> questions,
    bool isBankUpdate,
  ) async {
    final existingHashes = isBankUpdate
        ? const <String, String?>{}
        : await store.questions.contentHashIndex();
    final seen = <String, Question>{};
    final unique = <Question>[];
    var duplicates = 0;
    var conflicts = 0;
    for (final q in questions) {
      final key = q.contentHash!;
      final batchEntry = seen[key];
      if (batchEntry != null) {
        if (batchEntry.answerHash == q.answerHash) {
          duplicates++;
          continue;
        }
        conflicts++;
        unique.add(q);
        continue;
      }
      if (existingHashes.containsKey(key)) {
        if (existingHashes[key] == q.answerHash) {
          duplicates++;
          continue;
        }
        conflicts++;
      }
      seen[key] = q;
      unique.add(q);
    }
    return (questions: unique, duplicates: duplicates, conflicts: conflicts);
  }
}
