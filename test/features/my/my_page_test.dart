import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/app/theme.dart';
import 'package:jxu_campus_hub/core/auth/auth_recovery_state_store.dart';
import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';
import 'package:jxu_campus_hub/core/theme/app_colors.dart';
import 'package:jxu_campus_hub/core/theme/page_transition_activity.dart';
import 'package:jxu_campus_hub/features/settings/settings_page.dart';
import 'package:jxu_campus_hub/core/theme/personalization_controller.dart';
import 'package:jxu_campus_hub/features/my/my_page.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';
import 'package:jxu_campus_hub/shared/widgets/glass_dialog_route.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/fake_inappwebview.dart';

/// 推进「我的」页显式登出链直至自然结束（或 [until] 成立）。
///
/// widget 测试跑在 FakeAsync 区，`AuthRecoveryStateStore` 的文件 IO future
/// 不会完成（同 `dorm_electricity_settings_page_test` 的 `_settleCatalog`），
/// `pumpAndSettle` 会被拖到超时。这里用 `runAsync` 真实事件窗口放行磁盘
/// 读写，再用假时时钟推进 best-effort 链的后续步骤。
///
/// [rounds] 是有界上限而非固定等待：[until] 成立即返回。全量套件负载下真实
/// 事件窗口会被挤压，预算留足余量（约 6 秒真实时间）避免断言抢跑。
Future<void> _settleLogout(
  WidgetTester tester, {
  int rounds = 300,
  bool Function()? until,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (until != null && until()) return;
    await tester.runAsync<void>(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 登出链完成判定：两域「显式用户登出」都落账 + 两域会话都清掉。
bool _logoutFullyDone() {
  final store = AuthRecoveryStateStore.instance.debugSnapshot;
  return store.recordFor(AuthRecoveryDomain.cas).revoked &&
      store.recordFor(AuthRecoveryDomain.academic).revoked &&
      !UnifiedAuthService.instance.isLoggedIn &&
      !ZhengfangAuth.instance.isLoggedIn;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // 进门户前的 syncCookiesToWebView 需要 WebView Cookie 平台实现；
    // 测试用内存假实现（与 webview_page_test 等同一模式）。
    InAppWebViewPlatform.instance = FakeInAppWebViewPlatform(
      cookieMode: FakeCookieManagerMode.inMemory,
    );
  });

  setUp(() async {
    PageTransitionActivity.instance.debugReset();
    SharedPreferences.setMockInitialValues({});
    // 流体 Shader 默认开且不依赖壁纸：持续动画会让 pumpAndSettle 永不收敛。
    PersonalizationController.instance.shaderEnabled.value = false;
    UnifiedAuthService.instance.debugReset();
    ZhengfangAuth.instance.debugReset();
    await ScheduleService.instance.debugClearCache();
  });

  tearDown(() {
    PersonalizationController.instance.debugReset();
    UnifiedAuthService.instance.debugReset();
    ZhengfangAuth.instance.debugReset();
  });

  /// 教务行走真实 `ZhengfangAuth.validateSession` → Dio 链路：按仓库惯例用
  /// MockHttpClientAdapter 在 Dio 层伪造测活响应。widget 测试跑在 fake-async
  /// 区，Cookie 目录注入纯字符串 + 内存 Cookie 存储，全程不触文件 IO。
  Future<MockHttpClientAdapter> initAcademicLivenessMock() async {
    FlutterSecureStorage.setMockInitialValues({});
    AuthSessionPersistence.instance
      ..debugReset()
      ..debugDisableFileLock = true;
    NetworkSettings.instance.debugReset();
    DioClient.instance.debugReset();
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        '/my_page_test/$folderName/';
    DioClient.instance.debugUseMemoryCookieStorage = true;
    await DioClient.instance.ensureInitialized();
    final adapter = MockHttpClientAdapter();
    DioClient.instance.dio.httpClientAdapter = adapter;
    return adapter;
  }

  /// 显式登出用例的公共现场：两行已登录（测活全绿）、离线网络/存储替身、
  /// AuthRecoveryStateStore 真实文件 IO 的独立临时目录。
  Future<void> initLogoutStage() async {
    final adapter = await initAcademicLivenessMock();
    adapter.register(
      'GET',
      '/jwglxt/xtgl/index_initMenu.html',
      (options) async => ResponseBody.fromString(
        '<html><a href="/xtgl/index_initMenu.html">教务首页</a></html>',
        200,
      ),
    );
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2025001',
    );
    UnifiedAuthService.instance.debugSessionValidator = (_) async => true;
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: '20250001');

    final tempDir = Directory.systemTemp.createTempSync('my_page_logout_test');
    addTearDown(() {
      AuthRecoveryStateStore.instance.debugReset();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    AuthRecoveryStateStore.instance.debugReset();
    AuthRecoveryStateStore.instance.debugDirectoryProvider = () async =>
        tempDir;
  }

  testWidgets(
    'shows logged out when restored unified auth session is invalid',
    (tester) async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '2025001',
      );
      UnifiedAuthService.instance.debugSessionValidator = (_) async => false;

      await tester.pumpWidget(const MaterialApp(home: MyPage()));
      await tester.pump();
      await tester.pump();

      expect(find.text('统一认证'), findsOneWidget);
      expect(find.text('已登录'), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const Key('my_campus_status'))).data,
        '去登录',
      );
      // 副标题只写学校名，不带任何身份数字。
      expect(find.byKey(const Key('my_identity')), findsNothing);
    },
  );

  testWidgets('keeps logged in state when unified auth session validates', (
    tester,
  ) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2025001',
    );
    UnifiedAuthService.instance.debugSessionValidator = (_) async => true;

    await tester.pumpWidget(const MaterialApp(home: MyPage()));
    await tester.pump();
    await tester.pump();

    expect(find.text('统一认证'), findsOneWidget);
    // 副标题呈现「已登录」，已去除行尾状态灯及右侧独立状态文案。
    expect(find.text('已登录'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('my_campus_status'))).data,
      '已登录',
    );
  });

  testWidgets(
    'liveness result waits for the real settings push transition before applying',
    (tester) async {
      PageTransitionActivity.instance.debugMaxHold = const Duration(minutes: 1);
      final validation = Completer<bool?>();
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '2025001',
      );
      UnifiedAuthService.instance.debugSessionValidator = (_) =>
          validation.future;

      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            name: 'my',
            builder: (context, state) => const MyPage(),
          ),
          GoRoute(
            path: '/settings',
            name: 'settings',
            pageBuilder: (context, state) => MaterialPage<void>(
              key: state.pageKey,
              child: const SettingsPage(),
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp.router(
          theme: AppTheme.darkThemeFor(AppColors.primary)
              .copyWith(platform: TargetPlatform.android),
          routerConfig: router,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const Key('my_campus_status'))).data,
        '已登录',
      );

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pump();
      await tester.pump();
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(PageTransitionActivity.instance.isBusy, isTrue);

      validation.complete(false);
      await tester.pump();
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('my_campus_status'), skipOffstage: false),
            )
            .data,
        '去登录',
        reason: 'a failed liveness probe revokes local identity immediately',
      );

      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('my_campus_status'), skipOffstage: false),
            )
            .data,
        '去登录',
      );
      expect(tester.takeException(), isNull);
      router.dispose();
    },
  );

  testWidgets('pending liveness result is safe after MyPage is disposed', (
    tester,
  ) async {
    final validation = Completer<bool?>();
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2025001',
    );
    UnifiedAuthService.instance.debugSessionValidator = (_) =>
        validation.future;

    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          name: 'my',
          builder: (context, state) => const MyPage(),
        ),
        GoRoute(
          path: '/settings',
          name: 'settings',
          pageBuilder: (context, state) => MaterialPage<void>(
            key: state.pageKey,
            child: const SettingsPage(),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        theme: AppTheme.darkThemeFor(AppColors.primary)
            .copyWith(platform: TargetPlatform.android),
        routerConfig: router,
      ),
    );
    await tester.pump();

    router.go('/settings');
    await tester.pumpAndSettle();
    expect(find.byType(MyPage), findsNothing);
    expect(find.byType(SettingsPage), findsOneWidget);

    validation.complete(true);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    router.dispose();
  });

  group('identity display', () {
    testWidgets('subtitle carries no identity digits', (tester) async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '2025001',
      );
      UnifiedAuthService.instance.debugSessionValidator = (_) async => true;
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20250001',
      );
      await tester.pumpWidget(const MaterialApp(home: MyPage()));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('my_identity')), findsNothing);
      expect(find.textContaining('2025001'), findsNothing);
    });

    testWidgets('no overflow at 360x640 with 1.5x text scale', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '2025001',
      );
      UnifiedAuthService.instance.debugSessionValidator = (_) async => true;
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20250001',
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(360, 640),
              textScaler: TextScaler.linear(1.5),
            ),
            child: MyPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('logged-in CAS row navigates to campus card instead of modal', (
    tester,
  ) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2025001',
    );
    UnifiedAuthService.instance.debugSessionValidator = (_) async => true;

    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          name: 'my',
          builder: (context, state) => const MyPage(),
        ),
        GoRoute(
          path: '/campus-card',
          name: 'campus-card',
          builder: (context, state) => const Scaffold(body: Text('校园卡一卡通页')),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('统一认证'));
    await tester.pumpAndSettle();

    // 已登录点按直接进一卡通页，不再弹「重登模态自动关闭」的闪现。
    expect(find.text('校园卡一卡通页'), findsOneWidget);
    expect(find.byType(MyPage), findsNothing);
  });

  testWidgets('「导出给 AI」入口跳转到独立页面，且登出状态下也可进入', (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          name: 'my',
          builder: (context, state) => const MyPage(),
        ),
        GoRoute(
          path: '/ai-export',
          name: 'ai-export',
          builder: (context, state) => const Scaffold(body: Text('导出给 AI 页')),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    await tester.pump();

    expect(find.text('导出给 AI'), findsOneWidget);
    await tester.tap(find.text('导出给 AI'));
    await tester.pumpAndSettle();

    expect(find.text('导出给 AI 页'), findsOneWidget);
    expect(find.byType(MyPage), findsNothing);
  });

  testWidgets(
    'logged-out CAS row prompts unified auth login instead of navigating',
    (tester) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            name: 'my',
            builder: (context, state) => const MyPage(),
          ),
          GoRoute(
            path: '/campus-card',
            name: 'campus-card',
            builder: (context, state) => const Scaffold(body: Text('校园卡一卡通页')),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('统一认证'));
      await tester.pumpAndSettle();

      // 未登录先弹统一认证登录，不直接进一卡通页。
      expect(find.text('登录一卡通'), findsWidgets);
      expect(find.text('校园卡一卡通页'), findsNothing);
    },
  );

  testWidgets(
    'keeps local session state and silently retries once when liveness '
    'check is inconclusive (network error)',
    (tester) async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '2025001',
      );
      // 校验请求本身失败（返回 null = 网络异常，无法下结论）。
      var validateCount = 0;
      UnifiedAuthService.instance.debugSessionValidator = (_) async {
        validateCount++;
        return null;
      };

      await tester.pumpWidget(const MaterialApp(home: MyPage()));
      await tester.pump();
      await tester.pump();

      // 无法下结论：保持本地会话状态（已登录），不外露「未知」文案。
      expect(validateCount, 1);
      expect(
        tester.widget<Text>(find.byKey(const Key('my_campus_status'))).data,
        '已登录',
      );

      // 5 秒后静默重试一次，再次调用测活。
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(validateCount, 2);
      expect(
        tester.widget<Text>(find.byKey(const Key('my_campus_status'))).data,
        '已登录',
      );

      // 静默重试只发生一次，不会无限循环。
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(validateCount, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown campus status: tapping the row performs the normal logged-in '
    'action instead of only re-validating',
    (tester) async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '2025001',
      );
      UnifiedAuthService.instance.debugSessionValidator = (_) async => null;

      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            name: 'my',
            builder: (context, state) => const MyPage(),
          ),
          GoRoute(
            path: '/campus-card',
            name: 'campus-card',
            builder: (context, state) => const Scaffold(body: Text('校园卡一卡通页')),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pump();
      await tester.pump();

      expect(
        tester.widget<Text>(find.byKey(const Key('my_campus_status'))).data,
        '已登录',
      );

      // 未知状态下点按整行执行正常动作（已登录 → 直达一卡通），不再「只重新校验」。
      await tester.tap(find.text('统一认证'));
      await tester.pumpAndSettle();
      expect(find.text('校园卡一卡通页'), findsOneWidget);

      // 冲掉可能仍挂起的静默重试计时器，确保不留待处理的 Timer。
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('renders on small screen (360x640) without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: MyPage()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('my_identity')), findsNothing);
    expect(find.text('统一认证'), findsOneWidget);
    expect(find.text('教务系统'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders with large text scale (1.5x) without overflow', (
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
          child: MyPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('my_identity')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders in dark mode with unified icon colors', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: const MyPage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('my_identity')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'logged-in academic row opens portal directly without enter button',
    (tester) async {
      final adapter = await initAcademicLivenessMock();
      // 测活返回已有正向认证标记，不能仅凭“不是登录页”认定成功。
      adapter.register(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        (options) async => ResponseBody.fromString(
          '<html><a href="/xtgl/index_initMenu.html">教务首页</a></html>',
          200,
        ),
      );
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20250001',
      );

      var loginPromptCount = 0;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            name: 'my',
            builder: (context, state) => MyPage(
              academicLoginPrompt: (context) async {
                loginPromptCount++;
                return true;
              },
            ),
          ),
          GoRoute(
            path: '/portal',
            name: 'external-webview',
            builder: (context, state) => const Scaffold(body: Text('教务系统门户')),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      // 已验证登录：副标题为「已登录」，且行尾不再有「进入」按钮。
      expect(
        tester.widget<Text>(find.byKey(const Key('my_academic_status'))).data,
        '已登录',
      );
      expect(find.text('进入'), findsNothing);

      await tester.tap(find.text('教务系统'));
      await tester.pumpAndSettle();

      // 整行点按直达教务门户，不经过登录弹窗。
      expect(find.text('教务系统门户', skipOffstage: false), findsOneWidget);
      expect(loginPromptCount, 0);
    },
  );

  testWidgets(
    'logged-out academic row prompts login then stays on my page after success',
    (tester) async {
      final adapter = await initAcademicLivenessMock();
      adapter.register(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        (options) async => ResponseBody.fromString(
          '<html><a href="/xtgl/index_initMenu.html">教务首页</a></html>',
          200,
        ),
      );

      var loginPromptCount = 0;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            name: 'my',
            builder: (context, state) => MyPage(
              // 替代真实教务登录弹窗（LoginWidget 无法离线驱动到登录成功）：
              // 弹出登录界面，「模拟登录成功」落好会话后以 true 关闭。
              academicLoginPrompt: (context) async {
                loginPromptCount++;
                final result = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('登录教务系统'),
                    actions: [
                      TextButton(
                        onPressed: () {
                          ZhengfangAuth.instance.debugSetSession(
                            active: true,
                            studentId: '20250001',
                          );
                          Navigator.of(dialogContext).pop(true);
                        },
                        child: const Text('模拟登录成功'),
                      ),
                    ],
                  ),
                );
                return result ?? false;
              },
            ),
          ),
          GoRoute(
            path: '/portal',
            name: 'external-webview',
            builder: (context, state) => const Scaffold(body: Text('教务系统门户')),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const Key('my_academic_status'))).data,
        '去登录',
      );

      await tester.tap(find.text('教务系统'));
      await tester.pumpAndSettle();

      // 未登录点整行先弹登录，不直接进门户。
      expect(find.text('登录教务系统'), findsOneWidget);
      expect(find.text('教务系统门户', skipOffstage: false), findsNothing);
      expect(loginPromptCount, 1);

      await tester.tap(find.text('模拟登录成功'));
      await tester.pumpAndSettle();

      // 登录成功后留在「我的」页（真机手测反馈）：不再自动继续进教务门户。
      expect(find.text('登录教务系统'), findsNothing);
      expect(find.text('教务系统门户', skipOffstage: false), findsNothing);
      expect(find.text('统一认证'), findsOneWidget);
      expect(loginPromptCount, 1);
      // 两行状态已刷新：教务行转为已登录。
      expect(
        tester.widget<Text>(find.byKey(const Key('my_academic_status'))).data,
        '已登录',
      );

      // 已登录态导航不变：再点整行仍直达教务门户。
      await tester.tap(find.text('教务系统'));
      await tester.pumpAndSettle();
      expect(find.text('教务系统门户', skipOffstage: false), findsOneWidget);
      expect(loginPromptCount, 1);
    },
  );

  testWidgets(
    'unknown academic status keeps local state, silently retries once, and '
    'tap performs the normal logged-in action instead of only re-validating',
    (tester) async {
      final adapter = await initAcademicLivenessMock();
      var probeCount = 0;
      adapter.register('GET', '/jwglxt/xtgl/index_initMenu.html', (
        options,
      ) async {
        probeCount++;
        throw Exception('模拟网络异常');
      });
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20250001',
      );

      var loginPromptCount = 0;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            name: 'my',
            builder: (context, state) => MyPage(
              academicLoginPrompt: (context) async {
                loginPromptCount++;
                return true;
              },
            ),
          ),
          GoRoute(
            path: '/portal',
            name: 'external-webview',
            builder: (context, state) => const Scaffold(body: Text('教务系统门户')),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      // 测活网络异常（无法下结论）：保持本地会话状态（已登录），不外露「未知」。
      expect(
        tester.widget<Text>(find.byKey(const Key('my_academic_status'))).data,
        '已登录',
      );
      expect(probeCount, 1);

      // 未知状态下点按整行执行正常动作（已登录 → 直达门户），不再是「只重新校验」。
      await tester.tap(find.text('教务系统'));
      await tester.pumpAndSettle();

      expect(loginPromptCount, 0);
      expect(find.text('登录教务系统'), findsNothing);
      expect(find.text('教务系统门户', skipOffstage: false), findsOneWidget);

      // 冲掉初始测活安排的静默重试计时器：再测活一次，之后不再循环。
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(probeCount, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('logout action is hidden when both rows are logged out', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: MyPage()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('my_identity')), findsNothing);
    expect(find.byKey(const Key('my_logout')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'logout action is visible when either unified auth or academic is logged in',
    (tester) async {
      final adapter = await initAcademicLivenessMock();
      adapter.register(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        (options) async =>
            ResponseBody.fromString('<html><body>教务首页</body></html>', 200),
      );

      // 仅教务已登录 → 显示登出入口。
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20250001',
      );
      await tester.pumpWidget(const MaterialApp(home: MyPage()));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('my_logout')), findsOneWidget);

      // 仅统一认证已登录 → 同样显示。
      ZhengfangAuth.instance.debugReset();
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '2025001',
      );
      UnifiedAuthService.instance.debugSessionValidator = (_) async => true;
      await tester.pumpWidget(const MaterialApp(home: MyPage()));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('my_logout')), findsOneWidget);
    },
  );

  testWidgets(
    'logout action renders without overflow on small screen at 1.5x text scale',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '2025001',
      );
      UnifiedAuthService.instance.debugSessionValidator = (_) async => true;

      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: MyPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('my_identity')), findsNothing);
      expect(find.byKey(const Key('my_logout')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('logout confirmation cancel keeps both sessions logged in', (
    tester,
  ) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2025001',
    );
    UnifiedAuthService.instance.debugSessionValidator = (_) async => true;

    await tester.pumpWidget(const MaterialApp(home: MyPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('my_logout')));
    await tester.pumpAndSettle();

    // 确认框：平实中文，确认=退出登录，取消=返回。
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.widgetWithText(TextButton, '退出登录'), findsOneWidget);
    expect(find.text('返回'), findsOneWidget);

    // Issue #46：短确认框必须 shrink-wrap，玻璃表面不能撑到接近整屏。
    final surface = tester.getRect(find.byType(GlassOverlaySurface));
    final viewportHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(tester.takeException(), isNull);
    expect(
      surface.height,
      lessThan(viewportHeight * 0.5),
      reason: '短登出确认框不应接近整屏（表面 ${surface.height}, 视口 $viewportHeight）',
    );

    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();

    // 取消 = 返回：不登出，会话保持。
    expect(find.text('返回'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing); // 对话框已关闭
    expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
    expect(
      tester.widget<Text>(find.byKey(const Key('my_campus_status'))).data,
      '已登录',
    );
    expect(find.byKey(const Key('my_logout')), findsOneWidget);
  });

  testWidgets(
    'logout confirmation records explicit user logout for both domains and '
    'stays on my page',
    (tester) async {
      final adapter = await initAcademicLivenessMock();
      adapter.register(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        (options) async =>
            ResponseBody.fromString('<html><body>教务首页</body></html>', 200),
      );
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '2025001',
      );
      UnifiedAuthService.instance.debugSessionValidator = (_) async => true;
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20250001',
      );

      // 显式登出会写自动恢复状态（AuthRecoveryStateStore，真实文件 IO）：
      // 注入独立临时目录；文件 IO 的放行由 _settleLogout 的 runAsync 窗口负责。
      final tempDir = Directory.systemTemp.createTempSync(
        'my_page_logout_test',
      );
      addTearDown(() {
        AuthRecoveryStateStore.instance.debugReset();
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });
      AuthRecoveryStateStore.instance.debugReset();
      AuthRecoveryStateStore.instance.debugDirectoryProvider = () async =>
          tempDir;

      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            name: 'my',
            builder: (context, state) => const MyPage(),
          ),
          GoRoute(
            path: '/campus-card',
            name: 'campus-card',
            builder: (context, state) => const Scaffold(body: Text('校园卡一卡通页')),
          ),
          GoRoute(
            path: '/portal',
            name: 'external-webview',
            builder: (context, state) => const Scaffold(body: Text('教务系统门户')),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      // 初始：两行已登录，登出入口可见。
      expect(find.byKey(const Key('my_logout')), findsOneWidget);

      await tester.tap(find.byKey(const Key('my_logout')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '退出登录'));
      await tester.pump();
      await _settleLogout(
        tester,
        until: () => find.byKey(const Key('my_logout')).evaluate().isEmpty,
      );
      await tester.pumpAndSettle();

      // 停留在「我的」页：不跳一卡通页、不进教务门户。
      expect(find.text('统一认证'), findsOneWidget);
      expect(find.text('教务系统'), findsOneWidget);
      expect(find.text('校园卡一卡通页', skipOffstage: false), findsNothing);
      expect(find.text('教务系统门户', skipOffstage: false), findsNothing);
      expect(find.text('退出登录'), findsNothing); // 确认框已关闭

      // 两行状态刷新为未登录，登出入口隐藏。
      expect(
        tester.widget<Text>(find.byKey(const Key('my_campus_status'))).data,
        '去登录',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('my_academic_status'))).data,
        '去登录',
      );
      expect(find.byKey(const Key('my_logout')), findsNothing);

      // 两个会话都已撤销。
      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
      expect(ZhengfangAuth.instance.isLoggedIn, isFalse);

      // 两域都落了「显式用户登出」语义：revoked、关闭 opt-in、epoch 推进。
      final casRecord = AuthRecoveryStateStore.instance.debugSnapshot.recordFor(
        AuthRecoveryDomain.cas,
      );
      expect(casRecord.revoked, isTrue);
      expect(casRecord.optIn, isFalse);
      expect(casRecord.epoch, 1);
      final academicRecord = AuthRecoveryStateStore.instance.debugSnapshot
          .recordFor(AuthRecoveryDomain.academic);
      expect(academicRecord.revoked, isTrue);
      expect(academicRecord.optIn, isFalse);
      expect(academicRecord.epoch, 1);
    },
  );

  testWidgets(
    'dispose mid-logout still completes both domain revocations and session '
    'cleanups',
    (tester) async {
      await initLogoutStage();

      var academicRecordHeld = false;
      final release = Completer<void>();
      final stepCalls = <LogoutStep, int>{};
      Future<void> gate(LogoutStep step) async {
        stepCalls[step] = (stepCalls[step] ?? 0) + 1;
        if (step == LogoutStep.academicRecord) {
          academicRecordHeld = true;
          await release.future;
        }
      }

      await tester.pumpWidget(MaterialApp(home: MyPage(logoutStepGate: gate)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('my_logout')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '退出登录'));
      await _settleLogout(tester, until: () => academicRecordHeld);

      // 登出进行到一半（统一认证域已记账、教务域记账挂起）时页面被销毁。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      release.complete();
      await _settleLogout(tester, until: _logoutFullyDone);

      // 四步效果与 mounted 无关：两域「显式用户登出」都落账、两会话都撤销，
      // 绝不允许只撤销一域的半套登出。
      final store = AuthRecoveryStateStore.instance.debugSnapshot;
      expect(store.recordFor(AuthRecoveryDomain.cas).revoked, isTrue);
      expect(store.recordFor(AuthRecoveryDomain.cas).epoch, 1);
      expect(store.recordFor(AuthRecoveryDomain.academic).revoked, isTrue);
      expect(store.recordFor(AuthRecoveryDomain.academic).epoch, 1);
      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
      expect(ZhengfangAuth.instance.isLoggedIn, isFalse);
      expect(stepCalls[LogoutStep.casRecord], 1);
      expect(stepCalls[LogoutStep.academicRecord], 1);
      expect(stepCalls[LogoutStep.casSession], 1);
      expect(stepCalls[LogoutStep.academicSession], 1);
      // dispose 之后不得有 setState / context 崩溃。
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'duplicate logout interactions run each effect exactly once and row login '
    'and navigation stay inert while logout is in flight',
    (tester) async {
      await initLogoutStage();

      var academicRecordHeld = false;
      final release = Completer<void>();
      final stepCalls = <LogoutStep, int>{};
      var academicPromptCount = 0;
      Future<void> gate(LogoutStep step) async {
        stepCalls[step] = (stepCalls[step] ?? 0) + 1;
        if (step == LogoutStep.academicRecord) {
          academicRecordHeld = true;
          await release.future;
        }
      }

      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            name: 'my',
            builder: (context, state) => MyPage(
              logoutStepGate: gate,
              academicLoginPrompt: (context) async {
                academicPromptCount++;
                return true;
              },
            ),
          ),
          GoRoute(
            path: '/campus-card',
            name: 'campus-card',
            builder: (context, state) => const Scaffold(body: Text('校园卡一卡通页')),
          ),
          GoRoute(
            path: '/portal',
            name: 'external-webview',
            builder: (context, state) => const Scaffold(body: Text('教务系统门户')),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      // 重复点按（重建帧之前连点两次）：只弹一个确认框。
      await tester.tap(find.byKey(const Key('my_logout')));
      await tester.tap(find.byKey(const Key('my_logout')));
      await tester.pumpAndSettle();
      expect(find.text('返回'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.widgetWithText(TextButton, '退出登录'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '退出登录'));
      await _settleLogout(tester, until: () => academicRecordHeld);

      // 登出进行中：再点登出按钮不弹二次确认、不跑第二遍登出。
      await tester.tap(find.byKey(const Key('my_logout')));
      await tester.pumpAndSettle();
      expect(find.text('返回'), findsNothing);

      // 登出进行中：两行点按不弹登录、不导航。
      await tester.tap(find.text('统一认证'));
      await tester.pumpAndSettle();
      expect(find.text('登录一卡通'), findsNothing);
      expect(find.text('校园卡一卡通页', skipOffstage: false), findsNothing);

      await tester.tap(find.text('教务系统'));
      await tester.pumpAndSettle();
      expect(academicPromptCount, 0);
      expect(find.text('教务系统门户', skipOffstage: false), findsNothing);

      release.complete();
      await _settleLogout(tester, until: _logoutFullyDone);

      // 每步效果恰好执行一次：重复交互没有造成第二遍登出（epoch 不叠到 2）。
      expect(stepCalls[LogoutStep.casRecord], 1);
      expect(stepCalls[LogoutStep.academicRecord], 1);
      expect(stepCalls[LogoutStep.casSession], 1);
      expect(stepCalls[LogoutStep.academicSession], 1);
      final store = AuthRecoveryStateStore.instance.debugSnapshot;
      expect(store.recordFor(AuthRecoveryDomain.cas).epoch, 1);
      expect(store.recordFor(AuthRecoveryDomain.academic).epoch, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a failed logout step is reported honestly with retry while later steps '
    'still run',
    (tester) async {
      await initLogoutStage();

      var failAcademicRecord = true;
      final stepCalls = <LogoutStep, int>{};
      Future<void> gate(LogoutStep step) async {
        stepCalls[step] = (stepCalls[step] ?? 0) + 1;
        if (step == LogoutStep.academicRecord && failAcademicRecord) {
          throw Exception('模拟登出步骤失败');
        }
      }

      await tester.pumpWidget(MaterialApp(home: MyPage(logoutStepGate: gate)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('my_logout')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '退出登录'));
      await _settleLogout(
        tester,
        until: () => find.textContaining('退出登录未完全完成').evaluate().isNotEmpty,
      );
      // SnackBar 入场动画未结束时其动作按钮仍在屏外，直接 tap 会 miss；
      // 先推进动画到落位再点「重试」。
      await tester.pump(const Duration(milliseconds: 400));

      // 失败绝不静默当作成功：如实提示「未完全完成」+ 可重试动作。
      expect(find.textContaining('退出登录未完全完成'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      // 后续步骤仍 best-effort 走完：教务域记账失败，但两域会话照常撤销。
      final store = AuthRecoveryStateStore.instance.debugSnapshot;
      expect(store.recordFor(AuthRecoveryDomain.cas).revoked, isTrue);
      expect(store.recordFor(AuthRecoveryDomain.academic).revoked, isFalse);
      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
      expect(ZhengfangAuth.instance.isLoggedIn, isFalse);

      // 重试把失败的那步补上。
      failAcademicRecord = false;
      await tester.tap(find.text('重试'));
      await _settleLogout(
        tester,
        until: () => AuthRecoveryStateStore.instance.debugSnapshot
            .recordFor(AuthRecoveryDomain.academic)
            .revoked,
      );
      await tester.pumpAndSettle();

      // 重试成功后不再留着「未完全完成」的旧提示。
      expect(find.textContaining('退出登录未完全完成'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a newer login landing mid-logout is preserved instead of revoked',
    (tester) async {
      await initLogoutStage();

      var academicRecordHeld = false;
      final release = Completer<void>();
      final stepCalls = <LogoutStep, int>{};
      Future<void> gate(LogoutStep step) async {
        stepCalls[step] = (stepCalls[step] ?? 0) + 1;
        if (step == LogoutStep.academicRecord) {
          academicRecordHeld = true;
          await release.future;
        }
      }

      await tester.pumpWidget(MaterialApp(home: MyPage(logoutStepGate: gate)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('my_logout')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '退出登录'));
      await _settleLogout(tester, until: () => academicRecordHeld);

      // 登出等待期间落成一次「同账号新登录」：内存身份与 revision 不变，
      // 只有持久 epoch 前进——这正是只看 revision 会误杀的情形。
      final epochBefore = await AuthSessionPersistence.instance.readEpoch(
        CredentialSessionDomain.unified,
      );
      final commitResult = await AuthSessionPersistence.instance.commit(
        CredentialSessionDomain.unified,
        account: '2025001',
        expectedEpoch: epochBefore,
      );
      expect(commitResult, isNotNull);

      release.complete();
      // 等待条件覆盖下方全部断言：提示已出现 + 教务域撤销真正走完。
      await _settleLogout(
        tester,
        until: () =>
            find.textContaining('已保留新会话').evaluate().isNotEmpty &&
            !ZhengfangAuth.instance.isLoggedIn &&
            stepCalls[LogoutStep.academicSession] == 1,
      );

      // 新登录被保留：统一认证会话没被误撤销；教务域照常撤销。
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.isLoggedIn, isFalse);
      expect(stepCalls[LogoutStep.casSession] ?? 0, 0); // 闸门前即判定变化 → 未进闸门
      expect(stepCalls[LogoutStep.academicSession], 1);
      expect(find.textContaining('已保留新会话'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a newer login landing while the revoke gate is held is preserved '
    '(identity is re-checked after the gate await)',
    (tester) async {
      await initLogoutStage();

      var casSessionHeld = false;
      final release = Completer<void>();
      final stepCalls = <LogoutStep, int>{};
      Future<void> gate(LogoutStep step) async {
        stepCalls[step] = (stepCalls[step] ?? 0) + 1;
        if (step == LogoutStep.casSession) {
          casSessionHeld = true;
          await release.future;
        }
      }

      await tester.pumpWidget(MaterialApp(home: MyPage(logoutStepGate: gate)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('my_logout')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '退出登录'));
      await _settleLogout(tester, until: () => casSessionHeld);

      // 统一认证撤销已经过「闸门之前」的复核、正卡在闸门里；此刻落成一次
      // 同账号新登录（只有持久 epoch 前进，内存 revision/身份不变）。若只在
      // 闸门之前复核，放行后会无条件撤销这个新会话——必须被保留。
      final epochBefore = await AuthSessionPersistence.instance.readEpoch(
        CredentialSessionDomain.unified,
      );
      final commitResult = await AuthSessionPersistence.instance.commit(
        CredentialSessionDomain.unified,
        account: '2025001',
        expectedEpoch: epochBefore,
      );
      expect(commitResult, isNotNull);

      release.complete();
      // 等待条件覆盖下方全部断言：提示已出现 + 教务域撤销真正走完。
      await _settleLogout(
        tester,
        until: () =>
            find.textContaining('已保留新会话').evaluate().isNotEmpty &&
            !ZhengfangAuth.instance.isLoggedIn &&
            stepCalls[LogoutStep.academicSession] == 1,
      );

      // 闸门之后的复核拦住了旧退出：新登录被保留，教务域照常撤销。
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.isLoggedIn, isFalse);
      expect(stepCalls[LogoutStep.casSession], 1); // 进了闸门但复核后跳过效果
      expect(stepCalls[LogoutStep.academicSession], 1);
      expect(find.textContaining('已保留新会话'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dispose while the revoke gate is held still completes both domain '
    'revocations after the gate is released',
    (tester) async {
      await initLogoutStage();

      var casSessionHeld = false;
      final release = Completer<void>();
      final stepCalls = <LogoutStep, int>{};
      Future<void> gate(LogoutStep step) async {
        stepCalls[step] = (stepCalls[step] ?? 0) + 1;
        if (step == LogoutStep.casSession) {
          casSessionHeld = true;
          await release.future;
        }
      }

      await tester.pumpWidget(MaterialApp(home: MyPage(logoutStepGate: gate)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('my_logout')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '退出登录'));
      await _settleLogout(tester, until: () => casSessionHeld);

      // 已确认的持久撤销进行到会话撤销一半（正卡在统一认证撤销闸门）时销毁页面。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      release.complete();
      await _settleLogout(tester, until: _logoutFullyDone);

      // 撤销效果与 mounted 无关：两域都撤销，绝不允许停在半套登出。
      final store = AuthRecoveryStateStore.instance.debugSnapshot;
      expect(store.recordFor(AuthRecoveryDomain.cas).revoked, isTrue);
      expect(store.recordFor(AuthRecoveryDomain.academic).revoked, isTrue);
      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
      expect(ZhengfangAuth.instance.isLoggedIn, isFalse);
      expect(stepCalls[LogoutStep.casSession], 1);
      expect(stepCalls[LogoutStep.academicSession], 1);
      expect(tester.takeException(), isNull);
    },
  );
}
