// SQLite schema / 迁移 / 事务 / 完整性（PWA 对应：db/index.ts 的 Dexie 版本迁移、
// bankRepo.deleteBankCascade、replaceAllData 的事务语义）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/shuati/domain/shuati_models.dart';
import 'package:jxu_campus_hub/features/shuati/persistence/shuati_database.dart';
import 'package:jxu_campus_hub/features/shuati/persistence/shuati_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../helpers/shuati_test_support.dart';

void main() {
  group('schema（空库创建）', () {
    test('全新安装：版本、表、索引、外键开关', () async {
      final database = await openTestDatabase();
      final db = database.db;

      expect(await db.getVersion(), ShuatiSchema.version);
      final tables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
      )).map((r) => r['name']).toSet();
      expect(tables, {
        'banks',
        'questions',
        'records',
        'favorites',
        'wrong_questions',
        'practice_sessions',
        'settings',
        'ai_explanations',
      });

      final indexes = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%'",
      )).map((r) => r['name']).toSet();
      expect(
        indexes,
        containsAll([
          'idx_banks_updated_at',
          'idx_banks_source_file_name',
          'idx_questions_bank_order',
          'idx_questions_content_hash',
          'idx_questions_bank_hash',
          'idx_records_bank_question',
          'idx_wrong_bank_last',
          'idx_sessions_bank',
          'idx_ai_bank_question',
        ]),
      );

      final fk = await db.rawQuery('PRAGMA foreign_keys');
      expect(fk.first.values.first, 1);
    });

    test('文件库重新打开数据仍在，且不重复建表', () async {
      final dir = await Directory.systemTemp.createTemp('shuati_db_');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, ShuatiSchema.fileName);

      final first = await openTestDatabase(path: path, closeAtTearDown: false);
      final store1 = ShuatiStore(first.db);
      await seedBank(store1, 'b1', [question('q1', 'b1')]);
      await first.close();

      final second = await openTestDatabase(path: path);
      final store2 = ShuatiStore(second.db);
      expect((await store2.banks.getAllBanks()).single.id, 'b1');
      expect((await store2.questions.getByBank('b1')).single.id, 'q1');
    });
  });

  group('版本化迁移', () {
    test('v1 → v2：保留旧数据并执行登记的迁移', () async {
      final dir = await Directory.systemTemp.createTemp('shuati_mig_');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'm.db');

      final v1 = await openTestDatabase(path: path, closeAtTearDown: false);
      await seedBank(ShuatiStore(v1.db), 'b1', [
        question('q1', 'b1'),
        question('q2', 'b1'),
      ]);
      await v1.close();

      var ran = false;
      final v2 = await openTestDatabase(
        path: path,
        schemaVersion: 2,
        migrations: {
          2: (db) async {
            ran = true;
            await db.execute(
              'ALTER TABLE banks ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0',
            );
            await db.update('banks', {'pinned': 1});
          },
        },
      );
      expect(ran, isTrue);
      expect(await v2.db.getVersion(), 2);
      final banks = await v2.db.query('banks');
      expect(banks.single['pinned'], 1);
      expect(await ShuatiStore(v2.db).questions.countByBank('b1'), 2);
    });

    test('缺少某一级迁移 → 抛 ShuatiDatabaseException 且旧库不被破坏', () async {
      final dir = await Directory.systemTemp.createTemp('shuati_mig2_');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'm.db');

      final v1 = await openTestDatabase(path: path, closeAtTearDown: false);
      await seedBank(ShuatiStore(v1.db), 'b1', [question('q1', 'b1')]);
      await v1.close();

      await expectLater(
        openTestDatabase(path: path, schemaVersion: 3, migrations: {}),
        throwsA(isA<ShuatiDatabaseException>()),
      );

      final again = await openTestDatabase(path: path);
      expect(await again.db.getVersion(), 1);
      expect(await ShuatiStore(again.db).questions.countByBank('b1'), 1);
    });

    test('迁移中途抛错 → 事务回滚，版本不前进', () async {
      final dir = await Directory.systemTemp.createTemp('shuati_mig3_');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'm.db');

      final v1 = await openTestDatabase(path: path, closeAtTearDown: false);
      await v1.close();

      await expectLater(
        openTestDatabase(
          path: path,
          schemaVersion: 2,
          migrations: {
            2: (db) async {
              await db.execute(
                'ALTER TABLE banks ADD COLUMN half_done INTEGER',
              );
              throw StateError('boom');
            },
          },
        ),
        throwsA(anything),
      );

      final again = await openTestDatabase(path: path);
      expect(await again.db.getVersion(), 1);
      final cols = (await again.db.rawQuery('PRAGMA table_info(banks)'))
          .map((r) => r['name']);
      expect(cols, isNot(contains('half_done')));
    });

    test('降级（新库被旧应用打开）拒绝，不删库', () async {
      final dir = await Directory.systemTemp.createTemp('shuati_down_');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'm.db');

      final v2 = await openTestDatabase(
        path: path,
        schemaVersion: 2,
        migrations: {2: (db) async {}},
        closeAtTearDown: false,
      );
      await seedBank(ShuatiStore(v2.db), 'b1', [question('q1', 'b1')]);
      await v2.close();

      await expectLater(
        openTestDatabase(path: path),
        throwsA(isA<ShuatiDatabaseException>()),
      );

      final reopened = await openTestDatabase(
        path: path,
        schemaVersion: 2,
        migrations: {2: (db) async {}},
      );
      expect(await ShuatiStore(reopened.db).questions.countByBank('b1'), 1);
    });
  });

  group('事务', () {
    test('runInTransaction：中途抛错整体回滚', () async {
      final store = await openTestStore();
      await expectLater(
        store.runInTransaction((tx) async {
          await tx.banks.insertBank(bank('b1'));
          await tx.questions.insertAll([question('q1', 'b1')]);
          throw StateError('boom');
        }),
        throwsStateError,
      );
      expect((await tableCounts(store)).values.every((c) => c == 0), isTrue);
    });

    test('批量插入遇到主键冲突：整批回滚', () async {
      final store = await openTestStore();
      await store.banks.insertBank(bank('b1'));
      await expectLater(
        store.runInTransaction(
          (tx) => tx.questions.insertAll([
            question('dup', 'b1'),
            question('dup', 'b1'),
          ]),
        ),
        throwsA(anything),
      );
      expect(await store.questions.countByBank('b1'), 0);
    });

    test('嵌套 runInTransaction 复用同一事务（外层回滚内层也回滚）', () async {
      final store = await openTestStore();
      await expectLater(
        store.runInTransaction((tx) async {
          await tx.runInTransaction(
            (inner) => inner.banks.insertBank(bank('b1')),
          );
          throw StateError('outer');
        }),
        throwsStateError,
      );
      expect(await store.banks.getAllBanks(), isEmpty);
    });

    test('savePracticeAnswer：记录写失败时错题本也不会留下（原子）', () async {
      final store = await openTestStore();
      await seedBank(store, 'b1', [question('q1', 'b1')]);
      // 题目不存在 → records 外键失败 → 整个事务回滚
      await expectLater(
        store.savePracticeAnswer(
          record('b1', 'ghost', status: AnswerStatus.wrong),
        ),
        throwsA(anything),
      );
      expect(await store.records.getAll(), isEmpty);
      expect(await store.wrongQuestions.getAll(), isEmpty);
    });
  });

  group('外键 / 级联 / 唯一约束', () {
    test('deleteCascade 只删所选题库的数据，设置保留 (bankRepo.test.ts)', () async {
      final store = await openTestStore();
      await seedBank(store, 'b1', [question('q1', 'b1')]);
      await seedBank(store, 'b2', [question('q2', 'b2')]);
      for (final (b, q) in [('b1', 'q1'), ('b2', 'q2')]) {
        await store.records.upsert(record(b, q));
        await store.favorites.toggle(b, q);
        await store.wrongQuestions.mark(b, q, timestamp: 1);
        await store.aiExplanations.insertRaw(
          AiExplanationRow(
            bankId: b,
            questionId: q,
            explanation: 'E',
            createdAt: 1,
          ),
        );
        await store.saveLastPracticeSession(
          bankId: b,
          mode: PracticeMode.sequential,
          currentIndex: 0,
          questionIds: [q],
        );
      }
      await store.settings.set('theme', 'dark');

      await store.banks.deleteCascade('b1');

      expect((await store.banks.getAllBanks()).map((b) => b.id), ['b2']);
      expect((await store.questions.getAll()).map((q) => q.id), ['q2']);
      expect((await store.records.getAll()).map((r) => r.bankId), ['b2']);
      expect((await store.favorites.getAll()).map((f) => f.bankId), ['b2']);
      expect((await store.wrongQuestions.getAll()).map((w) => w.bankId), [
        'b2',
      ]);
      expect((await store.aiExplanations.getAll()).map((a) => a.bankId), [
        'b2',
      ]);
      // 'last' 属于 b2（后保存），scoped(b1) 已随题库级联删除
      expect((await store.sessions.load())?.bankId, 'b2');
      expect(
        await store.sessions.load(bankId: 'b1', mode: PracticeMode.sequential),
        isNull,
      );
      expect(await store.settings.get<String>('theme'), 'dark');
    });

    test('不能插入引用不存在题库 / 题目的行', () async {
      final store = await openTestStore();
      await expectLater(
        store.questions.insertAll([question('q', 'nobody')]),
        throwsA(anything),
      );
      await store.banks.insertBank(bank('b1'));
      await expectLater(
        store.records.upsert(record('b1', 'ghost')),
        throwsA(anything),
      );
    });

    test('收藏 / 错题 (bank, question) 唯一', () async {
      final store = await openTestStore();
      await seedBank(store, 'b1', [question('q1', 'b1')]);
      expect(await store.favorites.toggle('b1', 'q1'), isTrue);
      await expectLater(
        store.favorites.insertRaw(
          const Favorite(bankId: 'b1', questionId: 'q1', timestamp: 1),
        ),
        throwsA(anything),
      );
      await store.wrongQuestions.mark('b1', 'q1', timestamp: 1);
      await store.wrongQuestions.mark('b1', 'q1', timestamp: 2);
      expect(await store.wrongQuestions.getAll(), hasLength(1));
    });

    test('类型 / 状态 CHECK 约束拒绝非法取值', () async {
      final store = await openTestStore();
      await store.banks.insertBank(bank('b1'));
      await expectLater(
        store.executor.insert('questions', {
          'id': 'x',
          'bank_id': 'b1',
          'type': 'fill',
          'question': 'q',
          'answer_json': '[]',
          'sort_order': 0,
        }),
        throwsA(anything),
      );
    });

    test('删除题目时其作答 / 收藏 / 错题 / AI 解析一并清理；lastRecordId 置空', () async {
      final store = await openTestStore();
      await seedBank(store, 'b1', [question('q1', 'b1'), question('q2', 'b1')]);
      final rid = await store.savePracticeAnswer(
        record('b1', 'q1', status: AnswerStatus.wrong, timestamp: 5),
      );
      await store.wrongQuestions.mark(
        'b1',
        'q2',
        timestamp: 6,
        lastRecordId: rid,
      );
      await store.questions.deleteByIds(['q1']);
      expect(await store.records.getAll(), isEmpty);
      expect((await store.wrongQuestions.getAll()).map((w) => w.questionId), [
        'q2',
      ]);
      expect(
        (await store.wrongQuestions.find('b1', 'q2'))!.lastRecordId,
        isNull,
      );
    });
  });

  group('完整性检查', () {
    test('健康库通过', () async {
      final store = await openTestStore();
      await seedBank(store, 'b1', [question('q1', 'b1')]);
      expect((await store.checkIntegrity()).isHealthy, isTrue);
    });

    test('题数与 question_count 不符会被发现，recountQuestions 可修复', () async {
      final store = await openTestStore();
      await store.banks.insertBank(bank('b1', questionCount: 5));
      await store.questions.insertAll([question('q1', 'b1')]);
      final bad = await store.checkIntegrity();
      expect(bad.bankCountMismatches, ['b1']);
      expect(bad.isHealthy, isFalse);
      await store.banks.recountQuestions('b1');
      expect((await store.checkIntegrity()).isHealthy, isTrue);
    });
  });

  group('题目顺序与持久 ID', () {
    test('getByBank 按插入顺序（sort_order），不是 id 字典序', () async {
      final store = await openTestStore();
      await store.banks.insertBank(bank('b1'));
      await store.questions.insertAll([
        question('zzz', 'b1'),
        question('aaa', 'b1'),
        question('mmm', 'b1'),
      ]);
      expect((await store.questions.getByBank('b1')).map((q) => q.id), [
        'zzz',
        'aaa',
        'mmm',
      ]);
      expect(await store.questions.nextSortOrder('b1'), 3);
    });

    test('题目全部字段往返（选项 / 答案 / 选项解析 / 标签 / hash）', () async {
      final store = await openTestStore();
      await store.banks.insertBank(bank('b1'));
      final q = question(
        'q1',
        'b1',
        explanation: '解析',
      ).copyWith(optionExplanations: const {'A': '甲对'}, tags: const ['t1']);
      await store.questions.insertAll([q]);
      final back = (await store.questions.getByBank('b1')).single;
      expect(back.toJson(), q.toJson());
    });

    test('getByIds 超过 400 个 id 也能分块取回', () async {
      final store = await openTestStore();
      await store.banks.insertBank(bank('b1'));
      final qs = [
        for (var i = 0; i < 950; i++) question('q$i', 'b1', hashed: false),
      ];
      await store.questions.insertAll(qs);
      final got = await store.questions.getByIds([for (final q in qs) q.id]);
      expect(got, hasLength(950));
    });
  });
}
