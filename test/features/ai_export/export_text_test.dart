import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/ai_export/export_text.dart';

void main() {
  group('文本原语', () {
    test('cell 替换竖线为斜杠、压平换行、缺失显示破折号', () {
      expect(ExportText.cell('a|b\nc'), 'a/b c');
      expect(ExportText.cell(null), '\u2014');
      expect(ExportText.cell('  '), '\u2014');
    });
  });
}
