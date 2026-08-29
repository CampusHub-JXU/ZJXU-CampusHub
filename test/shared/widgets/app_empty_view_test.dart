import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/shared/widgets/app_empty_view.dart';

import '../../helpers/pump_app.dart';

void main() {
  testWidgets('renders title, message and icon without action', (tester) async {
    await pumpApp(
      tester,
      const AppEmptyView(
        title: '暂无成绩数据',
        message: '暂未录入成绩',
        icon: Icons.school_outlined,
      ),
    );

    expect(find.text('暂无成绩数据'), findsOneWidget);
    expect(find.text('暂未录入成绩'), findsOneWidget);
    expect(find.byIcon(Icons.school_outlined), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('renders action button only when label and callback are set', (
    tester,
  ) async {
    var acted = 0;

    await pumpApp(
      tester,
      AppEmptyView(
        title: '尚未配置寝室',
        actionLabel: '去选择寝室',
        onAction: () => acted++,
      ),
    );

    expect(find.text('尚未配置寝室'), findsOneWidget);
    expect(find.text('去选择寝室'), findsOneWidget);

    await tester.tap(find.text('去选择寝室'));
    await tester.pump();

    expect(acted, 1);
  });

  testWidgets('action label alone does not render a button', (tester) async {
    await pumpApp(
      tester,
      const AppEmptyView(title: '暂无通知', actionLabel: '去选择寝室'),
    );

    expect(find.text('去选择寝室'), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
  });
}
