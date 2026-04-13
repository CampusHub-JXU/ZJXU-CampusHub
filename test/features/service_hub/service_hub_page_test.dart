import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jxu_campus_hub/core/config/feature_entry_catalog.dart';
import 'package:jxu_campus_hub/features/service_hub/service_hub_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FeatureEntryCatalog.instance.debugSetEntries([
      _serviceHallEntry(),
      _entry(
        id: 'second-classroom',
        title: '第二课堂',
        subtitle: '学分活动、个人中心与微信版页面',
        icon: Icons.workspace_premium_outlined,
        accentColor: const Color(0xFFD4AF37),
        placements: const {FeatureEntryPlacement.serviceHub},
        sortOrder: 20,
        spans: const FeatureEntryResponsiveSpan(
          compact: FeatureEntrySpan(columns: 2, rows: 1),
          expanded: FeatureEntrySpan(columns: 2, rows: 1),
        ),
      ),
      _entry(
        id: 'changxing-jiada',
        title: '畅行嘉大',
        subtitle: '请假、返校、离校与加班申请',
        icon: Icons.north_rounded,
        accentColor: const Color(0xFF2EA567),
        placements: const {FeatureEntryPlacement.serviceHub},
        sortOrder: 30,
        spans: const FeatureEntryResponsiveSpan(
          compact: FeatureEntrySpan(columns: 2, rows: 1),
          expanded: FeatureEntrySpan(columns: 1, rows: 2),
        ),
      ),
      _entry(
        id: 'grades',
        title: '成绩查询',
        subtitle: '查看成绩、绩点和学业进展',
        icon: Icons.school_outlined,
        accentColor: const Color(0xFFF57C00),
        placements: const {FeatureEntryPlacement.serviceHub},
        sortOrder: 40,
      ),
    ]);
  });

  tearDown(() {
    FeatureEntryCatalog.instance.debugReset();
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

    final serviceHall = _serviceHallEntry();

    expect(serviceHubGridColumnCount(390), 2);
    expect(serviceHubActiveSpan(serviceHall, 2).rows, 1);
    expect(
      serviceHubActiveCardType(serviceHall, 2),
      FeatureEntryCardType.wideRect,
    );
    expect(
      serviceHubActiveCardType(serviceHall, 4),
      FeatureEntryCardType.largeSquare,
    );
    expect(serviceHubChevronAlignment(1), Alignment.bottomRight);
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

FeatureEntryDefinition _serviceHallEntry() {
  return _entry(
    id: 'service-hall',
    title: '服务大厅',
    subtitle: '统一入口，继续保留主页快捷访问',
    icon: Icons.dashboard_customize_outlined,
    accentColor: const Color(0xFF8B1A2D),
    placements: const {FeatureEntryPlacement.serviceHub},
    sortOrder: 10,
    spans: const FeatureEntryResponsiveSpan(
      compact: FeatureEntrySpan(columns: 2, rows: 1),
      expanded: FeatureEntrySpan(columns: 2, rows: 2),
    ),
  );
}

FeatureEntryDefinition _entry({
  required String id,
  required String title,
  required String subtitle,
  required IconData icon,
  required Color accentColor,
  required Set<FeatureEntryPlacement> placements,
  required int sortOrder,
  FeatureEntryResponsiveSpan spans = const FeatureEntryResponsiveSpan(
    compact: FeatureEntrySpan(columns: 1, rows: 1),
    expanded: FeatureEntrySpan(columns: 1, rows: 1),
  ),
}) {
  return FeatureEntryDefinition(
    id: id,
    title: title,
    subtitle: subtitle,
    icon: icon,
    accentColor: accentColor,
    routeName: id,
    spans: spans,
    placements: placements,
    sortOrder: sortOrder,
  );
}
