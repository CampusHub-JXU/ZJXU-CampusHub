import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jxu_campus_hub/app/app.dart';
import 'package:jxu_campus_hub/core/network/proxy_mode.dart';
import 'package:jxu_campus_hub/features/welcome/welcome_page.dart';

import '../helpers/test_setup.dart';

const startupProxyWarningText =
    '检测到系统代理或 VPN/TUN；若校务功能异常，请排除本 App 或将 *.zjxu.edu.cn 设为 DIRECT';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GoRouter router;

  setUp(() async {
    await resetTestEnvironment();
    debugSystemProxyLookup = null;
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) {
            return const Scaffold(body: Center(child: Text('首页内容')));
          },
        ),
      ],
    );
  });

  tearDown(() {
    router.dispose();
    debugSystemProxyLookup = null;
  });

  Future<void> pumpApp(
    WidgetTester tester, {
    SystemProxyDetector? systemProxyDetector,
    ConnectivityChecker? connectivityChecker,
    Duration startupProxyWarningDuration = const Duration(milliseconds: 200),
    Future<void> Function(NavigatorState rootNavigator)? welcomeGate,
  }) async {
    await tester.pumpWidget(
      JXUCampusHubApp(
        routerConfig: router,
        systemProxyDetector: systemProxyDetector ?? detectSystemProxy,
        connectivityChecker:
            connectivityChecker ?? () async => const [ConnectivityResult.wifi],
        startupProxyWarningDuration: startupProxyWarningDuration,
        welcomeGate: welcomeGate,
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('does not show startup proxy warning when proxy and vpn absent', (
    tester,
  ) async {
    await pumpApp(
      tester,
      systemProxyDetector: ({testUrl = 'https://newca.zjxu.edu.cn/'}) async =>
          null,
    );

    expect(find.text(startupProxyWarningText), findsNothing);
    expect(find.text('首页内容'), findsOneWidget);
  });

  testWidgets('首启未写 welcome_completed 时弹出欢迎向导', (tester) async {
    await pumpApp(
      tester,
      systemProxyDetector: ({testUrl = 'https://newca.zjxu.edu.cn/'}) async =>
          null,
    );
    await tester.pumpAndSettle();

    expect(find.byType(WelcomePage), findsOneWidget);
    // 首屏标题随引导页改版更新；断言首屏真实文案而非历史占位文案。
    expect(find.text('连接校园身份'), findsOneWidget);

    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();
    expect(find.byType(WelcomePage), findsNothing);
    expect(find.text('首页内容'), findsOneWidget);
  });

  testWidgets('已写 welcome_completed 时不再弹出欢迎向导', (tester) async {
    SharedPreferences.setMockInitialValues({'welcome_completed': true});
    await pumpApp(
      tester,
      systemProxyDetector: ({testUrl = 'https://newca.zjxu.edu.cn/'}) async =>
          null,
    );

    expect(find.byType(WelcomePage), findsNothing);
    expect(find.text('首页内容'), findsOneWidget);
  });

  testWidgets('shows startup proxy warning for detected system proxy', (
    tester,
  ) async {
    await pumpApp(
      tester,
      systemProxyDetector: ({testUrl = 'https://newca.zjxu.edu.cn/'}) async =>
          'PROXY 127.0.0.1:8888',
    );

    expect(find.text(startupProxyWarningText), findsOneWidget);
    expect(find.text('首页内容'), findsOneWidget);
    expect(find.text('退出'), findsNothing);
  });

  testWidgets('shows startup proxy warning for vpn environment', (
    tester,
  ) async {
    await pumpApp(
      tester,
      systemProxyDetector: ({testUrl = 'https://newca.zjxu.edu.cn/'}) async =>
          null,
      connectivityChecker: () async => const [ConnectivityResult.vpn],
    );

    expect(find.text(startupProxyWarningText), findsOneWidget);
  });

  testWidgets(
    'shows startup proxy warning once when proxy and vpn both detected',
    (tester) async {
      await pumpApp(
        tester,
        systemProxyDetector: ({testUrl = 'https://newca.zjxu.edu.cn/'}) async =>
            'PROXY 127.0.0.1:8888',
        connectivityChecker: () async => const [
          ConnectivityResult.vpn,
          ConnectivityResult.wifi,
        ],
      );

      expect(find.text(startupProxyWarningText), findsOneWidget);
    },
  );

  testWidgets(
    'does not show startup proxy warning again after rebuild in same launch',
    (tester) async {
      var shownCount = 0;
      final app = JXUCampusHubApp(
        routerConfig: router,
        systemProxyDetector: ({testUrl = 'https://newca.zjxu.edu.cn/'}) async =>
            'PROXY 127.0.0.1:8888',
        connectivityChecker: () async => const [ConnectivityResult.wifi],
        startupProxyWarningDuration: const Duration(milliseconds: 200),
        onStartupProxyWarningShown: () {
          shownCount += 1;
        },
        // 本例专注 SnackBar 去重，关掉欢迎闸门避免全屏页盖住被测首页。
        welcomeGate: (_) async {},
      );

      await tester.pumpWidget(app);
      await tester.pump();
      await tester.pump();

      expect(find.text(startupProxyWarningText), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(shownCount, 1);

      await tester.pumpWidget(app);
      await tester.pump();
      await tester.pump();

      expect(find.text('首页内容'), findsOneWidget);
      expect(shownCount, 1);
    },
  );
}
