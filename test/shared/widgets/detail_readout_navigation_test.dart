import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/app/theme.dart';
import 'package:jxu_campus_hub/shared/widgets/detail_readout.dart';

double _barFactor(WidgetTester tester) {
  return tester
      .widget<FractionallySizedBox>(
        find.descendant(
          of: find.byType(DetailLevelBar),
          matching: find.byType(FractionallySizedBox),
        ),
      )
      .widthFactor!;
}

void main() {
  // Issue #62：用真实的 AppTheme 转场（_SharedAxisPageTransitionsBuilder +
  // SnapshotWidget）合成「首页 → 详情 → 返回」的一条路由，验证：
  //   * 详情页进入转场的第一帧，电平条就已经是目标长度（不再 0→目标重播）；
  //   * 返回后首页子树元素不被重建、滚动位置不重置（P1 无整页重排）。
  //
  // 这是纯 widget 级证据（合成数据 / 合成首页），**不代表**真机 120Hz 观感
  // ——真机 A/B 录屏 gate 见 PR 的未完成项。
  testWidgets(
    'push shows the level bar at target on the first frame; pop keeps home',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final navigatorKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          navigatorKey: navigatorKey,
          home: Scaffold(
            body: ListView(
              controller: scroll,
              children: const [
                // 合成首页：一条带 key 的资产行，用来观察返回后是否被重建。
                SizedBox(key: ValueKey('home-asset-row'), height: 2400),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      scroll.jumpTo(300);
      await tester.pump();
      expect(scroll.offset, 300);

      final homeRow = tester.element(
        find.byKey(const ValueKey('home-asset-row')),
      );

      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                // 与详情页一致：缓存读数 66.6 度 → 0.666 的目标长度。
                child: DetailLevelBar(fraction: 0.666),
              ),
            ),
          ),
        ),
      );
      await tester.pump(); // 安装新路由
      await tester.pump(); // 构建详情页内容

      final barFinder = find.byType(DetailLevelBar);
      final route = ModalRoute.of(tester.element(barFinder))!;
      final total = route.transitionDuration;

      // 转场刚起步：首帧即目标长度，而不是从 0 起步向右拉满。
      expect(_barFactor(tester), closeTo(0.666, 1e-9));

      // 转场中段：依然是目标长度（不因快照 / 重建回到 0）。
      await tester.pump(total * 30 ~/ 100);
      expect(_barFactor(tester), closeTo(0.666, 1e-9));
      await tester.pumpAndSettle();
      expect(_barFactor(tester), closeTo(0.666, 1e-9));

      // 返回首页：同一元素仍在树上，滚动位置不变（没有整页重建 / 复位）。
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('home-asset-row')), findsOneWidget);
      expect(scroll.offset, 300);
      expect(
        identical(
          homeRow,
          tester.element(find.byKey(const ValueKey('home-asset-row'))),
        ),
        isTrue,
        reason: '返回后首页资产行应是同一 Element，不应被重建',
      );
    },
  );
}
