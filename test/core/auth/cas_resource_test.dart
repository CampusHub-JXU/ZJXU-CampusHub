import 'dart:async';
import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';

import '../../helpers/mock_http_client_adapter.dart';

const _cmsOwner = '1062118769';
const _cmsCallback =
    'http://jwc.zjxu.edu.cn/system/resource/code/auth/clogin.jsp?owner=$_cmsOwner';

void main() {
  test(
    'CMS callback receives ticket; original resource reuses target cookie',
    () async {
      final adapter = MockHttpClientAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(CookieManager(CookieJar()));
      const resource = 'https://jwc.zjxu.edu.cn/list.jsp';
      const callback = _cmsCallback;
      final cas = Uri.https('newca.zjxu.edu.cn', '/cas/login', {
        'service': callback,
      });
      adapter.register('GET', '/list.jsp', (request) async {
        if ((request.headers['cookie'] ?? '').toString().contains(
          'cms=ready',
        )) {
          return ResponseBody.fromString('<ul id="ul1"></ul>', 200);
        }
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': [cas.toString()],
          },
        );
      });
      adapter.register('GET', '/cas/login', (request) async {
        expect(request.uri.queryParameters['service'], callback);
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['$callback&ticket=ST-test'],
          },
        );
      });
      adapter.register('GET', '/system/resource/code/auth/clogin.jsp', (
        request,
      ) async {
        expect(request.uri.queryParameters['ticket'], 'ST-test');
        return ResponseBody.fromString(
          '<script>location.href="$resource";</script>',
          200,
          headers: {
            'set-cookie': ['cms=ready; Path=/; HttpOnly'],
          },
        );
      });
      final result = await CasAuthBroker.getResource(resource, dio: dio);
      expect(utf8.decode(result.data!), contains('ul1'));
      final exchanges = adapter.requestLog
          .where((r) => r == 'GET /cas/login')
          .length;
      await CasAuthBroker.getResource(resource, dio: dio);
      expect(
        adapter.requestLog.where((r) => r == 'GET /cas/login').length,
        exchanges,
      );
    },
  );

  test(
    'a real login form requires auth without submitting credentials',
    () async {
      final adapter = MockHttpClientAdapter()
        ..registerText(
          'GET',
          '/list',
          '',
          statusCode: 302,
          headers: {
            'location': ['https://newca.zjxu.edu.cn/cas/login'],
          },
        )
        ..registerText('GET', '/cas/login', '<form id="fm1"></form>');
      final dio = Dio()..httpClientAdapter = adapter;
      await expectLater(
        CasAuthBroker.getResource('https://jwc.zjxu.edu.cn/list', dio: dio),
        throwsA(isA<CasAuthExpiredException>()),
      );
      expect(adapter.requestLog.every((r) => r.startsWith('GET ')), isTrue);
    },
  );

  test('redirect loop is bounded', () async {
    final adapter = MockHttpClientAdapter()
      ..registerText(
        'GET',
        '/loop',
        '',
        statusCode: 302,
        headers: {
          'location': ['/loop'],
        },
      );
    await expectLater(
      CasAuthBroker.getResource(
        'https://jwc.zjxu.edu.cn/loop',
        dio: Dio()..httpClientAdapter = adapter,
      ),
      throwsStateError,
    );
    expect(adapter.requestLog, hasLength(16));
  });

  test('HTTP server failure cannot become a valid page', () async {
    final adapter = MockHttpClientAdapter()
      ..registerText('GET', '/list', '<ul id="ul1"></ul>', statusCode: 500);
    await expectLater(
      CasAuthBroker.getResource(
        'https://jwc.zjxu.edu.cn/list',
        dio: Dio()..httpClientAdapter = adapter,
      ),
      throwsA(isA<DioException>()),
    );
  });

  test('WebVPN CAS proxy is exchanged through real CAS origin', () async {
    const proxy =
        '/http/77726476706e69737468656265737421fef2569f267e725a661dc7a99c406d362a/cas/login';
    final adapter = MockHttpClientAdapter()
      ..registerText(
        'GET',
        '/resource',
        '',
        statusCode: 302,
        headers: {
          'location': [
            'https://webvpn.zjxu.edu.cn$proxy?service=https%3A%2F%2Fwebvpn.zjxu.edu.cn%2Flogin%3Fcas_login%3Dtrue',
          ],
        },
      );
    adapter.register('GET', '/cas/login', (request) async {
      expect(request.uri.host, 'newca.zjxu.edu.cn');
      expect(
        request.uri.queryParameters['service'],
        CasService.webVpnGateway.serviceUrl,
      );
      return ResponseBody.fromString('<form id="fm1"></form>', 200);
    });
    await expectLater(
      CasAuthBroker.getResource(
        'https://sjjx.zjxu.edu.cn/resource',
        dio: Dio()..httpClientAdapter = adapter,
      ),
      throwsA(isA<CasAuthExpiredException>()),
    );
  });

  test(
    'shared deadline cancels the in-flight hop instead of Future.timeout',
    () async {
      final pending = Completer<ResponseBody>();
      CancelToken? seenToken;
      final adapter = MockHttpClientAdapter()
        ..register('GET', '/list.jsp', (options) {
          seenToken = options.cancelToken;
          return pending.future;
        });
      final future = CasAuthBroker.getResource(
        'https://jwc.zjxu.edu.cn/list.jsp',
        dio: Dio()..httpClientAdapter = adapter,
        timeout: const Duration(milliseconds: 40),
      );
      await expectLater(
        future,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(seenToken?.isCancelled, isTrue);
      pending.complete(ResponseBody.fromString('late', 200));
    },
  );

  test('caller cancel token stops later hops', () async {
    final cancelToken = CancelToken();
    var hops = 0;
    final adapter = MockHttpClientAdapter()
      ..register('GET', '/list.jsp', (options) async {
        hops++;
        expect(options.cancelToken, same(cancelToken));
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': [_cmsCallback],
          },
        );
      })
      ..register('GET', '/system/resource/code/auth/clogin.jsp', (
        options,
      ) async {
        hops++;
        expect(options.cancelToken, same(cancelToken));
        cancelToken.cancel('stop after callback');
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': [
              'https://newca.zjxu.edu.cn/cas/login?service=${Uri.encodeQueryComponent(_cmsCallback)}',
            ],
          },
        );
      });
    await expectLater(
      CasAuthBroker.getResource(
        'https://jwc.zjxu.edu.cn/list.jsp',
        dio: Dio()..httpClientAdapter = adapter,
        cancelToken: cancelToken,
      ),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect(hops, 2);
    expect(adapter.requestLog.where((r) => r == 'GET /cas/login'), isEmpty);
  });

  test('injected deadline is shared across hops for a preselected URL', () async {
    final deadline = DateTime.now().add(const Duration(milliseconds: 80));
    final adapter = MockHttpClientAdapter()
      ..register('GET', '/list.jsp', (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': [_cmsCallback],
          },
        );
      })
      ..register('GET', '/system/resource/code/auth/clogin.jsp', (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': [
              'https://newca.zjxu.edu.cn/cas/login?service=${Uri.encodeQueryComponent(_cmsCallback)}',
            ],
          },
        );
      })
      ..register('GET', '/cas/login', (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        return ResponseBody.fromString('<form id="fm1"></form>', 200);
      });
    await expectLater(
      CasAuthBroker.getResource(
        'https://jwc.zjxu.edu.cn/list.jsp',
        dio: Dio()..httpClientAdapter = adapter,
        deadline: deadline,
      ),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
  });
}
