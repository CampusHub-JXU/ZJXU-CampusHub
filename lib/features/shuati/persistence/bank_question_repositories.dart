/// 题库 / 题目 repository（PWA `bankRepo.ts` + `questionRepo.ts`）。
///
/// 所有类都包着一个 [DatabaseExecutor]：可以是 `Database`，也可以是事务里的
/// `Transaction`，因此同一份代码既能单独调用也能被 [ShuatiStore.runInTransaction]
/// 组合进一个原子操作。
library;

import 'package:sqflite/sqflite.dart';

import '../domain/shuati_models.dart';
import 'row_mappers.dart';
import 'shuati_database.dart';

/// 把 `IN (?, ?, …)` 查询按块执行（SQLite 变量个数有上限）。
Future<List<Map<String, Object?>>> queryInChunks(
  DatabaseExecutor db, {
  required String table,
  required String column,
  required List<String> values,
  String? orderBy,
  int chunkSize = 400,
}) async {
  final rows = <Map<String, Object?>>[];
  for (var i = 0; i < values.length; i += chunkSize) {
    final chunk = values.sublist(
      i,
      i + chunkSize > values.length ? values.length : i + chunkSize,
    );
    final placeholders = List.filled(chunk.length, '?').join(',');
    rows.addAll(
      await db.query(
        table,
        where: '$column IN ($placeholders)',
        whereArgs: chunk,
        orderBy: orderBy,
      ),
    );
  }
  return rows;
}

class BankRepository {
  const BankRepository(this.db);

  final DatabaseExecutor db;

  /// 最近更新在前。
  Future<List<QuestionBank>> getAllBanks() async {
    final rows = await db.query(
      ShuatiSchema.tableBanks,
      orderBy: 'updated_at DESC, id DESC',
    );
    return rows.map(bankFromRow).toList();
  }

  Future<QuestionBank?> getBank(String id) async {
    final rows = await db.query(
      ShuatiSchema.tableBanks,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : bankFromRow(rows.first);
  }

  /// 同源文件（docx / txt / md 可「同源覆盖更新」）的既有题库。
  Future<QuestionBank?> findBySourceFile(String sourceFileName) async {
    final rows = await db.query(
      ShuatiSchema.tableBanks,
      where: 'source_file_name = ?',
      whereArgs: [sourceFileName],
      orderBy: 'id',
      limit: 1,
    );
    return rows.isEmpty ? null : bankFromRow(rows.first);
  }

  Future<void> insertBank(QuestionBank bank) async {
    await db.insert(
      ShuatiSchema.tableBanks,
      bankToRow(bank),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  Future<void> rename(String bankId, String newName, {int? now}) async {
    await db.update(
      ShuatiSchema.tableBanks,
      {
        'name': newName,
        'updated_at': now ?? DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [bankId],
    );
  }

  /// 删除题库及其全部题目 / 记录 / 收藏 / 错题 / AI 解析 / 会话（外键级联）。
  Future<void> deleteCascade(String bankId) async {
    await db.delete(
      ShuatiSchema.tableBanks,
      where: 'id = ?',
      whereArgs: [bankId],
    );
  }

  /// 清空全部数据（含设置）。
  Future<void> clearAll() async {
    for (final table in ShuatiSchema.tablesChildFirst) {
      await db.delete(table);
    }
  }

  /// 用实际题目数覆盖 `question_count`（备份里的数值可能过期）。
  Future<int> recountQuestions(String bankId, {int? now}) async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${ShuatiSchema.tableQuestions} WHERE bank_id = ?',
      [bankId],
    );
    final count = (rows.first['c']! as int);
    await db.update(
      ShuatiSchema.tableBanks,
      {'question_count': count, 'updated_at': ?now},
      where: 'id = ?',
      whereArgs: [bankId],
    );
    return count;
  }
}

class QuestionRepository {
  const QuestionRepository(this.db);

  final DatabaseExecutor db;

  /// 下一个可用的 `sort_order`（题库内追加用）。
  Future<int> nextSortOrder(String bankId) async {
    final rows = await db.rawQuery(
      'SELECT COALESCE(MAX(sort_order) + 1, 0) AS n '
      'FROM ${ShuatiSchema.tableQuestions} WHERE bank_id = ?',
      [bankId],
    );
    return rows.first['n']! as int;
  }

  /// 批量插入；`sort_order = startOrder + 下标`。主键冲突会抛出（调用方应事先去重）。
  Future<void> insertAll(List<Question> questions, {int startOrder = 0}) async {
    if (questions.isEmpty) return;
    final batch = db.batch();
    for (final (i, q) in questions.indexed) {
      batch.insert(
        ShuatiSchema.tableQuestions,
        questionToRow(q, sortOrder: startOrder + i),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
    }
    await batch.commit(noResult: true, continueOnError: false);
  }

  /// 题库内全部题目，按导入 / 备份顺序。
  Future<List<Question>> getByBank(String bankId) async {
    final rows = await db.query(
      ShuatiSchema.tableQuestions,
      where: 'bank_id = ?',
      whereArgs: [bankId],
      orderBy: 'sort_order, id',
    );
    return rows.map(questionFromRow).toList();
  }

  Future<List<Question>> getAll() async {
    final rows = await db.query(
      ShuatiSchema.tableQuestions,
      orderBy: 'bank_id, sort_order, id',
    );
    return rows.map(questionFromRow).toList();
  }

  /// 按 id 取题（顺序不保证与入参一致）。不存在的 id 被忽略。
  Future<List<Question>> getByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final rows = await queryInChunks(
      db,
      table: ShuatiSchema.tableQuestions,
      column: 'id',
      values: ids,
    );
    return rows.map(questionFromRow).toList();
  }

  Future<int> countByBank(String bankId) async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${ShuatiSchema.tableQuestions} WHERE bank_id = ?',
      [bankId],
    );
    return rows.first['c']! as int;
  }

  Future<Map<QuestionType, int>> typeCounts(String bankId) async {
    final rows = await db.rawQuery(
      'SELECT type, COUNT(*) AS c FROM ${ShuatiSchema.tableQuestions} '
      'WHERE bank_id = ? GROUP BY type',
      [bankId],
    );
    return {
      for (final r in rows) ?QuestionType.tryParse(r['type']): r['c']! as int,
    };
  }

  /// 全库 `id → bankId`（备份合并判重用）。
  Future<Map<String, String>> idToBankId() async {
    final rows = await db.rawQuery(
      'SELECT id, bank_id FROM ${ShuatiSchema.tableQuestions}',
    );
    return {for (final r in rows) r['id']! as String: r['bank_id']! as String};
  }

  /// 全库 `contentHash → answerHash`。同一 contentHash 有多题时取主键最小的一题，
  /// 与 PWA `db.questions.where('contentHash').equals(key).first()` 一致。
  Future<Map<String, String?>> contentHashIndex() async {
    final rows = await db.rawQuery(
      'SELECT content_hash, answer_hash FROM ${ShuatiSchema.tableQuestions} '
      'WHERE content_hash IS NOT NULL ORDER BY id',
    );
    final index = <String, String?>{};
    for (final r in rows) {
      index.putIfAbsent(
        r['content_hash']! as String,
        () => r['answer_hash'] as String?,
      );
    }
    return index;
  }

  /// 某题库 `contentHash → 题目 id`（同源覆盖更新用；重复 hash 取后者，与 JS `new Map` 一致）。
  Future<Map<String, String>> hashToIdForBank(String bankId) async {
    final rows = await db.rawQuery(
      'SELECT id, content_hash FROM ${ShuatiSchema.tableQuestions} '
      'WHERE bank_id = ? ORDER BY sort_order, id',
      [bankId],
    );
    return {
      for (final r in rows)
        if (r['content_hash'] != null)
          r['content_hash']! as String: r['id']! as String,
    };
  }

  Future<void> deleteByIds(List<String> ids) async {
    for (var i = 0; i < ids.length; i += 400) {
      final chunk = ids.sublist(i, i + 400 > ids.length ? ids.length : i + 400);
      await db.delete(
        ShuatiSchema.tableQuestions,
        where: 'id IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: chunk,
      );
    }
  }

  /// 按显式 `sort_order` 批量插入（同源更新追加新题用）。
  Future<void> insertOrdered(List<(int, Question)> items) async {
    if (items.isEmpty) return;
    final batch = db.batch();
    for (final (order, q) in items) {
      batch.insert(
        ShuatiSchema.tableQuestions,
        questionToRow(q, sortOrder: order),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
    }
    await batch.commit(noResult: true, continueOnError: false);
  }

  /// 批量覆盖既有题（同源更新命中 contentHash 时复用旧 id；同 id 出现多次后者生效）。
  Future<void> replaceExistingAll(List<(int, Question)> items) async {
    if (items.isEmpty) return;
    final batch = db.batch();
    for (final (order, q) in items) {
      final row = questionToRow(q, sortOrder: order)..remove('id');
      batch.update(
        ShuatiSchema.tableQuestions,
        row,
        where: 'id = ?',
        whereArgs: [q.id],
      );
    }
    await batch.commit(noResult: true, continueOnError: false);
  }
}
