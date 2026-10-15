import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/ai_export/export_text.dart';

void main() {
  group('文本原语', () {
    test('csvField 覆盖空值与特殊字符', () {
      expect(ExportText.csvField(null), '');
      expect(ExportText.csvField(''), '');
      expect(ExportText.csvField('abc'), 'abc');
      expect(ExportText.csvField('a,b'), '"a,b"');
      expect(ExportText.csvField('a"b'), '"a""b"');
      expect(ExportText.csvField('a\r\nb'), '"a\r\nb"');
      expect(ExportText.csvField('中文'), '中文');
    });

    test('远程文本的公式前缀与前导控制字符会被中和', () {
      for (final prefix in const ['=', '+', '-', '@']) {
        expect(
          ExportText.csvField('${prefix}1+1'),
          "'$prefix"
          '1+1',
        );
      }
      expect(ExportText.csvField('\t=1+1'), "'=1+1");
      expect(ExportText.csvField('\u0001@SUM(A1:A2)'), "'@SUM(A1:A2)");
      expect(ExportText.csvField('\t\n'), '');
    });

    test('mdCell 转义竖线、压平换行、缺失显示破折号', () {
      expect(ExportText.mdCell('a|b\nc'), r'a\|b c');
      expect(ExportText.mdCell(null), '\u2014');
      expect(ExportText.mdCell('  '), '\u2014');
    });

    test('格式扩展名', () {
      expect(ExportFormat.markdown.extension, 'md');
      expect(ExportFormat.json.extension, 'json');
      expect(ExportFormat.csv.extension, 'csv');
    });
  });
}
