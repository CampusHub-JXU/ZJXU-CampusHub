// 旧版 WebView 提取结果 → 备份 JSON / 会话计划的纯转换测试（离线）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/shuati/domain/shuati_models.dart';
import 'package:jxu_campus_hub/features/shuati/migration/legacy_payload.dart';

Map<String, Object?> _bank(String id) => {
  'id': id,
  'name': 'Bank $id',
  'createdAt': 1000,
  'updatedAt': 2000,
  'questionCount': 2,
};

Map<String, Object?> _question(String id, String bankId) => {
  'id': id,
  'bankId': bankId,
  'type': 'single',
  'question': 'Question $id?',
  'options': {'A': 'Alpha', 'B': 'Beta'},
  'answer': ['A'],
};

Map<String, Object?> _record(
  int id,
  String bankId,
  String questionId,
  String status,
  int timestamp,
) => {
  'id': id,
  'bankId': bankId,
  'questionId': questionId,
  'userAnswer': ['B'],
  'status': status,
  'timestamp': timestamp,
};

ShuatiLegacyExtraction _extraction({
  List<Object?> banks = const [],
  List<Object?> questions = const [],
  List<Object?> records = const [],
  List<Object?> favorites = const [],
  List<Object?> aiExplanations = const [],
  List<Object?> settings = const [],
  List<Object?> wrongQuestions = const [],
  List<Object?> sessions = const [],
  Map<String, String> progress = const {},
}) => ShuatiLegacyExtraction(
  databaseVersion: 50,
  storeNames: const [
    'banks',
    'questions',
    'records',
    'favorites',
    'aiExplanations',
    'practiceSessions',
    'settings',
  ],
  stores: {
    'banks': banks,
    'questions': questions,
    'records': records,
    'favorites': favorites,
    'aiExplanations': aiExplanations,
    'practiceSessions': sessions,
    'settings': settings,
    if (wrongQuestions.isNotEmpty) 'wrongQuestions': wrongQuestions,
  },
  progressByKey: progress,
);

void main() {
  group('ShuatiLegacyExtraction.tryFromJson', () {
    test('parses a well-formed payload', () {
      final extraction = ShuatiLegacyExtraction.tryFromJson({
        'databaseVersion': 50,
        'storeNames': ['banks'],
        'stores': {
          'banks': [_bank('b1')],
        },
        'progress': {'practice-progress-b1-sequential': '{}'},
      });
      expect(extraction, isNotNull);
      expect(extraction!.databaseVersion, 50);
      expect(extraction.stores['banks'], hasLength(1));
      expect(extraction.progressByKey, hasLength(1));
      expect(extraction.isEmpty, isFalse);
    });

    test('returns null for malformed payloads', () {
      expect(ShuatiLegacyExtraction.tryFromJson(null), isNull);
      expect(ShuatiLegacyExtraction.tryFromJson('string'), isNull);
      expect(ShuatiLegacyExtraction.tryFromJson({}), isNull);
      expect(ShuatiLegacyExtraction.tryFromJson({'stores': 'nope'}), isNull);
    });

    test('empty stores count as empty extraction', () {
      const extraction = ShuatiLegacyExtraction();
      expect(extraction.isEmpty, isTrue);
    });
  });

  group('buildLegacyMigrationArtifacts', () {
    test('produces a V3-shaped backup json with bucketed questions', () {
      final artifacts = buildLegacyMigrationArtifacts(
        _extraction(
          banks: [_bank('b1')],
          questions: [_question('q1', 'b1'), _question('q2', 'b1')],
          records: [_record(1, 'b1', 'q1', 'correct', 5000)],
          favorites: [
            {'id': 1, 'bankId': 'b1', 'questionId': 'q1', 'timestamp': 6000},
          ],
        ),
      );
      final backup = jsonDecode(artifacts.backupJson) as Map<String, Object?>;
      expect(backup['version'], 3);
      expect((backup['banks']! as List).single, isA<Map>());
      final questions = backup['questions']! as Map<String, Object?>;
      expect((questions['b1']! as List), hasLength(2));
      expect((backup['records']! as List), hasLength(1));
      expect((backup['favorites']! as List), hasLength(1));
    });

    test('drops structurally invalid rows and counts them', () {
      final artifacts = buildLegacyMigrationArtifacts(
        _extraction(
          banks: [
            _bank('b1'),
            {'noId': true},
          ],
          questions: [
            _question('q1', 'b1'),
            {'question': 'no bank id'},
          ],
        ),
      );
      expect(artifacts.droppedRows['banks'], 1);
      expect(artifacts.droppedRows['questions'], 1);
      final backup = jsonDecode(artifacts.backupJson) as Map<String, Object?>;
      expect((backup['banks']! as List), hasLength(1));
    });

    test('derives wrong questions from records when store is absent', () {
      final artifacts = buildLegacyMigrationArtifacts(
        _extraction(
          banks: [_bank('b1')],
          questions: [_question('q1', 'b1'), _question('q2', 'b1')],
          records: [
            // q1: wrong twice then correct → 最新有效作答为 correct，不推导
            _record(1, 'b1', 'q1', 'wrong', 1000),
            _record(2, 'b1', 'q1', 'wrong', 2000),
            _record(3, 'b1', 'q1', 'correct', 3000),
            // q2: correct then wrong twice → 推导一条
            _record(4, 'b1', 'q2', 'correct', 1000),
            _record(5, 'b1', 'q2', 'wrong', 2000),
            _record(6, 'b1', 'q2', 'wrong', 4000),
          ],
        ),
      );
      expect(artifacts.derivedWrongCount, 1);
      final backup = jsonDecode(artifacts.backupJson) as Map<String, Object?>;
      final wrong = (backup['wrongQuestions']! as List).cast<Map>();
      expect(wrong, hasLength(1));
      expect(wrong.single['questionId'], 'q2');
      expect(wrong.single['wrongCount'], 2);
      expect(wrong.single['firstWrongAt'], 2000);
      expect(wrong.single['lastWrongAt'], 4000);
      expect(wrong.single['lastRecordId'], 6);
    });

    test('passes through explicit wrongQuestions rows without derivation', () {
      final artifacts = buildLegacyMigrationArtifacts(
        _extraction(
          banks: [_bank('b1')],
          questions: [_question('q1', 'b1')],
          records: [_record(1, 'b1', 'q1', 'wrong', 1000)],
          wrongQuestions: [
            {
              'bankId': 'b1',
              'questionId': 'q1',
              'firstWrongAt': 900,
              'lastWrongAt': 1000,
              'wrongCount': 7,
            },
          ],
        ),
      );
      expect(artifacts.derivedWrongCount, 0);
      final backup = jsonDecode(artifacts.backupJson) as Map<String, Object?>;
      final wrong = (backup['wrongQuestions']! as List).cast<Map>();
      expect(wrong.single['wrongCount'], 7);
    });

    test('keeps ai/credential settings for the pipeline to drop', () {
      final artifacts = buildLegacyMigrationArtifacts(
        _extraction(
          banks: [_bank('b1')],
          settings: [
            {
              'key': 'ai_endpoint',
              'value': 'https://x.invalid',
              'updatedAt': 1,
            },
            {'key': 'other', 'value': true, 'updatedAt': 1},
          ],
        ),
      );
      final backup = jsonDecode(artifacts.backupJson) as Map<String, Object?>;
      // 透传；AI key 的丢弃在 prepareBackup 清洗阶段完成（备份导入管线职责）。
      expect((backup['settings']! as List), hasLength(2));
    });

    group('sessions', () {
      test('parses IndexedDB practice sessions and skips invalid ones', () {
        final artifacts = buildLegacyMigrationArtifacts(
          _extraction(
            banks: [_bank('b1')],
            questions: [_question('q1', 'b1'), _question('q2', 'b1')],
            sessions: [
              {
                'id': 'b1:sequential:all',
                'bankId': 'b1',
                'mode': 'sequential',
                'currentIndex': 99, // 越界 → 钳到题单末尾
                'questionIds': ['q1', 'q2'],
                'updatedAt': 7000,
              },
              {
                'id': 'last',
                'bankId': 'b1',
                'mode': 'sequential',
                'typeFilter': 'single',
                'currentIndex': 1,
                'questionIds': ['q1', 'q2'],
                'updatedAt': 8000,
              },
              // 未知题库 → 丢弃
              {
                'id': 'ghost:sequential:all',
                'bankId': 'ghost',
                'mode': 'sequential',
                'currentIndex': 0,
                'questionIds': ['q1'],
                'updatedAt': 1,
              },
              // 考试模式 → 丢弃
              {
                'id': 'b1:exam:all',
                'bankId': 'b1',
                'mode': 'exam',
                'currentIndex': 0,
                'questionIds': ['q1'],
                'updatedAt': 1,
              },
            ],
          ),
        );
        expect(artifacts.sessions, hasLength(2));
        final scoped = artifacts.sessions.firstWhere(
          (s) => s.id == 'b1:sequential:all',
        );
        expect(scoped.currentIndex, 1); // 99 clamp 到 len-1
        final last = artifacts.sessions.firstWhere((s) => s.id == 'last');
        expect(last.typeFilter, QuestionType.single);
      });

      test('synthesizes sequential session from localStorage fallback', () {
        final artifacts = buildLegacyMigrationArtifacts(
          _extraction(
            banks: [_bank('uuid-with-dashes-b1')],
            questions: [
              _question('q1', 'uuid-with-dashes-b1'),
              _question('q2', 'uuid-with-dashes-b1'),
            ],
            progress: {
              'practice-progress-uuid-with-dashes-b1-sequential':
                  '{"currentIndex": 1, "results": {"0": "correct"}}',
            },
          ),
        );
        expect(artifacts.sessions, hasLength(1));
        final session = artifacts.sessions.single;
        expect(session.bankId, 'uuid-with-dashes-b1');
        expect(session.mode, PracticeMode.sequential);
        expect(session.id, 'uuid-with-dashes-b1:sequential:all');
        expect(session.currentIndex, 1);
        expect(session.questionIds, ['q1', 'q2']);
      });

      test('localStorage fallback loses to IndexedDB sequential session', () {
        final artifacts = buildLegacyMigrationArtifacts(
          _extraction(
            banks: [_bank('b1')],
            questions: [_question('q1', 'b1')],
            sessions: [
              {
                'id': 'b1:sequential:all',
                'bankId': 'b1',
                'mode': 'sequential',
                'currentIndex': 0,
                'questionIds': ['q1'],
                'updatedAt': 7000,
              },
            ],
            progress: {
              'practice-progress-b1-sequential':
                  '{"currentIndex": 0, "results": {}}',
            },
          ),
        );
        expect(artifacts.sessions, hasLength(1));
        expect(artifacts.sessions.single.updatedAt, 7000);
      });

      test('malformed progress json is ignored', () {
        final artifacts = buildLegacyMigrationArtifacts(
          _extraction(
            banks: [_bank('b1')],
            questions: [_question('q1', 'b1')],
            progress: {'practice-progress-b1-sequential': 'not json'},
          ),
        );
        expect(artifacts.sessions, isEmpty);
      });
    });
  });
}
