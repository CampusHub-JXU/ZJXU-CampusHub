import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/shuati/shuati_backup_schema.dart';

void main() {
  group('ShuatiBackupSchema', () {
    test('reads a full V3 backup with counts and no issues', () {
      final inspection = ShuatiBackupSchema.inspectJson(
        jsonEncode({
          'version': 3,
          'exportedAt': 1700000000000,
          'banks': [
            {'id': 'b1', 'name': '题库'},
          ],
          'questions': {
            'b1': [
              {
                'id': 'q1',
                'bankId': 'b1',
                'type': 'single',
                'question': '1+1=?',
                'answer': ['B'],
              },
              {
                'id': 'q2',
                'bankId': 'b1',
                'type': 'judge',
                'question': '地球是圆的',
                'answer': ['true'],
              },
            ],
          },
          'records': [
            {
              'bankId': 'b1',
              'questionId': 'q1',
              'userAnswer': ['B'],
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
              'explanation': '解析',
              'createdAt': 1,
            },
          ],
          'settings': [
            {'key': 'theme', 'value': 'dark', 'updatedAt': 1},
            {'key': 'ai_model', 'value': 'gpt', 'updatedAt': 1},
          ],
          'wrongQuestions': [
            {
              'bankId': 'b1',
              'questionId': 'q1',
              'firstWrongAt': 1,
              'lastWrongAt': 2,
              'wrongCount': 1,
            },
          ],
        }),
      );

      expect(inspection.isSupported, isTrue);
      expect(inspection.errorMessage, isNull);
      expect(inspection.version, 3);
      expect(inspection.bankCount, 1);
      expect(inspection.questionCount, 2);
      expect(inspection.recordCount, 1);
      expect(inspection.favoriteCount, 1);
      expect(inspection.aiExplanationCount, 1);
      expect(inspection.settingCount, 2);
      expect(inspection.ignoredAiSettingCount, 1);
      expect(inspection.wrongQuestionCount, 1);
      expect(inspection.issues, isEmpty, reason: '${inspection.issues}');
    });

    test(
      'treats a missing version as V1 and keeps optional fields optional',
      () {
        final inspection = ShuatiBackupSchema.inspectJson(
          jsonEncode({
            'exportedAt': 1,
            'banks': [
              {'id': 'b1', 'name': '空库'},
            ],
            'questions': <String, Object?>{},
            'records': <Object?>[],
            'favorites': <Object?>[],
          }),
        );

        expect(inspection.isSupported, isTrue);
        expect(inspection.version, 1);
        expect(inspection.bankCount, 1);
        expect(inspection.questionCount, 0);
        expect(inspection.aiExplanationCount, 0);
        expect(inspection.settingCount, 0);
        expect(inspection.wrongQuestionCount, 0);
        expect(inspection.issues, isEmpty);
      },
    );

    test('accepts V2 payloads that carry AI explanations and settings', () {
      final inspection = ShuatiBackupSchema.inspectJson(
        jsonEncode({
          'version': 2,
          'exportedAt': 1,
          'banks': <Object?>[],
          'questions': <String, Object?>{},
          'aiExplanations': <Object?>[],
          'settings': [
            {'key': 'ai_key', 'value': 'secret', 'updatedAt': 1},
          ],
        }),
      );

      expect(inspection.isSupported, isTrue);
      expect(inspection.version, 2);
      expect(inspection.settingCount, 1);
      expect(inspection.ignoredAiSettingCount, 1);
      expect(inspection.wrongQuestionCount, 0);
    });

    test('rejects unsupported versions', () {
      // `null` 会被解码为缺省并回退为 V1，因此不在「不支持」之列。
      for (final version in <Object?>[0, 4, '3']) {
        final inspection = ShuatiBackupSchema.inspectJson(
          jsonEncode({'version': version, 'banks': <Object?>[]}),
        );
        expect(inspection.isSupported, isFalse, reason: 'version=$version');
        expect(inspection.version, isNull);
        expect(inspection.bankCount, 0);
        expect(inspection.errorMessage, contains('备份版本'));
      }
    });

    test('fails closed on invalid JSON and non-object roots', () {
      final invalid = ShuatiBackupSchema.inspectJson('{not json');
      expect(invalid.isSupported, isFalse);
      expect(invalid.errorMessage, contains('合法 JSON'));

      final arrayRoot = ShuatiBackupSchema.inspectJson('[1,2,3]');
      expect(arrayRoot.isSupported, isFalse);
      expect(arrayRoot.errorMessage, contains('根节点'));

      expect(ShuatiBackupSchema.inspect(null).isSupported, isFalse);
    });

    test('fails closed when a top-level collection has the wrong type', () {
      final wrongBanks = ShuatiBackupSchema.inspectJson(
        jsonEncode({
          'version': 3,
          'banks': {'id': 'b1'},
        }),
      );
      expect(wrongBanks.isSupported, isFalse);
      expect(wrongBanks.errorMessage, contains('banks'));

      final wrongQuestions = ShuatiBackupSchema.inspectJson(
        jsonEncode({'version': 3, 'questions': <Object?>[]}),
      );
      expect(wrongQuestions.isSupported, isFalse);
      expect(wrongQuestions.errorMessage, contains('questions'));
    });

    test('flags schema and relational integrity problems', () {
      final inspection = ShuatiBackupSchema.inspectJson(
        jsonEncode({
          'version': 3,
          'banks': [
            {'id': 'b1'},
            {'id': 'b1'},
            {'name': '没有 id 的题库'},
          ],
          'questions': {
            'b1': [
              {'id': 'q1', 'bankId': 'b1', 'type': 'weird', 'answer': []},
              {
                'id': 'q1',
                'bankId': 'b9',
                'type': 'single',
                'answer': ['A'],
              },
              {
                'bankId': 'b1',
                'type': 'single',
                'answer': ['A'],
              },
            ],
            'b2': 'not-a-list',
          },
        }),
      );

      expect(inspection.isSupported, isTrue);
      expect(inspection.bankCount, 3);
      expect(inspection.questionCount, 3);
      final codes = inspection.issues.map((issue) => issue.code).toSet();
      expect(
        codes,
        containsAll({
          ShuatiBackupIssueCode.duplicateBankId,
          ShuatiBackupIssueCode.missingBankId,
          ShuatiBackupIssueCode.duplicateQuestionId,
          ShuatiBackupIssueCode.unknownBankId,
          ShuatiBackupIssueCode.unknownQuestionType,
          ShuatiBackupIssueCode.missingAnswer,
          ShuatiBackupIssueCode.malformedEntry,
        }),
      );
    });

    test('counts questions across multiple banks', () {
      final inspection = ShuatiBackupSchema.inspectJson(
        jsonEncode({
          'version': 3,
          'banks': [
            {'id': 'b1'},
            {'id': 'b2'},
          ],
          'questions': {
            'b1': [
              {
                'id': 'q1',
                'bankId': 'b1',
                'type': 'blank',
                'answer': ['x'],
              },
            ],
            'b2': [
              {
                'id': 'q2',
                'bankId': 'b2',
                'type': 'short',
                'answer': ['y'],
              },
              {
                'id': 'q3',
                'bankId': 'b2',
                'type': 'multiple',
                'answer': ['A', 'C'],
              },
            ],
          },
        }),
      );

      expect(inspection.questionCount, 3);
      expect(inspection.issues, isEmpty, reason: '${inspection.issues}');
      expect(ShuatiBackupSchema.supportedVersions, {1, 2, 3});
      expect(ShuatiBackupSchema.aiSettingKeyPrefix, 'ai_');
    });
  });
}
