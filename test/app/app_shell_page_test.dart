import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jxu_campus_hub/app/app_shell_page.dart';
import 'package:jxu_campus_hub/features/home/home_zone_controller.dart';

/// AppShellPage dock 状态机测试（branch0=首页单滚动页 / branch1=我的）。
///
/// dock 四项：主页(branch0, zone0) / 今天(branch0, zone1) / 功能(branch0, zone2) / 我的(branch1)。
/// 高亮跟随 branch + HomeZoneController 的 ScrollSpy 分区。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var homeScrollCalls = 0;
  var todayScrollCalls = 0;
  var functionScrollCalls = 0;

  setUp(() {
    homeScrollCalls = 0;
    todayScrollCalls = 0;
    functionScrollCalls = 0;
    HomeZoneController.instance
      ..scrollToTop = () async {
        homeScrollCalls++;
      }
      ..scrollToToday = () async {
        todayScrollCalls++;
      }
      ..scrollToFunction = () async {
        functionScrollCalls++;
      }
      ..updateZone(0);
  });

  tearDown(() {
    HomeZoneController.instance
      ..scrollToTop = null
      ..scrollToToday = null
      ..scrollToFunction = null
      ..updateZone(0);
  });

  Future<GoRouter> pumpShell(
    WidgetTester tester, {
    bool reduceMotion = false,
    ScrollController? homeScrollController,
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
                  builder: (context, state) => Scaffold(
                    body: ListView(
                      controller: homeScrollController,
                      children: const [Text('首页页面'), SizedBox(height: 1600)],
                    ),
                  ),
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
                  routes: [
                    GoRoute(
                      path: 'detail',
                      builder: (context, state) =>
                          const Scaffold(body: Text('我的详情')),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(
        theme: ThemeData(
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {TargetPlatform.android: _NoTransitionsBuilder()},
          ),
        ),
        routerConfig: router,
        builder: (context, child) {
          // ignore: deprecated_member_use -- 与 lib/app/app.dart 根层桥接保持一致
          final wrapped = MaterialUiCompatibilityBridge(child: child!);
          return reduceMotion
              ? MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: true),
                  child: wrapped,
                )
              : wrapped;
        },
      ),
    );
    await tester.pumpAndSettle();
    return router;
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
    check('今天', Icons.today);
    check('功能', Icons.widgets);
    check('我的', Icons.person);
    return selected;
  }

  testWidgets('dock 显示四项：主页 / 今天 / 功能 / 我的', (tester) async {
    await pumpShell(tester);

    expect(find.text('主页'), findsOneWidget);
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('功能'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
  });

  testWidgets('branch0 初始高亮主页，ScrollSpy 依次切到今天/功能区', (tester) async {
    await pumpShell(tester);

    expect(selectedDockItems(tester), {'主页'});

    // 模拟 HomePage 滚动监听上报：今天区段落越过判定线。
    HomeZoneController.instance.updateZone(1);
    await tester.pumpAndSettle();
    expect(selectedDockItems(tester), {'今天'});

    // 继续滚到功能区。
    HomeZoneController.instance.updateZone(2);
    await tester.pumpAndSettle();
    expect(selectedDockItems(tester), {'功能'});

    // 滚回首屏区恢复高亮主页。
    HomeZoneController.instance.updateZone(0);
    await tester.pumpAndSettle();
    expect(selectedDockItems(tester), {'主页'});
  });

  testWidgets('branch0 内点今天/功能/主页直接触发对应滚动', (tester) async {
    await pumpShell(tester);

    await tester.tap(find.text('今天'));
    await tester.pumpAndSettle();
    expect(todayScrollCalls, 1);
    expect(functionScrollCalls, 0);
    expect(homeScrollCalls, 0);

    await tester.tap(find.text('功能'));
    await tester.pumpAndSettle();
    expect(functionScrollCalls, 1);
    expect(todayScrollCalls, 1);
    expect(homeScrollCalls, 0);

    await tester.tap(find.text('主页'));
    await tester.pumpAndSettle();
    expect(homeScrollCalls, 1);
    expect(todayScrollCalls, 1);
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
    expect(todayScrollCalls, 0);
  });

  testWidgets('在 branch1 点今天：先回 branch0 再触发今天区滚动', (tester) async {
    await pumpShell(tester);

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.text('我的页面'), findsOneWidget);

    await tester.tap(find.text('今天'));
    await tester.pumpAndSettle();

    // 回到 branch0 并调用了今天区滚动实现。
    expect(find.text('首页页面'), findsOneWidget);
    expect(todayScrollCalls, 1);
    expect(homeScrollCalls, 0);
    expect(functionScrollCalls, 0);
  });

  testWidgets('跨分支在首帧换页，旧页保持挂载但停止绘制与动画', (tester) async {
    await pumpShell(tester);
    final mountedHome = find.text('首页页面', skipOffstage: false);
    final homeElement = tester.element(mountedHome);

    await tester.tap(find.text('我的'));
    await tester.pump();
    expect(find.text('首页页面'), findsNothing);
    expect(find.text('我的页面'), findsOneWidget);
    expect(tester.element(mountedHome), same(homeElement));
    expect(selectedDockItems(tester), {'我的'});

    List<Offstage> branchSlots() => tester
        .widget<Stack>(
          find
              .descendant(
                of: find.byType(AppShellBranchContainer),
                matching: find.byType(Stack),
              )
              .first,
        )
        .children
        .cast<Offstage>();

    void expectBranchStates(List<bool> offstage) {
      final slots = branchSlots();
      expect(slots.map((slot) => slot.offstage), offstage);
      final tickerModes = slots.map((slot) => slot.child! as TickerMode);
      expect(tickerModes.map((mode) => mode.enabled), offstage.map((v) => !v));
      expect(
        tickerModes.map((mode) => (mode.child as IgnorePointer).ignoring),
        offstage,
      );
    }

    expectBranchStates([true, false]);
    for (final transitionType in [
      SnapshotWidget,
      FadeTransition,
      SlideTransition,
    ]) {
      expect(
        find.descendant(
          of: find.byType(AppShellBranchContainer),
          matching: find.byType(transitionType, skipOffstage: false),
          skipOffstage: false,
        ),
        findsNothing,
      );
    }

    // 在底栏反馈动画结束前反切，内容仍当帧落位。
    await tester.tap(find.text('主页'));
    await tester.pump();
    expect(tester.element(mountedHome), same(homeElement));
    expect(find.text('首页页面'), findsOneWidget);
    expect(find.text('我的页面'), findsNothing);
    expectBranchStates([false, true]);
    await tester.pumpAndSettle();
  });

  testWidgets('跨分支保留首页滚动位置和我的导航栈', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final router = await pumpShell(tester, homeScrollController: controller);
    controller.jumpTo(320);
    await tester.pump();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    router.push<void>('/my/detail');
    await tester.pumpAndSettle();
    expect(find.text('我的详情'), findsOneWidget);

    // 测试夹具的锚点回调只记录调用次数，可独立检查分支恢复的滚动位置。
    await tester.tap(find.text('功能'));
    await tester.pumpAndSettle();
    expect(functionScrollCalls, 1);
    expect(controller.offset, 320);
    expect(find.text('我的详情'), findsNothing);

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.text('我的详情'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('我的页面'), findsOneWidget);
  });

  testWidgets('系统移除动画时分支仍在首帧切换', (tester) async {
    await pumpShell(tester, reduceMotion: true);
    await tester.tap(find.text('我的'));
    await tester.pump();

    expect(find.text('首页页面'), findsNothing);
    expect(find.text('我的页面'), findsOneWidget);
    expect(selectedDockItems(tester), {'我的'});
  });
}

class _NoTransitionsBuilder extends PageTransitionsBuilder {
  const _NoTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}
