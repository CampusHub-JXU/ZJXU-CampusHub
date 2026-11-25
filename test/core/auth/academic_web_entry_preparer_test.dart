import 'dart:async';
import 'dart:io' as io;

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as iaw;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/academic_web_entry_preparer.dart';
import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/network/route_failure.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';

import '../../helpers/mock_http_client_adapter.dart';

/// 最小 WebView 平台替身：只接管 CookieManager，让严格同步路径可被单测。
class _FakeInAppWebViewPlatform extends iaw.InAppWebViewPlatform {
  _FakeInAppWebViewPlatform()
    : cookieManager = _FakePlatformCookieManager(
        const iaw.PlatformCookieManagerCreationParams(),
      );

  final _FakePlatformCookieManager cookieManager;

  @override
  iaw.PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    iaw.PlatformInAppWebViewWidgetCreationParams params,
  ) {
    throw UnimplementedError('本测试不使用 WebView 控件');
  }

  @override
  iaw.PlatformCookieManager createPlatformCookieManager(
    iaw.PlatformCookieManagerCreationParams params,
  ) {
    return cookieManager;
  }
}

class _FakePlatformCookieManager extends iaw.PlatformCookieManager {
  _FakePlatformCookieManager(super.params) : super.implementation();

  final Map<String, Map<String, String>> _byHost = {};
  bool throwOnSet = false;
  bool throwOnDelete = false;
  bool throwOnGet = false;
  bool corruptOnGet = false;
  int setCalls = 0;

  void reset() {
    _byHost.clear();
    throwOnSet = false;
    throwOnDelete = false;
    throwOnGet = false;
    corruptOnGet = false;
    setCalls = 0;
  }

  @override
  Future<bool> setCookie({
    required iaw.WebUri url,
    required String name,
    required String value,
    String path = '/',
    String? domain,
    int? expiresDate,
    int? maxAge,
    bool? isSecure,
    bool? isHttpOnly,
    iaw.HTTPCookieSameSitePolicy? sameSite,
    @Deprecated('Use webViewController instead')
    iaw.PlatformInAppWebViewController? iosBelow11WebViewController,
    iaw.PlatformInAppWebViewController? webViewController,
  }) async {
    setCalls++;
    if (throwOnSet) throw StateError('setCookie failed');
    (_byHost[url.host] ??= <String, String>{})[name] = value;
    return true;
  }

  @override
  Future<List<iaw.Cookie>> getCookies({
    required iaw.WebUri url,
    @Deprecated('Use webViewController instead')
    iaw.PlatformInAppWebViewController? iosBelow11WebViewController,
    iaw.PlatformInAppWebViewController? webViewController,
  }) async {
    if (throwOnGet) throw StateError('getCookies failed');
    final map = _byHost[url.host] ?? const <String, String>{};
    return map.entries
        .map(
          (entry) => iaw.Cookie(
            name: entry.key,
            value: corruptOnGet ? 'corrupted' : entry.value,
            domain: url.host,
            path: '/',
          ),
        )
        .toList();
  }

  @override
  Future<bool> deleteCookie({
    required iaw.WebUri url,
    required String name,
    String path = '/',
    String? domain,
    @Deprecated('Use webViewController instead')
    iaw.PlatformInAppWebViewController? iosBelow11WebViewController,
    iaw.PlatformInAppWebViewController? webViewController,
  }) async {
    if (throwOnDelete) throw StateError('deleteCookie failed');
    _byHost[url.host]?.remove(name);
    return true;
  }
}

Future<void> _seedJar(
  String origin,
  String name,
  String value, {
  bool webVpn = false,
}) async {
  await DioClient.instance.ensureInitialized();
  final uri = Uri.parse(origin);
  final jar = webVpn
      ? DioClient.instance.unifiedAuthCookieJar
      : DioClient.instance.zhengfangCookieJar;
  await jar.saveFromResponse(uri, [
    io.Cookie(name, value)
      ..domain = uri.host
      ..path = '/',
  ]);
}

const _trustedXs =
    'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html?jsdm=xs';

/// 严格命中 [looksLikeZhengfangLoginHtml] 的正方登录页 fixture。
const _zhengfangLoginHtml =
    '<html><form action="/jwglxt/xtgl/login_slogin.html">'
    '<input id="yhm" name="yhm" />'
    '<input id="mm" name="mm" />'
    '</form></html>';

/// 默认成功适配器：所有网络 / Cookie 副作用都被窄接口替身接管。
AcademicWebEntryPreparer _preparer({
  AcademicModeResolver? modeResolver,
  AcademicGatewaySessionEnsurer? gatewaySessionEnsurer,
  AcademicSessionProber? academicSessionProber,
  AcademicCookieSyncer? cookieSyncer,
  AcademicHeaderBuilder? headerBuilder,
}) {
  return AcademicWebEntryPreparer(
    modeResolver: modeResolver ?? (_) async => ZhengfangMode.direct,
    gatewaySessionEnsurer: gatewaySessionEnsurer ?? (_, _) async {},
    academicSessionProber:
        academicSessionProber ??
        (_, _, _) async => AcademicEntrySessionStatus.authenticated,
    cookieSyncer: cookieSyncer ?? (_, _) async {},
    headerBuilder: headerBuilder ?? (_, _) async => const {'Referer': 'test'},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeInAppWebViewPlatform webViewPlatform;

  setUpAll(() {
    webViewPlatform = _FakeInAppWebViewPlatform();
    iaw.InAppWebViewPlatform.instance = webViewPlatform;
  });

  setUp(() async {
    webViewPlatform.cookieManager.reset();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NetworkSettings.instance.debugReset();
    UnifiedAuthService.instance.debugReset();
    ZhengfangAuth.instance.debugReset();
    ConnectModeResolver.instance.debugReset();
    DioClient.instance.debugReset();
    DioClient.instance.debugUseMemoryCookieStorage = true;
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async {
      final dir = await io.Directory.systemTemp.createTemp(
        'academic_entry_test_',
      );
      return '${dir.path}/$folderName/';
    };
  });

  tearDown(() {
    UnifiedAuthService.instance.debugReset();
    ZhengfangAuth.instance.debugReset();
    ConnectModeResolver.instance.debugReset();
    DioClient.instance.debugReset();
    NetworkSettings.instance.debugReset();
  });

  group('受信入口校验', () {
    test('只允许受信 origin / path / jsdm 白名单', () {
      expect(AcademicWebEntryPreparer.isTrustedEntryUrl(_trustedXs), isTrue);
      expect(
        AcademicWebEntryPreparer.isTrustedEntryUrl(
          'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html?jsdm=query',
        ),
        isTrue,
      );

      // 异 origin / 协议 / path。
      expect(
        AcademicWebEntryPreparer.isTrustedEntryUrl(
          'https://evil.example.com/jwglxt/xtgl/index_initMenu.html?jsdm=xs',
        ),
        isFalse,
      );
      expect(
        AcademicWebEntryPreparer.isTrustedEntryUrl(
          'http://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html?jsdm=xs',
        ),
        isFalse,
      );
      expect(
        AcademicWebEntryPreparer.isTrustedEntryUrl(
          'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/login_slogin.html?jsdm=xs',
        ),
        isFalse,
      );
      expect(
        AcademicWebEntryPreparer.isTrustedEntryUrl(
          'https://jwzx.zjxu.edu.cn:8443/jwglxt/xtgl/index_initMenu.html?jsdm=xs',
        ),
        isFalse,
      );

      // 越权 query / ticket / 缺 jsdm。
      expect(
        AcademicWebEntryPreparer.isTrustedEntryUrl(
          'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html'
          '?jsdm=xs&ticket=ST-1',
        ),
        isFalse,
      );
      expect(
        AcademicWebEntryPreparer.isTrustedEntryUrl(
          'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html?jsdm=admin',
        ),
        isFalse,
      );
      expect(
        AcademicWebEntryPreparer.isTrustedEntryUrl(
          'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html',
        ),
        isFalse,
      );
      expect(
        AcademicWebEntryPreparer.isTrustedEntryUrl(
          'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html?jsdm=xs#x',
        ),
        isFalse,
      );
    });

    test('非法 jsdm 直接拒绝，不发起任何网络判定', () async {
      var resolverCalled = false;
      final result = await _preparer(
        modeResolver: (_) async {
          resolverCalled = true;
          return ZhengfangMode.direct;
        },
      ).prepare(jsdm: 'admin');

      expect(result, isA<AcademicWebEntryDenied>());
      expect(resolverCalled, isFalse);
    });

    test('trustedEntryUrl 只为白名单值返回受信 URL', () {
      expect(AcademicWebEntryPreparer.trustedEntryUrl(jsdm: 'xs'), _trustedXs);
      expect(
        AcademicWebEntryPreparer.trustedEntryUrl(jsdm: 'QUERY'),
        'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html?jsdm=query',
      );
      expect(AcademicWebEntryPreparer.trustedEntryUrl(jsdm: 'admin'), isNull);
    });
  });

  group('目标 origin 选路', () {
    test('默认用 target-origin 解析器判定直连并返回就绪', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'U');

      String? probedTarget;
      final resolver = ConnectModeResolver.instance;
      resolver.targetDirectReachabilityChecker = (url) async {
        probedTarget = url;
        return true;
      };
      resolver.webVpnReachabilityChecker = () async => true;

      final modes = <ZhengfangMode>[];
      final urls = <String>[];
      // 不注入 modeResolver：走生产默认的 ConnectModeResolver（target-origin）。
      final result = await AcademicWebEntryPreparer(
        gatewaySessionEnsurer: (_, _) async {
          fail('direct 模式不应建立 WebVPN 网关会话');
        },
        academicSessionProber: (_, _, _) async =>
            AcademicEntrySessionStatus.authenticated,
        cookieSyncer: (mode, _) async => modes.add(mode),
        headerBuilder: (mode, url) async {
          urls.add(url);
          return const {'Referer': 'direct'};
        },
      ).prepare();

      expect(probedTarget, _trustedXs);
      final ready = result as AcademicWebEntryReady;
      expect(ready.selectedMode, ZhengfangMode.direct);
      expect(ready.url, _trustedXs);
      expect(ready.isWebVpn, isFalse);
      expect(ready.headers['Referer'], 'direct');
      expect(modes, [ZhengfangMode.direct]);
      expect(urls, [_trustedXs]);
      expect(ZhengfangAuth.instance.mode, ZhengfangMode.direct);
    });

    test('解析器判定 webVpn 时走网关 + 代理地址', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'U');

      var gatewayCalls = 0;
      DateTime? gatewayDeadline;
      final proxied = ZhengfangAuth.instance.buildWebVpnProxyUrl(_trustedXs);
      String? probedUrl;
      final result = await _preparer(
        modeResolver: (_) async => ZhengfangMode.webVpn,
        gatewaySessionEnsurer: (_, deadline) async {
          gatewayCalls++;
          gatewayDeadline = deadline;
        },
        academicSessionProber: (mode, url, _) async {
          expect(mode, ZhengfangMode.webVpn);
          probedUrl = url;
          return AcademicEntrySessionStatus.authenticated;
        },
      ).prepare();

      expect(gatewayCalls, 1);
      expect(gatewayDeadline, isNotNull);
      final ready = result as AcademicWebEntryReady;
      expect(ready.selectedMode, ZhengfangMode.webVpn);
      expect(ready.url, proxied);
      expect(Uri.parse(proxied).host, 'webvpn.zjxu.edu.cn');
      expect(probedUrl, proxied);
      // 页面级准备绝不改全局教务模式。
      expect(ZhengfangAuth.instance.mode, ZhengfangMode.direct);
    });

    test('WebVPN 网关失败后重新确认直连，再准备直连 H5', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'U');
      var directProbes = 0;
      ConnectModeResolver.instance.directVerdictChecker = (_) async {
        directProbes++;
        return RouteVerdict.direct;
      };
      final modes = <ZhengfangMode>[];
      final result = await _preparer(
        modeResolver: (_) async => ZhengfangMode.webVpn,
        gatewaySessionEnsurer: (_, _) async =>
            throw RouteFailure(RouteFailureReason.webVpnGatewayFailed),
        academicSessionProber: (mode, url, _) async {
          modes.add(mode);
          expect(url, _trustedXs);
          return AcademicEntrySessionStatus.authenticated;
        },
      ).prepare();

      expect(
        result,
        isA<AcademicWebEntryReady>().having(
          (ready) => ready.didFallback,
          'didFallback',
          isTrue,
        ),
      );
      expect(modes, [ZhengfangMode.direct]);
      expect(directProbes, 1);
    });

    test('forceWebVpn 跳过直连偏好，不再调用解析器', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'U');

      var resolverCalled = false;
      final result = await _preparer(
        modeResolver: (_) async {
          resolverCalled = true;
          return ZhengfangMode.direct;
        },
      ).prepare(forceWebVpn: true);

      expect(resolverCalled, isFalse);
      final ready = result as AcademicWebEntryReady;
      expect(ready.selectedMode, ZhengfangMode.webVpn);
      expect(ready.url, contains('webvpn.zjxu.edu.cn'));
    });

    test('两者均不可达 -> unavailable，不推断登录失效', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      final result = await _preparer(modeResolver: (_) async => null).prepare();

      expect(result, isA<AcademicWebEntryUnavailable>());
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
    });
  });

  group('统一认证 / 教务登录判定', () {
    test('webVpn 需要 CAS：内存无统一认证 -> needsUnifiedLogin，不联网', () async {
      UnifiedAuthService.instance.debugSetSession(active: false, account: null);
      // 磁盘仍有可恢复身份，但页面级准备禁止 restoreSession 复活登出态。
      UnifiedAuthService.instance.debugSessionMetadataLoader = () async => 'U';
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');

      var gatewayCalls = 0;
      final result = await _preparer(
        modeResolver: (_) async => ZhengfangMode.webVpn,
        gatewaySessionEnsurer: (_, _) async {
          gatewayCalls++;
        },
      ).prepare();

      expect(result, isA<AcademicWebEntryNeedsUnifiedLogin>());
      expect(gatewayCalls, 0);
      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
    });

    test('网关明确要求 CAS -> needsUnifiedLogin，且不登出统一认证', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'U');

      var probeCalls = 0;
      final result = await _preparer(
        modeResolver: (_) async => ZhengfangMode.webVpn,
        gatewaySessionEnsurer: (_, _) async =>
            throw const CasAuthExpiredException(),
        academicSessionProber: (_, _, _) async {
          probeCalls++;
          return AcademicEntrySessionStatus.authenticated;
        },
      ).prepare();

      expect(result, isA<AcademicWebEntryNeedsUnifiedLogin>());
      expect(probeCalls, 0);
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.mode, ZhengfangMode.direct);
    });

    test('网关就绪但教务会话缺失 -> needsAcademicLogin，不谎报就绪', () async {
      ZhengfangAuth.instance.debugSetSession(active: false, studentId: null);
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'U');

      var probeCalls = 0;
      final result = await _preparer(
        modeResolver: (_) async => ZhengfangMode.webVpn,
        academicSessionProber: (_, _, _) async {
          probeCalls++;
          return AcademicEntrySessionStatus.authenticated;
        },
      ).prepare();

      expect(result, isA<AcademicWebEntryNeedsAcademicLogin>());
      expect(probeCalls, 0);
    });

    test('教务入口回跳登录页 -> needsAcademicLogin，不登出', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'U');
      final result = await _preparer(
        academicSessionProber: (mode, url, _) async {
          expect(mode, ZhengfangMode.direct);
          expect(url, _trustedXs);
          return AcademicEntrySessionStatus.academicLoginRequired;
        },
      ).prepare();

      expect(result, isA<AcademicWebEntryNeedsAcademicLogin>());
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
    });

    test('探测到统一认证 / 网关登录 -> needsUnifiedLogin，不误判教务登录', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'U');
      final result = await _preparer(
        modeResolver: (_) async => ZhengfangMode.webVpn,
        academicSessionProber: (_, _, _) async =>
            AcademicEntrySessionStatus.unifiedLoginRequired,
      ).prepare();

      expect(result, isA<AcademicWebEntryNeedsUnifiedLogin>());
    });
  });

  group('网络未知不判失效', () {
    test('直连探测 unknown -> unavailable 且保留教务会话', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      final result = await _preparer(
        academicSessionProber: (_, _, _) async =>
            AcademicEntrySessionStatus.unknown,
      ).prepare();

      expect(result, isA<AcademicWebEntryUnavailable>());
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.currentStudentId, 'A');
    });

    test('网关网络异常 -> unavailable，统一认证与教务标记都不动', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'U');
      final result = await _preparer(
        modeResolver: (_) async => ZhengfangMode.webVpn,
        gatewaySessionEnsurer: (_, _) async => throw DioException(
          requestOptions: RequestOptions(path: '/login'),
          type: DioExceptionType.connectionError,
        ),
      ).prepare();

      expect(result, isA<AcademicWebEntryUnavailable>());
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.mode, ZhengfangMode.direct);
    });
  });

  group('身份变化 / 取消 / 预算', () {
    test('网关等待期间教务换号 -> stale(identityChanged)，不污染新会话', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'U');

      final started = Completer<void>();
      final release = Completer<void>();
      final preparer = _preparer(
        modeResolver: (_) async => ZhengfangMode.webVpn,
        gatewaySessionEnsurer: (_, _) async {
          started.complete();
          await release.future;
        },
      );

      final future = preparer.prepare();
      await started.future;
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'B');
      release.complete();

      final result = await future;
      expect(result, isA<AcademicWebEntryStale>());
      expect(
        (result as AcademicWebEntryStale).reason,
        AcademicWebEntryStaleReason.identityChanged,
      );
      expect(ZhengfangAuth.instance.currentStudentId, 'B');
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
    });

    test('探测等待期间统一认证换号 -> stale(identityChanged)', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'U');

      final started = Completer<void>();
      final release = Completer<void>();
      final preparer = _preparer(
        academicSessionProber: (_, _, _) async {
          started.complete();
          await release.future;
          return AcademicEntrySessionStatus.authenticated;
        },
      );

      final future = preparer.prepare();
      await started.future;
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'U2');
      release.complete();

      final result = await future;
      expect(result, isA<AcademicWebEntryStale>());
      expect(
        (result as AcademicWebEntryStale).reason,
        AcademicWebEntryStaleReason.identityChanged,
      );
    });

    test('Cookie 同步 await 期间教务换号 -> stale(identityChanged)', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'U');

      final started = Completer<void>();
      final release = Completer<void>();
      bool? guardAfterChange;
      final preparer = _preparer(
        cookieSyncer: (_, guard) async {
          started.complete();
          await release.future;
          guardAfterChange = guard();
        },
      );

      final future = preparer.prepare();
      await started.future;
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'B');
      release.complete();

      final result = await future;
      expect(result, isA<AcademicWebEntryStale>());
      expect(
        (result as AcademicWebEntryStale).reason,
        AcademicWebEntryStaleReason.identityChanged,
      );
      expect(guardAfterChange, isFalse);
    });

    test('总预算到期真实取消传输，而不是只丢弃 Future', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      CancelToken? captured;
      final preparer = _preparer(
        academicSessionProber: (_, _, token) async {
          captured = token;
          await token.whenCancel;
          return AcademicEntrySessionStatus.unknown;
        },
      );

      final result = await preparer.prepare(
        totalBudget: const Duration(milliseconds: 50),
      );

      expect(result, isA<AcademicWebEntryStale>());
      expect(
        (result as AcademicWebEntryStale).reason,
        AcademicWebEntryStaleReason.cancelled,
      );
      expect(captured, isNotNull);
      expect(captured!.isCancelled, isTrue);
    });

    test('调用方取消 -> stale(cancelled) 且传输被取消', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      final cancelToken = CancelToken();
      final started = Completer<void>();
      CancelToken? captured;
      final preparer = _preparer(
        academicSessionProber: (_, _, token) async {
          captured = token;
          started.complete();
          await token.whenCancel;
          return AcademicEntrySessionStatus.unknown;
        },
      );

      final future = preparer.prepare(cancelToken: cancelToken);
      await started.future;
      cancelToken.cancel('user cancelled');

      final result = await future;
      expect(result, isA<AcademicWebEntryStale>());
      expect(
        (result as AcademicWebEntryStale).reason,
        AcademicWebEntryStaleReason.cancelled,
      );
      expect(captured!.isCancelled, isTrue);
    });
  });

  group('全局状态零副作用', () {
    test('webVpn 准备不改写全局教务模式（保持 direct）', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'U');
      ZhengfangAuth.instance.setMode(ZhengfangMode.direct);

      await _preparer(modeResolver: (_) async => ZhengfangMode.webVpn)
          .prepare();

      expect(ZhengfangAuth.instance.mode, ZhengfangMode.direct);
    });

    test('direct 准备不改写全局教务模式（保持 webVpn）', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      ZhengfangAuth.instance.setMode(ZhengfangMode.webVpn);

      await _preparer(modeResolver: (_) async => ZhengfangMode.direct)
          .prepare();

      expect(ZhengfangAuth.instance.mode, ZhengfangMode.webVpn);
    });

    test('Cookie 同步收到显式 mode 与身份守卫', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'U');
      ZhengfangMode? seenMode;
      bool? guardResult;
      final result = await _preparer(
        modeResolver: (_) async => ZhengfangMode.webVpn,
        cookieSyncer: (mode, guard) async {
          seenMode = mode;
          guardResult = guard();
        },
      ).prepare();

      expect(result, isA<AcademicWebEntryReady>());
      expect(seenMode, ZhengfangMode.webVpn);
      expect(guardResult, isTrue);
    });
  });

  group('probeTrustedEntrySession（生产探测实现）', () {
    Future<MockHttpClientAdapter> prepareDirectAdapter() async {
      await DioClient.instance.ensureInitialized();
      final adapter = MockHttpClientAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;
      return adapter;
    }

    test('302 回跳正方登录入口 -> academicLoginRequired，且不登出会话', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      final adapter = await prepareDirectAdapter();
      adapter.registerText(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        '',
        statusCode: 302,
        headers: {
          'location': ['/jwglxt/xtgl/login_slogin.html'],
        },
      );

      final result = await ZhengfangAuth.instance.probeTrustedEntrySession(
        mode: ZhengfangMode.direct,
        requestUrl: _trustedXs,
      );

      expect(result, AcademicEntrySessionStatus.academicLoginRequired);
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.currentStudentId, 'A');
    });

    test('302 跳转受信 origin 的已认证教务页面 -> authenticated', () async {
      final adapter = await prepareDirectAdapter();
      adapter.registerText(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        '',
        statusCode: 302,
        headers: {
          'location': ['/jwglxt/xtgl/index_initMenu.html?jsdm=xs'],
        },
      );

      final result = await ZhengfangAuth.instance.probeTrustedEntrySession(
        mode: ZhengfangMode.direct,
        requestUrl: _trustedXs,
      );

      expect(result, AcademicEntrySessionStatus.authenticated);
    });

    // 合成 fixture，结构对齐 2026-09-30 直连设备实测的已登录学生菜单页
    // （200、标题「教学管理信息服务平台」、页面级 sessionUserKey + 学生菜单链接）。
    test('200 已登录学生菜单页（sessionUserKey + 学生菜单）-> authenticated', () async {
      final adapter = await prepareDirectAdapter();
      adapter.registerText(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        '<html><head><title>教学管理信息服务平台</title></head><body>'
            '<input type="hidden" id="sessionUserKey" value="x"/>'
            '<a data-url="/kbcx/xskbcx_cxXskbcxIndex.html">'
            '学生课表查询</a><a href="#">退出</a></body></html>',
      );

      final result = await ZhengfangAuth.instance.probeTrustedEntrySession(
        mode: ZhengfangMode.direct,
        requestUrl: _trustedXs,
      );

      expect(result, AcademicEntrySessionStatus.authenticated);
    });

    test('200 只有 sessionUserKey 而无学生菜单 -> unknown', () async {
      final adapter = await prepareDirectAdapter();
      adapter.registerText(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        '<html><head><title>教学管理信息服务平台</title></head><body>'
            '<input type="hidden" id="sessionUserKey" value="x"/></body></html>',
      );

      final result = await ZhengfangAuth.instance.probeTrustedEntrySession(
        mode: ZhengfangMode.direct,
        requestUrl: _trustedXs,
      );

      expect(result, AcademicEntrySessionStatus.unknown);
    });

    test('302 跳转跨域任意地址 -> unknownRedirect，绝不判就绪', () async {
      final adapter = await prepareDirectAdapter();
      adapter.registerText(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        '',
        statusCode: 302,
        headers: {
          'location': ['https://evil.example.com/anything'],
        },
      );

      final result = await ZhengfangAuth.instance.probeTrustedEntrySession(
        mode: ZhengfangMode.direct,
        requestUrl: _trustedXs,
      );

      expect(result, AcademicEntrySessionStatus.unknownRedirect);
    });

    test('302 跳转同源但不可识别路径 -> unknown', () async {
      final adapter = await prepareDirectAdapter();
      adapter.registerText(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        '',
        statusCode: 302,
        headers: {
          'location': ['/some/random/page.html'],
        },
      );

      final result = await ZhengfangAuth.instance.probeTrustedEntrySession(
        mode: ZhengfangMode.direct,
        requestUrl: _trustedXs,
      );

      expect(result, AcademicEntrySessionStatus.unknown);
    });

    test('302 回跳统一认证 CAS 登录页 -> unifiedLoginRequired', () async {
      final adapter = await prepareDirectAdapter();
      adapter.registerText(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        '',
        statusCode: 302,
        headers: {
          'location': ['https://newca.zjxu.edu.cn/cas/login?service=x'],
        },
      );

      final result = await ZhengfangAuth.instance.probeTrustedEntrySession(
        mode: ZhengfangMode.direct,
        requestUrl: _trustedXs,
      );

      expect(result, AcademicEntrySessionStatus.unifiedLoginRequired);
    });

    test('200 正方登录 HTML -> academicLoginRequired', () async {
      final adapter = await prepareDirectAdapter();
      adapter.registerText(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        _zhengfangLoginHtml,
      );

      final result = await ZhengfangAuth.instance.probeTrustedEntrySession(
        mode: ZhengfangMode.direct,
        requestUrl: _trustedXs,
      );

      expect(result, AcademicEntrySessionStatus.academicLoginRequired);
    });

    test('200 带已认证签名 -> authenticated', () async {
      final adapter = await prepareDirectAdapter();
      adapter.registerText(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        '<html><a href="/xtgl/index_initMenu.html?jsdm=xs">首页</a></html>',
      );

      final result = await ZhengfangAuth.instance.probeTrustedEntrySession(
        mode: ZhengfangMode.direct,
        requestUrl: _trustedXs,
      );

      expect(result, AcademicEntrySessionStatus.authenticated);
    });

    test('200 无成功签名的任意页面 -> unknown（fail closed）', () async {
      final adapter = await prepareDirectAdapter();
      adapter.registerText(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        '<html>ok</html>',
      );

      final result = await ZhengfangAuth.instance.probeTrustedEntrySession(
        mode: ZhengfangMode.direct,
        requestUrl: _trustedXs,
      );

      expect(result, AcademicEntrySessionStatus.unknown);
    });

    test('5xx 服务端错误 -> schoolBackendError', () async {
      final adapter = await prepareDirectAdapter();
      adapter.registerText(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        'oops',
        statusCode: 500,
      );

      final result = await ZhengfangAuth.instance.probeTrustedEntrySession(
        mode: ZhengfangMode.direct,
        requestUrl: _trustedXs,
      );

      expect(result, AcademicEntrySessionStatus.schoolBackendError);
    });

    test('传输异常 -> connectionFailed', () async {
      final adapter = await prepareDirectAdapter();
      adapter.register('GET', '/jwglxt/xtgl/index_initMenu.html', (
        options,
      ) async {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      });

      final result = await ZhengfangAuth.instance.probeTrustedEntrySession(
        mode: ZhengfangMode.direct,
        requestUrl: _trustedXs,
      );

      expect(result, AcademicEntrySessionStatus.connectionFailed);
    });

    test('WebVPN 代理回跳网关登录页 -> unifiedLoginRequired', () async {
      await DioClient.instance.ensureInitialized();
      final proxyUrl = ZhengfangAuth.instance.buildWebVpnProxyUrl(_trustedXs);
      final path = Uri.parse(proxyUrl).path;
      final adapter = MockHttpClientAdapter()
        ..registerText(
          'GET',
          path,
          '',
          statusCode: 302,
          headers: {
            'location': ['/login'],
          },
        );
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      final result = await ZhengfangAuth.instance.probeTrustedEntrySession(
        mode: ZhengfangMode.webVpn,
        requestUrl: proxyUrl,
      );

      expect(result, AcademicEntrySessionStatus.unifiedLoginRequired);
    });
  });

  group('严格 Cookie 同步（fail closed，仅入口准备使用）', () {
    test('严格同步成功：写入并校验通过，不抛错', () async {
      await _seedJar('https://jwzx.zjxu.edu.cn/', 'JSESSIONID', 'abc');

      await ZhengfangAuth.instance.syncCookiesToWebViewForMode(
        ZhengfangMode.direct,
        strict: true,
      );

      expect(webViewPlatform.cookieManager.setCalls, greaterThan(0));
    });

    test('严格同步：无任何 Cookie -> 抛错，不得判 Ready', () async {
      await expectLater(
        ZhengfangAuth.instance.syncCookiesToWebViewForMode(
          ZhengfangMode.direct,
          strict: true,
        ),
        throwsA(isA<AcademicCookieSyncException>()),
      );
    });

    test('严格同步：写失败 -> 抛错', () async {
      await _seedJar('https://jwzx.zjxu.edu.cn/', 'JSESSIONID', 'abc');
      webViewPlatform.cookieManager.throwOnSet = true;

      await expectLater(
        ZhengfangAuth.instance.syncCookiesToWebViewForMode(
          ZhengfangMode.direct,
          strict: true,
        ),
        throwsA(isA<AcademicCookieSyncException>()),
      );
    });

    test('严格同步：校验读失败 -> 抛错', () async {
      await _seedJar('https://jwzx.zjxu.edu.cn/', 'JSESSIONID', 'abc');
      webViewPlatform.cookieManager.throwOnGet = true;

      await expectLater(
        ZhengfangAuth.instance.syncCookiesToWebViewForMode(
          ZhengfangMode.direct,
          strict: true,
        ),
        throwsA(isA<AcademicCookieSyncException>()),
      );
    });

    test('严格同步：校验值不一致 -> 抛错', () async {
      await _seedJar('https://jwzx.zjxu.edu.cn/', 'JSESSIONID', 'abc');
      webViewPlatform.cookieManager.corruptOnGet = true;

      await expectLater(
        ZhengfangAuth.instance.syncCookiesToWebViewForMode(
          ZhengfangMode.direct,
          strict: true,
        ),
        throwsA(isA<AcademicCookieSyncException>()),
      );
    });

    test('严格同步：清理删除失败 -> 抛错', () async {
      await _seedJar('https://jwzx.zjxu.edu.cn/', 'JSESSIONID', 'abc');
      webViewPlatform.cookieManager.throwOnDelete = true;

      await expectLater(
        ZhengfangAuth.instance.syncCookiesToWebViewForMode(
          ZhengfangMode.direct,
          strict: true,
        ),
        throwsA(isA<AcademicCookieSyncException>()),
      );
    });

    test('旧最佳努力语义：非严格写失败不抛错', () async {
      await _seedJar('https://jwzx.zjxu.edu.cn/', 'JSESSIONID', 'abc');
      webViewPlatform.cookieManager.throwOnSet = true;

      await ZhengfangAuth.instance.syncCookiesToWebViewForMode(
        ZhengfangMode.direct,
      );
    });

    test('旧 syncDirectCookiesToWebView 保留最佳努力行为', () async {
      ZhengfangAuth.instance.setMode(ZhengfangMode.direct);
      await _seedJar('https://jwzx.zjxu.edu.cn/', 'JSESSIONID', 'abc');
      webViewPlatform.cookieManager.throwOnSet = true;

      await ZhengfangAuth.instance.syncDirectCookiesToWebView();
    });

    test('旧 syncWebVpnCookiesToWebView 保留最佳努力行为', () async {
      ZhengfangAuth.instance.setMode(ZhengfangMode.webVpn);
      await _seedJar(
        'https://webvpn.zjxu.edu.cn/',
        'wengine_vpn_ticket',
        'abc',
        webVpn: true,
      );
      webViewPlatform.cookieManager.throwOnSet = true;

      await ZhengfangAuth.instance.syncWebVpnCookiesToWebView();
    });

    test('入口准备走生产严格同步：写失败 -> 不返回 Ready', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'U');
      await _seedJar('https://jwzx.zjxu.edu.cn/', 'JSESSIONID', 'abc');
      webViewPlatform.cookieManager.throwOnSet = true;

      final result = await AcademicWebEntryPreparer(
        modeResolver: (_) async => ZhengfangMode.direct,
        academicSessionProber: (_, _, _) async =>
            AcademicEntrySessionStatus.authenticated,
        // 不注入 cookieSyncer：走生产严格实现。
      ).prepare();

      expect(result, isNot(isA<AcademicWebEntryReady>()));
      expect(result, isA<AcademicWebEntryUnavailable>());
    });

    test('入口准备走生产严格同步：无 Cookie -> 不返回 Ready', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'U');

      final result = await AcademicWebEntryPreparer(
        modeResolver: (_) async => ZhengfangMode.direct,
        academicSessionProber: (_, _, _) async =>
            AcademicEntrySessionStatus.authenticated,
      ).prepare();

      expect(result, isNot(isA<AcademicWebEntryReady>()));
      expect(result, isA<AcademicWebEntryUnavailable>());
    });
  });
}
