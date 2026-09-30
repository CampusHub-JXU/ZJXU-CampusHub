import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jxu_campus_hub/app/app_bootstrap_controller.dart';
import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/cache/private_cache_store.dart';
import 'package:jxu_campus_hub/core/config/app_config.dart';
import 'package:jxu_campus_hub/core/epay100/epay100_gateway.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_builder.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_page.dart';
import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';
import 'package:jxu_campus_hub/shared/widgets/auth_required_view.dart';
import 'package:jxu_campus_hub/shared/widgets/login_shell.dart';
import 'package:jxu_campus_hub/shared/widgets/unified_auth_protected_webview_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shortcutChannel = MethodChannel('edu.zjxu.jxucampushub/shortcut');

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    AuthSessionPersistence.instance
      ..debugReset()
      ..debugDisableFileLock = true;
    UnifiedAuthService.instance.debugReset();
    AppBootstrapController.instance.debugReset();
    CampusCardPage.debugAutoRefreshTriggered = false;
    // 服务单例跨测试保留持久纪元 / 内存缓存 / 失败态：必须先清基线再重建
    // 缓存，否则上一测试推进的 _validEpoch 会让后续 restore / fetch 被
    // 「durableEpoch < observed」fail-closed 拒绝（余额消失、fetcher 不达）。
    CampusCardService.instance.debugReset();
    // 明确 CAS 身份：owner 缓存只在有明确账号时可见。
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'casuser',
    );
    await CredentialStore.instance.saveUnifiedAuthSession('casuser');
    final epoch = (await AuthSessionPersistence.instance.read(
      CredentialSessionDomain.unified,
    )).epoch;
    await SecureStoragePrivateCacheStore(CampusCardService.cacheKey).write(
      PrivateCacheEnvelope(
        owner: 'casuser',
        updatedAt: DateTime(2026, 4, 10, 8, 0),
        epoch: epoch,
        payload: 23.5,
      ),
    );
    await CampusCardService.instance.restoreBalance();
    // setUp 的 restore 已建立内存 epoch；清空 auth 持久化同域串行链，避免
    // 真实 async 建立的链跨入 widget fake-async 区导致后续锁调用挂起。
    AuthSessionPersistence.instance
      ..debugReset()
      ..debugDisableFileLock = true;
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shortcutChannel, null);
    AuthSessionPersistence.instance
      ..debugReset()
      ..debugDisableFileLock = true;
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

    expect(find.text('添加付款码到桌面'), findsOneWidget);

    await tester.tap(find.text('添加付款码到桌面'));
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
    await tester.tap(find.text('添加付款码到桌面'));
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

    // iOS 的 ⋮ 只剩「刷新余额」，没有桌面快捷方式。
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('刷新余额'), findsOneWidget);
    expect(find.text('添加付款码到桌面'), findsNothing);
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

  testWidgets('overflow menu refresh queries the balance again', (
    tester,
  ) async {
    var calls = 0;
    CampusCardService.instance.debugBalanceFetcher = () async {
      calls++;
      return 88.0;
    };

    await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
    await tester.pumpAndSettle();

    // 通栏刷新按钮与 AppBar 刷新图标都已移除，刷新收进 ⋮。
    expect(find.text('刷新余额'), findsNothing);
    expect(find.byTooltip('刷新余额'), findsNothing);
    await _tapMenuRefresh(tester);
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.text('88.00'), findsOneWidget);
    expect(find.text('校园卡余额已刷新'), findsOneWidget);
  });

  testWidgets('payment-code primary tile follows the theme seed', (tester) async {
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
            .ancestor(of: find.text('付款码'), matching: find.byType(Material))
            .first,
      );
      return material.color;
    }

    final red = await buttonColorFor(const Color(0xFFB3261E));
    final green = await buttonColorFor(const Color(0xFF2E7D32));

    // 付款码主格底色跟随主题 seed，而不是写死的品牌色。
    expect(red, isNotNull);
    expect(green, isNotNull);
    expect(red, isNot(green));
  });

  testWidgets('refresh keeps the cached amount and shows 正在刷新 inline', (
    tester,
  ) async {
    final pending = Completer<double?>();
    CampusCardService.instance.debugBalanceFetcher = () => pending.future;

    await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
    await tester.pumpAndSettle();
    await _tapMenuRefresh(tester);
    await tester.pump(const Duration(milliseconds: 50));

    // 刷新中：旧金额不闪成 --，卡内状态行提示正在刷新，没有通栏按钮。
    expect(find.text('23.50'), findsOneWidget);
    expect(find.textContaining('正在刷新'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '刷新余额'), findsNothing);

    pending.complete(30.0);
    await tester.pumpAndSettle();
    expect(find.text('30.00'), findsOneWidget);
    expect(find.textContaining('正在刷新'), findsNothing);
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
    await _tapMenuRefresh(tester);
    await tester.pumpAndSettle();
    expect(find.text('刷新失败，仍显示上次余额，请切换网络后重试'), findsOneWidget);
    expect(CampusCardService.instance.cachedBalance, 23.5);
    // 未知网络失败既不清缓存，也不误升格成登录问题：内容与重试保持可用。
    expect(find.text('23.50'), findsOneWidget);
    expect(find.textContaining('· 刷新失败'), findsOneWidget);
    expect(find.byType(AuthRequiredView), findsNothing);
    expect(find.byType(LoginShell), findsNothing);
    await _tapMenuRefresh(tester);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });

  group('balance card failure states and retry', () {
    testWidgets(
      'unauthenticated entry shows the auth gate and auto-prompts the login modal once',
      (tester) async {
        _enterLoggedOutWorld();
        var fetchCalls = 0;
        CampusCardService.instance.debugBalanceFetcher = () async {
          fetchCalls++;
          return 100.0;
        };

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await _pumpLoginModal(tester);

        // 首屏未登录：整页登录门 + 一次性自动唤起原生登录弹窗，而不是先报错。
        expect(find.byType(AuthRequiredView), findsOneWidget);
        expect(find.byType(LoginShell), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(LoginShell),
            matching: find.text('登录统一认证'),
          ),
          findsOneWidget,
        );
        // 未登录不发起任何余额查询，也不在后台自动登录。
        expect(fetchCalls, 0);
        expect(CampusCardPage.debugAutoRefreshTriggered, isFalse);

        // 关闭弹窗后登录门保持可用。
        await _closeLoginModal(tester);
        expect(find.byType(LoginShell), findsNothing);
        expect(find.byType(AuthRequiredView), findsOneWidget);
        expect(find.widgetWithText(FilledButton, '登录统一认证'), findsOneWidget);

        // 一次性窗口已关闭：认证通知与反复 rebuild 都不再自动弹窗。
        UnifiedAuthService.instance.notifyListeners();
        await tester.pumpAndSettle();
        await tester.pump();
        await tester.pump();
        expect(find.byType(LoginShell), findsNothing);
        expect(fetchCalls, 0);
      },
    );

    testWidgets(
      'auth gate action opens the login modal and successful login flows to the normal page',
      (tester) async {
        _enterLoggedOutWorld();
        var fetchCalls = 0;
        CampusCardService.instance.debugBalanceFetcher = () async {
          fetchCalls++;
          return 100.0;
        };

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await _pumpLoginModal(tester);
        await _closeLoginModal(tester);

        // 点击登录门按钮再次唤起统一认证登录弹窗。
        await tester.tap(find.widgetWithText(FilledButton, '登录统一认证'));
        await _pumpLoginModal(tester);
        expect(find.byType(LoginShell), findsOneWidget);

        // 模拟登录成功：更新登录态并广播认证通知（真实登录会通知），再以
        // true 关闭弹窗。身份切换拉取与模态成功拉取必须合并成恰好一次。
        UnifiedAuthService.instance.debugSetSession(
          active: true,
          account: 'casuser',
        );
        UnifiedAuthService.instance.notifyListeners();
        Navigator.of(
          tester.element(find.byType(LoginShell)),
          rootNavigator: true,
        ).pop(true);
        await tester.pumpAndSettle();

        // 回到正常页面：余额卡与功能入口回来，并自动查询一次余额。
        expect(find.byType(LoginShell), findsNothing);
        expect(find.byType(AuthRequiredView), findsNothing);
        expect(find.text('校园卡余额'), findsOneWidget);
        expect(find.text('100.00'), findsOneWidget);
        expect(find.text('付款码'), findsOneWidget);
        // 单位写在数字后（「100.00 元」），三格副标题说明去向。
        expect(find.text('元'), findsOneWidget);
        expect(find.text('¥'), findsNothing);
        expect(find.text('出示扫码'), findsOneWidget);
        expect(find.text('消费明细'), findsOneWidget);
        expect(find.text('微信'), findsOneWidget);
        expect(find.text('账单'), findsOneWidget);
        expect(find.text('充值'), findsOneWidget);
        expect(find.text('校园卡余额已刷新'), findsOneWidget);
        expect(fetchCalls, 1);
      },
    );

    testWidgets(
      'login success from the auth gate pulls exactly once when the login '
      'notification arrives without a ready account',
      (tester) async {
        _enterLoggedOutWorld();
        var fetchCalls = 0;
        CampusCardService.instance.debugBalanceFetcher = () async {
          fetchCalls++;
          return 100.0;
        };

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await _pumpLoginModal(tester);
        await _closeLoginModal(tester);

        // 点击登录门按钮再次唤起统一认证登录弹窗。
        await tester.tap(find.widgetWithText(FilledButton, '登录统一认证'));
        await _pumpLoginModal(tester);

        // 登录进行中的认证通知先到、账号仍未就绪（identity.account 为 null）：
        // _onAuthChanged 按「无明确 owner 不拉」跳过自动拉取。
        UnifiedAuthService.instance.debugSetSession(
          active: true,
          account: null,
        );
        UnifiedAuthService.instance.notifyListeners();
        await tester.pump();
        // 账号随后就绪但没有第二次认证广播（登录事务内「先通知、后定型」的
        // 时序）。此时以 true 关闭弹窗。
        UnifiedAuthService.instance.debugSetSession(
          active: true,
          account: 'casuser',
        );
        Navigator.of(
          tester.element(find.byType(LoginShell)),
          rootNavigator: true,
        ).pop(true);
        await tester.pumpAndSettle();

        // 登录成功收口必须恰好拉一次：既不因通知簿记漏拉成零拉取，
        // 也不与 _onAuthChanged 路径双拉。
        expect(fetchCalls, 1);
        expect(find.text('100.00'), findsOneWidget);
        expect(find.text('--'), findsNothing);
        expect(find.text('校园卡余额已刷新'), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        expect(fetchCalls, 1);
      },
    );

    testWidgets(
      'login success after a mid-modal identity notification pulls exactly '
      'once after the modal settles',
      (tester) async {
        _enterLoggedOutWorld();
        final pending = Completer<double>();
        var fetchCalls = 0;
        CampusCardService.instance.debugBalanceFetcher = () {
          fetchCalls++;
          return pending.future;
        };

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await _pumpLoginModal(tester);
        await _closeLoginModal(tester);

        await tester.tap(find.widgetWithText(FilledButton, '登录统一认证'));
        await _pumpLoginModal(tester);

        // 弹窗内登录成功的通知先到（身份推进、账号就绪）。
        UnifiedAuthService.instance.debugSetSession(
          active: true,
          account: 'casuser',
        );
        UnifiedAuthService.instance.notifyListeners();
        await tester.pump();
        await tester.pump();
        // 紧随其后的同身份重复认证通知：服务端监听器会清缓存并作废在途请求
        // ——弹窗内提早发出的拉取结果会被丢弃，余额只剩 `--`（真机「登录后
        // 余额不即时」的根因链）。
        UnifiedAuthService.instance.notifyListeners();
        await tester.pump();

        Navigator.of(
          tester.element(find.byType(LoginShell)),
          rootNavigator: true,
        ).pop(true);
        await tester.pump();
        await tester.pump();
        await tester.pump();

        // 拉取恰好一次，且发生在弹窗结算后，不被弹窗内的重复通知作废。
        expect(fetchCalls, 1);
        pending.complete(100.0);
        await tester.pumpAndSettle();

        expect(find.text('100.00'), findsOneWidget);
        expect(find.text('--'), findsNothing);
        expect(find.text('校园卡余额已刷新'), findsOneWidget);
        expect(fetchCalls, 1);
      },
    );

    testWidgets(
      'one-shot login prompt waits until the bootstrap state is known',
      (tester) async {
        _enterLoggedOutWorld();
        AppBootstrapController.instance.debugSetPhase(
          AppBootstrapPhase.warming,
        );

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pumpAndSettle();

        // 暖启动未完成（持久身份可能仍在恢复）：只显示登录门，不自动弹窗。
        expect(find.byType(AuthRequiredView), findsOneWidget);
        expect(find.byType(LoginShell), findsNothing);

        // 暖启动完成并确认未登录后：post-frame 自动弹一次。
        AppBootstrapController.instance.debugSetPhase(
          AppBootstrapPhase.localStateReady,
        );
        await _pumpLoginModal(tester);
        expect(find.byType(LoginShell), findsOneWidget);

        await _closeLoginModal(tester);
        expect(find.byType(LoginShell), findsNothing);
      },
    );

    testWidgets(
      'unauthenticated entry replaces query actions with the login gate and never queries',
      (tester) async {
        _enterLoggedOutWorld();
        var fetchCalls = 0;
        CampusCardService.instance.debugBalanceFetcher = () async {
          fetchCalls++;
          return 88.0;
        };

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await _pumpLoginModal(tester);
        await _closeLoginModal(tester);

        // 登录门外没有查询入口：不再先报错，再让用户找隐藏的登录按钮。
        expect(find.byTooltip('刷新余额'), findsNothing);
        expect(find.widgetWithText(FilledButton, '刷新余额'), findsNothing);
        expect(find.text('付款码'), findsNothing);
        expect(find.text('账单'), findsNothing);
        expect(find.text('充值'), findsNothing);
        expect(find.text('--'), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        expect(find.textContaining('网络'), findsNothing);
        expect(fetchCalls, 0);
        expect(CampusCardPage.debugAutoRefreshTriggered, isFalse);
        expect(find.byType(AuthRequiredView), findsOneWidget);
        expect(find.byType(LoginShell), findsNothing);
      },
    );

    testWidgets(
      'cached balance stays hidden behind the login gate when unauthenticated',
      (tester) async {
        // setUp 已为 'casuser' 建立 23.5 缓存；此时按未登录身份进入。
        _enterLoggedOutWorld();

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await _pumpLoginModal(tester);
        await _closeLoginModal(tester);

        // 遵从 owner 隔离，不展示旧账号余额，只给整页登录门。
        expect(find.text('23.50'), findsNothing);
        expect(find.text('--'), findsNothing);
        expect(find.byType(AuthRequiredView), findsOneWidget);
        expect(find.text('需要登录统一认证后继续'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, '登录统一认证'), findsOneWidget);
      },
    );

    testWidgets(
      'page visible when session is logged out elsewhere re-gates to the login gate without auto-prompting',
      (tester) async {
        // 先建立带 authExpired 的失效态页面（此时仍已登录）
        CampusCardService.instance.debugSetCachedBalance(null);
        CampusCardService.instance.debugSetLastBalanceFailure(
          BalanceFailureKind.authExpired,
        );

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pumpAndSettle();

        expect(find.text('登录已失效，请重新登录统一认证'), findsOneWidget);
        expect(find.text('重新登录'), findsOneWidget);
        expect(find.byType(AuthRequiredView), findsNothing);

        // 用户在别处登出（无 owner）：页面立即重绘为整页登录门，不能长留
        // 过期提示，也不自动弹登录窗。
        UnifiedAuthService.instance.debugSetSession(
          active: false,
          account: null,
        );
        UnifiedAuthService.instance.notifyListeners();
        await tester.pumpAndSettle();

        expect(find.byType(AuthRequiredView), findsOneWidget);
        expect(find.text('需要登录统一认证后继续'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, '登录统一认证'), findsOneWidget);
        expect(find.text('登录已失效，请重新登录统一认证'), findsNothing);
        expect(find.text('重新登录'), findsNothing);
        expect(find.text('--'), findsNothing);
        expect(find.byType(LoginShell), findsNothing);
      },
    );

    testWidgets(
      'page visible when user logs out elsewhere removes cached balance and shows the login gate',
      (tester) async {
        // 初始已登录且有 23.5 缓存余额
        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pumpAndSettle();

        expect(find.text('23.50'), findsOneWidget);

        // 在别处登出
        UnifiedAuthService.instance.debugSetSession(
          active: false,
          account: null,
        );
        UnifiedAuthService.instance.notifyListeners();
        await tester.pumpAndSettle();

        // 立即移除旧余额展示并整页上锁，遵从 owner 隔离；登出不自动弹登录。
        expect(find.text('23.50'), findsNothing);
        expect(find.byType(AuthRequiredView), findsOneWidget);
        expect(find.text('需要登录统一认证后继续'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, '登录统一认证'), findsOneWidget);
        expect(find.byType(LoginShell), findsNothing);
      },
    );

    testWidgets(
      'login elsewhere while the auth gate is mounted pulls the balance immediately exactly once',
      (tester) async {
        // 初始未登录：一次性登录弹窗出现后手动关闭，登录门保持挂载。
        _enterLoggedOutWorld();
        var fetchCalls = 0;
        CampusCardService.instance.debugBalanceFetcher = () async {
          fetchCalls++;
          return 42.5;
        };

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await _pumpLoginModal(tester);
        await _closeLoginModal(tester);
        expect(find.byType(AuthRequiredView), findsOneWidget);

        // 用户在别处完成登录：无需任何点击，余额立刻拉取并展示。
        UnifiedAuthService.instance.debugSetSession(
          active: true,
          account: 'casuser',
        );
        UnifiedAuthService.instance.notifyListeners();
        await tester.pumpAndSettle();

        // 登录门消失，余额直接就位；不自动弹窗，也只拉恰好一次。
        expect(find.byType(AuthRequiredView), findsNothing);
        expect(find.byType(LoginShell), findsNothing);
        expect(find.text('需要登录统一认证后继续'), findsNothing);
        expect(find.text('42.50'), findsOneWidget);
        expect(find.text('点击查询余额'), findsNothing);
        expect(find.text('校园卡余额已刷新'), findsOneWidget);
        expect(fetchCalls, 1);
      },
    );

    testWidgets(
      'sign out then login with a different account never exposes the prior balance and pulls once',
      (tester) async {
        var fetchCalls = 0;
        CampusCardService.instance.debugBalanceFetcher = () async {
          fetchCalls++;
          return 7.0;
        };

        // 初始已登录 'casuser' 且展示 23.5。
        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pumpAndSettle();
        expect(find.text('23.50'), findsOneWidget);

        // 登出：只上登录门，不发起任何查询。
        UnifiedAuthService.instance.debugSetSession(
          active: false,
          account: null,
        );
        UnifiedAuthService.instance.notifyListeners();
        await tester.pumpAndSettle();
        expect(find.byType(AuthRequiredView), findsOneWidget);
        expect(find.text('23.50'), findsNothing);
        expect(fetchCalls, 0);

        // 身份不完整（active 但无账号）：同样不得触发查询。
        UnifiedAuthService.instance.debugSetSession(
          active: true,
          account: null,
        );
        UnifiedAuthService.instance.notifyListeners();
        await tester.pumpAndSettle();
        expect(fetchCalls, 0);

        // 为新账号备好持久身份：服务端余额查询按持久 envelope 校验 owner。
        await tester.runAsync(
          () => CredentialStore.instance.saveUnifiedAuthSession('otheruser'),
        );

        // 换号登录：立即拉一次新 owner 的余额，绝不露出上一账号的 23.50。
        UnifiedAuthService.instance.debugSetSession(
          active: true,
          account: 'otheruser',
        );
        UnifiedAuthService.instance.notifyListeners();
        await tester.pumpAndSettle();

        expect(find.text('7.00'), findsOneWidget);
        expect(find.text('23.50'), findsNothing);
        expect(find.text('--'), findsNothing);
        expect(fetchCalls, 1);
        expect(find.byType(AuthRequiredView), findsNothing);
        expect(find.byType(LoginShell), findsNothing);
      },
    );

    testWidgets(
      'a pending fetch from the old account drops late and the new account still gets exactly one automatic pull',
      (tester) async {
        final pendingA = Completer<double?>();
        final pendingB = Completer<double?>();
        var calls = 0;
        CampusCardService.instance.debugBalanceFetcher = () {
          calls++;
          return calls == 1 ? pendingA.future : pendingB.future;
        };

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pumpAndSettle();
        expect(find.text('23.50'), findsOneWidget);

        // A（'casuser'）手动刷新：请求在途，服务端迟迟不返回。
        await _tapMenuRefresh(tester);
        await tester.pump();
        await tester.pump();
        expect(calls, 1);

        // B 换号登录（先备好 B 的持久身份）：新身份的拉取绝不能被 A 的在途
        // 请求挡掉——排到旧请求结算后自动补拉。
        await tester.runAsync(
          () => CredentialStore.instance.saveUnifiedAuthSession('otheruser'),
        );
        UnifiedAuthService.instance.debugSetSession(
          active: true,
          account: 'otheruser',
        );
        UnifiedAuthService.instance.notifyListeners();
        await tester.pump();
        await tester.pump();

        // A 仍在途：B 的补拉已排队、尚未发出，也不重复。
        expect(calls, 1);
        expect(find.text('23.50'), findsNothing);

        // A 迟到返回旧账号的 99：结果与提示一律作废，绝不覆盖 B 的界面。
        pendingA.complete(99.0);
        await tester.pump();
        await tester.pump();

        // 旧请求结算后恰好自动补拉一次新身份的余额。
        expect(calls, 2);
        expect(find.text('99.00'), findsNothing);
        expect(find.byType(SnackBar), findsNothing);

        pendingB.complete(7.0);
        await tester.pumpAndSettle();

        expect(find.text('7.00'), findsOneWidget);
        expect(find.text('99.00'), findsNothing);
        expect(find.text('校园卡余额已刷新'), findsOneWidget);
        expect(calls, 2);
        expect(find.byType(AuthRequiredView), findsNothing);
        expect(find.byType(LoginShell), findsNothing);
      },
    );

    testWidgets(
      'same-account re-login that advances the session revision pulls the balance exactly once',
      (tester) async {
        var calls = 0;
        CampusCardService.instance.debugBalanceFetcher = () async {
          calls++;
          return 58.0;
        };

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pumpAndSettle();
        expect(find.text('23.50'), findsOneWidget);
        expect(calls, 0);

        // 同账号重登会推进 sessionRevision（登出 + 同号重登合成一次通知，
        // 页面不经过登出中间态）：必须当作身份推进，自动重拉恰好一次。
        final revisionBefore = UnifiedAuthService.instance.sessionRevision;
        UnifiedAuthService.instance.debugSetSession(
          active: false,
          account: null,
        );
        UnifiedAuthService.instance.debugSetSession(
          active: true,
          account: 'casuser',
        );
        UnifiedAuthService.instance.notifyListeners();
        expect(
          UnifiedAuthService.instance.sessionRevision,
          greaterThan(revisionBefore),
        );
        await tester.pumpAndSettle();

        expect(calls, 1);
        expect(find.text('58.00'), findsOneWidget);
        expect(find.text('23.50'), findsNothing);
        expect(find.byType(AuthRequiredView), findsNothing);
        expect(find.byType(LoginShell), findsNothing);
      },
    );

    testWidgets(
      'repeat auth notifications for the same account and revision never re-fetch',
      (tester) async {
        var calls = 0;
        CampusCardService.instance.debugBalanceFetcher = () async {
          calls++;
          return 12.0;
        };

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pumpAndSettle();
        expect(find.text('23.50'), findsOneWidget);
        expect(calls, 0);

        // 同账号同 revision 的重复认证通知：既不弹登录，也一次都不拉。
        UnifiedAuthService.instance.notifyListeners();
        UnifiedAuthService.instance.notifyListeners();
        await tester.pumpAndSettle();
        await tester.pump();
        await tester.pump();

        expect(calls, 0);
        expect(CampusCardPage.debugAutoRefreshTriggered, isFalse);
        expect(find.byType(AuthRequiredView), findsNothing);
        expect(find.byType(LoginShell), findsNothing);
      },
    );

    testWidgets(
      'login notify without a ready account still settles exactly one pull after modal success',
      (tester) async {
        // 真机问题 1 的确定性复现：登录过程中先到一次「账号尚未就绪」的认证
        // 通知（revision 已推进、账号为 null），身份随后就绪但不再另行通知，
        // 登录弹窗此刻才返回 true。登录门→内容态完成切换后，余额拉取不得悬空。
        _enterLoggedOutWorld();
        var fetchCalls = 0;
        CampusCardService.instance.debugBalanceFetcher = () async {
          fetchCalls++;
          return 31.0;
        };

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await _pumpLoginModal(tester);

        // 通知到达时账号仍不可用：revision 已推进、currentAccount 为 null。
        UnifiedAuthService.instance.debugSetSession(
          active: true,
          account: 'casuser',
        );
        UnifiedAuthService.instance.debugSetSession(
          active: false,
          account: null,
        );
        UnifiedAuthService.instance.notifyListeners();
        await tester.pump();

        // 身份随后静默就绪（写入方不另行通知），弹窗此刻才返回 true。
        UnifiedAuthService.instance.debugSetSession(
          active: true,
          account: 'casuser',
        );
        Navigator.of(
          tester.element(find.byType(LoginShell)),
          rootNavigator: true,
        ).pop(true);
        await tester.pumpAndSettle();

        // 登录成功必须恰好补上一次余额拉取，余额即时可见，无需再手点刷新。
        expect(fetchCalls, 1);
        expect(find.text('31.00'), findsOneWidget);
        expect(find.text('--'), findsNothing);
        expect(find.byType(AuthRequiredView), findsNothing);
        expect(find.byType(LoginShell), findsNothing);
      },
    );

    testWidgets(
      'modal success settles exactly one pull even when identity completed without any notification',
      (tester) async {
        // 同一根因的最纯形态：整个登录期间没有任何认证通知，身份在弹窗内
        // 静默就绪后弹窗以 true 返回——登录成功本身必须成为拉取触发点。
        _enterLoggedOutWorld();
        var fetchCalls = 0;
        CampusCardService.instance.debugBalanceFetcher = () async {
          fetchCalls++;
          return 19.5;
        };

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await _pumpLoginModal(tester);

        UnifiedAuthService.instance.debugSetSession(
          active: true,
          account: 'casuser',
        );
        Navigator.of(
          tester.element(find.byType(LoginShell)),
          rootNavigator: true,
        ).pop(true);
        await tester.pumpAndSettle();

        expect(fetchCalls, 1);
        expect(find.text('19.50'), findsOneWidget);
        expect(find.text('--'), findsNothing);
        expect(find.byType(AuthRequiredView), findsNothing);
        expect(find.byType(LoginShell), findsNothing);
      },
    );

    testWidgets(
      'a late result after sign-out never shows stale feedback on the auth gate',
      (tester) async {
        final pending = Completer<double?>();
        CampusCardService.instance.debugBalanceFetcher = () => pending.future;

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pumpAndSettle();

        // 手动刷新在途时登出：登出本身不发起查询、也不排队拉取。
        await _tapMenuRefresh(tester);
        await tester.pump();
        await tester.pump();
        UnifiedAuthService.instance.debugSetSession(
          active: false,
          account: null,
        );
        UnifiedAuthService.instance.notifyListeners();
        await tester.pumpAndSettle();
        expect(find.byType(AuthRequiredView), findsOneWidget);

        // 旧请求迟到成功：既不露出旧账号余额，也不在登录门上弹过期提示。
        pending.complete(99.0);
        await tester.pumpAndSettle();
        await tester.pump();

        expect(find.text('99.00'), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        expect(find.byType(AuthRequiredView), findsOneWidget);
        expect(find.byType(LoginShell), findsNothing);
      },
    );

    testWidgets(
      'serviceUnavailable with null balance shows prompt and retry entry',
      (tester) async {
        CampusCardService.instance.debugSetCachedBalance(null);
        CampusCardService.instance.debugSetLastBalanceFailure(
          BalanceFailureKind.serviceUnavailable,
        );

        var refreshCalls = 0;
        CampusCardService.instance.debugBalanceFetcher = () async {
          refreshCalls++;
          return 52.0;
        };

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pumpAndSettle();

        expect(find.text('一卡通服务暂时不可用，请稍后重试'), findsOneWidget);
        expect(find.text('点击查询余额'), findsOneWidget);

        // 点击卡片内查询余额按钮重试
        await tester.tap(find.text('点击查询余额'));
        await tester.pumpAndSettle();

        expect(refreshCalls, 1);
        expect(find.text('52.00'), findsOneWidget);
        expect(find.text('一卡通服务暂时不可用，请稍后重试'), findsNothing);
      },
    );

    testWidgets(
      'auto-refresh failure with EpayGatewayException updates card to serviceUnavailable',
      (tester) async {
        CampusCardService.instance.debugSetCachedBalance(null);
        CampusCardService.instance.debugBalanceFetcher = () async {
          throw const EpayGatewayException('ERR4995');
        };
        AppBootstrapController.instance.debugSetPhase(
          AppBootstrapPhase.localStateReady,
        );

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pumpAndSettle();

        expect(find.text('一卡通服务暂时不可用，请稍后重试'), findsOneWidget);
        expect(find.text('点击查询余额'), findsOneWidget);
        // 网关瞬时故障不是登录问题：不上登录门，也不自动弹登录。
        expect(find.byType(AuthRequiredView), findsNothing);
        expect(find.byType(LoginShell), findsNothing);
      },
    );

    testWidgets(
      'authExpired with null balance shows prompt and opens unified auth modal',
      (tester) async {
        CampusCardService.instance.debugSetCachedBalance(null);
        CampusCardService.instance.debugSetLastBalanceFailure(
          BalanceFailureKind.authExpired,
        );
        CampusCardService.instance.debugBalanceFetcher = () async {
          throw const EpaySessionUnavailableException('会话已失效');
        };

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pumpAndSettle();

        expect(find.text('登录已失效，请重新登录统一认证'), findsOneWidget);
        expect(find.text('重新登录'), findsOneWidget);

        // 点击重新登录唤起统一认证登录弹窗
        await tester.tap(find.text('重新登录'));
        await tester.pump();

        expect(find.byType(LoginShell), findsOneWidget);
        expect(find.text('登录统一认证'), findsOneWidget);
      },
    );

    testWidgets(
      'network failure with null balance shows network prompt and retry',
      (tester) async {
        CampusCardService.instance.debugSetCachedBalance(null);
        CampusCardService.instance.debugSetLastBalanceFailure(
          BalanceFailureKind.network,
        );

        var retryCalled = false;
        CampusCardService.instance.debugBalanceFetcher = () async {
          retryCalled = true;
          return 66.0;
        };

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pumpAndSettle();

        expect(find.text('网络不可用，请检查网络后重试'), findsOneWidget);
        expect(find.text('点击查询余额'), findsOneWidget);

        await tester.tap(find.text('点击查询余额'));
        await tester.pumpAndSettle();

        expect(retryCalled, isTrue);
        expect(find.text('66.00'), findsOneWidget);
        expect(find.text('网络不可用，请检查网络后重试'), findsNothing);
      },
    );

    testWidgets(
      'serviceUnavailable with existing balance preserves balance display',
      (tester) async {
        CampusCardService.instance.debugBalanceFetcher = () async {
          throw const EpayGatewayException(
            'MH904接口：HTTP接口[open.ykt.getBalance]网络繁忙，请稍后再试',
          );
        };

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pumpAndSettle();

        // 原有缓存余额正常显示
        expect(find.text('23.50'), findsOneWidget);

        // 刷新失败时保留旧余额并显示提示
        await _tapMenuRefresh(tester);
        await tester.pumpAndSettle();

        expect(find.text('23.50'), findsOneWidget);
        expect(find.text('刷新失败，仍显示上次余额，请稍后重试'), findsOneWidget);
        expect(CampusCardService.instance.cachedBalance, 23.5);
      },
    );

    testWidgets('obscure toggle toggles between balance text and mask', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
      await tester.pumpAndSettle();

      expect(find.text('23.50'), findsOneWidget);
      expect(find.text('****'), findsNothing);

      // 可见性开关保持 44x44 最小点按区域。
      final toggleSize = tester.getSize(find.byTooltip('隐藏余额'));
      expect(toggleSize.width, greaterThanOrEqualTo(44));
      expect(toggleSize.height, greaterThanOrEqualTo(44));

      // 隐藏余额
      await tester.tap(find.byTooltip('隐藏余额'));
      await tester.pumpAndSettle();

      expect(find.text('****'), findsOneWidget);
      expect(find.text('23.50'), findsNothing);

      // 显示余额
      await tester.tap(find.byTooltip('显示余额'));
      await tester.pumpAndSettle();

      expect(find.text('23.50'), findsOneWidget);
      expect(find.text('****'), findsNothing);
    });

    testWidgets('visibility toggle sits on the 余额 header row', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
      await tester.pumpAndSettle();

      final label = tester.getRect(find.text('校园卡余额'));
      final amount = tester.getRect(find.text('23.50'));
      final eye = tester.getRect(find.byTooltip('隐藏余额'));

      // 顶行「余额」+ 眼睛：与标签同行、在金额之上、位于标签右侧。
      expect(eye.center.dy, moreOrLessEquals(label.center.dy, epsilon: 8));
      expect(eye.center.dy, lessThan(amount.top));
      expect(eye.left, greaterThan(label.right));

      final size = tester.getSize(find.byTooltip('隐藏余额'));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    });
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

  group('narrow screen and large text', () {
    testWidgets(
      'balance card fits 360px screen at 1.5x text without overflow',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData.fromView(tester.view)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: const CampusCardPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('23.50'), findsOneWidget);
        expect(find.text('校园卡余额'), findsOneWidget);
        expect(find.text('付款码'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  testWidgets('serviceUnavailable failure never suggests re-login', (
    tester,
  ) async {
    CampusCardService.instance.debugSetCachedBalance(null);
    CampusCardService.instance.debugSetLastBalanceFailure(
      BalanceFailureKind.serviceUnavailable,
    );

    await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
    await tester.pumpAndSettle();

    // 服务不可用是可重试故障：只给重试入口，不引导重新登录。
    expect(find.text('一卡通服务暂时不可用，请稍后重试'), findsOneWidget);
    expect(find.text('点击查询余额'), findsOneWidget);
    expect(find.text('登录统一认证'), findsNothing);
    expect(find.text('重新登录'), findsNothing);
    expect(find.byType(AuthRequiredView), findsNothing);
    expect(find.byType(LoginShell), findsNothing);
  });

  testWidgets('network failure never suggests re-login', (tester) async {
    CampusCardService.instance.debugSetCachedBalance(null);
    CampusCardService.instance.debugSetLastBalanceFailure(
      BalanceFailureKind.network,
    );

    await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
    await tester.pumpAndSettle();

    // 网络不可用同理，绝不误提示登录失效。
    expect(find.text('网络不可用，请检查网络后重试'), findsOneWidget);
    expect(find.text('点击查询余额'), findsOneWidget);
    expect(find.text('登录统一认证'), findsNothing);
    expect(find.text('重新登录'), findsNothing);
    expect(find.byType(AuthRequiredView), findsNothing);
    expect(find.byType(LoginShell), findsNothing);
  });
}

/// 未登录入场：登录弹窗里的 restoreSession 不得复活 setUp 写入的持久会话，
/// 但保留持久 envelope，供模拟登录成功后的余额查询通过身份校验。同时把
/// 暖启动标到已完成（真实页面进入时恒成立），让一次性登录引导可以决策。
void _enterLoggedOutWorld() {
  UnifiedAuthService.instance.debugSessionMetadataLoader = () async => null;
  UnifiedAuthService.instance.debugSetSession(active: false, account: null);
  AppBootstrapController.instance.debugSetPhase(AppBootstrapPhase.completed);
}

/// 登录弹窗内验证码准备在 FakeAsync 中挂起且带重复动画，不能 pumpAndSettle；
/// 只推进两帧让 post-frame 排定的弹窗入场完成。
Future<void> _pumpLoginModal(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _closeLoginModal(WidgetTester tester) async {
  await tester.tap(find.byTooltip('关闭'));
  await tester.pumpAndSettle();
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

/// UI 走真实入口：打开 ⋮「更多操作」再点「刷新余额」。
Future<void> _tapMenuRefresh(WidgetTester tester) async {
  await tester.tap(find.byTooltip('更多操作'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.text('刷新余额'));
  await tester.pump();
}
