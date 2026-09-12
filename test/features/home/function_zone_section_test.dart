import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/config/feature_entry_catalog.dart';
import 'package:jxu_campus_hub/features/home/function_zone/function_zone_section.dart';
import 'package:jxu_campus_hub/features/service_hub/service_hub_usage_store.dart';
import 'package:jxu_campus_hub/shared/widgets/app_icon_badge.dart';
import 'package:jxu_campus_hub/shared/widgets/app_tile_surface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ServiceHubUsageStore.instance.debugReset();
  });

  tearDown(() {
    ServiceHubUsageStore.instance.debugReset();
  });

  testWidgets(
    'renders hierarchical tiles: rank 0 as wide tile, others as small tiles',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FunctionZoneSection(
                campusCardBalance: '38.50',
                dormElectricity: '18.2',
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Section header
      expect(find.text('功能'), findsOneWidget);
      expect(find.text('长按置顶'), findsOneWidget);

      // All tiles are wrapped in AppTileSurface with rounded squircle shape
      expect(
        find.byType(AppTileSurface),
        findsNWidgets(AppFeaturesConfig.entries.length),
      );

      // Rank 0 (课表) is a wide tile showing title and subtitle
      expect(find.text('课表'), findsOneWidget);
      expect(find.text('查看本学期课程、周次与调课提醒'), findsOneWidget);

      // Standard entries are present
      expect(find.text('成绩'), findsOneWidget);
      expect(find.text('考试'), findsOneWidget);
      expect(find.text('付款码'), findsOneWidget);
      expect(find.text('图书馆'), findsOneWidget);
      expect(find.text('第二课堂'), findsOneWidget);
    },
  );

  testWidgets(
    'pinning an entry promotes it to wide tile at top with pin icon',
    (tester) async {
      // Pin library
      await ServiceHubUsageStore.instance.togglePinned('library');

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: FunctionZoneSection()),
          ),
        ),
      );
      await tester.pump();

      // Library should now have a pin icon and be at the top as a wide tile with its subtitle
      expect(find.byIcon(Icons.push_pin_rounded), findsWidgets);
      expect(find.text('图书馆'), findsOneWidget);
      expect(find.text('馆藏检索、借阅与电子资源入口'), findsOneWidget);
    },
  );

  testWidgets('long press toggles pinned status and displays snackbar', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: FunctionZoneSection()),
        ),
      ),
    );
    await tester.pump();

    expect(ServiceHubUsageStore.instance.snapshot.isPinned('library'), isFalse);

    // Long press 图书馆
    await tester.longPress(find.text('图书馆'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('已置顶 图书馆'), findsOneWidget);
    expect(ServiceHubUsageStore.instance.snapshot.isPinned('library'), isTrue);

    // Long press again to unpin
    await tester.longPress(find.text('图书馆'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('已取消置顶 图书馆'), findsOneWidget);
    expect(ServiceHubUsageStore.instance.snapshot.isPinned('library'), isFalse);
  });

  testWidgets('unifies non-semantic icon badges to theme primary color', (
    tester,
  ) async {
    const testSeedColor = Color(0xFF8B1D2C); // JXU Wine Red
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: testSeedColor,
            brightness: Brightness.light,
          ),
        ),
        home: const Scaffold(
          body: SingleChildScrollView(child: FunctionZoneSection()),
        ),
      ),
    );
    await tester.pump();

    // Verify that all AppIconBadge widgets on the page receive theme primary accentColor
    final badges = tester
        .widgetList<AppIconBadge>(find.byType(AppIconBadge))
        .toList();
    expect(badges.isNotEmpty, isTrue);

    final expectedPrimary = Theme.of(
      tester.element(find.byType(FunctionZoneSection)),
    ).colorScheme.primary;
    for (final badge in badges) {
      expect(badge.accentColor, expectedPrimary);
    }
  });

  testWidgets('tapping a tile triggers navigation and records usage', (
    tester,
  ) async {
    var navigatedRoute = '';
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          name: 'home',
          builder: (context, state) => const Scaffold(
            body: SingleChildScrollView(child: FunctionZoneSection()),
          ),
        ),
        GoRoute(
          path: '/exam',
          name: 'exam',
          builder: (context, state) {
            navigatedRoute = 'exam';
            return const Scaffold(body: Text('考试页面'));
          },
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();

    final visitsBefore =
        ServiceHubUsageStore.instance.snapshot.usageById['exam']?.visitCount ??
        0;
    expect(visitsBefore, 0);

    await tester.tap(find.text('考试'));
    await tester.pumpAndSettle();

    expect(navigatedRoute, 'exam');
    expect(find.text('考试页面'), findsOneWidget);
    expect(
      ServiceHubUsageStore.instance.snapshot.usageById['exam']?.visitCount,
      1,
    );
  });

  testWidgets(
    'wide screen layout (>= 600px) organizes tiles into multi-column grid',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: FunctionZoneSection()),
          ),
        ),
      );
      await tester.pump();

      // All entries are rendered
      expect(
        find.byType(AppTileSurface),
        findsNWidgets(AppFeaturesConfig.entries.length),
      );
      expect(find.text('课表'), findsOneWidget);
      expect(find.text('成绩'), findsOneWidget);
      expect(find.text('考试'), findsOneWidget);
    },
  );

  testWidgets('small screen (360x640) renders without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FunctionZoneSection(
              campusCardBalance: '¥38.50',
              dormElectricity: '18.2 度',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byType(AppTileSurface),
      findsNWidgets(AppFeaturesConfig.entries.length),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text scale (1.5x) renders without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: FunctionZoneSection(
                campusCardBalance: '¥38.50',
                dormElectricity: '18.2 度',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byType(AppTileSurface),
      findsNWidgets(AppFeaturesConfig.entries.length),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('library entry opens the in-app library route', (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          name: 'home',
          builder: (context, state) => const Scaffold(
            body: SingleChildScrollView(child: FunctionZoneSection()),
          ),
        ),
        GoRoute(
          path: '/library',
          name: 'library',
          builder: (context, state) => const Scaffold(body: Text('图书馆页面')),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();

    await tester.ensureVisible(find.text('图书馆'));
    await tester.pump();
    await tester.tap(find.text('图书馆'));
    await tester.pumpAndSettle();

    expect(find.text('图书馆页面'), findsOneWidget);
  });

  testWidgets('dark mode applies correct theme colors to surfaces and badges', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: const Scaffold(
          body: SingleChildScrollView(child: FunctionZoneSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byType(AppTileSurface),
      findsNWidgets(AppFeaturesConfig.entries.length),
    );
    expect(tester.takeException(), isNull);
  });
}
