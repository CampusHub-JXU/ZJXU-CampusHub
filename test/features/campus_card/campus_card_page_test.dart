import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/app/app_bootstrap_controller.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_page.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';
import 'package:jxu_campus_hub/shared/widgets/unified_auth_protected_webview_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shortcutChannel = MethodChannel('edu.zjxu.jxucampushub/shortcut');

  setUp(() {
    AppBootstrapController.instance.debugReset();
    CampusCardPage.debugAutoRefreshTriggered = false;
    CampusCardService.instance.debugBalanceFetcher = null;
    CampusCardService.instance.debugSetCachedBalance(
      23.5,
      updatedAt: DateTime(2026, 4, 10, 8, 0),
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shortcutChannel, null);
  });

  testWidgets('shows add-to-desktop action on android and requests shortcut', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shortcutChannel, (call) async {
          calls.add(call);
          if (call.method == 'consumeInitialShortcutAction') {
            return null;
          }
          if (call.method == 'requestCampusCardPaymentShortcut') {
            return 'requested';
          }
          return null;
        });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: const CampusCardPage(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();

    expect(find.text('添加至桌面'), findsOneWidget);

    await tester.tap(find.text('添加至桌面'));
    await tester.pumpAndSettle();

    expect(
      calls.map((call) => call.method),
      contains('requestCampusCardPaymentShortcut'),
    );
    expect(find.text('已发起添加请求，请在系统提示中确认'), findsOneWidget);
  });

  testWidgets('offers shortcut permission settings when launcher rejects', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shortcutChannel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'consumeInitialShortcutAction' => null,
            'requestCampusCardPaymentShortcut' => 'rejected',
            'openShortcutPermissionSettings' => true,
            _ => null,
          };
        });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: const CampusCardPage(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加至桌面'));
    await tester.pumpAndSettle();

    expect(find.text('去设置'), findsOneWidget);

    await tester.tap(find.text('去设置'));
    await tester.pumpAndSettle();

    expect(
      calls.map((call) => call.method),
      contains('openShortcutPermissionSettings'),
    );
  });

  testWidgets('hides add-to-desktop action on iOS themed page', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: const CampusCardPage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('添加至桌面'), findsNothing);
  });

  testWidgets('opens campus card inside webvpn protected webview', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('账单'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(UnifiedAuthProtectedWebViewPage), findsOneWidget);
  });

  group('bootstrap-aware balance refresh', () {
    testWidgets('does not query balance while bootstrap is still warming', (
      tester,
    ) async {
      CampusCardService.instance.debugSetCachedBalance(null);
      AppBootstrapController.instance.debugSetPhase(AppBootstrapPhase.warming);

      await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
      await tester.pumpAndSettle();

      // No balance query or WebView navigation should happen yet.
      expect(CampusCardPage.debugAutoRefreshTriggered, isFalse);
      expect(find.byType(UnifiedAuthProtectedWebViewPage), findsNothing);
    });

    testWidgets(
      'queries HTML directly when bootstrap completes with no cached balance',
      (tester) async {
        CampusCardService.instance.debugSetCachedBalance(null);
        CampusCardService.instance.debugBalanceFetcher = () async => 42.5;
        AppBootstrapController.instance.debugSetPhase(
          AppBootstrapPhase.warming,
        );

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pump();

        // Simulate bootstrap reaching localStateReady — balance is still null.
        AppBootstrapController.instance.debugSetPhase(
          AppBootstrapPhase.localStateReady,
        );
        await tester.pumpAndSettle();

        expect(CampusCardPage.debugAutoRefreshTriggered, isTrue);
        expect(find.byType(UnifiedAuthProtectedWebViewPage), findsNothing);
      },
    );

    testWidgets(
      'does not query balance when bootstrap restores the cached value',
      (tester) async {
        CampusCardService.instance.debugSetCachedBalance(null);
        AppBootstrapController.instance.debugSetPhase(
          AppBootstrapPhase.warming,
        );

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pump();

        // Simulate bootstrap restoring balance before phase completes.
        CampusCardService.instance.debugSetCachedBalance(
          50.0,
          updatedAt: DateTime.now(),
        );
        AppBootstrapController.instance.debugSetPhase(
          AppBootstrapPhase.localStateReady,
        );
        await tester.pump();
        await tester.pump();

        expect(CampusCardPage.debugAutoRefreshTriggered, isFalse);
      },
    );
  });
}
