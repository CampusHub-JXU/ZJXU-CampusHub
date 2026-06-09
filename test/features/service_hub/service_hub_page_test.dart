import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/config/feature_entry_catalog.dart';
import 'package:jxu_campus_hub/features/service_hub/service_hub_page.dart';
import 'package:jxu_campus_hub/features/service_hub/service_hub_usage_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ServiceHubUsageStore.instance.debugReset();
    FeatureEntryCatalog.instance.debugSetEntries([
      _entry(
        id: 'schedule',
        title: '课表',
        subtitle: '查看课程安排',
        routeName: 'schedule',
        category: FeatureEntryCategory.academic,
        keywords: const ['课程'],
        sortOrder: 10,
      ),
      _entry(
        id: 'grades',
        title: '成绩查询',
        subtitle: '查看成绩、绩点和学业进展',
        routeName: 'grades',
        category: FeatureEntryCategory.academic,
        keywords: const ['绩点'],
        sortOrder: 20,
      ),
      _entry(
        id: 'shuati-practice',
        title: '刷题助手',
        subtitle: '题库导入、错题重练、离线练习',
        routeName: 'shuati-practice',
        category: FeatureEntryCategory.academic,
        keywords: const ['题库', '练习'],
        sortOrder: 25,
      ),
      _entry(
        id: 'dorm-electricity',
        title: '宿舍电费',
        subtitle: '查询寝室剩余电量',
        routeName: 'dorm-electricity',
        category: FeatureEntryCategory.campusLife,
        keywords: const ['电量'],
        sortOrder: 30,
      ),
      _entry(
        id: 'notice-list',
        title: '校园公告',
        subtitle: '校级通知与重要公告',
        routeName: 'notice-list',
        category: FeatureEntryCategory.notices,
        keywords: const ['通知'],
        sortOrder: 40,
      ),
      _entry(
        id: 'service-hall',
        title: '服务大厅',
        subtitle: '统一入口',
        routeName: 'service-hall',
        category: FeatureEntryCategory.servicesAccounts,
        keywords: const ['办事'],
        sortOrder: 50,
      ),
    ]);
  });

  tearDown(() {
    FeatureEntryCatalog.instance.debugReset();
    ServiceHubUsageStore.instance.debugReset();
  });

  testWidgets('shows categorized compact grids and searchable results', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ServiceHubPage()));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('学业'), findsOneWidget);
    expect(find.text('校园生活'), findsOneWidget);
    expect(find.text('通知公告'), findsOneWidget);
    expect(find.text('办事与账号'), findsOneWidget);
    expect(find.text('成绩查询'), findsOneWidget);
    expect(find.text('课表'), findsOneWidget);
    expect(find.text('刷题助手'), findsOneWidget);
    expect(find.text('宿舍电费'), findsOneWidget);
    expect(find.text('校园公告'), findsOneWidget);
    expect(find.text('服务大厅'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsWidgets);

    await tester.enterText(find.byType(TextField), '刷题');
    await tester.pumpAndSettle();

    expect(find.text('搜索结果'), findsOneWidget);
    expect(find.text('刷题助手'), findsOneWidget);
    expect(find.text('宿舍电费'), findsNothing);
    expect(find.text('学业'), findsNothing);

    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '电量');
    await tester.pumpAndSettle();

    expect(find.text('搜索结果'), findsOneWidget);
    expect(find.text('宿舍电费'), findsOneWidget);
    expect(find.text('成绩查询'), findsNothing);

    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pumpAndSettle();

    expect(find.text('未找到相关功能'), findsOneWidget);

    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();

    expect(find.text('学业'), findsOneWidget);
    expect(find.text('成绩查询'), findsOneWidget);
    expect(find.text('宿舍电费'), findsOneWidget);
  });

  testWidgets('uses 2, 3, and 4 column grids across widths', (tester) async {
    await _pumpServiceHubAtWidth(tester, 390);
    expect(_firstGridDelegate(tester).crossAxisCount, 2);
    expect(_firstGridDelegate(tester).mainAxisExtent, 136);

    final subtitle = tester.widget<Text>(find.text('题库导入、错题重练、离线练习'));
    expect(subtitle.maxLines, 2);

    await _pumpServiceHubAtWidth(tester, 700);
    expect(_firstGridDelegate(tester).crossAxisCount, 3);

    await _pumpServiceHubAtWidth(tester, 1024);
    expect(_firstGridDelegate(tester).crossAxisCount, 4);
  });

  testWidgets('keeps compact tiles stable at increased text scale', (
    tester,
  ) async {
    await _pumpServiceHubAtWidth(tester, 390, textScale: 1.6);

    expect(tester.takeException(), isNull);
    expect(_firstGridDelegate(tester).crossAxisCount, 2);
    expect(_firstGridDelegate(tester).mainAxisExtent, greaterThan(136));
  });

  testWidgets('records visits and shows frequently used entries', (
    tester,
  ) async {
    await tester.pumpWidget(_buildRouterApp());
    await tester.pumpAndSettle();

    expect(find.text('常用'), findsNothing);

    await tester.tap(find.text('成绩查询'));
    await tester.pumpAndSettle();
    expect(find.text('成绩查询页面'), findsOneWidget);

    final router = GoRouter.of(tester.element(find.text('成绩查询页面')));
    router.go('/');
    await tester.pumpAndSettle();

    expect(find.text('常用'), findsOneWidget);
    expect(find.text('成绩查询'), findsWidgets);
  });

  testWidgets('long press toggles pinned entry', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ServiceHubPage()));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('服务大厅'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('服务大厅'));
    await tester.pumpAndSettle();

    expect(find.text('已置顶 服务大厅'), findsOneWidget);
    expect(find.byIcon(Icons.push_pin_rounded), findsWidgets);

    await tester.ensureVisible(find.text('服务大厅').last);
    await tester.pumpAndSettle();
    await tester.longPress(find.text('服务大厅').last);
    await tester.pumpAndSettle();

    expect(find.text('已取消置顶 服务大厅'), findsOneWidget);
  });
}

Future<void> _pumpServiceHubAtWidth(
  WidgetTester tester,
  double width, {
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        );
      },
      home: const ServiceHubPage(),
    ),
  );
  await tester.pumpAndSettle();
}

SliverGridDelegateWithFixedCrossAxisCount _firstGridDelegate(
  WidgetTester tester,
) {
  final grid = tester.widget<GridView>(find.byType(GridView).first);
  return grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
}

Widget _buildRouterApp() {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        name: 'service-hub',
        builder: (context, state) => const ServiceHubPage(),
      ),
      GoRoute(
        path: '/schedule',
        name: 'schedule',
        builder: (context, state) => const Scaffold(body: Text('课表页面')),
      ),
      GoRoute(
        path: '/grades',
        name: 'grades',
        builder: (context, state) => const Scaffold(body: Text('成绩查询页面')),
      ),
      GoRoute(
        path: '/shuati-practice',
        name: 'shuati-practice',
        builder: (context, state) => const Scaffold(body: Text('刷题助手页面')),
      ),
      GoRoute(
        path: '/dorm-electricity',
        name: 'dorm-electricity',
        builder: (context, state) => const Scaffold(body: Text('宿舍电费页面')),
      ),
      GoRoute(
        path: '/notice-list',
        name: 'notice-list',
        builder: (context, state) => const Scaffold(body: Text('校园公告页面')),
      ),
      GoRoute(
        path: '/service-hall',
        name: 'service-hall',
        builder: (context, state) => const Scaffold(body: Text('服务大厅页面')),
      ),
    ],
  );
  return MaterialApp.router(routerConfig: router);
}

FeatureEntryDefinition _entry({
  required String id,
  required String title,
  required String subtitle,
  required String routeName,
  required FeatureEntryCategory category,
  required int sortOrder,
  List<String> keywords = const [],
}) {
  return FeatureEntryDefinition(
    id: id,
    title: title,
    subtitle: subtitle,
    icon: Icons.extension_outlined,
    accentColor: const Color(0xFF8B1A2D),
    routeName: routeName,
    spans: const FeatureEntryResponsiveSpan(
      compact: FeatureEntrySpan(columns: 1, rows: 1),
      expanded: FeatureEntrySpan(columns: 1, rows: 1),
    ),
    placements: const {FeatureEntryPlacement.serviceHub},
    sortOrder: sortOrder,
    category: category,
    keywords: keywords,
  );
}
