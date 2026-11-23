import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/theme/glass_refraction.dart';
import 'package:jxu_campus_hub/core/theme/glass_style_controller.dart';
import 'package:jxu_campus_hub/core/theme/page_transition_activity.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_container.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_nav_bar.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final activity = PageTransitionActivity.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    activity.debugReset();
    await GlassStyleController.instance.debugReset();
    LiquidGlass.debugReset();
  });
  tearDown(activity.debugReset);

  testWidgets('GlassNavBar all 4 destinations align icon and label vertically', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(412, 915),
            padding: EdgeInsets.only(bottom: 24),
          ),
          child: Scaffold(
            bottomNavigationBar: GlassNavBar(
              currentIndex: 0,
              onDestinationSelected: (_) {},
              destinations: const [
                GlassNavBarDestination(
                  icon: Icons.home_outlined,
                  selectedIcon: Icons.home,
                  label: '主页',
                ),
                GlassNavBarDestination(
                  icon: Icons.today_outlined,
                  selectedIcon: Icons.today,
                  label: '今天',
                ),
                GlassNavBarDestination(
                  icon: Icons.widgets_outlined,
                  selectedIcon: Icons.widgets,
                  label: '功能',
                ),
                GlassNavBarDestination(
                  icon: Icons.person_outline,
                  selectedIcon: Icons.person,
                  label: '我的',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final icons = tester.widgetList<Icon>(find.byType(Icon)).toList();
    final iconRects = <Rect>[];
    for (var i = 0; i < icons.length; i++) {
      iconRects.add(tester.getRect(find.byType(Icon).at(i)));
    }
    final labels = ['主页', '今天', '功能', '我的'];
    final labelRects = labels.map((l) => tester.getRect(find.text(l))).toList();

    for (var i = 0; i < 4; i++) {
      expect(
        iconRects[i].top,
        closeTo(iconRects[0].top, 0.5),
        reason:
            'icon[$i] (${labels[i]}) top=${iconRects[i]} vs icon[0]=${iconRects[0]}',
      );
      expect(
        labelRects[i].top,
        closeTo(labelRects[0].top, 0.5),
        reason:
            'label[$i] (${labels[i]}) top=${labelRects[i]} vs label[0]=${labelRects[0]}',
      );
    }
  });

  testWidgets('转场期间仅 Dock 停止背景采样，保留控件位置和状态', (tester) async {
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const Center(
            child: GlassContainer(width: 80, height: 80, child: Text('卡片')),
          ),
          bottomNavigationBar: GlassNavBar(
            currentIndex: 0,
            onDestinationSelected: (index) => selected = index,
            destinations: const [
              GlassNavBarDestination(
                icon: Icons.home_outlined,
                selectedIcon: Icons.home,
                label: '主页',
              ),
            ],
          ),
        ),
      ),
    );
    final dock = find.byType(GlassNavBar);
    final dockFilter = find.descendant(
      of: dock,
      matching: find.byType(BackdropFilter),
    );
    final label = find.text('主页');
    final labelElement = tester.element(label);
    final labelRect = tester.getRect(label);
    final dockSize = tester.getSize(dock);
    expect(dockFilter, findsOneWidget);
    expect(find.byType(BackdropFilter), findsNWidgets(2));

    activity.acquire();
    await tester.pump();
    expect(dockFilter, findsNothing);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(tester.getSize(dock), dockSize);
    expect(tester.getRect(label), labelRect);
    expect(tester.element(label), same(labelElement));
    final background = tester.widget<Container>(
      find.descendant(of: dock, matching: find.byType(Container)).first,
    );
    final decoration = background.decoration! as ShapeDecoration;
    expect(decoration.color!.a, 1.0);
    expect((decoration.shape as Border).top.width, 0.75);

    await tester.tap(label);
    expect(selected, 0);
    activity.release();
    await tester.pumpAndSettle();
    expect(dockFilter, findsOneWidget);
    expect(tester.element(label), same(labelElement));
  });
}
