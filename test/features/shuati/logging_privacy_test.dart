// 日志隐私：导入 / 备份 / 数据库失败路径只记计数与固定文案，不记题目内容。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/logging/app_logger.dart';
import 'package:jxu_campus_hub/features/shuati/backup/backup_importer.dart';
import 'package:jxu_campus_hub/features/shuati/import/import_service.dart';

import '../../helpers/shuati_test_support.dart';

void main() {
  test('导入与备份导入的日志不含题目 / 题库内容或凭据', () async {
    const secretQuestion = 'SENTINEL_QUESTION_TEXT_7f3a';
    const secretBank = 'SENTINEL_BANK_NAME_91bc';
    const secretKey = 'sk-SENTINEL-KEY-0042';
    final store = await openTestStore();

    await ShuatiImportService(store, useIsolate: false).importFile(
      bytes: utf8Bytes(
        jsonEncode([
          {
            'question': secretQuestion,
            'options': {'A': '甲'},
            'answer': 'A',
          },
        ]),
      ),
      fileName: '$secretBank.json',
    );
    await ShuatiBackupImporter(store, useIsolate: false).importBytes(
      utf8Bytes(
        jsonEncode({
          'version': 3,
          'banks': [
            {
              'id': 'b',
              'name': secretBank,
              'createdAt': 1,
              'updatedAt': 1,
              'questionCount': 1,
            },
          ],
          'questions': {
            'b': [
              {
                'id': 'q',
                'bankId': 'b',
                'type': 'single',
                'question': secretQuestion,
                'options': {'A': '甲'},
                'answer': ['A'],
              },
            ],
          },
          'settings': [
            {'key': 'ai_apiKey', 'value': secretKey, 'updatedAt': 1},
          ],
        }),
      ),
    );
    try {
      await ShuatiImportService(store, useIsolate: false).importFile(
        bytes: utf8Bytes('{ $secretQuestion'),
        fileName: 'broken.json',
      );
    } on Object {
      // 预期失败
    }

    final all = AppLogger.instance.entries.map((e) => e.formatted).join('\n');
    expect(all.contains(secretQuestion), isFalse);
    expect(all.contains(secretBank), isFalse);
    expect(all.contains(secretKey), isFalse);
    expect(all, contains('刷题助手'));
  });
}
