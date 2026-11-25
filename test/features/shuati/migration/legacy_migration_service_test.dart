// 旧版迁移服务的端到端幂等性 / 标记 / 跳过逻辑测试（假 extractor + 内存库）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/shuati/backup/backup_importer.dart';
import 'package:jxu_campus_hub/features/shuati/domain/shuati_models.dart';
import 'package:jxu_campus_hub/features/shuati/migration/legacy_payload.dart';
import 'package:jxu_campus_hub/features/shuati/migration/shuati_legacy_extractor.dart';
import 'package:jxu_campus_hub/features/shuati/migration/shuati_legacy_migration_service.dart';
import 'package:jxu_campus_hub/features/shuati/persistence/shuati_store.dart';

import '../../../helpers/shuati_test_support.dart';

class _FakeExtractor implements ShuatiLegacyExtractor {
  _FakeExtractor(this.extraction);

  ShuatiLegacyExtraction extraction;
  int calls = 0;
  Object? error;

  @override
  Future<ShuatiLegacyExtraction> extract() async {
    calls++;
    final e = error;
    if (e != null) throw e;
    return extraction;
  }
}

class _MemoryPrefs implements ShuatiMigrationPrefs {
  final bools = <String, bool>{};
  final ints = <String, int>{};

  @override
  Future<bool> getBool(String key) async => bools[key] ?? false;

  @override
  Future<int> getInt(String key) async => ints[key] ?? 0;

  @override
  Future<void> setBool(String key, bool value) async => bools[key] = value;

  @override
  Future<void> setInt(String key, int value) async => ints[key] = value;
}

ShuatiLegacyExtraction _legacyExtraction() => ShuatiLegacyExtraction(
  databaseVersion: 50,
  storeNames: const [
    'banks',
    'questions',
    'records',
    'favorites',
    'practiceSessions',
    'settings',
  ],
  stores: {
    'banks': [
      {
        'id': 'legacy-bank',
        'name': '旧题库',
        'createdAt': 1000,
        'updatedAt': 2000,
        'questionCount': 2,
      },
    ],
    'questions': [
      {
        'id': 'lq1',
        'bankId': 'legacy-bank',
        'type': 'single',
        'question': '旧题一？',
        'options': {'A': '甲', 'B': '乙'},
        'answer': ['A'],
      },
      {
        'id': 'lq2',
        'bankId': 'legacy-bank',
        'type': 'single',
        'question': '旧题二？',
        'options': {'A': '甲', 'B': '乙'},
        'answer': ['B'],
      },
    ],
    'records': [
      {
        'id': 1,
        'bankId': 'legacy-bank',
        'questionId': 'lq1',
        'userAnswer': ['A'],
        'status': 'correct',
        'timestamp': 5000,
      },
      {
        'id': 2,
        'bankId': 'legacy-bank',
        'questionId': 'lq2',
        'userAnswer': ['A'],
        'status': 'wrong',
        'timestamp': 6000,
      },
    ],
    'favorites': [
      {
        'id': 1,
        'bankId': 'legacy-bank',
        'questionId': 'lq2',
        'timestamp': 6500,
      },
    ],
    'practiceSessions': [
      {
        'id': 'legacy-bank:sequential:all',
        'bankId': 'legacy-bank',
        'mode': 'sequential',
        'currentIndex': 1,
        'questionIds': ['lq1', 'lq2'],
        'updatedAt': 7000,
      },
      {
        'id': 'last',
        'bankId': 'legacy-bank',
        'mode': 'sequential',
        'currentIndex': 1,
        'questionIds': ['lq1', 'lq2'],
        'updatedAt': 7000,
      },
    ],
    'settings': [
      {'key': 'ai_endpoint', 'value': 'https://legacy.invalid', 'updatedAt': 1},
    ],
  },
  progressByKey: const {},
);

(ShuatiLegacyMigrationService, _FakeExtractor, _MemoryPrefs) _service(
  ShuatiStore store,
  ShuatiLegacyExtraction extraction,
) {
  final extractor = _FakeExtractor(extraction);
  final prefs = _MemoryPrefs();
  return (
    ShuatiLegacyMigrationService(
      store: store,
      extractor: extractor,
      prefs: prefs,
      // 测试里禁 isolate（ffi 内存库不能跨 isolate 传递）。
      importerFactory: (s) => ShuatiBackupImporter(s, useIsolate: false),
    ),
    extractor,
    prefs,
  );
}

void main() {
  test(
    'migrates legacy data end-to-end into an empty native database',
    () async {
      final store = await openTestStore();
      final (service, extractor, prefs) = _service(store, _legacyExtraction());

      expect(await service.shouldAutoMigrate(), isTrue);
      final outcome = await service.migrateIfNeeded();

      expect(outcome.status, ShuatiLegacyMigrationStatus.migrated);
      expect(extractor.calls, 1);
      final report = outcome.report!;
      expect(report.banks.added, 1);
      expect(report.questions.added, 2);
      expect(report.records.added, 2);
      expect(report.favorites.added, 1);
      // 错题由记录推导（lq2 最新为 wrong）
      expect(outcome.derivedWrongCount, 1);
      expect(report.wrongQuestions.added, 1);
      // AI 凭据设置永不落库
      expect(report.droppedAiSettings, 1);
      expect(await store.settings.getAll(), isEmpty);
      // 会话写入（scoped + last）
      expect(outcome.sessionsWritten, 2);
      final session = await store.sessions.load(
        bankId: 'legacy-bank',
        mode: PracticeMode.sequential,
      );
      expect(session, isNotNull);
      expect(session!.currentIndex, 1);
      expect(session.questionIds, ['lq1', 'lq2']);
      // 完成标记已写，失败计数清零
      expect(prefs.bools[ShuatiLegacyMigrationService.completedKey], isTrue);
    },
  );

  test(
    'is idempotent: repeated migration does not change row counts',
    () async {
      final store = await openTestStore();
      final (service, _, _) = _service(store, _legacyExtraction());

      final first = await service.migrateNow();
      expect(first.status, ShuatiLegacyMigrationStatus.migrated);
      final countsAfterFirst = await tableCounts(store);

      final second = await service.migrateNow();
      expect(second.status, ShuatiLegacyMigrationStatus.migrated);
      final report = second.report!;
      // 第二次全是重复命中
      expect(report.banks.added, 0);
      expect(report.questions.added, 0);
      expect(report.records.added, 0);
      expect(report.questions.duplicate, 2);
      expect(report.records.duplicate, 2);
      // 会话不再重复写入
      expect(second.sessionsWritten, 0);
      expect(await tableCounts(store), countsAfterFirst);
    },
  );

  test('skips auto migration once completed', () async {
    final store = await openTestStore();
    final (service, extractor, prefs) = _service(store, _legacyExtraction());

    await service.migrateIfNeeded();
    expect(prefs.bools[ShuatiLegacyMigrationService.completedKey], isTrue);

    final outcome = await service.migrateIfNeeded();
    expect(outcome.status, ShuatiLegacyMigrationStatus.skipped);
    expect(extractor.calls, 1); // 第二次没有再去读 WebView
  });

  test('skips auto migration when native database is not empty', () async {
    final store = await openTestStore();
    await seedBank(store, 'local-bank', [question('lq-local', 'local-bank')]);
    final (service, extractor, _) = _service(store, _legacyExtraction());

    expect(await service.shouldAutoMigrate(), isFalse);
    final outcome = await service.migrateIfNeeded();
    expect(outcome.status, ShuatiLegacyMigrationStatus.skipped);
    expect(extractor.calls, 0);
    // 本地内容不受任何影响
    final banks = await store.banks.getAllBanks();
    expect(banks.map((b) => b.id), ['local-bank']);
  });

  test('no legacy data marks completed without writing anything', () async {
    final store = await openTestStore();
    final (service, _, prefs) = _service(store, const ShuatiLegacyExtraction());

    final outcome = await service.migrateIfNeeded();
    expect(outcome.status, ShuatiLegacyMigrationStatus.noLegacyData);
    expect(prefs.bools[ShuatiLegacyMigrationService.completedKey], isTrue);
    for (final count in (await tableCounts(store)).values) {
      expect(count, 0);
    }
  });

  test(
    'extraction failure is reported, not marked completed, stops after cap',
    () async {
      final store = await openTestStore();
      final (service, extractor, prefs) = _service(store, _legacyExtraction());
      extractor.error = StateError('webview unavailable');

      for (var i = 0; i < ShuatiLegacyMigrationService.maxAutoFailures; i++) {
        final outcome = await service.migrateIfNeeded();
        expect(outcome.status, ShuatiLegacyMigrationStatus.failed);
        expect(
          prefs.bools[ShuatiLegacyMigrationService.completedKey] ?? false,
          isFalse,
        );
      }
      expect(extractor.calls, ShuatiLegacyMigrationService.maxAutoFailures);

      // 连续失败达上限：自动路径不再重试（不会再碰 WebView）
      final after = await service.migrateIfNeeded();
      expect(after.status, ShuatiLegacyMigrationStatus.skipped);
      expect(extractor.calls, ShuatiLegacyMigrationService.maxAutoFailures);

      // 手动入口不受影响，仍可重试
      final manual = await service.migrateNow();
      expect(manual.status, ShuatiLegacyMigrationStatus.failed);
      expect(extractor.calls, ShuatiLegacyMigrationService.maxAutoFailures + 1);
    },
  );

  test('success resets the failure counter', () async {
    final store = await openTestStore();
    final (service, extractor, prefs) = _service(store, _legacyExtraction());
    extractor.error = StateError('boom');
    await service.migrateNow();
    expect(prefs.ints[ShuatiLegacyMigrationService.failureCountKey], 1);

    extractor.error = null;
    final outcome = await service.migrateNow();
    expect(outcome.status, ShuatiLegacyMigrationStatus.migrated);
    expect(prefs.ints[ShuatiLegacyMigrationService.failureCountKey], 0);
  });

  test(
    'legacy backup json round-trips through the standard backup importer',
    () async {
      // 转换产物与「文件备份」共用同一条 prepare + import 管线：同一 payload
      // 既能走迁移服务，也能被 importBytes 幂等导入。
      final artifacts = buildLegacyMigrationArtifacts(_legacyExtraction());
      final store = await openTestStore();
      final importer = ShuatiBackupImporter(store, useIsolate: false);
      final bytes = utf8Bytes(artifacts.backupJson);

      final first = await importer.importBytes(bytes);
      expect(first.questions.added, 2);
      final countsAfterFirst = await tableCounts(store);
      final second = await importer.importBytes(bytes);
      expect(second.questions.added, 0);
      expect(second.records.duplicate, 2);
      expect(await tableCounts(store), countsAfterFirst);
    },
  );

  test('wrong derivation handles records without ids', () async {
    final extraction = ShuatiLegacyExtraction(
      storeNames: const ['banks', 'questions', 'records'],
      stores: {
        'banks': [
          {
            'id': 'b1',
            'name': 'Bank',
            'createdAt': 1,
            'updatedAt': 1,
            'questionCount': 1,
          },
        ],
        'questions': [
          {
            'id': 'q1',
            'bankId': 'b1',
            'type': 'single',
            'question': 'No-id record question?',
            'options': {'A': 'x', 'B': 'y'},
            'answer': ['A'],
          },
        ],
        'records': [
          {
            // 无 id（极端情况；IndexedDB 自增键其实总有 id，防御性覆盖）
            'bankId': 'b1',
            'questionId': 'q1',
            'userAnswer': ['B'],
            'status': 'wrong',
            'timestamp': 5000,
          },
        ],
      },
    );
    final artifacts = buildLegacyMigrationArtifacts(extraction);
    expect(artifacts.derivedWrongCount, 1);
    final decoded = jsonDecode(artifacts.backupJson) as Map<String, Object?>;
    final wrong = (decoded['wrongQuestions']! as List).cast<Map>().single;
    expect(wrong.containsKey('lastRecordId'), isFalse);
  });
}
