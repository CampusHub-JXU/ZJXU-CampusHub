import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jxu_campus_hub/app/app_shell_page.dart';
import 'package:jxu_campus_hub/features/home/home_zone_controller.dart';

/// AppShellPage dock 状态机测试（branch0=首页单滚动页 / branch1=我的）。
///
/// dock 三项：主页(branch0, zone0) / 功能(branch0, zone1) / 我的(branch1)。
/// 高亮跟随 branch + HomeZoneController 的 ScrollSpy 分区。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var homeScrollCalls = 0;
  var functionScrollCalls = 0;

  setUp(() {
    homeScrollCalls = 0;
    functionScrollCalls = 0;
    HomeZoneController.instance
      ..scrollToTop = () async {
        homeScrollCalls++;
      }
      ..scrollToFunction = () async {
        functionScrollCalls++;
      }
      ..updateZone(0);
  });

  tearDown(() {
    HomeZoneController.instance
      ..scrollToTop = null
      ..scrollToFunction = null
      ..updateZone(0);
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    bool reduceMotion = false,
  }) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        StatefulShellRoute(
          builder: (context, state, navigationShell) {
            return AppShellPage(navigationShell: navigationShell);
          },
          navigatorContainerBuilder: (context, navigationShell, children) =>
              AppShellBranchContainer(
                currentIndex: navigationShell.currentIndex,
                children: children,
              ),
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/',
                  name: 'home',
                  builder: (context, state) =>
                      const Scaffold(body: Text('首页页面')),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/my',
                  name: 'my',
                  builder: (context, state) =>
                      const Scaffold(body: Text('我的页面')),
                ),
              ],
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => reduceMotion
            ? MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!,
              )
            : child!,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 当前选中（显示 selectedIcon）的 dock 项对应的 icon 集合。
  Set<String> selectedDockItems(WidgetTester tester) {
    final selected = <String>{};
    void check(String label, IconData selectedIcon) {
      final icon = find.descendant(
        of: find.ancestor(of: find.text(label), matching: find.byType(Column)),
        matching: find.byIcon(selectedIcon),
      );
      if (icon.evaluate().isNotEmpty) selected.add(label);
    }

    check('主页', Icons.home);
    check('功能', Icons.widgets);
    check('我的', Icons.person);
    return selected;
  }

  testWidgets('dock 显示三项：主页 / 功能 / 我的', (tester) async {
    await pumpShell(tester);

    expect(find.text('主页'), findsOneWidget);
    expect(find.text('功能'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
  });

  testWidgets('branch0 初始高亮主页，ScrollSpy 切到 zone1 后高亮功能', (tester) async {
    await pumpShell(tester);

    expect(selectedDockItems(tester), {'主页'});

    // 模拟 HomePage 滚动监听上报：功能区段落越过判定线。
    HomeZoneController.instance.updateZone(1);
    await tester.pumpAndSettle();
    expect(selectedDockItems(tester), {'功能'});

    // 滚回首屏区恢复高亮主页。
    HomeZoneController.instance.updateZone(0);
    await tester.pumpAndSettle();
    expect(selectedDockItems(tester), {'主页'});
  });

  testWidgets('branch0 内点功能/主页直接触发对应滚动', (tester) async {
    await pumpShell(tester);

    await tester.tap(find.text('功能'));
    await tester.pumpAndSettle();
    expect(functionScrollCalls, 1);
    expect(homeScrollCalls, 0);

    await tester.tap(find.text('主页'));
    await tester.pumpAndSettle();
    expect(homeScrollCalls, 1);
    expect(functionScrollCalls, 1);
  });

  testWidgets('点我的切到 branch1 并高亮我的', (tester) async {
    await pumpShell(tester);

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    expect(find.text('我的页面'), findsOneWidget);
    expect(selectedDockItems(tester), {'我的'});
  });

  testWidgets('在 branch1 点功能：先回 branch0 再触发功能区滚动', (tester) async {
    await pumpShell(tester);

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.text('我的页面'), findsOneWidget);

    await tester.tap(find.text('功能'));
    await tester.pumpAndSettle();

    // 回到 branch0 并调用了功能区滚动实现。
    expect(find.text('首页页面'), findsOneWidget);
    expect(functionScrollCalls, 1);
    expect(homeScrollCalls, 0);
  });

  testWidgets('切换分支时旧页留在下层交叉淡化，结束后才下台', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.text('我的'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    // 过渡中两页都在台上：新页盖在旧页之上淡入，不透出底色。
    expect(find.text('首页页面'), findsOneWidget);
    expect(find.text('我的页面'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('首页页面'), findsNothing);
    expect(find.text('我的页面'), findsOneWidget);
  });

  testWidgets('过渡中旧分支被快照栅格化，结束后释放快照', (tester) async {
    await pumpShell(tester);
    await tester.tap(find.text('我的'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    SnapshotWidget snapshotOf(String text) => tester.widget<SnapshotWidget>(
      find.ancestor(of: find.text(text), matching: find.byType(SnapshotWidget)),
    );
    expect(snapshotOf('首页页面').controller.allowSnapshotting, isTrue);
    // 新分支不包快照：切换后立刻开始的锚点滚动不能被定格。
    expect(
      find.ancestor(
        of: find.text('我的页面'),
        matching: find.byType(SnapshotWidget),
      ),
      findsNothing,
    );

    await tester.pumpAndSettle();
    expect(find.text('首页页面'), findsNothing);
    final hidden = tester.widget<SnapshotWidget>(
      find.ancestor(
        of: find.text('首页页面', skipOffstage: false),
        matching: find.byType(SnapshotWidget, skipOffstage: false),
      ),
    );
    expect(hidden.controller.allowSnapshotting, isFalse);
  });

  testWidgets('系统移除动画时分支直接切换，不留过渡帧', (tester) async {
    await pumpShell(tester, reduceMotion: true);
    await tester.tap(find.text('我的'));
    await tester.pump();

    expect(find.text('首页页面'), findsNothing);
    expect(find.text('我的页面'), findsOneWidget);
    expect(selectedDockItems(tester), {'我的'});
  });
}
