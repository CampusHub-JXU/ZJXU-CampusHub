/// 作答记录 / 收藏 / 永久错题 / 练习会话 / 设置 / AI 解析 repository
/// （PWA `recordRepo` / `favoriteRepo` / `wrongQuestionRepo` / `practiceSessionStore` /
/// `settingsRepo` / `aiExplanationRepo`）。
library;

import 'package:sqflite/sqflite.dart';

import '../domain/practice_session.dart';
import '../domain/shuati_models.dart';
import '../domain/wrong_question.dart';
import '../shuati_backup_schema.dart';
import 'row_mappers.dart';
import 'shuati_database.dart';

class RecordRepository {
  const RecordRepository(this.db);

  final DatabaseExecutor db;

  Future<List<PracticeRecord>> getAll() async {
    final rows = await db.query(ShuatiSchema.tableRecords, orderBy: 'id');
    return rows.map(recordFromRow).toList();
  }

  Future<List<PracticeRecord>> getByBank(String bankId) async {
    final rows = await db.query(
      ShuatiSchema.tableRecords,
      where: 'bank_id = ?',
      whereArgs: [bankId],
      orderBy: 'id',
    );
    return rows.map(recordFromRow).toList();
  }

  /// PWA `upsertRecord`：给了 [existingId] 且该行仍在 → 就地更新答案 / 状态 / 时间，
  /// 返回同一 id；否则新增一条并返回新 id。
  Future<int> upsert(PracticeRecord record, {int? existingId}) async {
    if (existingId != null) {
      final updated = await db.update(
        ShuatiSchema.tableRecords,
        {
          'user_answer_json': encodeJson(record.userAnswer),
          'status': record.status.name,
          'timestamp': record.timestamp,
        },
        where: 'id = ?',
        whereArgs: [existingId],
      );
      if (updated > 0) return existingId;
    }
    return db.insert(
      ShuatiSchema.tableRecords,
      recordToRow(record)..remove('id'),
    );
  }

  /// 备份导入用：可指定 id（调用方保证未被占用）。
  Future<int> insertRaw(PracticeRecord record) =>
      db.insert(ShuatiSchema.tableRecords, recordToRow(record));
}

class FavoriteRepository {
  const FavoriteRepository(this.db);

  final DatabaseExecutor db;

  Future<List<Favorite>> getAll() async {
    final rows = await db.query(ShuatiSchema.tableFavorites, orderBy: 'id');
    return rows.map(favoriteFromRow).toList();
  }

  Future<bool> isFavorited(String bankId, String questionId) async {
    final rows = await db.query(
      ShuatiSchema.tableFavorites,
      columns: ['id'],
      where: 'bank_id = ? AND question_id = ?',
      whereArgs: [bankId, questionId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// 收藏顺序（先收藏在前），错题 / 收藏练习的题单就按它排。
  Future<List<String>> questionIds(String bankId) async {
    final rows = await db.query(
      ShuatiSchema.tableFavorites,
      columns: ['question_id'],
      where: 'bank_id = ?',
      whereArgs: [bankId],
      orderBy: 'id',
    );
    return [for (final r in rows) r['question_id']! as String];
  }

  /// 切换收藏，返回切换后是否已收藏。调用方在事务里调用以保证 check-then-write 原子。
  Future<bool> toggle(String bankId, String questionId, {int? now}) async {
    if (await isFavorited(bankId, questionId)) {
      await db.delete(
        ShuatiSchema.tableFavorites,
        where: 'bank_id = ? AND question_id = ?',
        whereArgs: [bankId, questionId],
      );
      return false;
    }
    await db.insert(ShuatiSchema.tableFavorites, {
      'bank_id': bankId,
      'question_id': questionId,
      'timestamp': now ?? DateTime.now().millisecondsSinceEpoch,
    });
    return true;
  }

  Future<int> insertRaw(Favorite f) =>
      db.insert(ShuatiSchema.tableFavorites, favoriteToRow(f));
}

class WrongQuestionRepository {
  const WrongQuestionRepository(this.db);

  final DatabaseExecutor db;

  Future<PermanentWrongQuestion?> find(String bankId, String questionId) async {
    final rows = await db.query(
      ShuatiSchema.tableWrongQuestions,
      where: 'bank_id = ? AND question_id = ?',
      whereArgs: [bankId, questionId],
      limit: 1,
    );
    return rows.isEmpty ? null : wrongFromRow(rows.first);
  }

  /// 标记答错（PWA `markWrongQuestion`）：新建或 `wrongCount + 1`。返回行 id。
  /// 调用方在事务里调用以保证 read-modify-write 原子。
  Future<int> mark(
    String bankId,
    String questionId, {
    int? timestamp,
    int? lastRecordId,
  }) async {
    final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch;
    final existing = await find(bankId, questionId);
    final next = markWrong(
      bankId: bankId,
      questionId: questionId,
      timestamp: ts,
      existing: existing,
      lastRecordId: lastRecordId,
    );
    if (existing?.id != null) {
      await db.update(
        ShuatiSchema.tableWrongQuestions,
        {
          'last_wrong_at': next.lastWrongAt,
          'wrong_count': next.wrongCount,
          'last_record_id': next.lastRecordId,
        },
        where: 'id = ?',
        whereArgs: [existing!.id],
      );
      return existing.id!;
    }
    return db.insert(ShuatiSchema.tableWrongQuestions, wrongToRow(next));
  }

  /// 本题库错题条目，最近答错在前（同时间 id 大者在前）。
  Future<List<PermanentWrongQuestion>> entriesByBank(String bankId) async {
    final rows = await db.query(
      ShuatiSchema.tableWrongQuestions,
      where: 'bank_id = ?',
      whereArgs: [bankId],
      orderBy: 'last_wrong_at DESC, id DESC',
    );
    return rows.map(wrongFromRow).toList();
  }

  Future<List<String>> questionIds(String bankId) async => [
    for (final e in await entriesByBank(bankId)) e.questionId,
  ];

  Future<List<PermanentWrongQuestion>> getAll() async {
    final rows = await db.query(
      ShuatiSchema.tableWrongQuestions,
      orderBy: 'last_wrong_at DESC, id DESC',
    );
    return rows.map(wrongFromRow).toList();
  }

  /// 显式移除（PWA 里仅 repo 层存在，UI 没有入口；答对**不会**自动移除）。
  Future<void> remove(String bankId, String questionId) async {
    await db.delete(
      ShuatiSchema.tableWrongQuestions,
      where: 'bank_id = ? AND question_id = ?',
      whereArgs: [bankId, questionId],
    );
  }

  Future<int> insertRaw(PermanentWrongQuestion w) =>
      db.insert(ShuatiSchema.tableWrongQuestions, wrongToRow(w));
}

class PracticeSessionRepository {
  const PracticeSessionRepository(this.db);

  final DatabaseExecutor db;

  /// PWA `saveLastPracticeSession`：考试模式不保存；同时写 scoped 与全局 `last`。
  /// 调用方在事务里调用以保证两行同时落盘。
  Future<void> saveLast({
    required String bankId,
    required PracticeMode mode,
    required int currentIndex,
    required List<String> questionIds,
    QuestionType? typeFilter,
    int? updatedAt,
  }) async {
    if (mode == PracticeMode.exam) return;
    final now = updatedAt ?? DateTime.now().millisecondsSinceEpoch;
    PracticeSessionRecord build(String id) => PracticeSessionRecord(
      id: id,
      bankId: bankId,
      mode: mode,
      typeFilter: typeFilter,
      currentIndex: currentIndex,
      questionIds: questionIds,
      updatedAt: now,
    );
    await db.insert(
      ShuatiSchema.tablePracticeSessions,
      sessionToRow(build(scopedId(bankId, mode, typeFilter))),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.insert(
      ShuatiSchema.tablePracticeSessions,
      sessionToRow(build(lastId)),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static const String lastId = lastSessionId;

  static String scopedId(
    String bankId,
    PracticeMode mode,
    QuestionType? typeFilter,
  ) => scopedSessionId(bankId, mode, typeFilter);

  /// PWA `loadLastPracticeSession`：不带参数取全局 `last`；带参数取 scoped，
  /// 无题型过滤时回退旧版 `bankId:mode`。
  Future<PracticeSessionRecord?> load({
    String? bankId,
    PracticeMode? mode,
    QuestionType? typeFilter,
  }) async {
    if (bankId == null || mode == null) return _get(lastId);
    final scoped = await _get(scopedId(bankId, mode, typeFilter));
    if (scoped != null) return scoped;
    if (typeFilter == null) return _get(legacyScopedSessionId(bankId, mode));
    return null;
  }

  Future<PracticeSessionRecord?> _get(String id) async {
    final rows = await db.query(
      ShuatiSchema.tablePracticeSessions,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : sessionFromRow(rows.first);
  }

  Future<void> deleteByBank(String bankId) async {
    await db.delete(
      ShuatiSchema.tablePracticeSessions,
      where: 'bank_id = ?',
      whereArgs: [bankId],
    );
  }
}

/// 设置 key-value。**拒绝写入 AI / 凭据类 key**（见 [ShuatiBackupSchema.isAiOrSecretSettingKey]）。
class SettingsRepository {
  const SettingsRepository(this.db);

  final DatabaseExecutor db;

  Future<AppSetting?> getRaw(String key) async {
    final rows = await db.query(
      ShuatiSchema.tableSettings,
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : settingFromRow(rows.first);
  }

  Future<T?> get<T>(String key) async {
    final value = (await getRaw(key))?.value;
    return value is T ? value : null;
  }

  Future<void> set(String key, Object? value, {int? now}) async {
    if (ShuatiBackupSchema.isAiOrSecretSettingKey(key)) {
      throw ArgumentError.value(key, 'key', '刷题助手不保存 AI / 凭据类设置');
    }
    await db.insert(
      ShuatiSchema.tableSettings,
      settingToRow(
        AppSetting(
          key: key,
          value: value,
          updatedAt: now ?? DateTime.now().millisecondsSinceEpoch,
        ),
      ),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<AppSetting>> getAll() async {
    final rows = await db.query(ShuatiSchema.tableSettings, orderBy: 'key');
    return rows.map(settingFromRow).toList();
  }

  /// 导出用：再过滤一遍 AI / 凭据 key（纵深防御；正常情况下库里本就没有）。
  Future<List<AppSetting>> getForExport() async => [
    for (final s in await getAll())
      if (!ShuatiBackupSchema.isAiOrSecretSettingKey(s.key)) s,
  ];
}

/// AI 解析缓存行：本阶段只做不透明的存取（PWA `aiExplanationRepo`）。
class AiExplanationRepository {
  const AiExplanationRepository(this.db);

  final DatabaseExecutor db;

  /// 取该题最新一条缓存解析（同一题可能有多次「重新生成」的历史行，取 id 最大者）。
  Future<AiExplanationRow?> getCached(String questionId) async {
    final rows = await db.query(
      ShuatiSchema.tableAiExplanations,
      where: 'question_id = ?',
      whereArgs: [questionId],
      orderBy: 'id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : aiFromRow(rows.first);
  }

  Future<List<AiExplanationRow>> getAll() async {
    final rows = await db.query(
      ShuatiSchema.tableAiExplanations,
      orderBy: 'id',
    );
    return rows.map(aiFromRow).toList();
  }

  /// 一题只保留最新解析：先删同 `question_id` 旧行再插入。
  /// 调用方在事务里调用以保证「删 + 插」原子。
  Future<int> upsertForQuestion(AiExplanationRow row) async {
    await db.delete(
      ShuatiSchema.tableAiExplanations,
      where: 'question_id = ?',
      whereArgs: [row.questionId],
    );
    return insertRaw(row);
  }

  Future<int> insertRaw(AiExplanationRow row) =>
      db.insert(ShuatiSchema.tableAiExplanations, aiToRow(row));
}
