/// 备份导入（PWA V1 / V2 / V3 的 JSON 或含 `backup.json` 的 ZIP）→ 原生 SQLite。
///
/// 与 PWA `importFullBackup` 的关键区别：
///
/// - 默认**合并**而不是清空重写，且**幂等**：同一份备份导入多次，库里的题库 / 题目 /
///   作答记录 / 收藏 / 错题行数不变（见 `docs/shuati-native-parity.md` §8 的判重键）；
/// - 整个写入是**一个事务**，并在提交前做外键 / 题数 / 错题引用的完整性检查，
///   任何一步失败整体回滚；
/// - 孤儿数据（引用了不存在的题库 / 题）被丢弃并计数，而不是原样塞进库；
/// - AI / 凭据类设置**永远不保存**，只计数。
library;

import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/shuati_models.dart';
import '../persistence/row_mappers.dart';
import '../persistence/shuati_database.dart';
import '../persistence/shuati_store.dart';
import 'backup_models.dart';
import 'backup_prepare.dart';

const String _sep = '\u0000';

class ShuatiBackupImporter {
  ShuatiBackupImporter(
    this.store, {
    String Function()? newId,
    this.useIsolate = true,
  }) : _newId = newId ?? (() => const Uuid().v4());

  final ShuatiStore store;
  final String Function() _newId;
  final bool useIsolate;

  /// 导入备份字节（zip 或 JSON）。失败抛 [ShuatiBackupFailure]，库不变。
  Future<ShuatiBackupImportReport> importBytes(
    Uint8List bytes, {
    BackupImportMode mode = BackupImportMode.merge,
  }) async {
    final text = readBackupText(bytes);
    final prepared = await prepareBackup(text, useIsolate: useIsolate);
    return importPrepared(prepared, mode: mode);
  }

  /// 把已清洗的备份写入数据库（也供将来「旧 WebView 导出」直接喂入）。
  Future<ShuatiBackupImportReport> importPrepared(
    PreparedBackup prepared, {
    BackupImportMode mode = BackupImportMode.merge,
  }) async {
    final report = await store.runInTransaction(
      (tx) => _commit(tx, prepared, mode),
    );
    AppLogger.instance.log(
      LogLevel.info,
      LogCategory.storage,
      '刷题助手备份导入完成：v${report.version} mode=${mode.name} '
      'banks+${report.banks.added} questions+${report.questions.added} '
      'records+${report.records.added} dupQuestions=${report.questions.duplicate} '
      'orphans=${report.records.orphan + report.questions.orphan}',
    );
    return report;
  }

  Future<ShuatiBackupImportReport> _commit(
    ShuatiStore tx,
    PreparedBackup p,
    BackupImportMode mode,
  ) async {
    if (mode == BackupImportMode.replaceAll) {
      await tx.banks.clearAll();
    }
    final writer = _BatchWriter(tx.executor);

    // ---------------- banks ----------------
    final existingBankIds = {
      for (final b in await tx.banks.getAllBanks()) b.id,
    };
    final validBanks = <String>{...existingBankIds};
    var banksAdded = 0;
    var banksExisting = 0;
    for (final b in p.banks) {
      if (existingBankIds.contains(b.id)) {
        banksExisting++;
        continue;
      }
      await tx.banks.insertBank(b);
      validBanks.add(b.id);
      banksAdded++;
    }

    // ---------------- questions ----------------
    final knownQuestionBank = await tx.questions.idToBankId();
    final nextOrder = <String, int>{};
    final remap = <String, String>{}; // "bank\0oldId" -> newId
    final touchedBanks = <String>{};
    final seenInBackup = <String>{};
    var qAdded = 0;
    var qDuplicate = 0;
    var qOrphan = 0;
    var qRemapped = 0;
    for (final q in p.questions) {
      if (!validBanks.contains(q.bankId)) {
        qOrphan++;
        continue;
      }
      if (!seenInBackup.add('${q.bankId}$_sep${q.id}')) {
        qDuplicate++;
        continue;
      }
      final owner = knownQuestionBank[q.id];
      if (owner != null) {
        if (owner == q.bankId) {
          qDuplicate++; // 幂等命中：保留本地版本
          continue;
        }
        // 同 id 属于另一个题库：给这道题换新 id，并记下映射供其引用方使用。
        final fresh = _newId();
        remap['${q.bankId}$_sep${q.id}'] = fresh;
        qRemapped++;
        await _insertQuestion(tx, writer, nextOrder, q.copyWith(id: fresh));
        knownQuestionBank[fresh] = q.bankId;
      } else {
        await _insertQuestion(tx, writer, nextOrder, q);
        knownQuestionBank[q.id] = q.bankId;
      }
      touchedBanks.add(q.bankId);
      qAdded++;
    }
    await writer.flush();
    touchedBanks.addAll(
      p.banks.map((b) => b.id).where((id) => !existingBankIds.contains(id)),
    );

    String resolveQuestionId(String bankId, String questionId) =>
        remap['$bankId$_sep$questionId'] ?? questionId;
    bool questionBelongs(String bankId, String questionId) =>
        validBanks.contains(bankId) && knownQuestionBank[questionId] == bankId;

    // ---------------- records ----------------
    final existingRecordRows = await tx.executor.query(
      ShuatiSchema.tableRecords,
      columns: [
        'id',
        'bank_id',
        'question_id',
        'timestamp',
        'status',
        'user_answer_json',
      ],
    );
    final recordKeyToId = <String, int>{};
    final usedIds = <int>{};
    for (final r in existingRecordRows) {
      final id = r['id']! as int;
      usedIds.add(id);
      recordKeyToId[_recordKey(
            r['bank_id']! as String,
            r['question_id']! as String,
            r['timestamp']! as int,
            r['status']! as String,
            r['user_answer_json']! as String,
          )] =
          id;
    }
    var nextRecordId = usedIds.isEmpty
        ? 1
        : usedIds.reduce((a, b) => a > b ? a : b) + 1;
    final recordIdMap = <int, int>{}; // 备份里的 id -> 库里的 id
    var rAdded = 0;
    var rDuplicate = 0;
    var rOrphan = 0;
    for (final r in p.records) {
      final qid = resolveQuestionId(r.bankId, r.questionId);
      if (!questionBelongs(r.bankId, qid)) {
        rOrphan++;
        continue;
      }
      final answerJson = encodeJson(r.userAnswer);
      final key = _recordKey(
        r.bankId,
        qid,
        r.timestamp,
        r.status.name,
        answerJson,
      );
      final existingId = recordKeyToId[key];
      if (existingId != null) {
        rDuplicate++;
        if (r.id != null) recordIdMap[r.id!] = existingId;
        continue;
      }
      var id = r.id;
      if (id == null || id <= 0 || usedIds.contains(id)) {
        id = nextRecordId;
      }
      usedIds.add(id);
      if (id >= nextRecordId) nextRecordId = id + 1;
      recordKeyToId[key] = id;
      if (r.id != null) recordIdMap[r.id!] = id;
      writer.add(
        ShuatiSchema.tableRecords,
        recordToRow(
          PracticeRecord(
            id: id,
            bankId: r.bankId,
            questionId: qid,
            userAnswer: r.userAnswer,
            status: r.status,
            timestamp: r.timestamp,
          ),
        ),
      );
      touchedBanks.add(r.bankId);
      rAdded++;
    }
    await writer.flush();

    // ---------------- favorites ----------------
    final existingFavorites = {
      for (final f in await tx.favorites.getAll())
        '${f.bankId}$_sep${f.questionId}',
    };
    var fAdded = 0;
    var fDuplicate = 0;
    var fOrphan = 0;
    for (final f in p.favorites) {
      final qid = resolveQuestionId(f.bankId, f.questionId);
      if (!questionBelongs(f.bankId, qid)) {
        fOrphan++;
        continue;
      }
      if (!existingFavorites.add('${f.bankId}$_sep$qid')) {
        fDuplicate++;
        continue;
      }
      writer.add(
        ShuatiSchema.tableFavorites,
        favoriteToRow(
          Favorite(bankId: f.bankId, questionId: qid, timestamp: f.timestamp),
        ),
      );
      fAdded++;
    }
    await writer.flush();

    // ---------------- wrong questions ----------------
    final existingWrong = {
      for (final w in await tx.wrongQuestions.getAll())
        '${w.bankId}$_sep${w.questionId}': w,
    };
    var wAdded = 0;
    var wDuplicate = 0;
    var wMerged = 0;
    var wOrphan = 0;
    for (final w in p.wrongQuestions) {
      final qid = resolveQuestionId(w.bankId, w.questionId);
      if (!questionBelongs(w.bankId, qid)) {
        wOrphan++;
        continue;
      }
      final mappedRecordId = w.lastRecordId == null
          ? null
          : recordIdMap[w.lastRecordId!];
      final key = '${w.bankId}$_sep$qid';
      final existing = existingWrong[key];
      if (existing == null) {
        final row = PermanentWrongQuestion(
          bankId: w.bankId,
          questionId: qid,
          firstWrongAt: w.firstWrongAt,
          lastWrongAt: w.lastWrongAt,
          wrongCount: w.wrongCount,
          lastRecordId: mappedRecordId,
        );
        writer.add(ShuatiSchema.tableWrongQuestions, wrongToRow(row));
        existingWrong[key] = row;
        wAdded++;
        continue;
      }
      // 幂等合并：取更早的首次、更晚的最近一次、更大的次数。
      final first = w.firstWrongAt < existing.firstWrongAt
          ? w.firstWrongAt
          : existing.firstWrongAt;
      final incomingNewer = w.lastWrongAt > existing.lastWrongAt;
      final last = incomingNewer ? w.lastWrongAt : existing.lastWrongAt;
      final count = w.wrongCount > existing.wrongCount
          ? w.wrongCount
          : existing.wrongCount;
      final lastRecord = incomingNewer
          ? (mappedRecordId ?? existing.lastRecordId)
          : existing.lastRecordId;
      if (first == existing.firstWrongAt &&
          last == existing.lastWrongAt &&
          count == existing.wrongCount &&
          lastRecord == existing.lastRecordId) {
        wDuplicate++;
        continue;
      }
      await writer.flush();
      await tx.executor.update(
        ShuatiSchema.tableWrongQuestions,
        {
          'first_wrong_at': first,
          'last_wrong_at': last,
          'wrong_count': count,
          'last_record_id': lastRecord,
        },
        where: 'bank_id = ? AND question_id = ?',
        whereArgs: [w.bankId, qid],
      );
      existingWrong[key] = PermanentWrongQuestion(
        id: existing.id,
        bankId: existing.bankId,
        questionId: existing.questionId,
        firstWrongAt: first,
        lastWrongAt: last,
        wrongCount: count,
        lastRecordId: lastRecord,
      );
      wMerged++;
    }
    await writer.flush();

    // ---------------- AI 解析（不透明缓存行） ----------------
    final existingAi = {
      for (final a in await tx.aiExplanations.getAll())
        '${a.bankId}$_sep${a.questionId}$_sep${a.createdAt}$_sep${a.explanation}',
    };
    var aAdded = 0;
    var aDuplicate = 0;
    var aOrphan = 0;
    for (final a in p.aiExplanations) {
      final qid = resolveQuestionId(a.bankId, a.questionId);
      // v4 之前的行没有 bankId：按题目所属题库回填。
      final bankId = a.bankId.isNotEmpty
          ? a.bankId
          : (knownQuestionBank[qid] ?? '');
      if (!questionBelongs(bankId, qid)) {
        aOrphan++;
        continue;
      }
      if (!existingAi.add(
        '$bankId$_sep$qid$_sep${a.createdAt}$_sep${a.explanation}',
      )) {
        aDuplicate++;
        continue;
      }
      writer.add(
        ShuatiSchema.tableAiExplanations,
        aiToRow(
          AiExplanationRow(
            bankId: bankId,
            questionId: qid,
            explanation: a.explanation,
            model: a.model,
            createdAt: a.createdAt,
          ),
        ),
      );
      aAdded++;
    }
    await writer.flush();

    // ---------------- settings（AI / 凭据已在清洗阶段剔除） ----------------
    final existingSettingKeys = {
      for (final s in await tx.settings.getAll()) s.key,
    };
    var sAdded = 0;
    var sDuplicate = 0;
    for (final s in p.settings) {
      if (!existingSettingKeys.add(s.key)) {
        sDuplicate++; // 本地设置优先
        continue;
      }
      writer.add(ShuatiSchema.tableSettings, settingToRow(s));
      sAdded++;
    }
    await writer.flush();

    // ---------------- 收尾：题数、完整性 ----------------
    for (final bankId in touchedBanks) {
      if (validBanks.contains(bankId)) {
        await tx.banks.recountQuestions(bankId);
      }
    }
    final integrity = await tx.checkIntegrity();
    if (!integrity.isHealthy) {
      throw ShuatiBackupFailure(
        ShuatiBackupFailureCode.integrityCheckFailed,
        '导入后完整性检查未通过（外键 ${integrity.foreignKeyViolations}，'
        '题数不符 ${integrity.bankCountMismatches.length}），已回滚。',
      );
    }

    return ShuatiBackupImportReport(
      version: p.version,
      mode: mode,
      banks: BackupCollectionCounts(
        added: banksAdded,
        duplicate: banksExisting,
        invalid: p.invalid['banks'] ?? 0,
      ),
      questions: BackupCollectionCounts(
        added: qAdded,
        duplicate: qDuplicate,
        orphan: qOrphan,
        invalid: p.invalid['questions'] ?? 0,
      ),
      records: BackupCollectionCounts(
        added: rAdded,
        duplicate: rDuplicate,
        orphan: rOrphan,
        invalid: p.invalid['records'] ?? 0,
      ),
      favorites: BackupCollectionCounts(
        added: fAdded,
        duplicate: fDuplicate,
        orphan: fOrphan,
        invalid: p.invalid['favorites'] ?? 0,
      ),
      wrongQuestions: BackupCollectionCounts(
        added: wAdded,
        duplicate: wDuplicate,
        orphan: wOrphan,
        merged: wMerged,
        invalid: p.invalid['wrongQuestions'] ?? 0,
      ),
      aiExplanations: BackupCollectionCounts(
        added: aAdded,
        duplicate: aDuplicate,
        orphan: aOrphan,
        invalid: p.invalid['aiExplanations'] ?? 0,
      ),
      settings: BackupCollectionCounts(
        added: sAdded,
        duplicate: sDuplicate,
        invalid: p.invalid['settings'] ?? 0,
      ),
      droppedAiSettings: p.droppedAiSettings,
      idsRemapped: qRemapped,
      typesInferred: p.typesInferred,
      hashesBackfilled: p.hashesBackfilled,
      issues: p.issues,
    );
  }

  Future<void> _insertQuestion(
    ShuatiStore tx,
    _BatchWriter writer,
    Map<String, int> nextOrder,
    Question q,
  ) async {
    final order =
        nextOrder[q.bankId] ?? await tx.questions.nextSortOrder(q.bankId);
    nextOrder[q.bankId] = order + 1;
    writer.add(ShuatiSchema.tableQuestions, questionToRow(q, sortOrder: order));
    await writer.maybeFlush();
  }

  static String _recordKey(
    String bankId,
    String questionId,
    int timestamp,
    String status,
    String answerJson,
  ) => '$bankId$_sep$questionId$_sep$timestamp$_sep$status$_sep$answerJson';
}

/// 批量写入：攒够一批再 `batch.commit`（同一个事务内，不会提前提交）。
class _BatchWriter {
  _BatchWriter(this._db);

  final DatabaseExecutor _db;
  Batch? _batch;
  int _pending = 0;
  static const int _flushEvery = 800;

  void add(String table, Map<String, Object?> row) {
    _batch ??= _db.batch();
    _batch!.insert(table, row, conflictAlgorithm: ConflictAlgorithm.abort);
    _pending++;
  }

  Future<void> maybeFlush() async {
    if (_pending >= _flushEvery) await flush();
  }

  Future<void> flush() async {
    final batch = _batch;
    if (batch == null || _pending == 0) return;
    _batch = null;
    _pending = 0;
    await batch.commit(noResult: true, continueOnError: false);
  }
}
