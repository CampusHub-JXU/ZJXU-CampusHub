import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/ai_export/export_text.dart';

void main() {
  group('文本原语', () {
    test('mdCell 转义竖线、压平换行、缺失显示破折号', () {
      expect(ExportText.mdCell('a|b\nc'), r'a\|b c');
      expect(ExportText.mdCell(null), '\u2014');
      expect(ExportText.mdCell('  '), '\u2014');
    });
  });
}
