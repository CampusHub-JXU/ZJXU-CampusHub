import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/grades/export/grades_export_serializer.dart';

import '../../helpers/academic_export_fixtures.dart';

void main() {
  group('GradesExportRecord 白名单', () {
    test('只保留学业字段，空串归一为 null', () {
      final record = GradesExportRecord.fromEntry(
        gradeEntry(grade: '', percentage: '  ', examType: ''),
      );
      expect(record.courseName, '高等数学A');
      expect(record.grade, isNull);
      expect(record.percentageScore, isNull);
      expect(record.examType, isNull);
      expect(record.gpaPoints, 4.0);
      expect(record.credits, 5.0);
    });

    test('JSON 不含原始教务键，也不含任何身份字段', () {
      final json = GradesExportRecord.fromEntry(gradeEntry()).toJson();
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

  group('文本原语', () {
    test('csvField 覆盖空值与特殊字符', () {
      expect(GradesExportSerializer.csvField(null), '');
      expect(GradesExportSerializer.csvField(''), '');
      expect(GradesExportSerializer.csvField('abc'), 'abc');
      expect(GradesExportSerializer.csvField('a,b'), '"a,b"');
      expect(GradesExportSerializer.csvField('a"b'), '"a""b"');
      expect(GradesExportSerializer.csvField('a\r\nb'), '"a\r\nb"');
      expect(GradesExportSerializer.csvField('中文'), '中文');
    });

    test('远程文本的公式前缀与前导控制字符会被中和', () {
      for (final prefix in const ['=', '+', '-', '@']) {
        expect(
          GradesExportSerializer.csvField('${prefix}1+1'),
          "'$prefix"
          '1+1',
        );
      }
      expect(GradesExportSerializer.csvField('\t=1+1'), "'=1+1");
      expect(
        GradesExportSerializer.csvField('\u0001@SUM(A1:A2)'),
        "'@SUM(A1:A2)",
      );
      expect(GradesExportSerializer.csvField('\t\n'), '');
    });

    test('mdCell 转义竖线、压平换行、缺失显示破折号', () {
      expect(GradesExportSerializer.mdCell('a|b\nc'), r'a\|b c');
      expect(GradesExportSerializer.mdCell(null), '\u2014');
      expect(GradesExportSerializer.mdCell('  '), '\u2014');
    });

    test('格式扩展名', () {
      expect(GradesExportFormat.markdown.extension, 'md');
      expect(GradesExportFormat.json.extension, 'json');
      expect(GradesExportFormat.csv.extension, 'csv');
    });
  });
}
