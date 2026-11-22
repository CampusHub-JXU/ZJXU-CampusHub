/// 题库文件导入服务（PWA `importService.importFromFile`）：
/// 解析（后台 isolate）→ 去重 → 单事务落库 → 返回类型化报告。
library;

import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../../core/logging/app_logger.dart';
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
    final ext = fileName.split('.').last.toLowerCase();
    final format = ShuatiImportFormat.fromExtension(ext);
    if (format == null) {
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

    // 同源覆盖更新：docx / txt / md 按文件名匹配既有题库。
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
        bankNameOverride: bankName,
      ),
      useIsolate: useIsolate,
    );
    final failure = parsed.failureCode;
    if (failure != null) {
      throw ShuatiImportFailure(failure, parsed.failureMessage ?? '导入失败');
    }

    // ---- 去重（PWA 同款：批内 + 仅新题库做跨库）----
    final existingHashes = existingBank == null
        ? await store.questions.contentHashIndex()
        : const <String, String?>{};
    final seen = <String, Question>{};
    final unique = <Question>[];
    var duplicates = 0;
    var conflicts = 0;
    for (final q in parsed.questions) {
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
        name: parsed.bankName,
        createdAt: now,
        updatedAt: now,
        questionCount: finalQuestions.length,
        sourceFileName: format.isReimportable ? fileName : null,
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
      '刷题助手导入完成：format=${format.name} parsed=${parsed.parsedCount} '
      'added=${finalQuestions.length} duplicates=$duplicates conflicts=$conflicts '
      'invalid=${parsed.invalid}',
    );

    return ShuatiImportReport(
      format: format,
      bank: resultBank,
      updatedExisting: existingBank != null,
      parsed: parsed.parsedCount,
      added: finalQuestions.length,
      duplicates: duplicates,
      conflicts: conflicts,
      invalid: parsed.invalid,
      rejections: parsed.rejections,
      rejectionCounts: parsed.rejectionCounts,
      withoutAnswer: parsed.withoutAnswer,
      idsRegenerated: regenerated,
      updatedQuestions: updatedQuestions,
      removedQuestions: removed,
      warnings: [
        if (parsed.decodedAsGbk) ImportWarning.decodedAsGbk,
        if (parsed.lossyDecoding) ImportWarning.lossyDecoding,
        if (parsed.withoutAnswer > 0) ImportWarning.questionsWithoutAnswer,
        if (regenerated > 0) ImportWarning.idsRegenerated,
        if (existingBank == null && finalQuestions.isEmpty)
          ImportWarning.allDuplicates,
      ],
    );
  }
}
