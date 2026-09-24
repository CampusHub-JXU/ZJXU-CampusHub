import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';
import 'package:jxu_campus_hub/features/my/my_page.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';

import '../../helpers/mock_http_client_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // 进门户前的 syncCookiesToWebView 需要 WebView Cookie 平台实现；
    // 测试用内存假实现（与 webview_page_test 等同一模式）。
    InAppWebViewPlatform.instance = _FakeInAppWebViewPlatform();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    UnifiedAuthService.instance.debugReset();
    ZhengfangAuth.instance.debugReset();
    await ScheduleService.instance.debugClearCache();
  });

  tearDown(() {
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

      expect(find.text('统一认证（含一卡通）'), findsOneWidget);
      expect(find.text('已登录'), findsNothing);
      // 副标题呈现「未登录」，已去除行尾状态灯及右侧独立状态文案。
      expect(find.text('未登录'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('my_campus_status'))).data,
        '未登录',
      );
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

    expect(find.text('统一认证（含一卡通）'), findsOneWidget);
    // 副标题呈现「已登录」，已去除行尾状态灯及右侧独立状态文案。
    expect(find.text('已登录'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('my_campus_status'))).data,
      '已登录',
    );
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

    await tester.tap(find.text('统一认证（含一卡通）'));
    await tester.pumpAndSettle();

    // 已登录点按直接进一卡通页，不再弹「重登模态自动关闭」的闪现。
    expect(find.text('校园卡一卡通页'), findsOneWidget);
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

      await tester.tap(find.text('统一认证（含一卡通）'));
      await tester.pumpAndSettle();

      // 未登录先弹统一认证登录，不直接进一卡通页。
      expect(find.text('登录一卡通'), findsWidgets);
      expect(find.text('校园卡一卡通页'), findsNothing);
    },
  );

  testWidgets(
    'shows unknown state when liveness check fails with network error',
    (tester) async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '2025001',
      );
      // 校验请求本身失败（返回 null = 网络异常）：不能沿用「已登录」。
      UnifiedAuthService.instance.debugSessionValidator = (_) async => null;

      await tester.pumpWidget(const MaterialApp(home: MyPage()));
      await tester.pump();
      await tester.pump();

      expect(find.text('已登录'), findsNothing);
      expect(find.textContaining('登录状态未知'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('my_campus_status'))).data,
        '登录状态未知 · 点按重新校验',
      );
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

    expect(find.text('我的'), findsOneWidget);
    expect(find.text('统一认证（含一卡通）'), findsOneWidget);
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

    expect(find.text('我的'), findsOneWidget);
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

    expect(find.text('我的'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'logged-in academic row opens portal directly without enter button',
    (tester) async {
      final adapter = await initAcademicLivenessMock();
      // 测活返回教务首页 HTML（非登录页）：会话有效。
      adapter.register(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        (options) async =>
            ResponseBody.fromString('<html><body>教务首页</body></html>', 200),
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
        '已登录 · 课表未缓存',
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
    'logged-out academic row prompts login then auto-continues into portal once',
    (tester) async {
      final adapter = await initAcademicLivenessMock();
      adapter.register(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        (options) async =>
            ResponseBody.fromString('<html><body>教务首页</body></html>', 200),
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
            builder: (context, state) => Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('教务系统门户'),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('返回'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const Key('my_academic_status'))).data,
        '未登录 · 课表未缓存',
      );

      await tester.tap(find.text('教务系统'));
      await tester.pumpAndSettle();

      // 未登录点整行先弹登录，不直接进门户。
      expect(find.text('登录教务系统'), findsOneWidget);
      expect(find.text('教务系统门户', skipOffstage: false), findsNothing);
      expect(loginPromptCount, 1);

      await tester.tap(find.text('模拟登录成功'));
      await tester.pumpAndSettle();

      // 登录成功后自动继续一次进入门户（栈内仅一个门户页）。
      expect(find.text('登录教务系统'), findsNothing);
      expect(find.text('教务系统门户', skipOffstage: false), findsOneWidget);
      expect(loginPromptCount, 1);

      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();

      // 返回后不循环：不再弹登录、不重复压栈进门户。
      expect(find.text('登录教务系统'), findsNothing);
      expect(find.text('教务系统门户', skipOffstage: false), findsNothing);
      expect(loginPromptCount, 1);
    },
  );

  testWidgets(
    'unknown academic status row only re-validates without prompting or opening',
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

      // 测活网络异常：登录状态未知。
      expect(
        tester.widget<Text>(find.byKey(const Key('my_academic_status'))).data,
        '登录状态未知 · 点按重新校验',
      );
      expect(probeCount, 1);

      await tester.tap(find.text('教务系统'));
      await tester.pumpAndSettle();

      // 点按 = 重新校验：发出第二次测活，但不弹登录、不进门户。
      expect(probeCount, 2);
      expect(loginPromptCount, 0);
      expect(find.text('登录教务系统'), findsNothing);
      expect(find.text('教务系统门户', skipOffstage: false), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const Key('my_academic_status'))).data,
        '登录状态未知 · 点按重新校验',
      );
    },
  );
}

class _FakeInAppWebViewPlatform extends InAppWebViewPlatform {
  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) {
    return _FakePlatformCookieManager(params);
  }
}

class _FakePlatformCookieManager extends PlatformCookieManager {
  _FakePlatformCookieManager(super.params) : super.implementation();

  final Map<String, Cookie> _cookies = {};

  String _key(WebUri url, String name, String? domain, String path) {
    return '${url.host}|${domain ?? ''}|$path|$name';
  }

  @override
  Future<bool> setCookie({
    required WebUri url,
    required String name,
    required String value,
    String path = '/',
    String? domain,
    int? expiresDate,
    int? maxAge,
    bool? isSecure,
    bool? isHttpOnly,
    HTTPCookieSameSitePolicy? sameSite,
    @Deprecated('Use webViewController instead')
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    _cookies[_key(url, name, domain, path)] = Cookie(
      name: name,
      value: value,
      domain: domain,
      path: path,
    );
    return true;
  }

  @override
  Future<List<Cookie>> getCookies({
    required WebUri url,
    @Deprecated('Use webViewController instead')
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    return _cookies.values.toList(growable: false);
  }

  @override
  Future<bool> deleteCookie({
    required WebUri url,
    required String name,
    String path = '/',
    String? domain,
    @Deprecated('Use webViewController instead')
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    _cookies.remove(_key(url, name, domain, path));
    return true;
  }
}
