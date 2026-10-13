import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/grades/export/grades_export_serializer.dart';
import 'package:jxu_campus_hub/features/grades/grades_model.dart';

GradeEntry _entry({
  String course = '高等数学A',
  String grade = '优',
  String percentage = '95',
  String gpa = '4.0',
  String credits = '5.0',
  String year = '2025-2026',
  String semester = '第二学期',
  String examType = '考试',
  String method = '闭卷',
  String requirement = '必修',
}) => GradeEntry(
  courseName: course,
  grade: grade,
  percentageScore: percentage,
  gpaPoints: double.parse(gpa),
  credits: double.parse(credits),
  academicYear: year,
  semester: semester,
  examType: examType,
  assessmentMethod: method,
  courseRequirement: requirement,
);

GradesExportDocument _doc(List<GradeEntry> entries) => GradesExportDocument(
  exportedAt: DateTime(2026, 10, 13, 10, 30),
  scope: const GradesExportScope(
    label: '2025–26 春',
    academicYear: '2025-2026',
    semester: '第二学期',
  ),
  records: [for (final e in entries) GradesExportRecord.fromEntry(e)],
);

void main() {
  group('GradesExportRecord 白名单', () {
    test('只保留学业字段，空串归一为 null', () {
      final record = GradesExportRecord.fromEntry(
        _entry(grade: '', percentage: '  ', examType: ''),
      );
      expect(record.courseName, '高等数学A');
      expect(record.grade, isNull);
      expect(record.percentageScore, isNull);
      expect(record.examType, isNull);
      expect(record.gpaPoints, 4.0);
      expect(record.credits, 5.0);
    });

    test('JSON 不含原始教务键，也不含任何身份字段', () {
      final json = GradesExportRecord.fromEntry(_entry()).toJson();
      // 原始成绩接口键（kcmc / cj / xh 等）不得泄漏。
      expect(json.keys, isNot(contains('kcmc')));
      expect(json.keys, isNot(contains('cj')));
      for (final forbidden in const [
        'xh',
        'xm',
        'studentId',
        'idCard',
        'name',
        'phone',
        'token',
        'cookie',
      ]) {
        expect(json.keys, isNot(contains(forbidden)));
      }
    });
  });

  group('JSON 导出', () {
    test('带 schemaVersion 且结构稳定，缺失字段为 null', () {
      final decoded = jsonDecode(
        GradesExportSerializer.jsonString(_doc([_entry()])),
      ) as Map<String, dynamic>;
      expect(decoded['schemaVersion'], kGradesExportSchemaVersion);
      expect(decoded['module'], 'grades');
      expect(decoded['recordCount'], 1);
      expect(decoded['totalCredits'], 5.0);
      expect(decoded['exportedAt'], '2026-10-13T10:30:00.000');
      // 页面无法确证的元信息如实为 null，不猜测。
      expect(decoded['lastUpdatedAt'], isNull);
      expect(decoded['dataSource'], isNull);
      final scope = decoded['scope'] as Map<String, dynamic>;
      expect(scope['semester'], '第二学期');
    });

    test('空列表导出为合法空数组', () {
      final decoded = jsonDecode(
        GradesExportSerializer.jsonString(_doc(const [])),
      ) as Map<String, dynamic>;
      expect(decoded['recordCount'], 0);
      expect(decoded['totalCredits'], 0);
      expect(decoded['grades'], isEmpty);
    });
  });

  group('Markdown 导出', () {
    test('含免责声明、范围与计数，缺失显示破折号', () {
      final md = GradesExportSerializer.markdown(
        _doc([_entry(grade: ''), _entry(course: '大学英语')]),
      );
      expect(md, contains('# 成绩导出'));
      expect(md, contains('仅导出当前已加载的成绩'));
      expect(md, contains('2025–26 春'));
      expect(md, contains('课程数：2'));
      expect(md, contains('学分合计：10.0'));
      expect(md, contains('数据来源：未知'));
      // 缺失成绩显示为破折号而不是留空。
      expect(md, contains('| 高等数学A | — |'));
      expect(md, contains('大学英语'));
    });

    test('中文与竖线/换行在表格单元格内被安全处理', () {
      final md = GradesExportSerializer.markdown(
        _doc([_entry(course: '计算机|导论\n实验', method: '开卷<笔试>')]),
      );
      expect(md, contains(r'计算机\|导论 实验'));
      expect(md.split('\n').where((l) => l.startsWith('| 计算机')).length, 1);
      expect(md, contains('开卷<笔试>'));
    });
  });

  group('CSV 导出', () {
    test('以 UTF-8 BOM 开头并含表头', () {
      final csv = GradesExportSerializer.csv(_doc([_entry()]));
      expect(csv.startsWith(GradesExportSerializer.csvBom), isTrue);
      final firstLine = csv.split('\n').first.replaceFirst('\uFEFF', '');
      expect(firstLine, startsWith('课程,成绩,百分制,绩点,学分'));
      expect(csv, contains('高等数学A,优,95,4.00,5.0,2025-2026,第二学期'));
    });

    test('逗号 / 引号 / 换行字段按 CSV 规则转义', () {
      final csv = GradesExportSerializer.csv(
        _doc([
          _entry(course: '数学,分析', method: '含"引号"', requirement: '第一行\n第二行'),
        ]),
      );
      expect(csv, contains('"数学,分析"'));
      expect(csv, contains('"含""引号"""'));
      expect(csv, contains('"第一行\n第二行"'));
    });

    test('csvField 直接覆盖空值与特殊字符', () {
      expect(GradesExportSerializer.csvField(null), '');
      expect(GradesExportSerializer.csvField(''), '');
      expect(GradesExportSerializer.csvField('abc'), 'abc');
      expect(GradesExportSerializer.csvField('a,b'), '"a,b"');
      expect(GradesExportSerializer.csvField('a"b'), '"a""b"');
      expect(GradesExportSerializer.csvField('a\r\nb'), '"a\r\nb"');
      expect(GradesExportSerializer.csvField('中文'), '中文');
    });
  });

  test('encode 按格式分派', () {
    final doc = _doc([_entry()]);
    expect(
      GradesExportSerializer.encode(GradesExportFormat.markdown, doc),
      GradesExportSerializer.markdown(doc),
    );
    expect(
      GradesExportSerializer.encode(GradesExportFormat.json, doc),
      GradesExportSerializer.jsonString(doc),
    );
    expect(
      GradesExportSerializer.encode(GradesExportFormat.csv, doc),
      GradesExportSerializer.csv(doc),
    );
    expect(GradesExportFormat.markdown.extension, 'md');
    expect(GradesExportFormat.csv.extension, 'csv');
  });
}
