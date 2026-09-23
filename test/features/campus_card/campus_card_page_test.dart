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
    CampusCardService.instance.debugBalanceFetcher = null;
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

  group('balance card failure states and retry', () {
    testWidgets(
      'authRequired with no CAS session shows prompt without auto modal and CTA opens modal',
      (tester) async {
        UnifiedAuthService.instance.debugSetSession(
          active: false,
          account: null,
        );
        CampusCardService.instance.debugBalanceFetcher = () async => 100.0;

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pumpAndSettle();

        // 初始首屏：正常展示无身份空态，不展示网络错误，不自动弹窗
        expect(find.text('--'), findsOneWidget);
        expect(find.text('请先登录统一认证，再查询校园卡余额'), findsOneWidget);
        expect(find.text('登录统一认证'), findsOneWidget);
        expect(find.text('重新登录'), findsNothing);
        expect(find.text('点击查询余额'), findsNothing);
        expect(find.byType(LoginShell), findsNothing);

        // 点击卡片 CTA 唤起统一认证登录弹窗；为避免模态框内发起真实网络验证码请求，就地提供 session
        UnifiedAuthService.instance.debugSetSession(
          active: true,
          account: 'casuser',
        );
        await tester.tap(find.text('登录统一认证'));
        await tester.pump();

        expect(find.byType(LoginShell), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(LoginShell),
            matching: find.text('登录统一认证'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'refreshing balance without CAS session provides auth feedback instead of network error',
      (tester) async {
        UnifiedAuthService.instance.debugSetSession(
          active: false,
          account: null,
        );

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pumpAndSettle();

        // 点击顶部刷新按钮：提示先登录统一认证，不给网络错误提示，不反复弹登录窗
        await tester.tap(find.byTooltip('刷新余额'));
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text('请先登录统一认证，再查询校园卡余额'),
          ),
          findsOneWidget,
        );
        expect(find.textContaining('网络'), findsNothing);
        expect(find.textContaining('检查网络或登录状态'), findsNothing);
        expect(find.byType(LoginShell), findsNothing);
        expect(find.text('--'), findsOneWidget);

        // 点击底部刷新按钮：同样给出正确提示，不弹窗
        await tester.ensureVisible(find.widgetWithText(FilledButton, '刷新余额'));
        await tester.tap(
          find.widgetWithText(FilledButton, '刷新余额'),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text('请先登录统一认证，再查询校园卡余额'),
          ),
          findsOneWidget,
        );
        expect(find.textContaining('网络'), findsNothing);
        expect(find.byType(LoginShell), findsNothing);
      },
    );

    testWidgets(
      'cached balance is isolated when session is cleared and shows authRequired state',
      (tester) async {
        // setUp 已为 'casuser' 建立 23.5 缓存；此时注销统一认证身份
        UnifiedAuthService.instance.debugSetSession(
          active: false,
          account: null,
        );

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pumpAndSettle();

        // 遵从 owner 隔离，不展示旧账号余额
        expect(find.text('23.50'), findsNothing);
        expect(find.text('--'), findsOneWidget);
        expect(find.text('请先登录统一认证，再查询校园卡余额'), findsOneWidget);
        expect(find.text('登录统一认证'), findsOneWidget);
      },
    );

    testWidgets(
      'page visible when session is logged out elsewhere immediately updates from authExpired to authRequired',
      (tester) async {
        // 先建立带 authExpired 的失效态页面
        CampusCardService.instance.debugSetCachedBalance(null);
        CampusCardService.instance.debugSetLastBalanceFailure(
          BalanceFailureKind.authExpired,
        );

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pumpAndSettle();

        expect(find.text('登录已失效，请重新登录统一认证'), findsOneWidget);
        expect(find.text('重新登录'), findsOneWidget);

        // 用户在别处登出（无 owner）：页面响应监听立即重绘为 authRequired，不能长留过期提示
        UnifiedAuthService.instance.debugSetSession(
          active: false,
          account: null,
        );
        UnifiedAuthService.instance.notifyListeners();
        await tester.pumpAndSettle();

        expect(find.text('登录已失效，请重新登录统一认证'), findsNothing);
        expect(find.text('重新登录'), findsNothing);
        expect(find.text('请先登录统一认证，再查询校园卡余额'), findsOneWidget);
        expect(find.text('登录统一认证'), findsOneWidget);
        expect(find.text('--'), findsOneWidget);
      },
    );

    testWidgets(
      'page visible when user logs out elsewhere immediately removes cached balance from display',
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

        // 页面立即重绘并移除旧余额展示，遵从 owner 隔离
        expect(find.text('23.50'), findsNothing);
        expect(find.text('--'), findsOneWidget);
        expect(find.text('请先登录统一认证，再查询校园卡余额'), findsOneWidget);
        expect(find.text('登录统一认证'), findsOneWidget);
      },
    );

    testWidgets(
      'page visible when user logs in elsewhere immediately updates prompt state',
      (tester) async {
        // 初始未登录
        UnifiedAuthService.instance.debugSetSession(
          active: false,
          account: null,
        );

        await tester.pumpWidget(const MaterialApp(home: CampusCardPage()));
        await tester.pumpAndSettle();

        expect(find.text('请先登录统一认证，再查询校园卡余额'), findsOneWidget);
        expect(find.text('登录统一认证'), findsOneWidget);

        // 用户在别处完成登录
        UnifiedAuthService.instance.debugSetSession(
          active: true,
          account: 'casuser',
        );
        UnifiedAuthService.instance.notifyListeners();
        await tester.pumpAndSettle();

        // 页面重绘：未登录提示消失，变为可点击查询余额
        expect(find.text('请先登录统一认证，再查询校园卡余额'), findsNothing);
        expect(find.text('登录统一认证'), findsNothing);
        expect(find.text('点击查询余额'), findsOneWidget);
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
        await tester.tap(find.byTooltip('刷新余额'));
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

  testWidgets(
    'serviceUnavailable failure never suggests re-login',
    (tester) async {
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
    },
  );

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
