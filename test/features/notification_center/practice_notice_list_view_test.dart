import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/notification_center/notice_group_section.dart';
import 'package:jxu_campus_hub/features/notification_center/practice_notice_list_view.dart';

/// 实践通知惰性列表的单元 / Widget 回归基线。
///
/// 固定 1518 条合成行，直接 instrument `itemBuilder`（`onItemBuilt`）与窗口
/// 大小（`debugWindowSize`），证明首屏只构建少量行、滚动按 20 条增量追加、
/// 底层是真正的 sliver 惰性构建，而不是「切 20 条后仍然堆在一个 Column 里」。
void main() {
  const double itemExtent = 64;

  Widget buildList({
    required int itemCount,
    ValueChanged<int>? onItemBuilt,
    Object? resetKey = 'a',
    Future<void> Function()? onRefresh,
    int pageSize = PracticeNoticeListView.defaultPageSize,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: PracticeNoticeListView(
          itemCount: itemCount,
          headerTitle: '全部',
          headerTrailing: '$itemCount 条',
          resetKey: resetKey,
          pageSize: pageSize,
          onRefresh: onRefresh,
          onItemBuilt: onItemBuilt,
          itemBuilder: (context, index) =>
              SizedBox(height: itemExtent, child: Text('item-$index')),
        ),
      ),
    );
  }

  Future<void> pumpList(
    WidgetTester tester,
    Widget widget, {
    Size size = const Size(412, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(widget);
    await tester.pump();
  }

  PracticeNoticeListViewState stateOf(WidgetTester tester) => tester
      .state<PracticeNoticeListViewState>(find.byType(PracticeNoticeListView));

  testWidgets('首屏只构建第一窗口内的少数行（真正的惰性构建）', (tester) async {
    final built = <int>[];
    await pumpList(tester, buildList(itemCount: 1518, onItemBuilt: built.add));

    expect(stateOf(tester).debugWindowSize, 20);
    expect(built, isNotEmpty);
    // itemBuilder 只可能收到窗口内的绝对索引，绝不会构建到第 1518 条。
    expect(built.every((index) => index < 20), isTrue, reason: '$built');
    expect(built.length, lessThanOrEqualTo(20));
    expect(find.text('item-20'), findsNothing);
    expect(find.text('item-40'), findsNothing);
  });

  testWidgets('滚动到底部时按每批 20 条确定性追加（20→40→60→80→100）', (tester) async {
    await pumpList(tester, buildList(itemCount: 1518));
    final state = stateOf(tester);
    expect(state.debugWindowSize, 20);

    final sizes = <int>[state.debugWindowSize];
    for (var i = 0; i < 4; i++) {
      state.debugJumpToEnd();
      await tester.pump();
      await tester.pump();
      sizes.add(state.debugWindowSize);
    }

    expect(sizes, [20, 40, 60, 80, 100]);
    // 追加后此前不可见的行开始进入窗口并可见。
    expect(find.text('item-40'), findsNothing);
  });

  testWidgets('滚到第 1518 条仍可达，顺序正确且窗口不越界', (tester) async {
    final built = <int>[];
    await pumpList(tester, buildList(itemCount: 1518, onItemBuilt: built.add));

    // 用真实手势向下滚动，直到最后一条进入可视区。
    var reached = false;
    for (var i = 0; i < 300; i++) {
      await tester.drag(
        find.byType(PracticeNoticeListView),
        const Offset(0, -4000),
      );
      await tester.pumpAndSettle();
      if (find.text('item-1517').evaluate().isNotEmpty) {
        reached = true;
        break;
      }
    }
    expect(reached, isTrue, reason: '向下滚动应最终到达第 1518 条');
    expect(stateOf(tester).debugWindowSize, 1518);
    expect(find.text('item-1517'), findsOneWidget);
    expect(find.text('item-1516'), findsOneWidget);
    // 顶部行已滚出，说明顺序未被破坏。
    expect(find.text('item-0'), findsNothing);

    // itemBuilder 从未收到越界索引；到顶后继续拖拽不再失控追加。
    expect(built.every((index) => index >= 0 && index < 1518), isTrue);
    final widthBefore = stateOf(tester).debugWindowSize;
    await tester.drag(
      find.byType(PracticeNoticeListView),
      const Offset(0, -4000),
    );
    await tester.pumpAndSettle();
    expect(stateOf(tester).debugWindowSize, widthBefore);
  });

  testWidgets('resetKey 变化时窗口回到首屏并滚回顶部', (tester) async {
    await pumpList(tester, buildList(itemCount: 1518, resetKey: 'a'));
    final state = stateOf(tester);
    for (var i = 0; i < 2; i++) {
      state.debugJumpToEnd();
      await tester.pump();
      await tester.pump();
    }
    expect(state.debugWindowSize, 60);
    expect(find.text('item-40', skipOffstage: false), findsOneWidget);

    // 同一 State 换 resetKey（模拟查询变化）。
    await tester.pumpWidget(buildList(itemCount: 1518, resetKey: 'b'));
    await tester.pump();
    expect(stateOf(tester).debugWindowSize, 20);
    expect(find.text('item-0'), findsOneWidget);
    expect(find.text('item-40', skipOffstage: false), findsNothing);
  });

  testWidgets('下拉刷新触发 onRefresh', (tester) async {
    var refreshed = 0;
    await pumpList(
      tester,
      buildList(
        itemCount: 100,
        onRefresh: () async {
          refreshed++;
        },
      ),
    );

    await tester.fling(
      find.byType(PracticeNoticeListView),
      const Offset(0, 320),
      1000,
    );
    await tester.pumpAndSettle();
    expect(refreshed, 1);
  });

  testWidgets('表头展示标题与总匹配数', (tester) async {
    await pumpList(tester, buildList(itemCount: 1518));
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('1518 条'), findsOneWidget);
  });

  testWidgets('空列表不构建任何行', (tester) async {
    await pumpList(tester, buildList(itemCount: 0));
    expect(stateOf(tester).debugWindowSize, 0);
    expect(find.byType(PracticeNoticeRow), findsNothing);
    expect(find.text('0 条'), findsOneWidget);
  });

  group('PracticeNoticeRow', () {
    testWidgets('点击与长按分别触发回调，日期与分类正常渲染', (tester) async {
      var tapped = 0;
      var longPressed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PracticeNoticeRow(
              title: '关于举办程序设计竞赛的通知',
              date: '2026-09-01',
              tag: '学科竞赛',
              onTap: () => tapped++,
              onLongPress: () => longPressed++,
            ),
          ),
        ),
      );

      expect(find.text('关于举办程序设计竞赛的通知'), findsOneWidget);
      expect(find.text('2026-09-01'), findsOneWidget);
      expect(find.text('学科竞赛'), findsOneWidget);

      await tester.tap(find.byType(PracticeNoticeRow));
      await tester.longPress(find.byType(PracticeNoticeRow));
      expect(tapped, 1);
      expect(longPressed, 1);
    });

    testWidgets('超长标题限三行并省略', (tester) async {
      final longTitle = '实践通知标题' * 40;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PracticeNoticeRow(title: longTitle, onTap: () {}),
          ),
        ),
      );
      final title = tester.widget<Text>(find.text(longTitle));
      expect(title.maxLines, NoticeListMetrics.titleMaxLines);
      expect(title.overflow, TextOverflow.ellipsis);
    });
  });
}
