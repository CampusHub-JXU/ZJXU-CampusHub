// 备份导入：PWA V1/V2/V3 JSON 与 ZIP → SQLite。
// 对应 PWA tests/services/importService.test.ts 的 importFullBackup 用例，外加幂等 / 孤儿 /
// 回滚 / 资源上限 / AI 凭据不落库。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/shuati/backup/backup_importer.dart';
import 'package:jxu_campus_hub/features/shuati/backup/backup_models.dart';
import 'package:jxu_campus_hub/features/shuati/backup/backup_prepare.dart';
import 'package:jxu_campus_hub/features/shuati/domain/question_fingerprint.dart';
import 'package:jxu_campus_hub/features/shuati/domain/shuati_models.dart';
import 'package:jxu_campus_hub/features/shuati/persistence/shuati_store.dart';
import 'package:jxu_campus_hub/features/shuati/shuati_backup_schema.dart';

import '../../../helpers/shuati_office_fixtures.dart';
import '../../../helpers/shuati_test_support.dart';

Uint8List jsonBytes(Object data) => utf8Bytes(jsonEncode(data));

Future<ShuatiBackupFailure> backupFailure(
  Future<Object?> Function() action,
) async {
  try {
    await action();
  } on ShuatiBackupFailure catch (e) {
    return e;
  }
  fail('应当抛 ShuatiBackupFailure');
}

Future<String> dumpAllText(ShuatiStore store) async {
  final buf = StringBuffer();
  for (final table in ['settings', 'ai_explanations', 'banks', 'questions']) {
    for (final row in await store.executor.query(table)) {
      buf.writeln(row.values.join('|'));
    }
  }
  return buf.toString();
}

void main() {
  group('importFullBackup 基本行为 (importService.test.ts)', () {
    test(
      'restores backup data, keeps hashes, and drops AI credentials',
      () async {
        final store = await openTestStore();
        final importer = ShuatiBackupImporter(store, useIsolate: false);
        final backup = {
          'version': 3,
          'exportedAt': 1,
          'banks': [
            {
              'id': 'b1',
              'name': 'Backup Bank',
              'createdAt': 1,
              'updatedAt': 1,
              'questionCount': 1,
            },
          ],
          'questions': {
            'b1': [
              {
                'id': 'q1',
                'bankId': 'b1',
                'type': 'single',
                'question': 'Which letter?',
                'options': {'A': 'A', 'B': 'B'},
                'answer': ['A'],
              },
            ],
          },
          'records': [
            {
              'bankId': 'b1',
              'questionId': 'q1',
              'userAnswer': ['A'],
              'status': 'correct',
              'timestamp': 1,
            },
          ],
          'favorites': [
            {'bankId': 'b1', 'questionId': 'q1', 'timestamp': 1},
          ],
          'aiExplanations': [
            {
              'bankId': 'b1',
              'questionId': 'q1',
              'explanation': 'Because A.',
              'createdAt': 1,
            },
          ],
          'wrongQuestions': [
            {
              'bankId': 'b1',
              'questionId': 'q1',
              'firstWrongAt': 1,
              'lastWrongAt': 1,
              'wrongCount': 1,
            },
          ],
          'settings': [
            {'key': 'theme', 'value': 'dark', 'updatedAt': 1},
            {'key': 'ai_apiKey', 'value': 'secret', 'updatedAt': 1},
            {
              'key': 'ai_endpoint',
              'value': 'https://example.com/v1',
              'updatedAt': 1,
            },
            {'key': 'ai_model', 'value': 'model', 'updatedAt': 1},
          ],
        };

        final report = await importer.importBytes(jsonBytes(backup));

        expect((await store.banks.getBank('b1'))!.name, 'Backup Bank');
        expect(await store.records.getAll(), hasLength(1));
        expect(await store.favorites.getAll(), hasLength(1));
        expect(await store.aiExplanations.getAll(), hasLength(1));
        expect(await store.wrongQuestions.getAll(), hasLength(1));
        final q = (await store.questions.getByIds(['q1'])).single;
        expect(q.contentHash, isNotNull);
        expect(q.answerHash, isNotNull);
        expect(report.hashesBackfilled, 1);
        expect(await store.settings.get<String>('theme'), 'dark');
        expect(await store.settings.getRaw('ai_apiKey'), isNull);
        expect(await store.settings.getRaw('ai_endpoint'), isNull);
        expect(await store.settings.getRaw('ai_model'), isNull);
        expect(report.droppedAiSettings, 3);
        expect((await dumpAllText(store)).contains('secret'), isFalse);
      },
    );

    test(
      'rejects unsupported backup versions before touching local data',
      () async {
        final store = await openTestStore();
        await seedBank(store, 'existing', [question('q', 'existing')]);
        final before = await tableCounts(store);
        final importer = ShuatiBackupImporter(store, useIsolate: false);

        final e = await backupFailure(
          () => importer.importBytes(jsonBytes({'version': 999})),
        );
        expect(e.code, ShuatiBackupFailureCode.unsupported);
        expect(e.message, contains('999'));
        expect(await tableCounts(store), before);
        expect((await store.banks.getBank('existing'))!.name, 'Bank existing');
      },
    );
  });

  group('V1 / V2 / V3 fixtures（合成数据）', () {
    Future<ShuatiBackupImportReport> run(
      ShuatiStore store,
      Map<String, Object?> data,
    ) => ShuatiBackupImporter(
      store,
      useIsolate: false,
    ).importBytes(jsonBytes(data));

    test(
      'V1：banks / questions / records / favorites；缺省 version 按 V1',
      () async {
        final store = await openTestStore();
        final v1 = syntheticBackup(version: 1);
        expect(v1.containsKey('aiExplanations'), isFalse);
        final report = await run(store, v1);
        expect(report.version, 1);
        expect(report.banks.added, 2);
        expect(report.questions.added, 6);
        expect(report.records.added, 6);
        expect(report.favorites.added, 2);
        expect(report.aiExplanations.total, 0);
        expect(report.wrongQuestions.total, 0);
        expect((await store.checkIntegrity()).isHealthy, isTrue);

        final store2 = await openTestStore();
        final noVersion = syntheticBackup(version: 1)..remove('version');
        expect((await run(store2, noVersion)).version, 1);
      },
    );

    test('V2：+ aiExplanations / settings（AI 设置被丢弃）', () async {
      final store = await openTestStore();
      final report = await run(store, syntheticBackup(version: 2));
      expect(report.version, 2);
      expect(report.aiExplanations.added, 2);
      expect(report.settings.added, 1);
      expect(report.droppedAiSettings, 3);
      expect(report.wrongQuestions.total, 0);
      expect((await store.settings.getAll()).map((s) => s.key), ['theme']);
    });

    test('V3：+ wrongQuestions，lastRecordId 指向导入后的记录', () async {
      final store = await openTestStore();
      final report = await run(store, syntheticBackup(version: 3));
      expect(report.version, 3);
      expect(report.wrongQuestions.added, 2);
      for (final w in await store.wrongQuestions.getAll()) {
        expect(w.lastRecordId, isNotNull);
        final rec = (await store.records.getAll()).firstWhere(
          (r) => r.id == w.lastRecordId,
        );
        expect(rec.questionId, w.questionId);
        expect(rec.status, AnswerStatus.wrong);
      }
      expect((await store.checkIntegrity()).isHealthy, isTrue);
    });

    test('稳定 ID 全部保留（题库 / 题目 / 记录 id）', () async {
      final store = await openTestStore();
      final data = syntheticBackup();
      await run(store, data);
      expect((await store.banks.getAllBanks()).map((b) => b.id).toSet(), {
        'bank-1',
        'bank-2',
      });
      expect((await store.questions.getAll()).map((q) => q.id).toSet(), {
        for (var b = 1; b <= 2; b++)
          for (var i = 1; i <= 3; i++) 'b$b-q$i',
      });
      expect((await store.records.getAll()).map((r) => r.id).toSet(), {
        for (var i = 100; i < 106; i++) i,
      });
      // 备份里的 questionCount / updatedAt 保留（updatedAt 不被重写）
      expect((await store.banks.getBank('bank-2'))!.updatedAt, 4000);
    });

    test('题目顺序 = 备份数组顺序', () async {
      final store = await openTestStore();
      await run(store, syntheticBackup(banks: 1, questionsPerBank: 5));
      expect((await store.questions.getByBank('bank-1')).map((q) => q.id), [
        'b1-q1',
        'b1-q2',
        'b1-q3',
        'b1-q4',
        'b1-q5',
      ]);
    });

    test('已带 PWA 算好的 hash 原样保留，缺 hash 的按 PWA 算法补算', () async {
      final store = await openTestStore();
      final data = syntheticBackup(
        banks: 1,
        questionsPerBank: 1,
        withHashes: false,
      );
      final report = await run(store, data);
      expect(report.hashesBackfilled, 1);
      final q = (await store.questions.getAll()).single;
      expect(q.contentHash, attachQuestionHash(q).contentHash);

      // 自带 hash（即便与本地算法不同）不被改写
      final store2 = await openTestStore();
      final custom = syntheticBackup(banks: 1, questionsPerBank: 1);
      (((custom['questions']! as Map)['bank-1']! as List).first
              as Map)['contentHash'] =
          'f' * 64;
      await run(store2, custom);
      expect((await store2.questions.getAll()).single.contentHash, 'f' * 64);
    });

    test('type 非法 / 缺失：按 PWA 题型推断补全并计数', () async {
      final store = await openTestStore();
      final data = {
        'version': 3,
        'banks': [
          {
            'id': 'b',
            'name': 'n',
            'createdAt': 1,
            'updatedAt': 1,
            'questionCount': 3,
          },
        ],
        'questions': {
          'b': [
            {
              'id': 'q1',
              'bankId': 'b',
              'type': 'fill',
              'question': '填入____',
              'answer': ['x'],
            },
            {
              'id': 'q2',
              'bankId': 'b',
              'question': '选择',
              'options': {'A': '甲', 'B': '乙'},
              'answer': ['A', 'B'],
            },
            {
              'id': 'q3',
              'bankId': 'b',
              'type': 'text',
              'question': '简述',
              'answer': ['长文本'],
            },
          ],
        },
      };
      final report = await run(store, data);
      expect(report.typesInferred, 3);
      final types = {
        for (final q in await store.questions.getAll()) q.id: q.type,
      };
      expect(types, {
        'q1': QuestionType.blank,
        'q2': QuestionType.multiple,
        'q3': QuestionType.short,
      });
    });

    test('桶里的题缺 bankId 时用桶的 key 补全', () async {
      final store = await openTestStore();
      final data = {
        'version': 3,
        'banks': [
          {
            'id': 'b',
            'name': 'n',
            'createdAt': 1,
            'updatedAt': 1,
            'questionCount': 1,
          },
        ],
        'questions': {
          'b': [
            {
              'id': 'q1',
              'type': 'single',
              'question': '题目',
              'options': {'A': '甲'},
              'answer': ['A'],
            },
          ],
        },
      };
      final report = await run(store, data);
      expect(report.questions.added, 1);
      expect((await store.questions.getAll()).single.bankId, 'b');
    });
  });

  group('ZIP', () {
    test('ZIP（backup.json）与裸 JSON 导入结果一致；zip 判定看魔数而非文件名', () async {
      final data = syntheticBackup();
      final bytes = jsonBytes(data);
      final storeJson = await openTestStore();
      await ShuatiBackupImporter(
        storeJson,
        useIsolate: false,
      ).importBytes(bytes);

      final storeZip = await openTestStore();
      final zip = zipBytes({'backup.json': bytes});
      final report = await ShuatiBackupImporter(
        storeZip,
        useIsolate: false,
      ).importBytes(zip);
      expect(report.questions.added, 6);
      expect(await tableCounts(storeZip), await tableCounts(storeJson));
    });

    test('ZIP 里没有 backup.json → missingBackupJson；多余条目被忽略', () async {
      final store = await openTestStore();
      final importer = ShuatiBackupImporter(store, useIsolate: false);
      final e = await backupFailure(
        () => importer.importBytes(zipBytes({'other.json': utf8Bytes('{}')})),
      );
      expect(e.code, ShuatiBackupFailureCode.missingBackupJson);
      expect(e.message, 'ZIP 中未找到 backup.json');

      final ok = await importer.importBytes(
        zipBytes({
          'readme.txt': utf8Bytes('x'),
          'backup.json': jsonBytes(syntheticBackup(banks: 1)),
        }),
      );
      expect(ok.banks.added, 1);
    });

    test('损坏 / 炸弹 ZIP → corruptArchive / tooLarge，库不变', () async {
      final store = await openTestStore();
      final importer = ShuatiBackupImporter(store, useIsolate: false);
      final good = zipBytes({'backup.json': jsonBytes(syntheticBackup())});
      final truncated = good.sublist(0, good.length ~/ 2);
      expect(
        (await backupFailure(() => importer.importBytes(truncated))).code,
        anyOf(
          ShuatiBackupFailureCode.corruptArchive,
          ShuatiBackupFailureCode.invalidJson,
        ),
      );

      final bomb = zipBytes({
        'backup.json': Uint8List(ShuatiBackupSchema.maxJsonBytes + 1024),
      }, level: 9);
      expect(bomb.length, lessThan(100 * 1024));
      expect(
        (await backupFailure(() => importer.importBytes(bomb))).code,
        ShuatiBackupFailureCode.tooLarge,
      );
      expect((await tableCounts(store)).values.every((c) => c == 0), isTrue);
    });
  });

  group('幂等与合并', () {
    test('同一份备份导入两次（merge）：行数不变，第二次全部判重', () async {
      final store = await openTestStore();
      final importer = ShuatiBackupImporter(store, useIsolate: false);
      final bytes = jsonBytes(syntheticBackup(banks: 2, questionsPerBank: 4));
      final first = await importer.importBytes(bytes);
      final counts = await tableCounts(store);
      final second = await importer.importBytes(bytes);

      expect(await tableCounts(store), counts);
      expect(first.questions.added, 8);
      expect((second.banks.added, second.banks.duplicate), (0, 2));
      expect((second.questions.added, second.questions.duplicate), (0, 8));
      expect((second.records.added, second.records.duplicate), (0, 8));
      expect((second.favorites.added, second.favorites.duplicate), (0, 2));
      expect(
        (
          second.wrongQuestions.added,
          second.wrongQuestions.duplicate,
          second.wrongQuestions.merged,
        ),
        (0, 4, 0),
      );
      expect(
        (second.aiExplanations.added, second.aiExplanations.duplicate),
        (0, 2),
      );
      expect((second.settings.added, second.settings.duplicate), (0, 1));
      expect((await store.checkIntegrity()).isHealthy, isTrue);
    });

    test('merge 之后 replaceAll 再导同一份：结果与首次一致', () async {
      final store = await openTestStore();
      final importer = ShuatiBackupImporter(store, useIsolate: false);
      final bytes = jsonBytes(syntheticBackup());
      await importer.importBytes(bytes);
      final reference = await tableCounts(store);
      await store.records.upsert(
        record('bank-1', 'b1-q1', timestamp: 99999),
      ); // 本地新增
      await importer.importBytes(bytes, mode: BackupImportMode.replaceAll);
      expect(await tableCounts(store), reference); // 本地新增被清掉
    });

    test('merge 不删本地数据：本地独有的题库 / 记录保留，备份缺的补上', () async {
      final store = await openTestStore();
      await seedBank(store, 'local', [question('lq', 'local')]);
      await store.records.upsert(record('local', 'lq', timestamp: 7));
      await store.settings.set('theme', 'light');

      final report = await ShuatiBackupImporter(
        store,
        useIsolate: false,
      ).importBytes(jsonBytes(syntheticBackup(banks: 1, questionsPerBank: 2)));

      expect(report.banks.added, 1);
      expect((await store.banks.getAllBanks()).map((b) => b.id).toSet(), {
        'local',
        'bank-1',
      });
      expect(await store.records.getByBank('local'), hasLength(1));
      expect(await store.settings.get<String>('theme'), 'light'); // 本地设置优先
      expect(report.settings.duplicate, 1);
    });

    test('已存在的题库：保留本地元数据，补充备份里本地没有的题', () async {
      final store = await openTestStore();
      await store.banks.insertBank(
        bank('bank-1', name: '本地改过的名字', updatedAt: 9),
      );
      await store.questions.insertAll([question('b1-q1', 'bank-1')]);
      final report = await ShuatiBackupImporter(
        store,
        useIsolate: false,
      ).importBytes(jsonBytes(syntheticBackup(banks: 1, questionsPerBank: 3)));
      expect(
        (
          report.banks.duplicate,
          report.questions.added,
          report.questions.duplicate,
        ),
        (1, 2, 1),
      );
      final b = (await store.banks.getBank('bank-1'))!;
      expect((b.name, b.updatedAt, b.questionCount), ('本地改过的名字', 9, 3));
      expect((await store.questions.getByBank('bank-1')).map((q) => q.id), [
        'b1-q1',
        'b1-q2',
        'b1-q3',
      ]);
    });

    test('永久错题合并：更早的首次、更晚的最近一次、更大的次数；重复合并幂等', () async {
      final store = await openTestStore();
      await seedBank(store, 'b', [question('q', 'b')]);
      await store.wrongQuestions.mark(
        'b',
        'q',
        timestamp: 500,
      ); // 本地：first=last=500,count=1
      Map<String, Object?> backup(int first, int last, int count) => {
        'version': 3,
        'banks': [
          {
            'id': 'b',
            'name': 'n',
            'createdAt': 1,
            'updatedAt': 1,
            'questionCount': 1,
          },
        ],
        'questions': {
          'b': [question('q', 'b').toJson()],
        },
        'wrongQuestions': [
          {
            'bankId': 'b',
            'questionId': 'q',
            'firstWrongAt': first,
            'lastWrongAt': last,
            'wrongCount': count,
          },
        ],
      };
      final importer = ShuatiBackupImporter(store, useIsolate: false);
      final r1 = await importer.importBytes(jsonBytes(backup(100, 900, 4)));
      expect(r1.wrongQuestions.merged, 1);
      var w = (await store.wrongQuestions.find('b', 'q'))!;
      expect((w.firstWrongAt, w.lastWrongAt, w.wrongCount), (100, 900, 4));
      final r2 = await importer.importBytes(jsonBytes(backup(100, 900, 4)));
      expect((r2.wrongQuestions.merged, r2.wrongQuestions.duplicate), (0, 1));
      // 较旧的备份不会把本地较新的数据冲掉
      await importer.importBytes(jsonBytes(backup(300, 400, 2)));
      w = (await store.wrongQuestions.find('b', 'q'))!;
      expect((w.firstWrongAt, w.lastWrongAt, w.wrongCount), (100, 900, 4));
    });

    test('作答记录按 (题库,题,时间,状态,答案) 判重，与 PWA 自增 id 无关', () async {
      final store = await openTestStore();
      await seedBank(store, 'b', [question('q', 'b')]);
      await store.records.upsert(record('b', 'q', timestamp: 1000)); // 本地 id=1
      final backup = {
        'version': 3,
        'banks': [
          {
            'id': 'b',
            'name': 'n',
            'createdAt': 1,
            'updatedAt': 1,
            'questionCount': 1,
          },
        ],
        'questions': {
          'b': [question('q', 'b').toJson()],
        },
        'records': [
          // PWA 里 id=1 的是另一条记录；与本地 id=1 撞号但内容不同 → 都应保留
          {
            'id': 1,
            'bankId': 'b',
            'questionId': 'q',
            'userAnswer': ['B'],
            'status': 'wrong',
            'timestamp': 2000,
          },
          // 与本地 id=1 内容完全相同（PWA 的 id=7）→ 判重
          {
            'id': 7,
            'bankId': 'b',
            'questionId': 'q',
            'userAnswer': ['A'],
            'status': 'correct',
            'timestamp': 1000,
          },
        ],
        'wrongQuestions': [
          {
            'bankId': 'b',
            'questionId': 'q',
            'firstWrongAt': 2000,
            'lastWrongAt': 2000,
            'wrongCount': 1,
            'lastRecordId': 1,
          },
        ],
      };
      final report = await ShuatiBackupImporter(
        store,
        useIsolate: false,
      ).importBytes(jsonBytes(backup));
      expect((report.records.added, report.records.duplicate), (1, 1));
      final records = await store.records.getAll();
      expect(records, hasLength(2));
      final wrong = (await store.wrongQuestions.find('b', 'q'))!;
      final target = records.firstWhere((r) => r.id == wrong.lastRecordId);
      expect(target.status, AnswerStatus.wrong); // lastRecordId 被重映射到新写入的那条
    });

    test('题目 id 与库内另一题库冲突：换新 id，其作答 / 收藏 / 错题 / AI 解析跟随', () async {
      var n = 0;
      final store = await openTestStore();
      await seedBank(store, 'other', [
        question('shared', 'other', text: '别的题库的题'),
      ]);
      final backup = {
        'version': 3,
        'banks': [
          {
            'id': 'b',
            'name': 'n',
            'createdAt': 1,
            'updatedAt': 1,
            'questionCount': 1,
          },
        ],
        'questions': {
          'b': [question('shared', 'b', text: '备份里的题').toJson()],
        },
        'records': [
          {
            'id': 1,
            'bankId': 'b',
            'questionId': 'shared',
            'userAnswer': ['B'],
            'status': 'wrong',
            'timestamp': 5,
          },
        ],
        'favorites': [
          {'bankId': 'b', 'questionId': 'shared', 'timestamp': 5},
        ],
        'wrongQuestions': [
          {
            'bankId': 'b',
            'questionId': 'shared',
            'firstWrongAt': 5,
            'lastWrongAt': 5,
            'wrongCount': 1,
            'lastRecordId': 1,
          },
        ],
        'aiExplanations': [
          {
            'bankId': 'b',
            'questionId': 'shared',
            'explanation': 'E',
            'createdAt': 5,
          },
        ],
      };
      final report = await ShuatiBackupImporter(
        store,
        useIsolate: false,
        newId: () => 'fresh-${++n}',
      ).importBytes(jsonBytes(backup));
      expect(report.idsRemapped, 1);
      expect((await store.questions.getByBank('other')).single.id, 'shared');
      final moved = (await store.questions.getByBank('b')).single;
      expect(moved.id, 'fresh-1');
      expect((await store.records.getByBank('b')).single.questionId, 'fresh-1');
      expect(await store.favorites.questionIds('b'), ['fresh-1']);
      expect(
        (await store.wrongQuestions.entriesByBank('b')).single.questionId,
        'fresh-1',
      );
      expect(
        (await store.aiExplanations.getAll()).single.questionId,
        'fresh-1',
      );
      expect((await store.checkIntegrity()).isHealthy, isTrue);
    });
  });

  group('完整性：孤儿 / 重复 / 非法条目', () {
    Map<String, Object?> messy() => {
      'version': 3,
      'banks': [
        {
          'id': 'b',
          'name': 'n',
          'createdAt': 1,
          'updatedAt': 1,
          'questionCount': 99,
        },
        {
          'id': 'b',
          'name': 'dup bank',
          'createdAt': 1,
          'updatedAt': 1,
          'questionCount': 1,
        },
        {'name': 'no id'},
        'not an object',
      ],
      'questions': {
        'b': [
          question('q1', 'b').toJson(),
          question('q1', 'b', text: '重复 id').toJson(),
          question('q2', 'ghost-bank').toJson(),
          {'id': 'q3', 'bankId': 'b'},
          'junk',
          question('q4', 'b').toJson(),
        ],
        'not-a-list': 5,
      },
      'records': [
        {
          'bankId': 'b',
          'questionId': 'q1',
          'userAnswer': ['A'],
          'status': 'correct',
          'timestamp': 1,
        },
        {
          'bankId': 'b',
          'questionId': 'nope',
          'userAnswer': ['A'],
          'status': 'correct',
          'timestamp': 2,
        },
        {
          'bankId': 'ghost',
          'questionId': 'q1',
          'userAnswer': ['A'],
          'status': 'correct',
          'timestamp': 3,
        },
        {
          'bankId': 'b',
          'questionId': 'q1',
          'userAnswer': ['A'],
          'status': 'maybe',
          'timestamp': 4,
        },
        {'bankId': 'b', 'questionId': 'q1', 'status': 'correct'},
      ],
      'favorites': [
        {'bankId': 'b', 'questionId': 'q1', 'timestamp': 1},
        {'bankId': 'b', 'questionId': 'q1', 'timestamp': 2},
        {'bankId': 'b', 'questionId': 'nope', 'timestamp': 1},
      ],
      'wrongQuestions': [
        {
          'bankId': 'b',
          'questionId': 'nope',
          'firstWrongAt': 1,
          'lastWrongAt': 1,
          'wrongCount': 1,
        },
        {
          'bankId': 'b',
          'questionId': 'q1',
          'firstWrongAt': 1,
          'lastWrongAt': 1,
          'wrongCount': 1,
          'lastRecordId': 12345,
        },
      ],
      'aiExplanations': [
        {'questionId': 'q1', 'explanation': '旧版没有 bankId 的解析', 'createdAt': 1},
        {
          'bankId': 'b',
          'questionId': 'nope',
          'explanation': 'x',
          'createdAt': 1,
        },
      ],
    };

    test(
      '孤儿丢弃并计数；重复 id 保留第一条；question_count 以实际为准；lastRecordId 悬空置空',
      () async {
        final store = await openTestStore();
        final report = await ShuatiBackupImporter(
          store,
          useIsolate: false,
        ).importBytes(jsonBytes(messy()));

        expect(
          (report.banks.added, report.banks.invalid),
          (1, 3),
        ); // 重复 id / 缺 id / 非对象
        expect(report.questions.added, 2); // q1 q4
        expect(report.questions.orphan, 1); // ghost-bank
        expect(report.questions.duplicate, 1); // 重复 id
        expect(report.questions.invalid, 3); // 缺字段 / junk / 非数组桶
        expect(
          (report.records.added, report.records.orphan, report.records.invalid),
          (1, 2, 2),
        );
        expect(
          (
            report.favorites.added,
            report.favorites.duplicate,
            report.favorites.orphan,
          ),
          (1, 1, 1),
        );
        expect(
          (report.wrongQuestions.added, report.wrongQuestions.orphan),
          (1, 1),
        );
        expect(
          (report.aiExplanations.added, report.aiExplanations.orphan),
          (1, 1),
        );
        expect((await store.banks.getBank('b'))!.questionCount, 2);
        expect(
          (await store.wrongQuestions.find('b', 'q1'))!.lastRecordId,
          isNull,
        );
        expect((await store.aiExplanations.getAll()).single.bankId, 'b'); // 回填
        expect((await store.checkIntegrity()).isHealthy, isTrue);
        expect(report.issues, isNotEmpty); // Stage-A 检查器也报告了结构问题
      },
    );

    test('题目全是孤儿也不会写入脏行', () async {
      final store = await openTestStore();
      final data = {
        'version': 3,
        'banks': <Object>[],
        'questions': {
          'x': [question('q', 'x').toJson()],
        },
        'records': [
          {
            'bankId': 'x',
            'questionId': 'q',
            'userAnswer': ['A'],
            'status': 'correct',
            'timestamp': 1,
          },
        ],
      };
      final report = await ShuatiBackupImporter(
        store,
        useIsolate: false,
      ).importBytes(jsonBytes(data));
      expect((report.questions.orphan, report.records.orphan), (1, 1));
      expect((await tableCounts(store)).values.every((c) => c == 0), isTrue);
    });
  });

  group('事务回滚', () {
    Future<void> poison(ShuatiStore store) => store.executor.execute('''
CREATE TRIGGER poison BEFORE INSERT ON records
WHEN NEW.timestamp = 424242
BEGIN SELECT RAISE(ABORT, 'poisoned'); END''');

    Map<String, Object?> withPoison() {
      final data = syntheticBackup();
      ((data['records']! as List).last as Map)['timestamp'] = 424242;
      return data;
    }

    test('merge：写到记录阶段失败 → 题库 / 题目也一并回滚', () async {
      final store = await openTestStore();
      await seedBank(store, 'keep', [question('kq', 'keep')]);
      await poison(store);
      final before = await tableCounts(store);
      await expectLater(
        ShuatiBackupImporter(
          store,
          useIsolate: false,
        ).importBytes(jsonBytes(withPoison())),
        throwsA(anything),
      );
      expect(await tableCounts(store), before);
    });

    test('replaceAll：失败时旧数据完好（清空与写入同属一个事务）', () async {
      final store = await openTestStore();
      await seedBank(store, 'keep', [question('kq', 'keep')]);
      await store.records.upsert(record('keep', 'kq'));
      await poison(store);
      final before = await tableCounts(store);
      await expectLater(
        ShuatiBackupImporter(store, useIsolate: false).importBytes(
          jsonBytes(withPoison()),
          mode: BackupImportMode.replaceAll,
        ),
        throwsA(anything),
      );
      expect(await tableCounts(store), before);
      expect((await store.banks.getBank('keep'))!.id, 'keep');
    });
  });

  group('资源上限与坏输入', () {
    test('空文件 / 非 JSON / 根不是对象 / 超大 JSON / 集合类型错误', () async {
      final store = await openTestStore();
      final importer = ShuatiBackupImporter(store, useIsolate: false);
      expect(
        (await backupFailure(() => importer.importBytes(Uint8List(0)))).code,
        ShuatiBackupFailureCode.invalidJson,
      );
      expect(
        (await backupFailure(() => importer.importBytes(utf8Bytes('{oops'))))
            .code,
        ShuatiBackupFailureCode.invalidJson,
      );
      expect(
        (await backupFailure(() => importer.importBytes(utf8Bytes('[1,2]'))))
            .code,
        ShuatiBackupFailureCode.invalidJson,
      );
      expect(
        (await backupFailure(
          () => importer.importBytes(
            Uint8List(ShuatiBackupSchema.maxJsonBytes + 1),
          ),
        )).code,
        ShuatiBackupFailureCode.tooLarge,
      );
      expect(
        (await backupFailure(
          () => importer.importBytes(jsonBytes({'version': 3, 'banks': 'x'})),
        )).code,
        ShuatiBackupFailureCode.unsupported,
      );
      expect(
        (await backupFailure(
          () => importer.importBytes(jsonBytes({'version': '3'})),
        )).code,
        ShuatiBackupFailureCode.unsupported,
      );
      expect((await tableCounts(store)).values.every((c) => c == 0), isTrue);
    });

    test('集合条目数超过上限 → 整体拒绝', () async {
      final store = await openTestStore();
      final importer = ShuatiBackupImporter(store, useIsolate: false);
      final tooMany = {
        'version': 3,
        'favorites': List.generate(
          ShuatiBackupSchema.maxEntriesPerCollection + 1,
          (i) => 0,
        ),
      };
      expect(
        (await backupFailure(() => importer.importBytes(jsonBytes(tooMany))))
            .code,
        ShuatiBackupFailureCode.unsupported,
      );
    });

    test('后台 isolate 版本与同步版本结果一致', () async {
      final bytes = jsonBytes(syntheticBackup());
      final a = await openTestStore();
      final b = await openTestStore();
      await ShuatiBackupImporter(a, useIsolate: false).importBytes(bytes);
      await ShuatiBackupImporter(b).importBytes(bytes);
      expect(await tableCounts(a), await tableCounts(b));
    });
  });

  group('AI 凭据永不落库', () {
    test('任何版本、任何模式导入后，库里搜不到凭据字符串', () async {
      for (final version in [2, 3]) {
        for (final mode in BackupImportMode.values) {
          final store = await openTestStore();
          await ShuatiBackupImporter(store, useIsolate: false).importBytes(
            jsonBytes(syntheticBackup(version: version)),
            mode: mode,
          );
          final dump = await dumpAllText(store);
          expect(dump.contains('sk-NOT-A-REAL-KEY'), isFalse);
          expect(dump.contains('example.invalid'), isFalse);
          expect(dump.contains('model-x'), isFalse);
          expect(await store.settings.getForExport(), hasLength(1));
        }
      }
    });

    test('更宽的凭据 key 也被丢弃：apiKey / token / secret / ai-', () async {
      final store = await openTestStore();
      final data = {
        'version': 3,
        'settings': [
          {'key': 'openaiApiKey', 'value': 'x', 'updatedAt': 1},
          {'key': 'auth_token', 'value': 'x', 'updatedAt': 1},
          {'key': 'client_secret', 'value': 'x', 'updatedAt': 1},
          {'key': 'ai-endpoint', 'value': 'x', 'updatedAt': 1},
          {'key': 'AI_MODEL', 'value': 'x', 'updatedAt': 1},
          {'key': 'theme', 'value': 'dark', 'updatedAt': 1},
        ],
      };
      final report = await ShuatiBackupImporter(
        store,
        useIsolate: false,
      ).importBytes(jsonBytes(data));
      expect(report.droppedAiSettings, 5);
      expect((await store.settings.getAll()).map((s) => s.key), ['theme']);
    });
  });

  group('Stage-A 检查器扩展', () {
    test('isAiOrSecretSettingKey', () {
      for (final k in [
        'ai_apiKey',
        'ai_endpoint',
        'AI_MODEL',
        'ai-x',
        'ai.y',
        'apiKey',
        'my_api_key',
        'x-api-key',
        'secretValue',
        'authToken',
        'password',
      ]) {
        expect(ShuatiBackupSchema.isAiOrSecretSettingKey(k), isTrue, reason: k);
      }
      for (final k in [
        'theme',
        'airplane',
        'color_palette',
        'last_bank',
        'ai',
      ]) {
        expect(
          ShuatiBackupSchema.isAiOrSecretSettingKey(k),
          isFalse,
          reason: k,
        );
      }
    });

    test('inspectJson 的 ignoredAiSettingCount 与导入实际丢弃数一致', () {
      final data = syntheticBackup();
      final inspection = ShuatiBackupSchema.inspectJson(jsonEncode(data));
      final prepared = prepareBackupSync(jsonEncode(data));
      expect(inspection.ignoredAiSettingCount, prepared.droppedAiSettings);
    });
  });

  group('性能冒烟', () {
    test('2000 题 + 20000 条作答记录的备份在合理时间内导入', () async {
      final store = await openTestStore();
      final banks = <Map<String, Object?>>[];
      final questions = <String, List<Map<String, Object?>>>{};
      final records = <Map<String, Object?>>[];
      for (var b = 0; b < 4; b++) {
        banks.add({
          'id': 'pb$b',
          'name': 'perf $b',
          'createdAt': 1,
          'updatedAt': 1,
          'questionCount': 500,
        });
        questions['pb$b'] = [
          for (var i = 0; i < 500; i++)
            attachQuestionHash(
              question('pb$b-q$i', 'pb$b', text: '性能题 $b-$i', hashed: false),
            ).toJson(),
        ];
        for (var i = 0; i < 500; i++) {
          for (var k = 0; k < 10; k++) {
            records.add({
              'id': b * 5000 + i * 10 + k + 1,
              'bankId': 'pb$b',
              'questionId': 'pb$b-q$i',
              'userAnswer': ['A'],
              'status': k.isEven ? 'correct' : 'wrong',
              'timestamp': 1000 + k,
            });
          }
        }
      }
      final bytes = jsonBytes({
        'version': 3,
        'banks': banks,
        'questions': questions,
        'records': records,
      });
      final sw = Stopwatch()..start();
      final report = await ShuatiBackupImporter(store).importBytes(bytes);
      sw.stop();
      expect(report.questions.added, 2000);
      expect(report.records.added, 20000);
      expect(sw.elapsed, lessThan(const Duration(seconds: 60)));
      expect((await store.checkIntegrity()).isHealthy, isTrue);
    });
  });
}
