// 导入服务（importService.importFromFile 的原生移植）：各格式、去重、同源更新、
// 坏文件、编码、事务回滚、千题性能冒烟。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart' show gbk;
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/shuati/domain/shuati_models.dart';
import 'package:jxu_campus_hub/features/shuati/import/import_models.dart';
import 'package:jxu_campus_hub/features/shuati/import/import_parse.dart';
import 'package:jxu_campus_hub/features/shuati/import/import_service.dart';
import 'package:jxu_campus_hub/features/shuati/persistence/shuati_store.dart';

import '../../../helpers/shuati_office_fixtures.dart';
import '../../../helpers/shuati_test_support.dart';

// tests/fixtures/import/option-explanations.txt
const optionExplanationsFixture = '''
1、以下哪个是离线优先 PWA 的核心能力？
A、所有数据只能存储在服务器
B、Service Worker 可以缓存资源以支持离线访问
C、必须每次打开都重新下载安装包
D、IndexedDB 只能保存字符串
答案：B
解析：离线优先应用通常结合 Service Worker 缓存静态资源，并用 IndexedDB 保存本地数据。
A解析：这与离线优先相反，离线优先应尽量减少对服务器的即时依赖。
B解析：这是正确项，Service Worker 可以拦截请求并返回缓存资源。
C解析：PWA 安装后不需要每次重新下载安装包。
D解析：IndexedDB 可以保存结构化数据，不只限于字符串。
''';

Future<({ShuatiStore store, ShuatiImportService service})> setup({
  bool useIsolate = false,
}) async {
  final store = await openTestStore();
  return (
    store: store,
    service: ShuatiImportService(store, useIsolate: useIsolate),
  );
}

String jsonQuestions(int n, {String prefix = 'Q'}) => jsonEncode([
  for (var i = 0; i < n; i++)
    {
      'question': '$prefix 题目 $i：下列说法正确的是？',
      'options': ['A. 选项甲$i', 'B. 选项乙$i', 'C. 选项丙$i', 'D. 选项丁$i'],
      'answer': ['A', 'C'][i % 2],
      'explanation': '解析 $i',
    },
]);

void main() {
  group('importFromFile (importService.test.ts)', () {
    test('imports text fixture with per-option explanations', () async {
      final t = await setup();
      final report = await t.service.importFile(
        bytes: utf8Bytes(optionExplanationsFixture),
        fileName: 'option-explanations.txt',
        bankName: 'Option Explanations',
      );
      expect(report.added, 1);
      expect(report.bank!.name, 'Option Explanations');
      expect(report.bank!.sourceFileName, 'option-explanations.txt');
      expect(report.bank!.sourceFileExt, 'txt');
      final qs = await t.store.questions.getByBank(report.bank!.id);
      expect(qs, hasLength(1));
      expect(qs.single.explanation, contains('离线优先应用'));
      expect(
        qs.single.optionExplanations!['A'],
        '这与离线优先相反，离线优先应尽量减少对服务器的即时依赖。',
      );
      expect(
        qs.single.optionExplanations!['B'],
        '这是正确项，Service Worker 可以拦截请求并返回缓存资源。',
      );
      expect(qs.single.contentHash, isNotNull);
      expect((await t.store.checkIntegrity()).isHealthy, isTrue);
    });
  });

  group('JSON', () {
    test('数组：选项数组 / 答案 / 解析被规范化，题库名取文件名', () async {
      final t = await setup();
      final report = await t.service.importFile(
        bytes: utf8Bytes(jsonQuestions(4)),
        fileName: '期末复习.json',
      );
      expect(report.format, ShuatiImportFormat.json);
      expect(
        (report.parsed, report.added, report.duplicates, report.invalid),
        (4, 4, 0, 0),
      );
      expect(report.bank!.name, '期末复习');
      expect(report.bank!.sourceFileName, isNull); // json 不可同源更新
      final qs = await t.store.questions.getByBank(report.bank!.id);
      expect(qs.map((q) => q.type).toSet(), {QuestionType.single});
      expect(qs.first.options, {
        'A': '选项甲0',
        'B': '选项乙0',
        'C': '选项丙0',
        'D': '选项丁0',
      });
      expect(qs[1].answer, ['C']);
      expect(report.bank!.questionCount, 4);
    });

    test('{ name, questions }：name 作题库名，bankName 参数优先', () async {
      final t = await setup();
      final body = jsonEncode({
        'name': '对象形态',
        'questions': [
          {'question': '这是一道判断题', 'type': 'judge', 'answer': '对'},
        ],
      });
      final a = await t.service.importFile(
        bytes: utf8Bytes(body),
        fileName: 'x.json',
      );
      expect(a.bank!.name, '对象形态');
      final qs = await t.store.questions.getByBank(a.bank!.id);
      expect(qs.single.type, QuestionType.judge);
      expect(qs.single.answer, ['true']);

      final b = await t.service.importFile(
        bytes: utf8Bytes(body.replaceAll('这是一道判断题', '另一道判断题')),
        fileName: 'x.json',
        bankName: '自定义名',
      );
      expect(b.bank!.name, '自定义名');
    });

    test('保留 JSON 里的题目 id；id 与库内其它题冲突时重新生成并提示', () async {
      var n = 0;
      final store = await openTestStore();
      final service = ShuatiImportService(
        store,
        useIsolate: false,
        newId: () => 'gen-${++n}',
      );
      String body(String text) => jsonEncode([
        {
          'id': 'q1',
          'question': text,
          'options': {'A': '甲', 'B': '乙'},
          'answer': 'A',
        },
      ]);
      final first = await service.importFile(
        bytes: utf8Bytes(body('第一份题目内容')),
        fileName: 'a.json',
      );
      expect((await store.questions.getByBank(first.bank!.id)).single.id, 'q1');
      expect(first.idsRegenerated, 0);

      final second = await service.importFile(
        bytes: utf8Bytes(body('第二份题目内容')),
        fileName: 'b.json',
      );
      expect(second.idsRegenerated, 1);
      expect(second.warnings, contains(ImportWarning.idsRegenerated));
      final qs = await store.questions.getByBank(second.bank!.id);
      expect(qs.single.id, isNot('q1'));
      expect(await store.questions.countByBank(first.bank!.id), 1);
    });

    test('非对象元素 / 缺题干被逐条拒绝并记录原因，其余照常导入（PWA 此处整体抛 TypeError）', () async {
      final t = await setup();
      final body = jsonEncode([
        {
          'question': '正常题目内容',
          'options': {'A': '甲'},
          'answer': 'A',
        },
        'oops',
        42,
        {'answer': 'A'},
        {'question': '   ', 'answer': 'A'},
        {'question': 'bad options', 'options': 'AB', 'answer': 'A'},
        {
          'question': 'bad options 2',
          'options': [
            1,
            {'x': 1},
          ],
          'answer': 'A',
        },
      ]);
      final report = await t.service.importFile(
        bytes: utf8Bytes(body),
        fileName: 'mixed.json',
      );
      expect(report.parsed, 7);
      expect(report.added, 1);
      expect(report.invalid, 6);
      expect(report.rejectionCounts[ImportRejectionReason.notAnObject], 2);
      expect(
        report.rejectionCounts[ImportRejectionReason.missingQuestionText],
        2,
      );
      expect(report.rejectionCounts[ImportRejectionReason.invalidOptions], 2);
      expect(report.rejections.map((r) => r.index), [1, 2, 3, 4, 5, 6]);
    });

    test('没有答案的题仍导入，但在报告里计数并告警（PWA 同样导入）', () async {
      final t = await setup();
      final report = await t.service.importFile(
        bytes: utf8Bytes(
          jsonEncode([
            {
              'question': '没有答案的题目',
              'options': {'A': '甲', 'B': '乙'},
            },
          ]),
        ),
        fileName: 'noans.json',
      );
      expect(report.added, 1);
      expect(report.withoutAnswer, 1);
      expect(report.warnings, contains(ImportWarning.questionsWithoutAnswer));
      final q = (await t.store.questions.getByBank(report.bank!.id)).single;
      expect(q.isPracticeReady, isFalse);
    });

    test('旧别名 type=fill/text 不被识别，按推断落到 short/blank', () async {
      final t = await setup();
      final report = await t.service.importFile(
        bytes: utf8Bytes(
          jsonEncode([
            {'question': '简述一下这个概念', 'type': 'fill', 'answer': 'x'},
            {'question': '填入____内容', 'type': 'text', 'answer': 'y'},
          ]),
        ),
        fileName: 'alias.json',
      );
      final qs = await t.store.questions.getByBank(report.bank!.id);
      expect(qs.map((q) => q.type), [QuestionType.short, QuestionType.blank]);
    });
  });

  group('CSV / TXT / MD', () {
    test('CSV：表头 + 选项列 + 答案 + 解析', () async {
      final t = await setup();
      final report = await t.service.importFile(
        bytes: utf8Bytes(
          '题目,A,B,C,D,答案,解析\n1+1=?,1,2,3,4,B,因为1+1=2\n地球是圆的,,,,,对,\n',
        ),
        fileName: 'math.csv',
      );
      expect(report.added, 2);
      final qs = await t.store.questions.getByBank(report.bank!.id);
      expect(qs[0].answer, ['B']);
      expect(qs[0].explanation, '因为1+1=2');
      expect(qs[1].type, QuestionType.judge);
      expect(qs[1].answer, ['true']);
    });

    test('CSV 带 UTF-8 BOM / UTF-16LE BOM 都能读', () async {
      final t = await setup();
      const csv = '题目,答案\n中文题目内容一,对\n';
      final bom = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]);
      final r1 = await t.service.importFile(bytes: bom, fileName: 'bom.csv');
      expect(r1.added, 1);

      final units = csv.codeUnits;
      final utf16 = Uint8List.fromList([
        0xFF,
        0xFE,
        for (final u in units) ...[u & 0xFF, u >> 8],
      ]);
      final r2 = await t.service.importFile(
        bytes: utf16,
        fileName: 'utf16.csv',
        bankName: 'u16',
      );
      // 与上一份内容完全相同 → 全部重复，不新建题库
      expect(r2.duplicates, 1);
      expect(r2.bank, isNull);
    });

    test('GBK 编码的 CSV（Excel 另存为 CSV）按 GBK 解码并告警', () async {
      final t = await setup();
      final bytes = Uint8List.fromList(gbk.encode('题目,答案\n这是GBK编码的题目,对\n'));
      final report = await t.service.importFile(
        bytes: bytes,
        fileName: 'gbk.csv',
      );
      expect(report.added, 1);
      expect(report.warnings, contains(ImportWarning.decodedAsGbk));
      expect(
        (await t.store.questions.getByBank(report.bank!.id)).single.question,
        '这是GBK编码的题目',
      );
    });

    test('无法解码的二进制垃圾：不崩溃；txt 回退解析会产出一条无答案的题（PWA 同样）并告警', () async {
      final t = await setup();
      final garbage = Uint8List.fromList([
        for (var i = 0; i < 400; i++) 0x80 + (i * 37) % 128,
      ]);
      final report = await t.service.importFile(
        bytes: garbage,
        fileName: 'garbage.txt',
      );
      expect(report.withoutAnswer, report.added);
      expect(report.warnings, contains(ImportWarning.questionsWithoutAnswer));
      expect((await t.store.checkIntegrity()).isHealthy, isTrue);
    });

    test('只有空白的文本 → noQuestionsParsed', () async {
      final t = await setup();
      await expectLater(
        t.service.importFile(
          bytes: utf8Bytes('\n   \n\t\n'),
          fileName: 'blank.txt',
        ),
        throwsA(
          isA<ShuatiImportFailure>().having(
            (e) => e.code,
            'code',
            ShuatiImportFailureCode.noQuestionsParsed,
          ),
        ),
      );
    });

    test('TXT：标准格式；MD 同样；txt 解析不出时回退旧文本解析', () async {
      final t = await setup();
      final txt = await t.service.importFile(
        bytes: utf8Bytes(
          '1、以下哪个是正确的（ ）。\nA、 选项A\nB、 选项B\n答案：A\n2、这是一道判断题目\n答案：对\n',
        ),
        fileName: '练习.txt',
      );
      expect(txt.added, 2);
      expect(txt.bank!.name, '练习');

      final md = await t.service.importFile(
        bytes: utf8Bytes('1、第三道题目内容\nA、选项A\nB、选项B\n答案：B\n'),
        fileName: 'notes.md',
      );
      expect(
        (md.added, md.bank!.name, md.bank!.sourceFileExt),
        (1, 'notes', 'md'),
      );

      // 主解析要求题号后紧跟正文；这里题干太短，主解析丢弃，旧解析接手
      final legacy = await t.service.importFile(
        bytes: utf8Bytes('1. 题目内容在这里\nA. 甲\nB. 乙\n答案：B\n解析：因为\n'),
        fileName: 'legacy.txt',
      );
      expect(legacy.added, 1);
    });

    test('CRLF 换行', () async {
      final t = await setup();
      final report = await t.service.importFile(
        bytes: utf8Bytes('1、以下哪个是正确的\r\nA、选项A\r\nB、选项B\r\n答案：A\r\n'),
        fileName: 'crlf.txt',
      );
      expect(report.added, 1);
    });
  });

  group('xlsx / docx', () {
    test('xlsx：表头 + 数值 / 布尔 / 内联字符串 / 空洞，只读第一个工作表', () async {
      final t = await setup();
      final bytes = buildXlsx(
        [
          ['题目', 'A', 'B', '答案', '解析'],
          ['1+1 等于几', 1, 2, 'B', '加法'],
          ['空洞单元格题目', '甲', null, 'A'],
          ['', '', '', '', ''],
          ['地球是圆的', null, null, '对', null],
        ],
        secondSheet: [
          ['题目', '答案'],
          ['第二个工作表应被忽略', '对'],
        ],
      );
      final report = await t.service.importFile(
        bytes: bytes,
        fileName: 'sheet.xlsx',
      );
      expect(report.format, ShuatiImportFormat.xlsx);
      expect(report.bank!.name, 'sheet');
      expect(report.bank!.sourceFileName, isNull); // xlsx 不可同源更新
      final qs = await t.store.questions.getByBank(report.bank!.id);
      expect(qs, hasLength(3));
      expect(qs[0].options, {'A': '1', 'B': '2'}); // 数值 1 → "1"（不是 1.0）
      expect(qs[0].answer, ['B']);
      expect(qs[1].options, {'A': '甲'});
      expect(qs[2].type, QuestionType.judge);
    });

    test('xlsx：内联字符串 / 带命名空间前缀的 XML / 数据不从 A 列开始', () async {
      final t = await setup();
      final inline = buildXlsx([
        ['题目', '答案'],
        ['内联字符串题目', '对'],
      ], inlineStrings: true);
      expect(
        (await t.service.importFile(
          bytes: inline,
          fileName: 'inline.xlsx',
        )).added,
        1,
      );

      final shifted = buildXlsx([
        ['题目', '答案'],
        ['偏移列题目内容', '错'],
      ], startCol: 2);
      final r = await t.service.importFile(
        bytes: shifted,
        fileName: 'shifted.xlsx',
      );
      expect(r.added, 1);
      expect((await t.store.questions.getByBank(r.bank!.id)).single.answer, [
        'false',
      ]);
    });

    test('docx：段落文本 + 制表符 + 表格单元格段落（mammoth extractRawText 语义）', () async {
      final t = await setup();
      final bytes = buildDocx([
        '一、',
        '1、以下哪个是正确的\t答案：B',
        'A、选项A',
        'B、选项B',
        '2、这是一道判断题目',
        '答案：对',
      ]);
      final report = await t.service.importFile(
        bytes: bytes,
        fileName: '题库.docx',
      );
      expect(report.added, 2);
      expect(report.bank!.sourceFileName, '题库.docx');
      expect(report.bank!.sourceFileExt, 'docx');
      final qs = await t.store.questions.getByBank(report.bank!.id);
      expect(qs[0].answer, ['B']);
      expect(qs[1].answer, ['true']);
    });

    test('docx：软换行 w:br 不产生换行（与 mammoth 纯文本一致）', () async {
      final t = await setup();
      final bytes = buildDocx([
        '1、题目内容在这里',
        'A、甲',
        '答案：A',
      ], withSoftBreak: true);
      final report = await t.service.importFile(
        bytes: bytes,
        fileName: 'br.docx',
      );
      expect(report.added, 1);
    });

    test('docx 同源覆盖更新：命中 contentHash 的题保留 id 与作答记录，旧题删除，新题追加', () async {
      final t = await setup();
      final v1 = buildDocx([
        '1、保留的题目内容',
        'A、选项A',
        'B、选项B',
        '答案：A',
        '2、将被删除的题目',
        'A、选项A',
        'B、选项B',
        '答案：B',
      ]);
      final first = await t.service.importFile(
        bytes: v1,
        fileName: 'bank.docx',
      );
      final bankId = first.bank!.id;
      final before = await t.store.questions.getByBank(bankId);
      await t.store.savePracticeAnswer(
        record(bankId, before[0].id, status: AnswerStatus.wrong),
      );
      await t.store.toggleFavorite(bankId, before[1].id);

      final v2 = buildDocx([
        '1、保留的题目内容', 'A、选项A', 'B、选项B', '答案：B', // 答案改了
        '2、新增的题目内容', 'A、选项A', 'B、选项B', '答案：A',
      ]);
      final second = await t.service.importFile(
        bytes: v2,
        fileName: 'bank.docx',
      );
      expect(second.updatedExisting, isTrue);
      expect(second.bank!.id, bankId);
      expect(
        (second.added, second.updatedQuestions, second.removedQuestions),
        (2, 1, 1),
      );
      final after = await t.store.questions.getByBank(bankId);
      expect(after, hasLength(2));
      expect(after[0].id, before[0].id);
      expect(after[0].answer, ['B']);
      expect(after[1].question, '新增的题目内容');
      expect(await t.store.records.getByBank(bankId), hasLength(1));
      expect(await t.store.favorites.getAll(), isEmpty); // 被删题的收藏随题目清理
      expect((await t.store.banks.getAllBanks()), hasLength(1));
      expect((await t.store.checkIntegrity()).isHealthy, isTrue);
    });
  });

  group('去重 (importService 去重规则)', () {
    String one(String q, String ans) => jsonEncode([
      {
        'question': q,
        'options': {'A': '甲', 'B': '乙'},
        'answer': ans,
      },
    ]);

    test('批内：contentHash+answerHash 相同 → 跳过；答案不同 → 冲突仍导入', () async {
      final t = await setup();
      final body = jsonEncode([
        {
          'question': '同一道题目',
          'options': {'A': '甲', 'B': '乙'},
          'answer': 'A',
        },
        {
          'question': '同一道题目',
          'options': {'A': '甲', 'B': '乙'},
          'answer': 'A',
        },
        {
          'question': '同一道题目',
          'options': {'A': '甲', 'B': '乙'},
          'answer': 'B',
        },
        {
          'question': '同一道题目',
          'options': {'A': '甲', 'B': '乙'},
          'answer': 'B',
        },
      ]);
      final report = await t.service.importFile(
        bytes: utf8Bytes(body),
        fileName: 'dup.json',
      );
      // 第 2 条与首条同答案 → 跳过；第 3、4 条与「首条」答案不同 → 都算冲突（PWA 只记录批内第一条）
      expect((report.added, report.duplicates, report.conflicts), (3, 1, 2));
    });

    test('跨题库（仅新题库）：同内容同答案跳过，不同答案算冲突仍导入', () async {
      final t = await setup();
      final a = await t.service.importFile(
        bytes: utf8Bytes(one('跨库重复题目', 'A')),
        fileName: 'a.json',
      );
      expect(a.added, 1);
      final dup = await t.service.importFile(
        bytes: utf8Bytes(one('跨库重复题目', 'A')),
        fileName: 'b.json',
      );
      expect((dup.added, dup.duplicates, dup.bank), (0, 1, null));
      expect(dup.warnings, contains(ImportWarning.allDuplicates));
      expect(await t.store.banks.getAllBanks(), hasLength(1)); // 全重复不建空题库
      final conflict = await t.service.importFile(
        bytes: utf8Bytes(one('跨库重复题目', 'B')),
        fileName: 'c.json',
      );
      expect((conflict.added, conflict.conflicts), (1, 1));
    });

    test('同一个文件导入两次：第二次全部判重（重复导入安全）', () async {
      final t = await setup();
      final bytes = utf8Bytes(jsonQuestions(30));
      await t.service.importFile(bytes: bytes, fileName: 'again.json');
      final second = await t.service.importFile(
        bytes: bytes,
        fileName: 'again.json',
      );
      expect((second.added, second.duplicates), (0, 30));
      expect((await tableCounts(t.store))['questions'], 30);
    });
  });

  group('坏文件 / 异常输入', () {
    Future<ShuatiImportFailure> failure(
      ShuatiImportService s,
      Uint8List bytes,
      String name,
    ) async {
      try {
        await s.importFile(bytes: bytes, fileName: name);
      } on ShuatiImportFailure catch (e) {
        return e;
      }
      fail('应当失败: $name');
    }

    test('不支持的扩展名 / 无扩展名 / .xls', () async {
      final t = await setup();
      final a = await failure(t.service, utf8Bytes('x'), 'a.pdf');
      expect(a.code, ShuatiImportFailureCode.unsupportedFormat);
      expect(a.message, '不支持的文件格式: pdf。请使用 JSON、CSV、Excel、Word 或文本文件。');
      expect(
        (await failure(t.service, utf8Bytes('x'), 'noext')).code,
        ShuatiImportFailureCode.unsupportedFormat,
      );
      expect(
        (await failure(t.service, utf8Bytes('x'), 'old.XLS')).code,
        ShuatiImportFailureCode.legacyXls,
      );
    });

    test('空文件 / 超大文件', () async {
      final t = await setup();
      expect(
        (await failure(t.service, Uint8List(0), 'e.json')).code,
        ShuatiImportFailureCode.emptyFile,
      );
      expect(
        (await failure(
          t.service,
          Uint8List(kMaxImportFileBytes + 1),
          'big.csv',
        )).code,
        ShuatiImportFailureCode.fileTooLarge,
      );
    });

    test('JSON 语法错误 / 形态错误 / null', () async {
      final t = await setup();
      final syntax = await failure(
        t.service,
        utf8Bytes('{ not json'),
        'a.json',
      );
      expect(syntax.code, ShuatiImportFailureCode.invalidJson);
      expect(syntax.message, startsWith('JSON 格式不正确'));
      final shape = await failure(t.service, utf8Bytes('{"foo":1}'), 'b.json');
      expect(shape.code, ShuatiImportFailureCode.invalidJsonShape);
      expect(shape.message, 'JSON 格式不正确，需要是数组或包含 questions 字段的对象');
      expect(
        (await failure(t.service, utf8Bytes('null'), 'c.json')).code,
        ShuatiImportFailureCode.invalidJsonShape,
      );
      expect(
        (await failure(t.service, utf8Bytes('[]'), 'd.json')).code,
        ShuatiImportFailureCode.noQuestionsParsed,
      );
    });

    test('损坏 / 伪造的 xlsx、docx → corruptArchive，库不变', () async {
      final t = await setup();
      expect(
        (await failure(t.service, utf8Bytes('not a zip'), 'a.xlsx')).code,
        ShuatiImportFailureCode.corruptArchive,
      );
      expect(
        (await failure(t.service, utf8Bytes('PK\x03\x04junk'), 'b.docx')).code,
        ShuatiImportFailureCode.corruptArchive,
      );
      final truncated = buildXlsx([
        ['题目', '答案'],
        ['题目内容', '对'],
      ]).sublist(0, 60);
      expect(
        (await failure(t.service, truncated, 'c.xlsx')).code,
        ShuatiImportFailureCode.corruptArchive,
      );
      // 合法 zip 但不是 Office 文档
      final plain = zipBytes({'hello.txt': utf8.encode('hi')});
      expect(
        (await failure(t.service, plain, 'd.xlsx')).code,
        ShuatiImportFailureCode.corruptArchive,
      );
      expect(
        (await failure(t.service, plain, 'e.docx')).code,
        ShuatiImportFailureCode.corruptArchive,
      );
      expect((await tableCounts(t.store)).values.every((c) => c == 0), isTrue);
    });

    test('xlsx 里 XML 部件被篡改成非 XML → corruptArchive', () async {
      final t = await setup();
      final broken = zipBytes({'xl/workbook.xml': utf8.encode('<<<not xml')});
      expect(
        (await failure(t.service, broken, 'x.xlsx')).code,
        ShuatiImportFailureCode.corruptArchive,
      );
    });

    test('zip 炸弹（小压缩体、解压后超限）被拒，且不会拖垮进程', () async {
      final t = await setup();
      final bomb = zipBytes({
        'word/document.xml': Uint8List(kMaxOfficeBombSize), // 全零，压缩比极高
      }, level: 9);
      expect(bomb.length, lessThan(300 * 1024));
      final e = await failure(t.service, bomb, 'bomb.docx');
      expect(e.code, ShuatiImportFailureCode.corruptArchive);
    });

    test('事务回滚：写到一半失败不会留下半个题库', () async {
      final t = await setup();
      await t.store.executor.execute('''
CREATE TRIGGER poison BEFORE INSERT ON questions
WHEN NEW.question LIKE '%POISON%'
BEGIN SELECT RAISE(ABORT, 'poisoned'); END''');
      final body = jsonEncode([
        for (var i = 0; i < 20; i++)
          {
            'question': '题目内容 $i${i == 15 ? ' POISON' : ''}',
            'options': {'A': '甲'},
            'answer': 'A',
          },
      ]);
      await expectLater(
        t.service.importFile(bytes: utf8Bytes(body), fileName: 'poison.json'),
        throwsA(anything),
      );
      final counts = await tableCounts(t.store);
      expect(counts['banks'], 0);
      expect(counts['questions'], 0);
    });
  });

  group('性能冒烟（千题级）', () {
    test('1000 题 JSON 导入走后台 isolate，主 isolate 事件循环不被阻塞', () async {
      final store = await openTestStore();
      final service = ShuatiImportService(store); // useIsolate 默认 true
      final bytes = utf8Bytes(jsonQuestions(1000));

      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => ticks++,
      );
      final sw = Stopwatch()..start();
      final report = await service.importFile(
        bytes: bytes,
        fileName: 'big.json',
      );
      sw.stop();
      timer.cancel();

      expect(report.added, 1000);
      expect(await store.questions.countByBank(report.bank!.id), 1000);
      expect(sw.elapsed, lessThan(const Duration(seconds: 30)));
      expect(ticks, greaterThan(0), reason: '导入期间事件循环应仍在运转');
      expect((await store.checkIntegrity()).isHealthy, isTrue);
    });

    test('3000 行 CSV 与 1000 题 docx 也能在合理时间内完成', () async {
      final t = await setup(useIsolate: true);
      final csv = StringBuffer('题目,A,B,C,D,答案\n');
      for (var i = 0; i < 3000; i++) {
        csv.writeln('CSV 题目 $i 内容,甲$i,乙$i,丙$i,丁$i,${'ABCD'[i % 4]}');
      }
      final sw = Stopwatch()..start();
      final r = await t.service.importFile(
        bytes: utf8Bytes(csv.toString()),
        fileName: 'big.csv',
      );
      expect(r.added, 3000);

      final paragraphs = <String>[];
      for (var i = 0; i < 1000; i++) {
        paragraphs
          ..add('${i + 1}、DOCX 题目 $i 内容')
          ..add('A、选项甲$i')
          ..add('B、选项乙$i')
          ..add('答案：A');
      }
      final d = await t.service.importFile(
        bytes: buildDocx(paragraphs),
        fileName: 'big.docx',
      );
      expect(d.added, 1000);
      expect(sw.elapsed, lessThan(const Duration(seconds: 60)));
    });
  });
}

/// 解压后约 64 MB，超过单个 OOXML 部件 40 MB 上限。
const int kMaxOfficeBombSize = 64 * 1024 * 1024;
