import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 下拉选择统一守卫：全 App 下拉选择只走 `AppDropdown`
/// （lib/shared/widgets/app_dropdown.dart）。原生 `DropdownButton` /
/// `DropdownButtonFormField` / `DropdownMenu` 与 `CupertinoPicker` 底部弹层
/// 会带来第二套外观与交互，新增时请改用 `AppDropdown`（表单里传 `label`）。
void main() {
  test('dropdown selectors use AppDropdown only', () {
    final forbidden = RegExp(
      r'\b(DropdownButtonFormField|DropdownButton|DropdownMenuItem|'
      r'DropdownMenu|CupertinoPicker)\b',
    );
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (path.endsWith('lib/shared/widgets/app_dropdown.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (line.startsWith('//')) continue;
        if (forbidden.hasMatch(line)) offenders.add('$path:${i + 1}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '请改用 AppDropdown（lib/shared/widgets/app_dropdown.dart）：\n'
          '${offenders.join('\n')}',
    );
  });
}
