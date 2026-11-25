import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/academic_auth_guard.dart';
import 'package:jxu_campus_hub/core/auth/auth_recovery_state_store.dart';
import 'package:jxu_campus_hub/core/auth/auth_session_persistence.dart';
import 'package:jxu_campus_hub/core/auth/automatic_login.dart';
import 'package:jxu_campus_hub/core/auth/cas_routed_access.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';

import '../../helpers/mock_http_client_adapter.dart';

/// 严格命中 [looksLikeZhengfangLoginHtml] 的正方登录页 fixture。
const String _loginHtml =
    '<html><form action="/jwglxt/xtgl/login_slogin.html">'
    '<input id="yhm" name="yhm" />'
    '<input id="mm" name="mm" />'
    '</form></html>';

/// 模拟一次真实教务提交：推进持久 epoch + 强制 bump revision，返回 typed receipt。
Future<AutomaticLoginAttemptResult> _commitAcademicSession(
  String account,
) async {
  final epoch = await AuthSessionPersistence.instance.readEpoch(
    CredentialSessionDomain.academic,
  );
  final receipt = await AuthSessionPersistence.instance.commit(
    CredentialSessionDomain.academic,
    account: account,
    expectedEpoch: epoch,
  );
  ZhengfangAuth.instance.debugSetSession(
    active: true,
    studentId: account,
    forceRevision: true,
  );
  return AutomaticLoginAttemptResult(
    outcome: AutomaticLoginOutcome.committed,
    receipt: receipt,
  );
}

Response<T> _response<T>(int? statusCode, T? data) => Response<T>(
  requestOptions: RequestOptions(path: '/kbcx/xskbcx_cxXsKb.html'),
  statusCode: statusCode,
  headers: Headers.fromMap({
    if (statusCode == 302 || statusCode == 303)
      'location': ['/jwglxt/xtgl/login_slogin.html'],
  }),
  data: data,
);

Response<Map<String, dynamic>> _okResponse() =>
    _response<Map<String, dynamic>>(200, {'items': <dynamic>[]});

Response<Map<String, dynamic>> _redirectResponse() =>
    _response<Map<String, dynamic>>(302, null);

Response<Map<String, dynamic>> _status901Response({Object? data}) =>
    _response<Map<String, dynamic>>(901, data as Map<String, dynamic>?);

DioException _statusDioException(int statusCode, {Object? data}) {
  final options = RequestOptions(path: '/kbcx/xskbcx_cxXsKb.html');
  return DioException.badResponse(
    statusCode: statusCode,
    requestOptions: options,
    response: _response<Map<String, dynamic>>(
      statusCode,
      data as Map<String, dynamic>?,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NetworkSettings.instance.debugReset();
    DioClient.instance.debugReset();
    // 恢复探测（`ensureWebVpnGatewaySessionResult`）会初始化共享 Dio；
    // 测试环境没有 path_provider 实现，必须注入目录提供者，否则初始化
    // 在探测之前就抛 MissingPluginException，恢复链路钩子根本走不到。
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        'jxuc_academic_guard_test/$folderName/';
    ZhengfangAuth.instance.debugReset();
    AuthSessionPersistence.instance.debugReset();
    AcademicAuthGuard.debugAutomaticLoginOverride = null;
    AcademicAuthGuard.debugAutomaticLoginReceiptOverride = null;
    final resolver = ConnectModeResolver.instance;
    resolver.debugReset();
    resolver.directReachabilityChecker = () async => false;
    resolver.webVpnReachabilityChecker = () async => false;
  });

  test(
    'cold academic queries wait for one gateway and academic session check',
    () async {
      const student = '2025000001';
      final auth = ZhengfangAuth.instance;
      auth.debugSetSession(active: true, studentId: student);
      final unified = UnifiedAuthService.instance;
      unified.debugSetSession(active: true, account: student);
      addTearDown(unified.debugReset);
      ConnectModeResolver.instance.directVerdictChecker = (_) async =>
          RouteVerdict.webVpnRedirected;
      final gatewayStarted = Completer<void>();
      final release = Completer<void>();
      var gatewayCalls = 0;
      CasRoutedAccess.debugGatewayEnsurer = (_, _) async {
        gatewayCalls++;
        gatewayStarted.complete();
        await release.future;
      };
      addTearDown(() => CasRoutedAccess.debugGatewayEnsurer = null);
      DioClient.instance.debugUseMemoryCookieStorage = true;
      DioClient.instance.debugCookieDirectoryPathProvider = (
        folderName,
      ) async => 'jxuc_academic_guard_test/$folderName/';
      AuthSessionPersistence.instance.debugDisableFileLock = true;
      await DioClient.instance.ensureInitialized();
      final proxyMenu = Uri.parse(
        auth.buildPortalUrl(
          '/xtgl/index_initMenu.html',
          mode: ZhengfangMode.webVpn,
        ),
      );
      final adapter = MockHttpClientAdapter()
        ..registerText(
          'GET',
          proxyMenu.path,
          '<a href="/xtgl/index_initMenu.html">菜单</a>',
        );
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
      final sent = <ZhengfangMode>[];
      Future<AcademicGuardedResponse<Map<String, dynamic>>> query() =>
          AcademicAuthGuard.guardRoutedQuery(
            owner: student,
            authExpiredException: const AcademicAuthExpiredException(),
            request: (mode) async {
              sent.add(mode);
              return _okResponse();
            },
          );

      final first = query();
      await gatewayStarted.future;
      final second = query();
      expect(auth.mode, ZhengfangMode.direct);
      expect(sent, isEmpty);
      release.complete();
      await Future.wait([first, second]);
      expect(sent, [ZhengfangMode.webVpn, ZhengfangMode.webVpn]);
      expect(gatewayCalls, 1);
      expect(adapter.requestLog, hasLength(1));
    },
  );

  tearDown(() {
    AcademicAuthGuard.debugAutomaticLoginOverride = null;
    AcademicAuthGuard.debugAutomaticLoginReceiptOverride = null;
    DioClient.instance.debugReset();
    ZhengfangAuth.instance.debugReset();
    AuthSessionPersistence.instance.debugReset();
    ConnectModeResolver.instance.debugReset();
    NetworkSettings.instance.debugReset();
  });

  test('passes through when first request is ok', () async {
    var calls = 0;
    final resp = await AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
      authExpiredException: const _Marker(),
      request: () async {
        calls++;
        return _okResponse();
      },
    );

    expect(resp.statusCode, 200);
    expect(calls, 1);
  });

  test('throws auth expired when 302 and recovery unavailable', () async {
    var calls = 0;
    await expectLater(
      AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
        authExpiredException: const _Marker(),
        request: () async {
          calls++;
          return _redirectResponse();
        },
      ),
      throwsA(isA<_Marker>()),
    );
    // 恢复失败，不重试。
    expect(calls, 1);
    expect(ZhengfangAuth.instance.isLoggedIn, isFalse);
  });

  test('过期恢复探测到 WebVPN 但网关未建成：不改全局模式', () async {
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
    final resolver = ConnectModeResolver.instance;
    resolver.webVpnReachabilityChecker = () async => true;
    expect(ZhengfangAuth.instance.mode, ZhengfangMode.direct);
    AcademicAuthGuard.debugAutomaticLoginOverride = (
      domain, {
      String? expectedAccount,
    }) async => AutomaticLoginOutcome.notEligible;

    await expectLater(
      AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
        authExpiredException: const _Marker(),
        request: () async => _redirectResponse(),
      ),
      throwsA(isA<_Marker>()),
    );
    expect(
      ZhengfangAuth.instance.mode,
      ZhengfangMode.direct,
      reason: '恢复未证实有效前不得把全局模式切到 WebVPN',
    );
  });

  group('isAuthExpiredResponse', () {
    test('901/401 与明确登录跳转识别为认证过期；403 不误判', () {
      expect(
        AcademicAuthGuard.isAuthExpiredResponse(_response(403, null)),
        isFalse,
      );
      for (final status in <int>[901, 302, 303, 401]) {
        final response = _response<Map<String, dynamic>>(
          status,
          <String, dynamic>{'code': status},
        );
        expect(
          AcademicAuthGuard.isAuthExpiredResponse<Map<String, dynamic>>(
            response,
          ),
          isTrue,
          reason: 'HTTP $status 应识别为认证过期',
        );
      }
    });

    test('200 严格登录 HTML 识别为过期（fixture 自校验）', () {
      expect(
        looksLikeZhengfangLoginHtml(_loginHtml),
        isTrue,
        reason: 'fixture 必须严格命中登录页判定，否则本测试无意义',
      );
      final response = _response<String>(200, _loginHtml);

      expect(AcademicAuthGuard.isAuthExpiredResponse(response), isTrue);
    });

    test('200 非登录 HTML 不误判', () {
      final nonLoginBodies = <String>[
        '<html><body>成绩查询结果</body></html>',
        '',
        // 仅用户名一个凭据字段。
        '<html><body><input id="yhm" name="yhm" /></body></html>',
        // 用户名 + 密码但缺少登录 action / csrf / 提交按钮。
        '<html><body><input id="yhm" name="yhm" />'
            '<input id="mm" name="mm" /></body></html>',
        // 密码 + 验证码两个字段，但没有登录 form 语义。
        '<html><body><input name="mm" /><input name="yzm" /></body></html>',
      ];
      for (final body in nonLoginBodies) {
        final response = _response<String>(200, body);
        expect(
          AcademicAuthGuard.isAuthExpiredResponse(response),
          isFalse,
          reason: '非登录页不得误判: $body',
        );
      }
    });

    test('非字符串响应体 / 其他状态码 / 空响应不误判', () {
      expect(
        AcademicAuthGuard.isAuthExpiredResponse<Map<String, dynamic>>(
          _response<Map<String, dynamic>>(200, <String, dynamic>{'code': 901}),
        ),
        isFalse,
        reason: '状态码 200 的业务 JSON 不是登录 HTML',
      );
      for (final status in <int?>[404, 500, 204, null]) {
        expect(
          AcademicAuthGuard.isAuthExpiredResponse<Map<String, dynamic>>(
            _response<Map<String, dynamic>>(status, <String, dynamic>{}),
          ),
          isFalse,
          reason: 'HTTP $status 不是认证过期',
        );
      }
      expect(
        AcademicAuthGuard.isAuthExpiredResponse<Map<String, dynamic>>(null),
        isFalse,
      );
    });
  });

  group('901 主 POST 场景（validateStatus < 1000 返回 Response）', () {
    test('首次 901、自动登录提交成功但重试仍 901：有界终止且条件撤销', () async {
      var autoLoginCalls = 0;
      AcademicAuthGuard.debugAutomaticLoginReceiptOverride =
          (domain, {String? expectedAccount}) async {
            autoLoginCalls++;
            expect(domain, AuthRecoveryDomain.academic);
            return _commitAcademicSession('2025000001');
          };
      var calls = 0;

      await expectLater(
        AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
          authExpiredException: const _Marker(),
          request: () async {
            calls++;
            return _status901Response();
          },
        ),
        throwsA(isA<_Marker>()),
      );

      expect(calls, 2, reason: '仅一次恢复/自动登录预算 + 至多一次重试');
      expect(autoLoginCalls, 1, reason: '自动登录只尝试一次');
      expect(ZhengfangAuth.instance.isLoggedIn, isFalse);
    });

    test('首次 901、自动登录提交成功后重试成功', () async {
      var autoLoginCalls = 0;
      AcademicAuthGuard.debugAutomaticLoginReceiptOverride =
          (domain, {String? expectedAccount}) async {
            autoLoginCalls++;
            return _commitAcademicSession('2025000001');
          };
      var calls = 0;

      final resp = await AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
        request: () async {
          calls++;
          return calls == 1 ? _status901Response() : _okResponse();
        },
      );

      expect(resp.statusCode, 200);
      expect(calls, 2, reason: '自动登录成功后只重试一次');
      expect(autoLoginCalls, 1);
    });

    test('901 首次命中：自动登录 manualRequired 抛出可区分异常且不重试', () async {
      AcademicAuthGuard.debugAutomaticLoginOverride = (
        domain, {
        String? expectedAccount,
      }) async => AutomaticLoginOutcome.manualRequired;
      var calls = 0;

      await expectLater(
        AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
          request: () async {
            calls++;
            return _status901Response();
          },
        ),
        throwsA(
          isA<AcademicAuthExpiredException>().having(
            (e) => e.automaticLoginPaused,
            'automaticLoginPaused',
            isTrue,
          ),
        ),
      );
      expect(calls, 1, reason: '暂停后不得重试');
    });

    test('901 首次命中：无已保存凭据时抛过期异常且不重试', () async {
      var calls = 0;
      await expectLater(
        AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
          authExpiredException: const _Marker(),
          request: () async {
            calls++;
            return _status901Response();
          },
        ),
        throwsA(isA<_Marker>()),
      );
      expect(calls, 1, reason: '自动登录未提交时不得重试');
      expect(ZhengfangAuth.instance.isLoggedIn, isFalse);
    });

    test('901 首次命中：会话恢复成功后只重试一次，不走自动登录', () async {
      final adapter = MockHttpClientAdapter();
      adapter.registerText(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        '<html><a href="/xtgl/index_initMenu.html">教务首页</a></html>',
      );
      DioClient.instance.debugUseMemoryCookieStorage = true;
      // 内存存储仍会解析 cookie 目录路径，测试环境不注册 path_provider。
      DioClient.instance.debugCookieDirectoryPathProvider = (
        folderName,
      ) async => 'jxuc_academic_guard_test/$folderName/';
      await DioClient.instance.ensureInitialized();
      DioClient.instance.dio.httpClientAdapter = adapter;
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '2025000001',
      );
      ConnectModeResolver.instance.directReachabilityChecker = () async => true;

      var autoLoginCalls = 0;
      AcademicAuthGuard.debugAutomaticLoginOverride =
          (domain, {String? expectedAccount}) async {
            autoLoginCalls++;
            return AutomaticLoginOutcome.failed;
          };
      var calls = 0;

      final resp = await AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
        request: () async {
          calls++;
          return calls == 1 ? _status901Response() : _okResponse();
        },
      );

      expect(resp.statusCode, 200);
      expect(calls, 2, reason: '恢复成功后只重试一次');
      expect(autoLoginCalls, 0, reason: '恢复成功不应再走自动登录');
      expect(
        adapter.requestLog.where((r) => r.contains('index_initMenu')).length,
        1,
        reason: '恢复探测只发一次',
      );
    });
  });

  group('直连被改道到 WebVPN（isRouteMovedResponse）', () {
    const webVpnResource =
        'https://webvpn.zjxu.edu.cn/https/77726476706e69737468656265737421'
        'fae05b84692a62486b468ca88d1b203b//jwglxt/cjcx/cjcx_cxDgXscj.html'
        '?doType=query';

    Response<Object?> moved(String requestUrl, String location) =>
        Response<Object?>(
          requestOptions: RequestOptions(path: requestUrl),
          statusCode: 302,
          headers: Headers.fromMap({
            'location': [location],
          }),
          data: '<html>302 Found</html>',
        );

    test('jwzx 302 到 WebVPN 代理资源识别为改道，而非登录过期', () {
      final response = moved(
        'https://jwzx.zjxu.edu.cn/jwglxt/cjcx/cjcx_cxDgXscj.html',
        webVpnResource,
      );
      expect(AcademicAuthGuard.isRouteMovedResponse(response), isTrue);
      expect(AcademicAuthGuard.isAuthExpiredResponse(response), isFalse);
      expect(
        AcademicAuthGuard.isRouteMovedResponse(
          moved(
            'https://jwzx.zjxu.edu.cn:8443/x',
            ZhengfangAuth.instance.buildWebVpnProxyUrl(
              'https://jwzx.zjxu.edu.cn:8443/x',
            ),
          ),
        ),
        isTrue,
        reason: '带端口的代理路径同样是改道',
      );
    });

    test('WebVPN 登录页 / 教务登录页 / WebVPN 自身请求 / 非 3xx 不算改道', () {
      final cases = <Response<Object?>>[
        moved('https://jwzx.zjxu.edu.cn/x', 'https://webvpn.zjxu.edu.cn/login'),
        moved('https://jwzx.zjxu.edu.cn/x', '/jwglxt/xtgl/login_slogin.html'),
        moved('https://webvpn.zjxu.edu.cn/https/abc/x', webVpnResource),
        moved(
          'https://jwzx.zjxu.edu.cn/x',
          'https://webvpn.zjxu.edu.cn/https/abc/cas/login?service=x',
        ),
        // 跳到其它校内站点（如图书馆 libapp）的 WebVPN 包装，不是本次改道。
        moved(
          'https://jwzx.zjxu.edu.cn/x',
          ZhengfangAuth.instance.buildWebVpnProxyUrl(
            'https://libapp.zjxu.edu.cn/x',
          ),
        ),
        moved(
          'https://jwzx.zjxu.edu.cn/x',
          'https://webvpn.zjxu.edu.cn/https/abc/x',
        ),
        Response<Object?>(
          requestOptions: RequestOptions(path: 'https://jwzx.zjxu.edu.cn/x'),
          statusCode: 200,
          headers: Headers.fromMap({
            'location': [webVpnResource],
          }),
        ),
      ];
      for (final response in cases) {
        expect(
          AcademicAuthGuard.isRouteMovedResponse(response),
          isFalse,
          reason: '${response.statusCode} → ${response.headers['location']}',
        );
      }
      expect(AcademicAuthGuard.isRouteMovedResponse<Object?>(null), isFalse);
    });

    test('真实 Dio：302 HTML 响应体不再变成 DioException，恢复后重试一次', () async {
      final dio = Dio(
        BaseOptions(
          followRedirects: false,
          validateStatus: (status) => status != null && status < 400,
        ),
      );
      final adapter = MockHttpClientAdapter();
      var hits = 0;
      adapter.register('POST', '/jwglxt/cjcx/cjcx_cxDgXscj.html', (_) async {
        hits++;
        if (hits == 1) {
          return ResponseBody.fromString(
            '<html><body>302 Found</body></html>',
            302,
            headers: <String, List<String>>{
              'location': <String>[webVpnResource],
              Headers.contentTypeHeader: <String>['text/html'],
            },
          );
        }
        return ResponseBody.fromString(
          '{"items":[]}',
          200,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>['application/json'],
          },
        );
      });
      dio.httpClientAdapter = adapter;
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '2025000001',
      );

      var autoLoginCalls = 0;
      AcademicAuthGuard.debugAutomaticLoginReceiptOverride =
          (domain, {String? expectedAccount}) async {
            autoLoginCalls++;
            return _commitAcademicSession('2025000001');
          };

      final guarded = await AcademicAuthGuard.guardWithSession<Object?>(
        request: () => dio.post<Object?>(
          'https://jwzx.zjxu.edu.cn/jwglxt/cjcx/cjcx_cxDgXscj.html',
        ),
      );

      expect(guarded.response.statusCode, 200);
      expect((guarded.response.data as Map)['items'], isA<List>());
      expect(hits, 2, reason: '改道后只重试一次');
      expect(autoLoginCalls, 1);
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
    });

    test('重新选路后仍被改道：抛恢复中异常，不撤销会话', () async {
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '2025000001',
      );
      AcademicAuthGuard.debugAutomaticLoginReceiptOverride = (
        domain, {
        String? expectedAccount,
      }) async => _commitAcademicSession('2025000001');
      var calls = 0;

      await expectLater(
        AcademicAuthGuard.guardWithSession<Object?>(
          request: () async {
            calls++;
            return moved(
              'https://jwzx.zjxu.edu.cn/jwglxt/cjcx/cjcx_cxDgXscj.html',
              webVpnResource,
            );
          },
        ),
        throwsA(isA<AcademicAuthRecoveryPendingException>()),
      );
      expect(calls, 2);
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue, reason: '改道不得撤销会话');
    });

    test('改道后恢复失败且无法自动登录：不撤销会话', () async {
      for (final outcome in [
        AutomaticLoginOutcome.notEligible,
        AutomaticLoginOutcome.manualRequired,
      ]) {
        ZhengfangAuth.instance.debugSetSession(
          active: true,
          studentId: '2025000001',
        );
        // 恢复链路会把全局模式切到 WebVPN；网关建不起来时必须回滚。
        final resolver = ConnectModeResolver.instance;
        resolver.webVpnReachabilityChecker = () async => true;
        resolver.targetDirectReachabilityChecker = (_) async => false;
        expect(ZhengfangAuth.instance.mode, ZhengfangMode.direct);
        AcademicAuthGuard.debugAutomaticLoginReceiptOverride = null;
        AcademicAuthGuard.debugAutomaticLoginOverride = (
          domain, {
          String? expectedAccount,
        }) async => outcome;

        await expectLater(
          AcademicAuthGuard.guardWithSession<Object?>(
            request: () async => moved(
              'https://jwzx.zjxu.edu.cn/jwglxt/cjcx/cjcx_cxDgXscj.html',
              webVpnResource,
            ),
          ),
          outcome == AutomaticLoginOutcome.manualRequired
              ? throwsA(
                  isA<AcademicAuthExpiredException>().having(
                    (e) => e.automaticLoginPaused,
                    'automaticLoginPaused',
                    isTrue,
                  ),
                )
              : throwsA(isA<AcademicAuthRecoveryPendingException>()),
        );
        expect(
          ZhengfangAuth.instance.isLoggedIn,
          isTrue,
          reason: '$outcome：改道恢复失败不得撤销会话',
        );
        expect(
          ZhengfangAuth.instance.mode,
          ZhengfangMode.direct,
          reason: '$outcome：改道恢复失败后回滚恢复链路切换的模式',
        );
      }
    });
  });

  group('_safeRequest 的 DioException 处理', () {
    test('真实 Dio 抛出的认证 status DioException 也能被识别（非合成响应）', () async {
      final dio = Dio(
        BaseOptions(validateStatus: (status) => status != null && status < 400),
      );
      final adapter = MockHttpClientAdapter();
      adapter.registerText(
        'GET',
        '/kbcx/xskbcx_cxXsKb.html',
        '{"error":"denied"}',
        statusCode: 901,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['application/json'],
        },
      );
      dio.httpClientAdapter = adapter;

      var autoLoginCalls = 0;
      AcademicAuthGuard.debugAutomaticLoginReceiptOverride =
          (domain, {String? expectedAccount}) async {
            autoLoginCalls++;
            return _commitAcademicSession('2025000001');
          };
      var calls = 0;

      await expectLater(
        AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
          authExpiredException: const _Marker(),
          request: () async {
            calls++;
            return dio.get<Map<String, dynamic>>('/kbcx/xskbcx_cxXsKb.html');
          },
        ),
        throwsA(isA<_Marker>()),
      );

      expect(calls, 2, reason: '真实 DioException 也走有界重试');
      expect(autoLoginCalls, 1);
      expect(adapter.requestLog.length, 2);
    });

    for (final status in <int>[901, 303, 401]) {
      test('DioException(HTTP $status) 视为认证过期并恢复重试一次', () async {
        var autoLoginCalls = 0;
        AcademicAuthGuard.debugAutomaticLoginReceiptOverride =
            (domain, {String? expectedAccount}) async {
              autoLoginCalls++;
              return _commitAcademicSession('2025000001');
            };
        var calls = 0;

        final resp = await AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
          request: () async {
            calls++;
            if (calls == 1) throw _statusDioException(status);
            return _okResponse();
          },
        );

        expect(resp.statusCode, 200);
        expect(calls, 2);
        expect(autoLoginCalls, 1);
      });
    }

    test('DioException 其他业务错误与网络错误一律重抛，不被吞', () async {
      var autoLoginCalls = 0;
      AcademicAuthGuard.debugAutomaticLoginOverride =
          (domain, {String? expectedAccount}) async {
            autoLoginCalls++;
            return AutomaticLoginOutcome.committed;
          };

      var badResponseCalls = 0;
      await expectLater(
        AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
          request: () async {
            badResponseCalls++;
            throw _statusDioException(500, data: <String, dynamic>{'msg': 'x'});
          },
        ),
        throwsA(isA<DioException>()),
      );
      expect(badResponseCalls, 1);
      expect(autoLoginCalls, 0, reason: '非认证错误不得触发自动登录');

      var connectionCalls = 0;
      await expectLater(
        AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
          request: () async {
            connectionCalls++;
            throw DioException(
              requestOptions: RequestOptions(path: '/x'),
              type: DioExceptionType.connectionError,
            );
          },
        ),
        throwsA(isA<DioException>()),
      );
      expect(connectionCalls, 1);
      expect(autoLoginCalls, 0);
    });
  });

  test('200 非登录 HTML 原样返回，不触发自动登录', () async {
    var autoLoginCalls = 0;
    AcademicAuthGuard.debugAutomaticLoginOverride =
        (domain, {String? expectedAccount}) async {
          autoLoginCalls++;
          return AutomaticLoginOutcome.committed;
        };
    var calls = 0;

    final resp = await AcademicAuthGuard.guardRequest<String>(
      request: () async {
        calls++;
        return _response<String>(200, '<html><body>成绩查询结果</body></html>');
      },
    );

    expect(resp.statusCode, 200);
    expect(calls, 1);
    expect(autoLoginCalls, 0, reason: '非登录页不得当作过期');
  });

  test('901 响应体中的密码 / 票据标记不会出现在抛出的异常里', () async {
    const password = 'Pw-Leak-Canary';
    const ticket = 'Ticket-Leak-Canary';
    const bodyMarker = 'Response-Body-Leak-Canary';
    AcademicAuthGuard.debugAutomaticLoginReceiptOverride = (
      domain, {
      String? expectedAccount,
    }) async => _commitAcademicSession('2025000001');
    var calls = 0;
    Object? thrown;

    try {
      await AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
        request: () async {
          calls++;
          return _status901Response(
            data: <String, dynamic>{
              'code': 901,
              'message': 'password=$password ticket=$ticket body=$bodyMarker',
            },
          );
        },
      );
    } catch (error) {
      thrown = error;
    }

    expect(thrown, isA<AcademicAuthExpiredException>());
    expect(calls, 2, reason: '预算仍有界');
    final text = thrown.toString();
    for (final secret in <String>[password, ticket, bodyMarker]) {
      expect(text.contains(secret), isFalse, reason: '异常文案不得泄露响应敏感内容: $secret');
    }
  });

  // ── P1：guard 跨 await 边界的 owner/revision 追踪 ──
  group('owner/sessionRevision 边界（旧失效响应不得登出新会话）', () {
    test('首个请求期间身份已变化：fail closed，不 OCR、不重试、不登出 B', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      var autoLoginCalls = 0;
      AcademicAuthGuard.debugAutomaticLoginOverride =
          (domain, {String? expectedAccount}) async {
            autoLoginCalls++;
            return AutomaticLoginOutcome.committed;
          };
      var calls = 0;

      await expectLater(
        AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
          authExpiredException: const _Marker(),
          request: () async {
            calls++;
            // 响应返回前并发换号到 B。
            ZhengfangAuth.instance.debugSetSession(
              active: true,
              studentId: 'B',
            );
            return _status901Response();
          },
        ),
        throwsA(isA<_Marker>()),
      );

      expect(calls, 1, reason: '旧 owner 的失效响应不得重试');
      expect(autoLoginCalls, 0, reason: '旧 owner 的失效响应不得触发 OCR/自动登录');
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.currentStudentId, 'B');
    });

    test('恢复探测期间切到 B：不重试、不 OCR、不登出 B', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      var autoLoginCalls = 0;
      AcademicAuthGuard.debugAutomaticLoginOverride =
          (domain, {String? expectedAccount}) async {
            autoLoginCalls++;
            return AutomaticLoginOutcome.committed;
          };
      // 恢复探测（模式判定）期间并发换号到 B，且判定为不可达。
      ConnectModeResolver.instance.directReachabilityChecker = () async {
        ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'B');
        return false;
      };
      var calls = 0;

      await expectLater(
        AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
          authExpiredException: const _Marker(),
          request: () async {
            calls++;
            return _status901Response();
          },
        ),
        throwsA(isA<_Marker>()),
      );

      expect(calls, 1, reason: '恢复期间切号后不得重试');
      expect(autoLoginCalls, 0, reason: '恢复期间切号后不得触发 OCR/自动登录');
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.currentStudentId, 'B');
    });

    test('自动登录提交期间切到 B：guard 抛过期但绝不登出 B', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      var autoLoginCalls = 0;
      AcademicAuthGuard.debugAutomaticLoginOverride =
          (domain, {String? expectedAccount}) async {
            autoLoginCalls++;
            // 模拟并发外部换号：自动登录期间身份已切到 B。
            ZhengfangAuth.instance.debugSetSession(
              active: true,
              studentId: 'B',
            );
            return AutomaticLoginOutcome.committed;
          };
      var calls = 0;

      await expectLater(
        AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
          authExpiredException: const _Marker(),
          request: () async {
            calls++;
            return _status901Response();
          },
        ),
        throwsA(isA<_Marker>()),
      );

      expect(autoLoginCalls, 1);
      expect(calls, 1, reason: '提交结果不属于本次 owner 时不得重试');
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.currentStudentId, 'B');
    });

    test('自动登录失败但期间切到 B：guard 抛过期且不登出 B', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      AcademicAuthGuard.debugAutomaticLoginOverride =
          (domain, {String? expectedAccount}) async {
            ZhengfangAuth.instance.debugSetSession(
              active: true,
              studentId: 'B',
            );
            return AutomaticLoginOutcome.failed;
          };
      var calls = 0;

      await expectLater(
        AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
          authExpiredException: const _Marker(),
          request: () async {
            calls++;
            return _status901Response();
          },
        ),
        throwsA(isA<_Marker>()),
      );

      expect(calls, 1);
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.currentStudentId, 'B');
    });

    test('无既有 owner 时静默自动登录提交成功仍重试一次', () async {
      var autoLoginCalls = 0;
      AcademicAuthGuard.debugAutomaticLoginReceiptOverride =
          (domain, {String? expectedAccount}) async {
            autoLoginCalls++;
            expect(expectedAccount, isNull, reason: '登出态发起时无 owner');
            return _commitAcademicSession('A');
          };
      var calls = 0;

      final resp = await AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
        request: () async {
          calls++;
          return calls == 1 ? _status901Response() : _okResponse();
        },
      );

      expect(resp.statusCode, 200);
      expect(calls, 2, reason: '登出态下的合法自动登录成功后应重试一次');
      expect(autoLoginCalls, 1);
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.currentStudentId, 'A');
    });

    test('enum-only committed 无 receipt：无证据必须 fail closed，不重试不撤销', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      var autoLoginCalls = 0;
      AcademicAuthGuard.debugAutomaticLoginOverride =
          (domain, {String? expectedAccount}) async {
            autoLoginCalls++;
            return AutomaticLoginOutcome.committed;
          };
      var calls = 0;

      await expectLater(
        AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
          authExpiredException: const _Marker(),
          request: () async {
            calls++;
            return _status901Response();
          },
        ),
        throwsA(isA<_Marker>()),
      );

      expect(autoLoginCalls, 1);
      expect(calls, 1, reason: '无可信 receipt 不得发无归属 retry');
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.currentStudentId, 'A');
    });

    test('直连 901 → index 登录 HTML：无副作用探测后仍一次 OCR 提交并重试', () async {
      final adapter = MockHttpClientAdapter();
      adapter.registerText(
        'GET',
        '/jwglxt/xtgl/index_initMenu.html',
        _loginHtml,
      );
      DioClient.instance.debugUseMemoryCookieStorage = true;
      DioClient.instance.debugCookieDirectoryPathProvider = (
        folderName,
      ) async => 'jxuc_academic_guard_test/$folderName/';
      await DioClient.instance.ensureInitialized();
      DioClient.instance.dio.httpClientAdapter = adapter;
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      ConnectModeResolver.instance.directReachabilityChecker = () async => true;

      var autoLoginCalls = 0;
      AcademicAuthGuard.debugAutomaticLoginReceiptOverride =
          (domain, {String? expectedAccount}) async {
            autoLoginCalls++;
            return _commitAcademicSession('A');
          };
      var calls = 0;

      final resp = await AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
        request: () async {
          calls++;
          return calls == 1 ? _status901Response() : _okResponse();
        },
      );

      expect(resp.statusCode, 200);
      expect(calls, 2, reason: '无副作用探测后自动登录成功应重试一次');
      expect(
        autoLoginCalls,
        1,
        reason: 'validateSession 无副作用探测不得登出，guard 仍能走一次 OCR 提交',
      );
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.currentStudentId, 'A');
      expect(
        adapter.requestLog.where((r) => r.contains('index_initMenu')).length,
        1,
        reason: '恢复探测只发一次',
      );
    });

    test('receipt 后被外部换号 B：fail closed，不重试、不撤销 B，envelope 保留', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      var autoLoginCalls = 0;
      AcademicAuthGuard.debugAutomaticLoginReceiptOverride =
          (domain, {String? expectedAccount}) async {
            autoLoginCalls++;
            final aResult = await _commitAcademicSession('A');
            // 外部并发换号 B 胜出：更新 epoch + revision。
            final epoch = await AuthSessionPersistence.instance.readEpoch(
              CredentialSessionDomain.academic,
            );
            final bReceipt = await AuthSessionPersistence.instance.commit(
              CredentialSessionDomain.academic,
              account: 'B',
              expectedEpoch: epoch,
            );
            expect(bReceipt, isNotNull);
            ZhengfangAuth.instance.debugSetSession(
              active: true,
              studentId: 'B',
              forceRevision: true,
            );
            // 仍返回 A 的 receipt（声称本次提交，但已被 B 旁路）。
            return aResult;
          };
      var calls = 0;

      await expectLater(
        AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
          authExpiredException: const _Marker(),
          request: () async {
            calls++;
            return _status901Response();
          },
        ),
        throwsA(isA<_Marker>()),
      );

      expect(autoLoginCalls, 1);
      expect(calls, 1, reason: '无归属 receipt 不得重试');
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.currentStudentId, 'B');
      final envelope = await CredentialStore.instance.readSessionEnvelope(
        CredentialSessionDomain.academic,
      );
      expect(envelope.active, isTrue);
      expect(envelope.account, 'B');
    });

    test('重试期间同账号 A 并发重登：fail closed，不撤销新会话', () async {
      ZhengfangAuth.instance.debugSetSession(active: true, studentId: 'A');
      final initialEpoch = await AuthSessionPersistence.instance.readEpoch(
        CredentialSessionDomain.academic,
      );
      final initial = await AuthSessionPersistence.instance.commit(
        CredentialSessionDomain.academic,
        account: 'A',
        expectedEpoch: initialEpoch,
      );
      expect(initial, isNotNull);

      var autoLoginCalls = 0;
      AcademicAuthGuard.debugAutomaticLoginReceiptOverride =
          (domain, {String? expectedAccount}) async {
            autoLoginCalls++;
            return _commitAcademicSession('A');
          };

      final retryGate = Completer<void>();
      var calls = 0;
      final future = AcademicAuthGuard.guardRequest<Map<String, dynamic>>(
        authExpiredException: const _Marker(),
        request: () async {
          calls++;
          if (calls == 2) await retryGate.future;
          return _status901Response();
        },
      );

      while (calls < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      // 重试在途时，同账号 A 并发重登推进 epoch + revision。
      final epochNow = await AuthSessionPersistence.instance.readEpoch(
        CredentialSessionDomain.academic,
      );
      final newer = await AuthSessionPersistence.instance.commit(
        CredentialSessionDomain.academic,
        account: 'A',
        expectedEpoch: epochNow,
      );
      expect(newer, isNotNull);
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: 'A',
        forceRevision: true,
      );

      retryGate.complete();
      await expectLater(future, throwsA(isA<_Marker>()));

      expect(autoLoginCalls, 1);
      expect(calls, 2, reason: '至多一次有界重试');
      expect(ZhengfangAuth.instance.isLoggedIn, isTrue);
      expect(ZhengfangAuth.instance.currentStudentId, 'A');
      final envelope = await CredentialStore.instance.readSessionEnvelope(
        CredentialSessionDomain.academic,
      );
      expect(envelope.active, isTrue, reason: '并发同账号重登的新会话不得被撤销');
      expect(envelope.account, 'A');
      expect(envelope.epoch, newer!.epoch);
    });
  });
}

class _Marker implements Exception {
  const _Marker();
}
