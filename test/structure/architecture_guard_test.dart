import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tools/architecture/check_import_boundaries.dart';

void main() {
  test('feature 侧不得直接创建 MethodChannel / launchUrl / 调用 WechatLauncher', () {
    final violations = collectBoundaryViolations();
    expect(
      violations,
      isEmpty,
      reason:
          '架构边界违例（新增违例必须修复，不得加入 allowlist）：\n'
          '${violations.join('\n')}',
    );
  });

  test('守卫能识别新违例', () {
    final dir = Directory.systemTemp.createTempSync('arch_guard_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final featureDir = Directory('${dir.path}/features/demo')
      ..createSync(recursive: true);
    File('${featureDir.path}/bad.dart').writeAsStringSync(
      "import 'package:flutter/services.dart';\n"
      "const channel = MethodChannel('x');\n",
    );

    final violations = collectBoundaryViolations(root: dir.path);
    expect(violations, isNotEmpty);
    expect(violations.first.rule, contains('MethodChannel'));
  });
}
