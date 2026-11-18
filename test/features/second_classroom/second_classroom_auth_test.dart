import 'dart:convert';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_auth.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_route.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_service.dart';

const _gateway = 'https://webvpn.zjxu.edu.cn';
const _proxyPrefix =
    '/http/'
    '77726476706e69737468656265737421e4e045992c24264a74109ce29d51367bc8e6';

void main() {
  test('uses the verified /dekt/ CAS service', () {
    expect(
      CasService.secondClassroom.serviceUrl,
      'https://twdekt.zjxu.edu.cn/dekt/',
    );
    expect(
      SecondClassroomAuth.serviceUrl,
      CasService.secondClassroom.serviceUrl,
    );
  });

  test(
    'authenticates only after ticket consumption and identity probe',
    () async {
      final adapter = _AuthAdapter();
      final jar = CookieJar();
      final auth = _auth(adapter, jar);

      final state = await auth.ensureSession();

      expect(state, SecondClassroomAuthState.authenticated);
      expect(auth.isAuthenticated, isTrue);
      expect(auth.authenticatedRoute, SecondClassroomRoute.direct);
      expect(adapter.paths, contains('/cas/login'));
      expect(adapter.paths, contains('/dekt/'));
      expect(adapter.paths, contains('/dekt/mobile/index'));
    },
  );

  test(
    'consumes the off-campus ticket and sends business requests via WebVPN',
    () async {
      final adapter = _AuthAdapter(
        ticketRedirect: '$_gateway$_proxyPrefix//dekt/',
      );
      final jar = CookieJar();
      await jar.saveFromResponse(Uri.parse(_gateway), [
        Cookie('wengine_vpn_ticket', 'gateway-test')..path = '/',
      ]);
      final dio = _dio(adapter, jar);
      final auth = _auth(adapter, jar, dio: dio);

      expect(
        await auth.ensureSession(),
        SecondClassroomAuthState.authenticated,
      );
      expect(auth.authenticatedRoute, SecondClassroomRoute.webVpn);
      expect(adapter.paths, [
        '/cas/login',
        '/dekt/',
        '$_proxyPrefix//dekt/',
        '$_proxyPrefix//dekt/mobile/index',
      ]);
      final callback = adapter.requests[2];
      expect(callback.uri.queryParameters['ticket'], 'ST-test-ticket');
      expect(callback.headers['cookie'], contains('wengine_vpn_ticket='));

      await SecondClassroomService(dio: dio, auth: auth).fetchCatalog();
      final request = adapter.requests.last;
      expect(
        request.uri.toString(),
        '$_gateway$_proxyPrefix//dekt/mobile/hdList',
      );
      expect(request.headers['Origin'], _gateway);
      expect(
        request.headers['Referer'],
        '$_gateway$_proxyPrefix//dekt/wx/index?_WXFTL=0',
      );
      expect(request.headers['cookie'], contains('SESSION=test-vpn-session'));

      await auth.clearSession();
      expect(
        (await jar.loadForRequest(request.uri)).map((cookie) => cookie.name),
        ['wengine_vpn_ticket'],
      );
    },
  );

  test(
    'gets a fresh ticket when the direct probe redirects to WebVPN',
    () async {
      final adapter = _AuthAdapter(redirectDirectProbe: true);
      final auth = _auth(adapter, CookieJar());

      expect(
        await auth.ensureSession(),
        SecondClassroomAuthState.authenticated,
      );
      expect(auth.authenticatedRoute, SecondClassroomRoute.webVpn);
      expect(adapter.paths, [
        '/cas/login',
        '/dekt/',
        '/dekt/mobile/index',
        '/cas/login',
        '$_proxyPrefix//dekt/',
        '$_proxyPrefix//dekt/mobile/index',
      ]);
    },
  );

  test('never follows another WebVPN wrapper with the CAS ticket', () async {
    final adapter = _AuthAdapter(ticketRedirect: '$_gateway/http/other//dekt/');
    final auth = _auth(adapter, CookieJar());

    expect(await auth.ensureSession(), SecondClassroomAuthState.failed);
    expect(adapter.paths, ['/cas/login', '/dekt/']);
  });

  test(
    'reports unavailable when the WebVPN portal bounce cannot recover',
    () async {
      final adapter = _AuthAdapter(
        ticketRedirect: '$_gateway$_proxyPrefix//dekt/',
        gatewayUnavailable: true,
      );
      final auth = _auth(adapter, CookieJar());

      expect(await auth.ensureSession(), SecondClassroomAuthState.unavailable);
      expect(auth.authenticatedRoute, isNull);
      expect(adapter.paths, [
        '/cas/login',
        '/dekt/',
        '$_proxyPrefix//dekt/',
        '/login',
      ]);
      expect(adapter.requests.last.uri.query, 'cas_login=true');
    },
  );

  test('returns needsLogin when CAS still serves the login page', () async {
    final adapter = _AuthAdapter(casMode: _CasMode.loginPage);
    final jar = CookieJar();
    final auth = _auth(adapter, jar);

    final state = await auth.ensureSession();

    expect(state, SecondClassroomAuthState.needsLogin);
    expect(auth.isAuthenticated, isFalse);
    expect(adapter.paths, isNot(contains('/dekt/')));
  });

  test(
    'treats login:false as needsLogin and clears the twdekt cookie',
    () async {
      final adapter = _AuthAdapter(probeLogin: false);
      final jar = CookieJar();
      final auth = _auth(adapter, jar);

      final state = await auth.ensureSession();

      expect(state, SecondClassroomAuthState.needsLogin);
      expect(
        await jar.loadForRequest(Uri.parse('https://twdekt.zjxu.edu.cn/dekt/')),
        isEmpty,
      );
    },
  );

  test('rejects a second-classroom identity that differs from CAS', () async {
    final adapter = _AuthAdapter(probeUserId: '99999999');
    final jar = CookieJar();
    final auth = _auth(adapter, jar);

    final state = await auth.ensureSession();

    expect(state, SecondClassroomAuthState.identityMismatch);
    expect(auth.isAuthenticated, isFalse);
    expect(
      await jar.loadForRequest(Uri.parse('https://twdekt.zjxu.edu.cn/dekt/')),
      isEmpty,
    );
  });

  test(
    'keeps the session cookie and reports unavailable on network error',
    () async {
      final adapter = _AuthAdapter(throwOnCas: true);
      final jar = CookieJar();
      final auth = _auth(adapter, jar);

      final state = await auth.ensureSession();

      expect(state, SecondClassroomAuthState.unavailable);
      expect(auth.isAuthenticated, isFalse);
    },
  );
}

SecondClassroomAuth _auth(_AuthAdapter adapter, CookieJar jar, {Dio? dio}) {
  return SecondClassroomAuth(
    dio: dio ?? _dio(adapter, jar),
    cookieJar: jar,
    accountProvider: () => '00213544',
    casLoggedInProvider: () => true,
    bindAuthListener: false,
  );
}

Dio _dio(_AuthAdapter adapter, CookieJar jar) {
  final dio = Dio(
    BaseOptions(
      followRedirects: false,
      validateStatus: (status) => status != null && status < 500,
    ),
  );
  dio.interceptors.add(CookieManager(jar));
  dio.httpClientAdapter = adapter;
  return dio;
}

enum _CasMode { ticket, loginPage }

class _AuthAdapter implements HttpClientAdapter {
  _AuthAdapter({
    this.casMode = _CasMode.ticket,
    this.probeLogin = true,
    this.probeUserId = '00213544',
    this.throwOnCas = false,
    this.ticketRedirect,
    this.redirectDirectProbe = false,
    this.gatewayUnavailable = false,
  });

  final _CasMode casMode;
  final bool probeLogin;
  final String probeUserId;
  final bool throwOnCas;
  final String? ticketRedirect;
  final bool redirectDirectProbe;
  final bool gatewayUnavailable;
  final requests = <RequestOptions>[];
  List<String> get paths =>
      requests.map((request) => request.uri.path).toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.uri.host == 'newca.zjxu.edu.cn') {
      if (throwOnCas) {
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'offline',
        );
      }
      if (casMode == _CasMode.loginPage) {
        return ResponseBody.fromString(
          '<html><body>统一身份认证平台 <input name="execution" value="x"></body></html>',
          200,
          headers: {
            'content-type': ['text/html; charset=utf-8'],
          },
        );
      }
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': [
            'https://twdekt.zjxu.edu.cn/dekt/?ticket=ST-test-ticket',
          ],
        },
      );
    }

    if (options.uri.host == 'twdekt.zjxu.edu.cn' &&
        options.uri.path == '/dekt/') {
      final location = ticketRedirect;
      if (location != null) return _redirect('$location?${options.uri.query}');
      return ResponseBody.fromString(
        '<html>second classroom</html>',
        200,
        headers: {
          'content-type': ['text/html; charset=utf-8'],
          'set-cookie': [
            'SESSION=test-session; Path=/dekt; HttpOnly; SameSite=Lax',
          ],
        },
      );
    }

    if (options.uri.path == '$_proxyPrefix//dekt/') {
      if (gatewayUnavailable) return _redirect('$_gateway/m/portal');
      return ResponseBody.fromString(
        '<html>second classroom</html>',
        200,
        headers: {
          'set-cookie': ['SESSION=test-vpn-session; Path=$_proxyPrefix//dekt'],
        },
      );
    }

    if (gatewayUnavailable && options.uri.path == '/login') {
      return ResponseBody.fromString('service unavailable', 503);
    }

    if (options.uri.path == '/dekt/mobile/index' && redirectDirectProbe) {
      return _redirect('$_gateway$_proxyPrefix//dekt/mobile/index');
    }

    if (options.uri.path.endsWith('/dekt/mobile/index')) {
      return ResponseBody.fromString(
        jsonEncode({
          'code': 0,
          'extend': {
            'login': probeLogin,
            'userId': probeUserId,
            'userSource': 'STUDENT',
          },
        }),
        200,
        headers: {
          'content-type': ['application/json; charset=utf-8'],
        },
      );
    }

    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );
  }

  ResponseBody _redirect(String location) => ResponseBody.fromString(
    '',
    302,
    headers: {
      'location': [location],
    },
  );

  @override
  void close({bool force = false}) {}
}
