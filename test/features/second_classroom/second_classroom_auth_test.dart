import 'dart:convert';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_auth.dart';

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
      expect(adapter.paths, contains('/cas/login'));
      expect(adapter.paths, contains('/dekt/'));
      expect(adapter.paths, contains('/dekt/mobile/index'));
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

SecondClassroomAuth _auth(_AuthAdapter adapter, CookieJar jar) {
  final dio = Dio(
    BaseOptions(
      followRedirects: false,
      validateStatus: (status) => status != null && status < 500,
    ),
  );
  dio.interceptors.add(CookieManager(jar));
  dio.httpClientAdapter = adapter;
  return SecondClassroomAuth(
    dio: dio,
    cookieJar: jar,
    accountProvider: () => '00213544',
    casLoggedInProvider: () => true,
    bindAuthListener: false,
  );
}

enum _CasMode { ticket, loginPage }

class _AuthAdapter implements HttpClientAdapter {
  _AuthAdapter({
    this.casMode = _CasMode.ticket,
    this.probeLogin = true,
    this.probeUserId = '00213544',
    this.throwOnCas = false,
  });

  final _CasMode casMode;
  final bool probeLogin;
  final String probeUserId;
  final bool throwOnCas;
  final List<String> paths = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.uri.path);
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

    if (options.uri.path == '/dekt/mobile/index') {
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

  @override
  void close({bool force = false}) {}
}
