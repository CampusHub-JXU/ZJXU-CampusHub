import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tools/architecture/check_design_ratchet.dart';
import '../helpers/design_ratchet_baseline.dart';

/// 设计棘轮：绕开设计系统的写法（写死字号 / 颜色值、直接弹 SnackBar /
/// 对话框 / 底部弹层、裸 Card）每个文件只许减少、不许增加。
///
/// 迁移页面后数量下降，本测试会要求重新生成基线（与 import_layering_test
/// 的 stale 检查同理，防止基线虚高后被悄悄用回去）：
///   dart run tools/architecture/check_design_ratchet.dart --write
void main() {
  test('设计写法只减不增', () {
    final actual = collectDesignCounts();
    final increased = <String>[];
    final decreased = <String>[];

    final paths = {...actual.keys, ...designRatchetBaseline.keys}.toList()
      ..sort();
    for (final path in paths) {
      final now = actual[path] ?? const <String, int>{};
      final allowed = designRatchetBaseline[path] ?? const <String, int>{};
      for (final name in designPatterns.keys) {
        final n = now[name] ?? 0;
        final max = allowed[name] ?? 0;
        if (n > max) increased.add('$path  $name: $max → $n');
        if (n < max) decreased.add('$path  $name: $max → $n');
      }
    }

    expect(
      increased,
      isEmpty,
      reason:
          '以下文件新增了绕开设计系统的写法。请改用 context.appText / 主题 '
          'textTheme、ColorScheme 角色、AppFeedback、AppCard 等共享件'
          '（docs/ui-unification-plan.md §6）：\n${increased.join('\n')}',
    );
    expect(
      decreased,
      isEmpty,
      reason:
          '以下文件的写法已经减少，请重新生成基线把上限调低：\n'
          '  dart run tools/architecture/check_design_ratchet.dart --write\n'
          '${decreased.join('\n')}',
    );
  });

  test('守卫能识别新写法，并忽略行注释与豁免文件', () {
    final dir = Directory.systemTemp.createTempSync('design_ratchet_');
    addTearDown(() => dir.deleteSync(recursive: true));
    Directory('${dir.path}/features/demo').createSync(recursive: true);
    Directory('${dir.path}/shared/widgets').createSync(recursive: true);
    File('${dir.path}/features/demo/bad.dart').writeAsStringSync(
      "final a = TextStyle(fontSize: 13);\n"
      "final b = Color(0xFF168A52);\n"
      "void f(c) { ScaffoldMessenger.of(c).showSnackBar(x); showDialog(context: c); }\n"
      "final card = Card(child: x);\n"
      "final ok = AppCard(child: x);\n"
      "// fontSize: 12 只在注释里出现，不计数\n",
    );
    File('${dir.path}/shared/widgets/app_feedback.dart')
        .writeAsStringSync("void f(m) => m.showSnackBar(x);\n");

    final counts = collectDesignCounts(root: dir.path);
    expect(counts.keys, ['features/demo/bad.dart']);
    expect(counts['features/demo/bad.dart'], {
      'fontSize': 1,
      'hexColor': 1,
      'showSnackBar': 1,
      'showDialog': 1,
      'rawCard': 1,
    });
  });
}
