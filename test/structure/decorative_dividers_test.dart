import 'package:flutter_test/flutter_test.dart';

import '../../tools/architecture/check_decorative_dividers.dart';

/// 装饰性分割线守卫：默认任何新出现的手工分割线都报错，只有写进
/// `decorativeDividerAllowlist` 的已知站点（带数量上限 + 理由）才放行。
///
/// 规则与盲区见 `tools/architecture/check_decorative_dividers.dart` 文件头、
/// `docs/design-guidelines.md` §1.2 与 `docs/decorative-divider-audit.md`。
void main() {
  List<String> violationsFor(String source, {String file = 'synthetic.dart'}) =>
      decorativeDividerViolations(
        hits: scanDividersInSource(source, file: file),
      );

  group('真实仓库', () {
    test('未豁免的装饰性分割线为 0', () {
      final violations = decorativeDividerViolations();
      expect(
        violations,
        isEmpty,
        reason:
            '发现未豁免的装饰性分割线。内容区分组请改用留白 / 字号字重层级 / 对齐 / '
            '低对比背景分区（docs/design-guidelines.md §1.2）；确属语义线（表格网格 / '
            '输入框 / 焦点 / 图表连线 / 时间轴）请确认它没被误判，并只在 '
            'decorativeDividerAllowlist 里加带理由的窄豁免：\n${violations.join('\n')}',
      );
    });

    test('豁免清单不静默放宽：只有已知的畅行专项站点，且都带理由', () {
      expect(decorativeDividerAllowlist, isNotEmpty);
      for (final allowance in decorativeDividerAllowlist) {
        expect(allowance.reason.trim(), isNotEmpty);
        expect(allowance.file, isNot(startsWith('lib/')));
        expect(allowance.allowed, greaterThan(0));
      }
      // 新增豁免会让本断言失败，强制在 diff 里显式暴露。
      expect(decorativeDividerAllowlist.map((a) => a.file).toSet(), {
        'features/changxing_jiada/changxing_jiada_page.dart',
      }, reason: '豁免清单只应覆盖畅行嘉大（#57/#58 → PR73）；新增豁免须同步修改本断言。');
    });
  });

  group('识别新增装饰线（防止回退）', () {
    test('新出现的 Divider 会失败', () {
      const src = '''
Widget build(BuildContext context) {
  return Column(children: [Text('a'), Divider(), Text('b')]);
}
''';
      expect(violationsFor(src), hasLength(1));
    });

    test('新出现的 VerticalDivider 会失败', () {
      const src = '''
Widget build(BuildContext context) {
  return Row(children: [Text('a'), const VerticalDivider(), Text('b')]);
}
''';
      expect(violationsFor(src), hasLength(1));
    });

    test('整宽 height:1 手工发丝线会失败', () {
      const src = '''
Widget build(BuildContext context) {
  return Container(height: 1, margin: const EdgeInsets.only(left: 46), color: cs.outlineVariant);
}
''';
      expect(violationsFor(src), hasLength(1));
    });

    test('1×32 手工竖线会失败', () {
      const src = '''
Widget build(BuildContext context) {
  return Container(width: 1, height: 32, margin: const EdgeInsets.symmetric(horizontal: 12), color: cs.outlineVariant);
}
''';
      expect(violationsFor(src), hasLength(1));
    });

    test('同一文件新增第 2 处也会失败（上限不是整文件白名单）', () {
      const src = '''
Widget build(BuildContext context) {
  return Column(children: [
    Container(height: 1, color: cs.outlineVariant),
    Container(width: 1, height: 32, color: cs.outlineVariant),
  ]);
}
''';
      final violations = violationsFor(src);
      expect(violations, hasLength(1));
      expect(violations.single, contains('出现 2 处'));
    });
  });

  group('语义例外不误报', () {
    test('表格网格 / 输入框 / 轮廓 / 图表连线不报', () {
      const src = '''
Widget build(BuildContext context) {
  return Column(children: [
    Table(
      border: TableBorder.all(color: cs.outlineVariant),
      children: const [],
    ),
    TextField(
      decoration: InputDecoration(
        border: OutlineInputBorder(side: BorderSide(color: cs.outline)),
        enabledBorder: OutlineInputBorder(side: BorderSide(color: cs.outline)),
      ),
    ),
    Container(decoration: BoxDecoration(border: Border.all(color: cs.outline))),
    CustomPaint(painter: _Paint()),
  ]);
}
class _Paint extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(Offset.zero, const Offset(1, 1), Paint());
  }
  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
''';
      expect(violationsFor(src), isEmpty);
    });

    test('主题配置与文本行高不报', () {
      const src = '''
final theme = ThemeData(
  dividerTheme: const DividerThemeData(color: Color(0x11000000), space: 1),
);
final labelStyle = textStyle.copyWith(height: 1);
final navLabel = TextStyle(height: 1.0, color: color);
''';
      expect(violationsFor(src), isEmpty);
    });

    test('可见的圆角卡片轮廓（非细线）不报', () {
      const src = '''
Widget build(BuildContext context) {
  return Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: cs.outlineVariant),
    ),
    child: const Text('card'),
  );
}
''';
      expect(violationsFor(src), isEmpty);
    });

    test('不可见的 SizedBox 细间隔不报（不画线）', () {
      const src = '''
Widget build(BuildContext context) {
  return const SizedBox(width: 1, height: 32);
}
''';
      expect(violationsFor(src), isEmpty);
    });

    test('注释里提到 Divider( 不报', () {
      const src = '''
// 旧的写法是 Divider()，现在改成留白。
/// 也不要 Container(width: 1, height: 32, color: x)。
Widget build(BuildContext context) => const SizedBox.shrink();
''';
      expect(violationsFor(src), isEmpty);
    });
  });

  group('豁免清单按（文件 + 模式）计数', () {
    test('未列出的文件一律上限 0', () {
      const src = 'final w = Divider();\n';
      expect(
        decorativeDividerViolations(
          hits: scanDividersInSource(src, file: 'features/other/page.dart'),
        ),
        hasLength(1),
      );
    });

    test('恰好等于上限时通过，超出才失败', () {
      final hits = scanDividersInSource(
        'final a = Divider();\nfinal b = Divider();\nfinal c = Divider();\n',
        file: 'features/changxing_jiada/changxing_jiada_page.dart',
      );
      expect(decorativeDividerViolations(hits: hits), isEmpty);

      final exceeded = scanDividersInSource(
        'final a = Divider();\nfinal b = Divider();\n'
        'final c = Divider();\nfinal d = Divider();\n',
        file: 'features/changxing_jiada/changxing_jiada_page.dart',
      );
      expect(decorativeDividerViolations(hits: exceeded), hasLength(1));
    });
  });
}
