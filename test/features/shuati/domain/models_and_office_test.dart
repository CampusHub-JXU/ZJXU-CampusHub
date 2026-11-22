// 领域模型 JSON 往返 / 宽松解析；xlsx / docx 读取器的边角行为。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/shuati/domain/shuati_models.dart';
import 'package:jxu_campus_hub/features/shuati/import/office_readers.dart';
import 'package:jxu_campus_hub/features/shuati/import/text_decoding.dart';

import '../../../helpers/shuati_office_fixtures.dart';
import '../../../helpers/shuati_test_support.dart';

void main() {
  group('模型 JSON（与 ExportDataV3 条目同形）', () {
    test('Question 往返；null 字段省略（对应 JS undefined）', () {
      const q = Question(
        id: 'q1',
        bankId: 'b1',
        type: QuestionType.multiple,
        question: '题',
        options: {'A': '甲', 'B': '乙'},
        answer: ['A', 'B'],
        explanation: '解析',
        optionExplanations: {'A': '甲对'},
        tags: ['t'],
        contentHash: 'c',
        answerHash: 'a',
      );
      final json = jsonDecode(jsonEncode(q.toJson())) as Map<String, Object?>;
      expect(Question.tryFromJson(json)!.toJson(), q.toJson());
      const bare = Question(
        id: 'x',
        bankId: 'b',
        type: QuestionType.short,
        question: 'q',
        answer: ['a'],
      );
      expect(bare.toJson().keys, [
        'id',
        'bankId',
        'type',
        'question',
        'answer',
      ]);
    });

    test('tryFromJson 宽松：数字 id/选项被字符串化；缺必要字段返回 null', () {
      final q = Question.tryFromJson({
        'id': 'q',
        'bankId': 'b',
        'type': 'single',
        'question': 'x',
        'options': {'A': 1, 'B': true, 'C': null},
        'answer': ['A', 2, null],
      })!;
      expect(q.options, {'A': '1', 'B': 'true'});
      expect(q.answer, ['A', '2']);
      expect(
        Question.tryFromJson({
          'id': 'q',
          'bankId': 'b',
          'type': 'fill',
          'question': 'x',
        }),
        isNull,
      );
      expect(
        Question.tryFromJson({
          'id': '',
          'bankId': 'b',
          'type': 'single',
          'question': 'x',
        }),
        isNull,
      );
      expect(Question.tryFromJson('not a map'), isNull);
    });

    test('Record / Favorite / Wrong / Ai / Setting / Bank 往返', () {
      const rec = PracticeRecord(
        id: 3,
        bankId: 'b',
        questionId: 'q',
        userAnswer: ['A'],
        status: AnswerStatus.wrong,
        timestamp: 9,
      );
      expect(PracticeRecord.tryFromJson(rec.toJson())!.toJson(), rec.toJson());
      const fav = Favorite(id: 1, bankId: 'b', questionId: 'q', timestamp: 2);
      expect(Favorite.tryFromJson(fav.toJson())!.toJson(), fav.toJson());
      const wrong = PermanentWrongQuestion(
        id: 1,
        bankId: 'b',
        questionId: 'q',
        firstWrongAt: 1,
        lastWrongAt: 2,
        wrongCount: 3,
        lastRecordId: 4,
      );
      expect(
        PermanentWrongQuestion.tryFromJson(wrong.toJson())!.toJson(),
        wrong.toJson(),
      );
      const ai = AiExplanationRow(
        id: 1,
        bankId: 'b',
        questionId: 'q',
        explanation: 'e',
        model: 'm',
        createdAt: 5,
      );
      expect(AiExplanationRow.tryFromJson(ai.toJson())!.toJson(), ai.toJson());
      const setting = AppSetting(
        key: 'k',
        value: {
          'a': [1, 2],
        },
        updatedAt: 6,
      );
      expect(
        AppSetting.tryFromJson(setting.toJson())!.toJson(),
        setting.toJson(),
      );
      const bank = QuestionBank(
        id: 'b',
        name: 'n',
        description: 'd',
        createdAt: 1,
        updatedAt: 2,
        questionCount: 3,
        sourceFileName: 'f.docx',
        sourceFileExt: 'docx',
      );
      expect(QuestionBank.tryFromJson(bank.toJson())!.toJson(), bank.toJson());
    });

    test('非法 status / 缺 timestamp 的记录被拒', () {
      expect(
        PracticeRecord.tryFromJson({
          'bankId': 'b',
          'questionId': 'q',
          'status': 'maybe',
          'timestamp': 1,
        }),
        isNull,
      );
      expect(
        PracticeRecord.tryFromJson({
          'bankId': 'b',
          'questionId': 'q',
          'status': 'correct',
        }),
        isNull,
      );
      // 整数值的 double（JSON 数字）可接受
      expect(
        PracticeRecord.tryFromJson({
          'bankId': 'b',
          'questionId': 'q',
          'status': 'correct',
          'timestamp': 1.0,
        }),
        isNotNull,
      );
    });

    test('枚举标签与 PWA 一致', () {
      expect(QuestionType.values.map((t) => t.label), [
        '单选',
        '多选',
        '判断',
        '填空',
        '简答',
      ]);
      expect(PracticeMode.values.map((m) => m.label), [
        '顺序练习',
        '随机练习',
        '错题本',
        '收藏题目',
        '模拟考试',
      ]);
      expect(PracticeMode.tryParse('exam'), PracticeMode.exam);
      expect(PracticeMode.tryParse('Exam'), isNull);
    });

    test('isPracticeReady：无答案 / 选择题无非空选项 不可作答', () {
      Question mk(
        QuestionType t, {
        Map<String, String>? options,
        List<String> answer = const ['A'],
      }) => Question(
        id: 'q',
        bankId: 'b',
        type: t,
        question: 'x',
        options: options,
        answer: answer,
      );
      expect(
        mk(QuestionType.single, options: {'A': '甲'}).isPracticeReady,
        isTrue,
      );
      expect(
        mk(QuestionType.single, options: {'A': '  '}).isPracticeReady,
        isFalse,
      );
      expect(mk(QuestionType.single).isPracticeReady, isFalse);
      expect(
        mk(QuestionType.judge, answer: const ['true']).isPracticeReady,
        isTrue,
      );
      expect(mk(QuestionType.blank, answer: const []).isPracticeReady, isFalse);
    });
  });

  group('xlsx / docx 读取器边角', () {
    test('带命名空间前缀的 xlsx XML（x:worksheet）', () {
      final rows = readXlsxFirstSheetRows(
        buildXlsx([
          ['题目', '答案'],
          ['前缀题目', '对'],
        ], prefix: 'x:'),
      );
      expect(rows, [
        ['题目', '答案'],
        ['前缀题目', '对'],
      ]);
    });

    test('数值格式：整数不带 .0，小数保留；布尔为 true/false；空洞为 null', () {
      final rows = readXlsxFirstSheetRows(
        buildXlsx([
          [1, 2.5, true, null, '末'],
        ]),
      );
      expect(rows.single, ['1', '2.5', 'true', null, '末']);
    });

    test('无 dimension 时按单元格位置读取；起始列偏移被折算', () {
      final rows = readXlsxFirstSheetRows(
        buildXlsx(
          [
            ['a', 'b'],
          ],
          startCol: 3,
          withDimension: false,
        ),
      );
      // 没有 dimension 时列号是绝对的（A..），前导空洞保留为 null
      expect(rows.single.where((c) => c != null), ['a', 'b']);
    });

    test('docx 表格单元格里的段落被提取，tab 保留，pPr/tabs 里的 tab 不算', () {
      final text = extractDocxRawText(
        buildDocx(
          ['第一段\t带制表符'],
          tableRows: [
            ['单元格甲', '单元格乙'],
          ],
        ),
      );
      expect(text, '第一段\t带制表符\n\n单元格甲\n\n单元格乙\n\n');
    });

    test('docx 软换行 w:br 不输出', () {
      final text = extractDocxRawText(buildDocx([], withSoftBreak: true));
      expect(text, '软换行前软换行后\n\n');
    });
  });

  group('decodeTextBytes', () {
    test('UTF-8 / UTF-8 BOM / UTF-16LE BOM / UTF-16BE BOM / 空', () {
      expect(decodeTextBytes(utf8Bytes('中文')).text, '中文');
      expect(
        decodeTextBytes(
          Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('中文')]),
        ).text,
        '中文',
      );
      expect(
        decodeTextBytes(
          Uint8List.fromList([0xFF, 0xFE, 0x2D, 0x4E, 0x87, 0x65]),
        ).text,
        '中文',
      );
      expect(
        decodeTextBytes(
          Uint8List.fromList([0xFE, 0xFF, 0x4E, 0x2D, 0x65, 0x87]),
        ).text,
        '中文',
      );
      expect(decodeTextBytes(Uint8List(0)).text, '');
    });

    test('非法 UTF-8：按 GBK 兜底', () {
      final d = decodeTextBytes(
        Uint8List.fromList([0xD6, 0xD0, 0xCE, 0xC4]),
      ); // GBK「中文」
      expect(d.text, '中文');
      expect(d.usedGbk, isTrue);
      expect(d.lossy, isFalse);
    });
  });
}
