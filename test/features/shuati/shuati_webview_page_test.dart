import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';

import 'package:jxu_campus_hub/app/app_bootstrap_controller.dart';
import 'package:jxu_campus_hub/core/shortcut/app_shortcut_service.dart';
import 'package:jxu_campus_hub/features/shuati/shuati_webview_page.dart';

import '../../helpers/fake_inappwebview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shortcutChannel = MethodChannel('edu.zjxu.jxucampushub/shortcut');

  setUpAll(() {
    InAppWebViewPlatform.instance = FakeInAppWebViewPlatform();
  });

  setUp(() {
    AppBootstrapController.instance.debugReset(
      phaseValue: AppBootstrapPhase.localStateReady,
    );
    AppShortcutService.instance.debugReset();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shortcutChannel, null);
    AppShortcutService.instance.debugReset();
  });

  testWidgets(
    'shows add-to-desktop action on android and removes unused link actions',
    (tester) async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(shortcutChannel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'consumeInitialShortcutAction' => null,
              'requestShuatiShortcut' => 'requested',
              _ => null,
            };
          });

      await tester.pumpWidget(_ShuatiTestApp(platform: TargetPlatform.android));
      await tester.pump();

      expect(find.byTooltip('复制链接'), findsNothing);
      expect(find.byTooltip('在外部浏览器打开'), findsNothing);
      expect(find.byTooltip('更多操作'), findsOneWidget);

      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();

      expect(find.text('添加到桌面'), findsOneWidget);
      expect(find.text('复制链接'), findsNothing);
      expect(find.text('在外部浏览器打开'), findsNothing);

      await tester.tap(find.text('添加到桌面'));
      await tester.pumpAndSettle();

      expect(
        calls.map((call) => call.method),
        contains('requestShuatiShortcut'),
      );
      expect(find.text('已发起添加请求，请在系统提示中确认'), findsOneWidget);
    },
  );

  testWidgets('offers shortcut permission settings when launcher rejects', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shortcutChannel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'consumeInitialShortcutAction' => null,
            'requestShuatiShortcut' => 'rejected',
            'openShortcutPermissionSettings' => true,
            _ => null,
          };
        });

    await tester.pumpWidget(_ShuatiTestApp(platform: TargetPlatform.android));
    await tester.pump();

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加到桌面'));
    await tester.pumpAndSettle();

    expect(find.text('去设置'), findsOneWidget);

    await tester.tap(find.text('去设置'));
    await tester.pumpAndSettle();

    expect(
      calls.map((call) => call.method),
      contains('openShortcutPermissionSettings'),
    );
  });

  testWidgets('hides add-to-desktop menu on iOS themed page', (tester) async {
    await tester.pumpWidget(_ShuatiTestApp(platform: TargetPlatform.iOS));
    await tester.pump();

    expect(find.byTooltip('更多操作'), findsNothing);
    expect(find.text('添加到桌面'), findsNothing);
  });
}

class _ShuatiTestApp extends StatelessWidget {
  const _ShuatiTestApp({required this.platform});

  final TargetPlatform platform;

  @override
  Widget build(BuildContext context) {
    final router = GoRouter(
      initialLocation: '/shuati-practice',
      routes: [
        GoRoute(
          path: '/',
          name: 'home',
          builder: (context, state) => const Scaffold(body: Text('首页')),
        ),
        GoRoute(
          path: '/shuati-practice',
          name: 'shuati-practice',
          builder: (context, state) => const ShuatiWebViewPage(),
        ),
      ],
    );

    return MaterialApp.router(
      theme: ThemeData(platform: platform),
      routerConfig: router,
    );
  }
}
