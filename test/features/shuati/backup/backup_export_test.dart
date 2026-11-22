// 导出：ExportDataV3 JSON / ZIP，与 PWA exportService.test.ts 对齐，并验证与导入的往返。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/shuati/backup/backup_exporter.dart';
import 'package:jxu_campus_hub/features/shuati/backup/backup_importer.dart';
import 'package:jxu_campus_hub/features/shuati/backup/backup_models.dart';
import 'package:jxu_campus_hub/features/shuati/domain/shuati_models.dart';
import 'package:jxu_campus_hub/features/shuati/import/safe_zip.dart';
import 'package:jxu_campus_hub/features/shuati/persistence/shuati_store.dart';
import 'package:jxu_campus_hub/features/shuati/shuati_backup_schema.dart';

import '../../../helpers/shuati_test_support.dart';

ShuatiBackupExporter exporterFor(ShuatiStore store) => ShuatiBackupExporter(
  store,
  clock: () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
  useIsolate: false,
);

/// 收藏 / 永久错题 / AI 解析的自增 id 没有跨表引用，往返后可能重排；比较时忽略并按 (bank, question) 排序。
/// 题库、题目、作答记录的 id 是稳定的，必须原样保留。
Map<String, Object?> _canonical(Map<String, Object?> data) {
  final copy = Map<String, Object?>.from(data);
  for (final key in ['favorites', 'wrongQuestions', 'aiExplanations']) {
    final list = copy[key] as List?;
    if (list == null) continue;
    final rows =
        [
          for (final row in list)
            Map<String, Object?>.from(row as Map)..remove('id'),
        ]..sort(
          (a, b) => '${a['bankId']}${a['questionId']}'.compareTo(
            '${b['bankId']}${b['questionId']}',
          ),
        );
    copy[key] = rows;
  }
  return copy;
}

Future<Map<String, Object?>> exportMap(ShuatiStore store) async =>
    jsonDecode(await exporterFor(store).exportJson()) as Map<String, Object?>;

void main() {
  group('exportAllData (exportService.test.ts)', () {
    test('返回正确结构的 ExportDataV3 JSON', () async {
      final store = await openTestStore();
      await seedBank(store, 'b1', [question('q1', 'b1'), question('q2', 'b1')]);
      await store.records.upsert(record('b1', 'q1'));
      await store.toggleFavorite('b1', 'q1');

      final data = await exportMap(store);
      expect(data['version'], 3);
      expect(data['exportedAt'], 1700000000000);
      expect((data['banks']! as List), hasLength(1));
      expect((data['banks']! as List).first['id'], 'b1');
      expect(data['records'], hasLength(1));
      expect(data['favorites'], hasLength(1));
    });

    test('题目按 bankId 分组，组内保持题库顺序', () async {
      final store = await openTestStore();
      await seedBank(store, 'b1', [question('q2', 'b1'), question('q1', 'b1')]);
      await seedBank(store, 'b2', [question('q3', 'b2')]);
      final data = await exportMap(store);
      final qs = data['questions']! as Map<String, Object?>;
      expect((qs['b1']! as List).map((q) => (q as Map)['id']), ['q2', 'q1']);
      expect(qs['b2'], hasLength(1));
    });

    test('AI 凭据被排除（即便被绕过仓库写进了库）', () async {
      final store = await openTestStore();
      await store.settings.set('theme', 'dark');
      await store.executor.insert('settings', {
        'key': 'ai_apiKey',
        'value_json': '"sk-leak"',
        'updated_at': 1,
      });
      await store.executor.insert('settings', {
        'key': 'ai_endpoint',
        'value_json': '"ep"',
        'updated_at': 1,
      });
      final json = await exporterFor(store).exportJson();
      final data = jsonDecode(json) as Map<String, Object?>;
      expect((data['settings']! as List).map((s) => (s as Map)['key']), [
        'theme',
      ]);
      expect(json.contains('sk-leak'), isFalse);
    });

    test('无 AI 解析 / 无设置 / 无永久错题时省略对应字段；有时包含', () async {
      final store = await openTestStore();
      var data = await exportMap(store);
      expect(data.containsKey('aiExplanations'), isFalse);
      expect(data.containsKey('settings'), isFalse);
      expect(data.containsKey('wrongQuestions'), isFalse);

      await seedBank(store, 'b1', [question('q1', 'b1')]);
      await store.aiExplanations.insertRaw(
        const AiExplanationRow(
          bankId: 'b1',
          questionId: 'q1',
          explanation: 'E',
          createdAt: 1000,
        ),
      );
      await store.wrongQuestions.mark('b1', 'q1', timestamp: 1000);
      await store.settings.set('theme', 'dark');
      data = await exportMap(store);
      expect(data['aiExplanations'], hasLength(1));
      expect(data['wrongQuestions'], hasLength(1));
      expect(
        (data['wrongQuestions']! as List).first,
        containsPair('wrongCount', 1),
      );
      expect(data['settings'], hasLength(1));
    });

    test('空数据库返回空结构', () async {
      final store = await openTestStore();
      final data = await exportMap(store);
      expect(data['banks'], isEmpty);
      expect(data['questions'], isEmpty);
      expect(data['records'], isEmpty);
      expect(data['favorites'], isEmpty);
    });

    test('exportBankQuestionsJson：指定题库、缩进 2 空格；不存在返回空数组', () async {
      final store = await openTestStore();
      await seedBank(store, 'b1', [question('q1', 'b1'), question('q2', 'b1')]);
      await seedBank(store, 'b2', [question('q3', 'b2')]);
      final text = await exporterFor(store).exportBankQuestionsJson('b1');
      expect(text, startsWith('[\n  {'));
      final list = jsonDecode(text) as List;
      expect(list, hasLength(2));
      expect(list.every((q) => (q as Map)['bankId'] == 'b1'), isTrue);
      expect(
        jsonDecode(await exporterFor(store).exportBankQuestionsJson('nope')),
        isEmpty,
      );
    });
  });

  group('ZIP', () {
    test('exportZip 只含 backup.json，内容就是 exportJson', () async {
      final store = await openTestStore();
      await seedBank(store, 'b1', [question('q1', 'b1')]);
      final exporter = exporterFor(store);
      final zipBytes = await exporter.exportZip();
      final zip = SafeZipReader.open(zipBytes);
      expect(zip.entries.keys, ['backup.json']);
      expect(
        utf8.decode(zip.read('backup.json', maxBytes: 1 << 20)),
        await exporter.exportJson(),
      );
    });

    test('isolate 版与同步版导出一致', () async {
      final store = await openTestStore();
      await seedBank(store, 'b1', [question('q1', 'b1')]);
      DateTime clock() => DateTime.fromMillisecondsSinceEpoch(5);
      final a = await ShuatiBackupExporter(
        store,
        clock: clock,
        useIsolate: true,
      ).exportJson();
      final b = await ShuatiBackupExporter(
        store,
        clock: clock,
        useIsolate: false,
      ).exportJson();
      expect(a, b);
    });
  });

  group('往返（导出 → 导入 → 再导出）', () {
    test('PWA 备份 → 原生库 → 导出 → 新库 → 再导出：数据逐字段一致', () async {
      final source = await openTestStore();
      final original = syntheticBackup(banks: 3, questionsPerBank: 4);
      await ShuatiBackupImporter(
        source,
        useIsolate: false,
      ).importBytes(utf8Bytes(jsonEncode(original)));

      final exported = await exportMap(source);
      final fresh = await openTestStore();
      await ShuatiBackupImporter(fresh, useIsolate: false).importBytes(
        await exporterFor(source).exportZip(),
        mode: BackupImportMode.replaceAll,
      );
      final again = await exportMap(fresh);

      expect(_canonical(again), _canonical(exported));
    });

    test('导出的备份与原始 PWA 备份在 ID / 记录 / 错题上等价（排序后比较）', () async {
      final store = await openTestStore();
      final original = syntheticBackup();
      await ShuatiBackupImporter(
        store,
        useIsolate: false,
      ).importBytes(utf8Bytes(jsonEncode(original)));
      final exported = await exportMap(store);

      List<String> ids(Object? v, String key) =>
          ((v! as List).map((e) => '${(e as Map)[key]}').toList()..sort());
      expect(ids(exported['banks'], 'id'), ids(original['banks'], 'id'));
      expect(ids(exported['records'], 'id'), ids(original['records'], 'id'));
      expect(
        ids(exported['wrongQuestions'], 'questionId'),
        ids(original['wrongQuestions'], 'questionId'),
      );
      final eq = (exported['questions']! as Map).map(
        (k, v) =>
            MapEntry(k, (v as List).map((q) => (q as Map)['id']).toList()),
      );
      final oq = (original['questions']! as Map).map(
        (k, v) =>
            MapEntry(k, (v as List).map((q) => (q as Map)['id']).toList()),
      );
      expect(eq, oq);
      // AI 凭据不在导出里；其余设置保留
      expect(
        ((exported['settings']! as List).map((s) => (s as Map)['key']))
            .toList(),
        ['theme'],
      );
      // 每条记录字段保持不变
      final exportedRecords = {
        for (final r in exported['records']! as List) (r as Map)['id']: r,
      };
      for (final r in original['records']! as List) {
        expect(exportedRecords[(r as Map)['id']], r);
      }
    });

    test('导出的 JSON 通过 Stage-A 结构检查器且无任何 issue', () async {
      final store = await openTestStore();
      await ShuatiBackupImporter(
        store,
        useIsolate: false,
      ).importBytes(utf8Bytes(jsonEncode(syntheticBackup())));
      final inspection = ShuatiBackupSchema.inspectJson(
        await exporterFor(store).exportJson(),
      );
      expect(inspection.isSupported, isTrue);
      expect(inspection.version, 3);
      expect(inspection.issues, isEmpty);
      expect(inspection.questionCount, 6);
      expect(inspection.ignoredAiSettingCount, 0);
    });

    test('原生新增的数据（作答 / 收藏 / 错题）也能导出并被导入回来', () async {
      final store = await openTestStore();
      await seedBank(store, 'b1', [question('q1', 'b1'), question('q2', 'b1')]);
      await store.savePracticeAnswer(
        record('b1', 'q1', status: AnswerStatus.wrong, timestamp: 11),
      );
      await store.savePracticeAnswer(record('b1', 'q2', timestamp: 12));
      await store.toggleFavorite('b1', 'q2');

      final fresh = await openTestStore();
      final report = await ShuatiBackupImporter(
        fresh,
        useIsolate: false,
      ).importBytes(await exporterFor(store).exportZip());
      expect(
        (
          report.records.added,
          report.favorites.added,
          report.wrongQuestions.added,
        ),
        (2, 1, 1),
      );
      final w = (await fresh.wrongQuestions.getAll()).single;
      expect(
        (await fresh.records.getAll())
            .firstWhere((r) => r.id == w.lastRecordId)
            .status,
        AnswerStatus.wrong,
      );
    });
  });
}
