import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/notification_center/notice_group_section.dart';
import 'package:jxu_campus_hub/shared/widgets/plain_list.dart';

/// Issue #63：通知分组从「squircle 圆角卡片」改为无框宽幅列表。
///
/// 这里锁住组件契约：分组不再套 `PlainListGroup`、只保留**一层**页边距、
/// 分组标题仍带 header 语义、标题左缘让出未读标记列与行标题首字对齐。
void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(412, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  }

  testWidgets('不再套 PlainListGroup 卡面，仍保留 header 语义与数量', (tester) async {
    await pump(
      tester,
      const NoticeGroupSection(
        title: '未读',
        trailing: '3 条',
        children: [SizedBox(height: 20, child: Text('通知一'))],
      ),
    );

    // 整组内不再有共享圆角卡片包装。
    expect(
      find.descendant(
        of: find.byType(NoticeGroupSection),
        matching: find.byType(PlainListGroup),
      ),
      findsNothing,
    );
    expect(find.text('未读'), findsOneWidget);
    expect(find.text('3 条'), findsOneWidget);
    expect(find.text('通知一'), findsOneWidget);

    // 分组标题仍以 header 语义暴露给读屏。
    final headers = tester
        .widgetList<Semantics>(
          find.ancestor(of: find.text('未读'), matching: find.byType(Semantics)),
        )
        .where((s) => s.properties.header ?? false);
    expect(headers, isNotEmpty);
  });

  testWidgets('单层页边距：子项只让出 pageMargin，标题再让出未读标记列', (tester) async {
    await pump(
      tester,
      const NoticeGroupSection(
        title: '未读',
        children: [SizedBox(height: 20, child: Text('行'))],
      ),
    );

    final sectionLeft = tester.getTopLeft(find.byType(NoticeGroupSection)).dx;
    final childLeft = tester.getTopLeft(find.text('行')).dx;
    final headerLeft = tester.getTopLeft(find.text('未读')).dx;

    // 子项（行）与外层之间只有一层 pageMargin，没有第二层 inset 叠加。
    expect(
      childLeft - sectionLeft,
      moreOrLessEquals(NoticeListMetrics.pageMargin, epsilon: 0.01),
    );
    // 分组标题再让出未读标记列，与行标题首字对齐。
    expect(
      headerLeft - sectionLeft,
      moreOrLessEquals(
        NoticeListMetrics.pageMargin + NoticeListMetrics.markerWidth,
        epsilon: 0.01,
      ),
    );
  });

  testWidgets('leadingGap 控制标题左偏移（0 = 无标记列，如实践通知）', (tester) async {
    await pump(
      tester,
      const Padding(
        padding: EdgeInsets.only(left: 20),
        child: SizedBox(width: 300, child: NoticeGroupHeader('全部')),
      ),
    );
    expect(
      tester.getTopLeft(find.text('全部')).dx,
      moreOrLessEquals(20, epsilon: 0.01),
    );

    await pump(
      tester,
      const Padding(
        padding: EdgeInsets.only(left: 20),
        child: SizedBox(
          width: 300,
          child: NoticeGroupHeader('全部', leadingGap: 12),
        ),
      ),
    );
    expect(
      tester.getTopLeft(find.text('全部')).dx,
      moreOrLessEquals(32, epsilon: 0.01),
    );
  });
}
