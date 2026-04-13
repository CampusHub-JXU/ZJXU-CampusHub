import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/campus_card/campus_card_page.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';
import 'package:jxu_campus_hub/shared/widgets/webvpn_protected_webview_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shortcutChannel = MethodChannel('edu.zjxu.jxucampushub/shortcut');

  setUp(() {
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
            return true;
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

    expect(find.byType(WebVpnProtectedWebViewPage), findsOneWidget);
  });
}
