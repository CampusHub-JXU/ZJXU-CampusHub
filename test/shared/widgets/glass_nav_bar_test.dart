import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_nav_bar.dart';
import 'package:material_ui/material_ui.dart';

void main() {
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
                  label: '今日',
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
    final labels = ['主页', '今日', '功能', '我的'];
    final labelRects = labels.map((l) => tester.getRect(find.text(l))).toList();

    for (var i = 0; i < 4; i++) {
      expect(
        iconRects[i].top,
        closeTo(iconRects[0].top, 0.5),
        reason: 'icon[$i] (${labels[i]}) top=${iconRects[i]} vs icon[0]=${iconRects[0]}',
      );
      expect(
        labelRects[i].top,
        closeTo(labelRects[0].top, 0.5),
        reason: 'label[$i] (${labels[i]}) top=${labelRects[i]} vs label[0]=${labelRects[0]}',
      );
    }
  });
}
