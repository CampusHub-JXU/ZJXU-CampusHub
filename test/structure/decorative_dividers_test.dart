import 'package:flutter_test/flutter_test.dart';

import '../../tools/architecture/check_decorative_dividers.dart';

/// 装饰性分割线守卫：默认任何命中的手工分割线都报错，只有写进
/// `decorativeDividerAllowlist` 的已知站点（带数量上限 + 理由、且当前仍命中）
/// 才放行。规则、有界覆盖与盲区见 `tools/architecture/check_decorative_dividers.dart`
/// 文件头、`docs/design-guidelines.md` §1.2 与 `docs/decorative-divider-audit.md`。
void main() {
  const changxing = 'features/changxing_jiada/changxing_jiada_page.dart';

  List<DecorativeDividerHit> hitsFor(
    String source, {
    String file = 'synthetic.dart',
  }) => scanDividersInSource(source, file: file);

  List<String> violationsFor(
    String source, {
    String file = 'synthetic.dart',
    bool checkStaleExemptions = false,
  }) => decorativeDividerViolations(
    hits: hitsFor(source, file: file),
    checkStaleExemptions: checkStaleExemptions,
  );

  group('真实仓库', () {
    test('未豁免 / 未过期的装饰性分割线为 0', () {
      final violations = decorativeDividerViolations();
      expect(
        violations,
        isEmpty,
        reason:
            '发现未豁免或过期的装饰性分割线。内容区分组请改用留白 / 字号字重层级 / 对齐 / '
            '低对比背景分区（docs/design-guidelines.md §1.2）；确属语义线（表格网格 / '
            '输入框 / 焦点 / 图表连线 / 时间轴）请确认它没被误判，并只在 '
            'decorativeDividerAllowlist 里加带理由的窄豁免：\n${violations.join('\n')}',
      );
    });

    test('豁免清单不静默放宽：只有已知的畅行专项站点，且都带理由', () {
      expect(
        decorativeDividerAllowlist,
        isEmpty,
        reason: 'PR73 已移除畅行专项线条，过期豁免应随本变更删除。',
      );
    });
  });

  group('F1 宿主完整平衡实参区间（参数顺序无关）', () {
    final cases = <(String, String, int)>[
      ('height 在前', 'final w = Container(height: 1, color: cs.x);', 1),
      ('height 在后（无尾逗号）', 'final w = Container(color: cs.x, height: 1);', 1),
      ('height 在后（有尾逗号）', 'final w = Container(color: cs.x, height: 1,);', 1),
      ('width 在后（无尾逗号）', 'final w = Container(color: cs.x, width: 1);', 1),
      ('多行', 'final w = Container(\n  height: 1,\n  color: cs.x,\n);', 1),
      (
        '多行 + 尾注释',
        'final w = Container(\n  color: cs.x, // note\n  height: 1,\n);',
        1,
      ),
      (
        '嵌套（外层 + 内层各 1）',
        'final w = Container(height: 1, color: cs.y, '
            'child: Container(width: 1, height: 32, color: cs.x));',
        2,
      ),
      ('重复实参名', 'final w = Container(height: 1, color: a, color: b);', 1),
      ('width: 1.0', 'final w = Container(width: 1.0, color: cs.x);', 1),
      ('width: 0.5', 'final w = Container(width: 0.5, color: cs.x);', 1),
      (
        'AnimatedContainer（前缀 token）',
        'final w = AnimatedContainer(height: 1, color: cs.x);',
        1,
      ),
      (
        'ColoredBox 宿主 + 细 Container 子节点',
        'final w = ColoredBox(color: cs.x, child: Container(width: 1, height: 32));',
        1,
      ),
      (
        'DecoratedBox 仅 decoration + 细 SizedBox 子节点',
        'final w = DecoratedBox(decoration: d, child: SizedBox(height: 1, width: 1));',
        1,
      ),
      (
        '细 SizedBox 子节点（width 在前）',
        'final w = DecoratedBox(decoration: d, child: SizedBox(width: 1, height: 32));',
        1,
      ),
    ];
    for (final (label, src, expected) in cases) {
      test(label, () => expect(hitsFor(src), hasLength(expected)));
    }

    test('不可见的 Container 细间距（无绘制）不报', () {
      expect(hitsFor('final w = Container(width: 1, height: 32);'), isEmpty);
    });

    test('纯 SizedBox 细间距不报', () {
      expect(
        hitsFor("final w = SizedBox(width: 1, height: 32, child: Text('x'));"),
        isEmpty,
      );
    });
  });

  group('F2 词法遮蔽（字符串 / 注释不误报）', () {
    final quoted = <(String, String)>[
      ('单引号', "final s = 'Container(height: 1, color: x)';"),
      ('双引号', 'final s = "Container(height: 1, color: x)";'),
      ('单引号内 Divider', "final s = 'Divider()';"),
      ('三引号', 'final s = """Divider()""";'),
      ('raw 三引号', "final s = r'''Container(height: 1, color: x)''';"),
      ('转义双引号', 'final s = "a \\" Container(height: 1, color: x)";'),
      ('插值整体遮蔽', "final s = '\${Container(height: 1, color: x)}';"),
    ];
    for (final (label, src) in quoted) {
      test('字符串字面量：$label', () => expect(hitsFor(src), isEmpty));
    }

    test('注释里提到 Divider( 不报，注释后的真实 Divider 仍报', () {
      expect(hitsFor("/* 'Divider()' */ final a = Divider();"), hasLength(1));
      expect(
        hitsFor("// 'Divider()'\nfinal a = VerticalDivider();"),
        hasLength(1),
      );
    });

    test('带引号的 color 实参值仍被识别', () {
      expect(
        hitsFor("final w = Container(height: 1, color: 'red');"),
        hasLength(1),
      );
    });

    test('遮蔽保持长度与换行（精确诊断）', () {
      const src = "// c\nfinal s = 'a\nb'; /* x */\nfinal t = 1;\n";
      final masked = maskDartSource(src);
      expect(masked.length, src.length);
      expect(masked.split('\n').length, src.split('\n').length);
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
      expect(hitsFor(src), isEmpty);
    });

    test('主题配置与文本行高不报', () {
      const src = '''
final theme = ThemeData(
  dividerTheme: const DividerThemeData(color: Color(0x11000000), space: 1),
);
final labelStyle = textStyle.copyWith(height: 1);
final navLabel = TextStyle(height: 1.0, color: color);
''';
      expect(hitsFor(src), isEmpty);
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
      expect(hitsFor(src), isEmpty);
    });

    test('子节点 / 孙节点的无关绘制不被宿主继承', () {
      expect(
        hitsFor(
          "final w = Container(height: 1, child: Text('x', style: TextStyle(color: c)));",
        ),
        isEmpty,
      );
      expect(
        hitsFor(
          "final w = Container(height: 1, child: Column(children: [Text('x', style: TextStyle(color: c))]));",
        ),
        isEmpty,
      );
    });
  });

  group('默认拦截新增', () {
    test('新出现的 Divider 会失败', () {
      expect(
        violationsFor(
          "Widget build(BuildContext context) => Column(children: [Text('a'), Divider(), Text('b')]);",
        ),
        hasLength(1),
      );
    });

    test('新出现的 VerticalDivider 会失败', () {
      expect(
        violationsFor(
          "Widget build(BuildContext context) => Row(children: [Text('a'), const VerticalDivider(), Text('b')]);",
        ),
        hasLength(1),
      );
    });

    test('未列出的文件一律上限 0', () {
      expect(
        decorativeDividerViolations(
          hits: hitsFor(
            'final w = Divider();',
            file: 'features/other/page.dart',
          ),
          checkStaleExemptions: false,
        ),
        hasLength(1),
      );
    });
  });

  group('PR73 stacked base', () {
    test('original base pattern remains detectable and stacked state rejects reintroduction', () {
      final originalBaseHits = scanDividersInSource(
        'final a = Divider();\nfinal b = Divider();\nfinal c = Divider();\n'
        'final d = Container(width: 1, color: cs.x);',
        file: changxing,
      );
      expect(
        originalBaseHits.where((hit) => hit.pattern == 'nativeDivider'),
        hasLength(3),
      );
      expect(
        originalBaseHits.where((hit) => hit.pattern == 'handDrawnThinBox'),
        hasLength(1),
      );

      final violations = decorativeDividerViolations(
        hits: hitsFor('final a = Divider();', file: changxing),
      );
      expect(violations, hasLength(1));
      expect(violations.single, contains('不在豁免清单'));
    });
  });
}
