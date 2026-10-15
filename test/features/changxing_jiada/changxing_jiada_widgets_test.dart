import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/theme/app_typography.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_widgets.dart';
import 'package:jxu_campus_hub/shared/widgets/plain_list.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: PlainListGroup(children: [child])),
);

void main() {
  testWidgets('附件行：未上传显示占位值，可点', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        changxingAttachmentRow(
          label: '',
          uploading: false,
          onTap: () => taps++,
        ),
      ),
    );
    expect(find.text('附件'), findsOneWidget);
    expect(find.text('未上传'), findsOneWidget);
    await tester.tap(find.text('附件'));
    expect(taps, 1);
  });

  testWidgets('附件行：上传中显示 spinner 且不可点', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        changxingAttachmentRow(
          label: '证明.pdf',
          uploading: true,
          onTap: () => taps++,
        ),
      ),
    );
    expect(find.text('证明.pdf'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('附件'));
    expect(taps, 0);
  });

  testWidgets('统计数字走行值档（24，等宽数字）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ChangxingMetric(value: 3, label: '办理中')),
      ),
    );
    final style = tester.widget<Text>(find.text('3')).style!;
    final expected = AppTypography.fromScheme(
      Theme.of(tester.element(find.text('3'))).colorScheme,
    ).rowValue;
    expect(style.fontSize, expected.fontSize);
    expect(style.fontFeatures, expected.fontFeatures);
  });

  testWidgets('次级统计走轻量档（titleMedium，等宽数字）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChangxingMetric(value: 5, label: '未读消息', emphasized: false),
        ),
      ),
    );
    final style = tester.widget<Text>(find.text('5')).style!;
    final theme = Theme.of(tester.element(find.text('5')));
    expect(style.fontSize, theme.textTheme.titleMedium?.fontSize);
    expect(style.fontFeatures, const [FontFeature.tabularFigures()]);
  });

  testWidgets('零值转 onSurfaceVariant：占位数字不抢眼', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ChangxingMetric(value: 0, label: '办理中')),
      ),
    );
    final style = tester.widget<Text>(find.text('0')).style!;
    final cs = Theme.of(tester.element(find.text('0'))).colorScheme;
    expect(style.color, cs.onSurfaceVariant);
  });
}
