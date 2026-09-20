import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jxu_campus_hub/app/app_bootstrap_controller.dart';
import 'package:jxu_campus_hub/core/config/app_config.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_builder.dart';
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
    final page = tester.widget<UnifiedAuthProtectedWebViewPage>(
      find.byType(UnifiedAuthProtectedWebViewPage),
    );
    expect(page.prepareAuthenticatedUrl, isNotNull);
    expect(page.loginDescription, contains('WebVPN'));
    // 受保护业务页绝不进入 CAS H5 登录页，也不提供一键填充。
    expect(page.url, isNot(contains('/cas/login')));
    expect(find.text('一键填充'), findsNothing);
    expect(find.text('一卡通快速填充'), findsNothing);
  });

  testWidgets('recharge tile opens xiaofubao page in WeChat', (tester) async {
    const wechatChannel = MethodChannel('edu.zjxu.jxucampushub/wechat');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wechatChannel, (call) async {
          calls.add(call);
          return true;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(wechatChannel, null);
    });
    final clipboard = _mockClipboard();

    await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('充值'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(calls.single.method, 'openUrlInWeChat');
    expect(
      (calls.single.arguments as Map)['url'],
      contains('webapp.xiaofubao.com'),
    );
    expect(find.text('已跳转到微信，请在微信中完成充值'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, '复制链接'), findsOneWidget);

    await tester.tap(find.widgetWithText(SnackBarAction, '复制链接'));
    await tester.pumpAndSettle();

    expect(clipboard.single, AppConfig.xiaofubaoRechargeUri.toString());
    expect(find.text('链接已复制'), findsOneWidget);
  });

  testWidgets('recharge failure auto-copies link and copy action copies url', (
    tester,
  ) async {
    const wechatChannel = MethodChannel('edu.zjxu.jxucampushub/wechat');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wechatChannel, (call) async => false);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(wechatChannel, null);
    });
    final clipboard = _mockClipboard();
    final url = AppConfig.xiaofubaoRechargeUri.toString();

    await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('充值'));
    await tester.pumpAndSettle();

    expect(clipboard, [url]);
    expect(find.text('未能打开页面，充值链接已复制，请到微信中打开'), findsOneWidget);
    expect(find.textContaining('已安装微信'), findsNothing);
    expect(find.widgetWithText(SnackBarAction, '复制链接'), findsOneWidget);

    await tester.tap(find.widgetWithText(SnackBarAction, '复制链接'));
    await tester.pumpAndSettle();

    expect(clipboard, [url, url]);
    expect(find.text('链接已复制'), findsOneWidget);
  });

  testWidgets('recharge copy survives clipboard PlatformException', (
    tester,
  ) async {
    const wechatChannel = MethodChannel('edu.zjxu.jxucampushub/wechat');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wechatChannel, (call) async => false);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(wechatChannel, null);
    });
    _mockClipboard(throwOnSet: true);

    await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('充值'));
    await tester.pumpAndSettle();

    expect(find.text('未能打开页面，可复制链接后到微信中打开'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.widgetWithText(SnackBarAction, '复制链接'));
    await tester.pumpAndSettle();

    expect(find.text('复制失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('payment code tile opens the payment page', (tester) async {
    final router = GoRouter(
      initialLocation: '/campus-card',
      routes: [
        GoRoute(
          path: '/campus-card',
          name: 'campus-card',
          builder: (context, state) => const CampusCardPage(),
        ),
        GoRoute(
          path: '/campus-card-payment',
          name: 'campus-card-payment',
          builder: (context, state) => const Scaffold(body: Text('付款码占位页')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('付款码'), findsOneWidget);
    await tester.tap(find.text('付款码'));
    await tester.pumpAndSettle();

    expect(find.text('付款码占位页'), findsOneWidget);
  });

  testWidgets('bottom refresh button queries the balance again', (
    tester,
  ) async {
    var calls = 0;
    CampusCardService.instance.debugBalanceFetcher = () async {
      calls++;
      return 88.0;
    };

    await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
    await tester.pumpAndSettle();

    expect(find.text('刷新余额'), findsOneWidget);
    await tester.ensureVisible(find.text('刷新余额'));
    await tester.tap(find.text('刷新余额'));
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.text('校园卡余额已刷新'), findsOneWidget);
  });

  testWidgets('bottom refresh button follows the theme seed', (tester) async {
    Future<Color?> buttonColorFor(Color seed) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemeBuilder.light(seed),
          home: const CampusCardPage(),
        ),
      );
      await tester.pumpAndSettle();
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.widgetWithText(FilledButton, '刷新余额'),
              matching: find.byType(Material),
            )
            .first,
      );
      return material.color;
    }

    final red = await buttonColorFor(const Color(0xFFB3261E));
    final green = await buttonColorFor(const Color(0xFF2E7D32));

    // 按钮底色跟随主题 seed，而不是写死的品牌色。
    expect(red, isNotNull);
    expect(green, isNotNull);
    expect(red, isNot(green));
  });

  testWidgets('balance exception shows failure and allows another refresh', (
    tester,
  ) async {
    var calls = 0;
    CampusCardService.instance.debugBalanceFetcher = () async {
      calls++;
      throw StateError('offline');
    };
    await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('刷新余额'));
    await tester.pumpAndSettle();
    expect(find.text('刷新失败，仍显示上次余额，请切换网络后重试'), findsOneWidget);
    expect(CampusCardService.instance.cachedBalance, 23.5);
    await tester.tap(find.byTooltip('刷新余额'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(tester.takeException(), isNull);
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

List<String> _mockClipboard({bool throwOnSet = false}) {
  final texts = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          if (throwOnSet) {
            throw PlatformException(code: 'unavailable');
          }
          texts.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  return texts;
}
