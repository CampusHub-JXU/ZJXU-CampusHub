import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jiaxing_university_portal/core/config/feature_entry_catalog.dart';
import 'package:jiaxing_university_portal/features/service_hub/service_hub_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FeatureEntryCatalog.instance.debugSetEntries(
      FeatureEntryCatalog.instance.parse('''
entries:
  - id: service-hall
    title: 服务大厅
    subtitle: 统一入口，继续保留主页快捷访问
    icon: dashboard_customize_outlined
    color: primary
    route: service-hall
    cardType: large_square
    span:
      columns: 2
      rows: 2
    placements:
      - service_hub
    sort: 10
  - id: second-classroom
    title: 第二课堂
    subtitle: 学分活动、个人中心与微信版页面
    icon: workspace_premium_outlined
    color: gold
    route: second-classroom
    cardType: wide_rect
    span:
      columns: 2
      rows: 1
    placements:
      - service_hub
    sort: 20
  - id: changxing-jiada
    title: 畅行嘉大
    subtitle: 请假、返校、离校与加班申请
    icon: north_rounded
    color: "#2EA567"
    route: changxing-jiada
    cardType: tall_rect
    span:
      columns: 1
      rows: 2
    placements:
      - service_hub
    sort: 30
  - id: grades
    title: 成绩查询
    subtitle: 查看成绩、绩点和学业进展
    icon: school_outlined
    color: warning
    route: grades
    cardType: small_square
    span:
      columns: 1
      rows: 1
    placements:
      - service_hub
    sort: 40
'''),
    );
  });

  testWidgets('uses two columns on narrow screens', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const MaterialApp(home: ServiceHubPage()));
    await tester.pumpAndSettle();

    expect(serviceHubGridColumnCount(390), 2);
    expect(serviceHubChevronAlignment(1), Alignment.centerRight);
    expect(serviceHubChevronAlignment(2), Alignment.bottomRight);
    expect(find.text('服务大厅'), findsOneWidget);
    expect(find.text('成绩查询'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNWidgets(4));
    expect(find.text('进入服务'), findsNothing);
  });

  testWidgets('uses four columns on wide screens and navigates on tap', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1024, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          name: 'service-hub',
          builder: (context, state) => const ServiceHubPage(),
        ),
        GoRoute(
          path: '/service-hall',
          name: 'service-hall',
          builder: (context, state) => const Scaffold(body: Text('服务大厅页面')),
        ),
        GoRoute(
          path: '/second-classroom',
          name: 'second-classroom',
          builder: (context, state) => const Scaffold(body: Text('第二课堂页面')),
        ),
        GoRoute(
          path: '/changxing-jiada',
          name: 'changxing-jiada',
          builder: (context, state) => const Scaffold(body: Text('畅行嘉大页面')),
        ),
        GoRoute(
          path: '/grades',
          name: 'grades',
          builder: (context, state) => const Scaffold(body: Text('成绩查询页面')),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(serviceHubGridColumnCount(1024), 4);

    await tester.tap(find.text('服务大厅'));
    await tester.pumpAndSettle();

    expect(find.text('服务大厅页面'), findsOneWidget);
  });
}
