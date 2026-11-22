/// 刷题助手持久化门面：把各 repository 聚合在一个 [DatabaseExecutor] 上，并提供
/// 事务组合与跨表的业务操作（PWA `practiceAnswerService` / `practiceService` /
/// `wrongQuestionService` / `bankRepo.updateBankQuestions`）。
library;

import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';

import '../domain/practice_selection.dart';
import '../domain/practice_session.dart';
import '../domain/shuati_models.dart';
import '../domain/wrong_question.dart';
import 'activity_repositories.dart';
import 'bank_question_repositories.dart';
import 'shuati_database.dart';

/// 数据完整性检查结果。
class ShuatiIntegrityReport {
  const ShuatiIntegrityReport({
    required this.foreignKeyViolations,
    required this.bankCountMismatches,
    required this.danglingWrongRecordRefs,
    required this.sqliteIntegrityOk,
  });

  /// `PRAGMA foreign_key_check` 的违例行数。
  final int foreignKeyViolations;

  /// `banks.question_count` 与实际题数不符的题库 id。
  final List<String> bankCountMismatches;

  /// `wrong_questions.last_record_id` 指向不存在记录的行数。
  final int danglingWrongRecordRefs;

  /// `PRAGMA integrity_check` 是否返回 `ok`。
  final bool sqliteIntegrityOk;

  bool get isHealthy =>
      foreignKeyViolations == 0 &&
      bankCountMismatches.isEmpty &&
      danglingWrongRecordRefs == 0 &&
      sqliteIntegrityOk;
}

/// 同源覆盖更新的结果（PWA `updateBankQuestions`）。
class BankUpdateResult {
  const BankUpdateResult({
    required this.added,
    required this.updated,
    required this.removed,
  });

  final int added;
  final int updated;
  final int removed;
}

class ShuatiStore {
  ShuatiStore(this.executor)
    : banks = BankRepository(executor),
      questions = QuestionRepository(executor),
      records = RecordRepository(executor),
      favorites = FavoriteRepository(executor),
      wrongQuestions = WrongQuestionRepository(executor),
      sessions = PracticeSessionRepository(executor),
      settings = SettingsRepository(executor),
      aiExplanations = AiExplanationRepository(executor);

  /// 打开应用文档目录下的默认数据库。
  static Future<(ShuatiDatabase, ShuatiStore)> openDefault() async {
    final database = await ShuatiDatabase.openDefault();
    return (database, ShuatiStore(database.db));
  }

  final DatabaseExecutor executor;
  final BankRepository banks;
  final QuestionRepository questions;
  final RecordRepository records;
  final FavoriteRepository favorites;
  final WrongQuestionRepository wrongQuestions;
  final PracticeSessionRepository sessions;
  final SettingsRepository settings;
  final AiExplanationRepository aiExplanations;

  /// 在**一个事务**里执行 [action]：抛出任何异常整体回滚。已处于事务内时直接复用。
  Future<T> runInTransaction<T>(Future<T> Function(ShuatiStore tx) action) {
    final e = executor;
    if (e is Database) {
      return e.transaction((txn) => action(ShuatiStore(txn)));
    }
    return action(this);
  }

  // ============ 作答 ============

  /// PWA `savePracticeAnswer`：保存（或更新）作答记录；答错同时累加永久错题本。
  /// 两步放进同一事务，不会出现「记录写了、错题没记」的半成功（PWA 是两次独立写）。
  Future<int> savePracticeAnswer(PracticeRecord record, {int? existingId}) {
    return runInTransaction((tx) async {
      final recordId = await tx.records.upsert(record, existingId: existingId);
      if (record.status == AnswerStatus.wrong) {
        await tx.wrongQuestions.mark(
          record.bankId,
          record.questionId,
          timestamp: record.timestamp,
          lastRecordId: recordId,
        );
      }
      return recordId;
    });
  }

  /// 切换收藏（事务内 check-then-write）。返回切换后是否已收藏。
  Future<bool> toggleFavorite(String bankId, String questionId, {int? now}) =>
      runInTransaction(
        (tx) => tx.favorites.toggle(bankId, questionId, now: now),
      );

  /// 保存断点（scoped + 全局 last 同事务）。考试模式忽略。
  Future<void> saveLastPracticeSession({
    required String bankId,
    required PracticeMode mode,
    required int currentIndex,
    required List<String> questionIds,
    QuestionType? typeFilter,
    int? updatedAt,
  }) {
    if (mode == PracticeMode.exam) return Future<void>.value();
    return runInTransaction(
      (tx) => tx.sessions.saveLast(
        bankId: bankId,
        mode: mode,
        currentIndex: currentIndex,
        questionIds: questionIds,
        typeFilter: typeFilter,
        updatedAt: updatedAt,
      ),
    );
  }

  // ============ 练习加载 ============

  /// PWA `loadQuestions`。
  Future<List<Question>> loadQuestions(
    String bankId,
    PracticeMode mode, {
    PracticeLoadOptions options = const PracticeLoadOptions(),
    math.Random? random,
  }) async {
    var orderedIds = const <String>[];
    List<Question> candidates;
    if (mode == PracticeMode.wrong) {
      orderedIds = await wrongQuestions.questionIds(bankId);
      candidates = await questions.getByIds(orderedIds);
    } else if (mode == PracticeMode.favorite) {
      orderedIds = await favorites.questionIds(bankId);
      candidates = await questions.getByIds(orderedIds);
    } else {
      candidates = await questions.getByBank(bankId);
    }
    final needsRecords =
        mode == PracticeMode.random && (options.randomCount ?? 0) > 0;
    return selectPracticeQuestions(
      mode: mode,
      bankId: bankId,
      candidates: candidates,
      orderedIds: orderedIds,
      records: needsRecords ? await records.getByBank(bankId) : const [],
      options: options,
      random: random,
    );
  }

  /// PWA `loadPracticeSession`：按模式取题 → 用作答记录恢复已答状态与起始位置；
  /// 考试模式不恢复历史。
  Future<PracticeSession> loadPracticeSession(
    String bankId,
    PracticeMode mode, {
    PracticeLoadOptions options = const PracticeLoadOptions(),
    math.Random? random,
  }) async {
    final qs = await loadQuestions(
      bankId,
      mode,
      options: options,
      random: random,
    );
    if (mode == PracticeMode.exam) {
      return PracticeSession(
        questions: qs,
        results: const {},
        questionStates: const {},
        startIndex: 0,
      );
    }
    return restoreFromRecords(
      mode: mode,
      questions: qs,
      records: await records.getByBank(bankId),
    );
  }

  /// `?resume=1`：优先按保存的题单顺序续练，失败（无会话 / 题全被删）回退正常加载。
  Future<PracticeSession> resumeOrLoadPracticeSession(
    String bankId,
    PracticeMode mode, {
    QuestionType? typeFilter,
    PracticeLoadOptions options = const PracticeLoadOptions(),
    math.Random? random,
  }) async {
    if (mode != PracticeMode.random) {
      final scoped = await sessions.load(
        bankId: bankId,
        mode: mode,
        typeFilter: typeFilter,
      );
      final globalLast = scoped == null ? await sessions.load() : null;
      final saved = pickResumeSession(
        bankId: bankId,
        mode: mode,
        typeFilter: typeFilter,
        scoped: scoped,
        globalLast: globalLast,
      );
      if (saved != null && saved.questionIds.isNotEmpty) {
        final resumed = resumePracticeSession(
          mode: mode,
          saved: saved,
          availableQuestions: await questions.getByIds(saved.questionIds),
          records: await records.getByBank(bankId),
        );
        if (resumed != null) return resumed;
      }
    }
    return loadPracticeSession(
      bankId,
      mode,
      options: PracticeLoadOptions(
        examCount: options.examCount,
        randomCount: options.randomCount,
        shuffle: options.shuffle,
        typeFilter: options.typeFilter ?? typeFilter,
      ),
      random: random,
    );
  }

  // ============ 错题本 ============

  /// PWA `searchWrongQuestions`：永久错题（最近答错在前）→ 取题 → 过滤跨库 /
  /// 已删除题 → 按查询过滤。
  Future<List<WrongQuestionListItem>> searchWrongQuestions(
    String bankId, {
    String query = '',
  }) async {
    final entries = await wrongQuestions.entriesByBank(bankId);
    if (entries.isEmpty) return const [];
    final qs = await questions.getByIds([
      for (final e in entries) e.questionId,
    ]);
    final byId = {for (final q in qs) q.id: q};
    final items = <WrongQuestionListItem>[];
    for (final entry in sortWrongQuestionEntries(entries)) {
      final q = byId[entry.questionId];
      if (q != null && q.bankId == bankId && matchesWrongQuery(q, query)) {
        items.add(WrongQuestionListItem(question: q, entry: entry));
      }
    }
    return items;
  }

  // ============ 同源覆盖更新 ============

  /// PWA `updateBankQuestions`：按 `contentHash` 匹配旧题 → 命中复用旧 id 并覆盖内容
  /// （**保留**作答记录 / 收藏 / 错题）；未命中追加；旧题不在新文件里则删除并级联清理
  /// 其记录 / 收藏 / 错题 / AI 解析；最后清掉该题库的旧练习会话（题单可能失效）。
  /// 全部在一个事务里。
  Future<BankUpdateResult> updateBankQuestions(
    String bankId,
    List<Question> newQuestions, {
    int? now,
  }) {
    return runInTransaction((tx) async {
      final oldByHash = await tx.questions.hashToIdForBank(bankId);
      final newHashes = {for (final q in newQuestions) q.contentHash};
      final oldAll = await tx.questions.getByBank(bankId);

      final toUpdate = <(int, Question)>[];
      final toAdd = <(int, Question)>[];
      for (final (i, nq) in newQuestions.indexed) {
        final oldId = nq.contentHash == null ? null : oldByHash[nq.contentHash];
        if (oldId != null) {
          toUpdate.add((i, nq.copyWith(id: oldId)));
        } else {
          toAdd.add((i, nq));
        }
      }
      final removedIds = [
        for (final oq in oldAll)
          if (!newHashes.contains(oq.contentHash)) oq.id,
      ];
      await tx.questions.replaceExistingAll(toUpdate);
      await tx.questions.deleteByIds(removedIds);
      await tx.questions.insertOrdered(toAdd);
      await tx.banks.recountQuestions(
        bankId,
        now: now ?? DateTime.now().millisecondsSinceEpoch,
      );
      await tx.sessions.deleteByBank(bankId);
      return BankUpdateResult(
        added: toAdd.length,
        updated: toUpdate.length,
        removed: removedIds.length,
      );
    });
  }

  // ============ 完整性 ============

  Future<ShuatiIntegrityReport> checkIntegrity() async {
    final fk = await executor.rawQuery('PRAGMA foreign_key_check');
    final mismatches = await executor.rawQuery('''
SELECT b.id AS id FROM ${ShuatiSchema.tableBanks} b
WHERE b.question_count != (
  SELECT COUNT(*) FROM ${ShuatiSchema.tableQuestions} q WHERE q.bank_id = b.id
)''');
    final dangling = await executor.rawQuery('''
SELECT COUNT(*) AS c FROM ${ShuatiSchema.tableWrongQuestions} w
WHERE w.last_record_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM ${ShuatiSchema.tableRecords} r WHERE r.id = w.last_record_id
)''');
    final integrity = await executor.rawQuery('PRAGMA integrity_check');
    return ShuatiIntegrityReport(
      foreignKeyViolations: fk.length,
      bankCountMismatches: [for (final r in mismatches) r['id']! as String],
      danglingWrongRecordRefs: dangling.first['c']! as int,
      sqliteIntegrityOk:
          integrity.length == 1 && integrity.first.values.first == 'ok',
    );
  }
}
