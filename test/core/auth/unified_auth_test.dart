import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/auth_failure.dart';
import 'package:jxu_campus_hub/core/auth/credential_store.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';
import 'package:jxu_campus_hub/core/network/proxy_mode.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/mock_http_client_adapter.dart';

void main() {
  group('Unified auth url classifiers', () {
    test('treats CAS login pages as unauthenticated entry pages', () {
      expect(
        isUnifiedAuthLoginEntryUrl(
          'https://newca.zjxu.edu.cn/cas/login?service=https://mobilehall.zjxu.edu.cn',
        ),
        isTrue,
      );
      expect(
        isUnifiedAuthLoginEntryUrl(
          '/cas/login?service=https://mobilehall.zjxu.edu.cn',
        ),
        isTrue,
      );
      expect(
        isUnifiedAuthAuthenticatedUrl(
          'https://newca.zjxu.edu.cn/cas/login?service=https://mobilehall.zjxu.edu.cn',
        ),
        isFalse,
      );
    });

    test('treats downstream service pages as authenticated destinations', () {
      expect(
        isUnifiedAuthAuthenticatedUrl(
          'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home',
        ),
        isTrue,
      );
      expect(
        isUnifiedAuthAuthenticatedUrl(
          'https://newca.zjxu.edu.cn/casClient/login/ydd?ticket=abc',
        ),
        isTrue,
      );
      expect(
        isUnifiedAuthAuthenticatedUrl(
          'https://libapp.zjxu.edu.cn/Info/Thirdparty/ssoFromDingDing?ticket=abc',
        ),
        isTrue,
      );
      expect(
        isUnifiedAuthAuthenticatedUrl('/casClient/login/ydd?ticket=abc'),
        isTrue,
      );
    });

    test('extracts downstream service url from CAS login pages', () {
      expect(
        extractUnifiedAuthServiceUrl(
          'https://newca.zjxu.edu.cn/cas/login?service=https%3A%2F%2Flibapp.zjxu.edu.cn%2FInfo%2FThirdparty%2FssoFromDingDing',
        ),
        'https://libapp.zjxu.edu.cn/Info/Thirdparty/ssoFromDingDing',
      );
      expect(
        extractUnifiedAuthServiceUrl(
          'https://newca.zjxu.edu.cn/cas/login?service=https%3A%2F%2Fnewca.zjxu.edu.cn%2FcasClient%2Flogin%2Fydd',
        ),
        'https://newca.zjxu.edu.cn/casClient/login/ydd',
      );
      expect(
        extractUnifiedAuthServiceUrl(
          'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home',
        ),
        isNull,
      );
    });

    test('detects CAS service ticket in redirect URL', () {
      expect(
        urlHasCasTicket(
          'https://jwc.zjxu.edu.cn/list.jsp?urltype=tree.TreeTempUrl&wbtreeid=1046&ticket=ST-1-test',
        ),
        isTrue,
      );
      expect(
        urlHasCasTicket(
          'https://newca.zjxu.edu.cn/casClient/login/ydd?ticket=ST-2-test',
        ),
        isTrue,
      );
      expect(
        urlHasCasTicket(
          'https://jwc.zjxu.edu.cn/list.jsp?urltype=tree.TreeTempUrl&wbtreeid=1046',
        ),
        isFalse,
      );
      expect(urlHasCasTicket(''), isFalse);
      expect(
        urlHasCasTicket('https://example.com/page?ticket=not-a-cas-ticket'),
        isFalse,
      );
    });
  });

  group('Unified auth login html detection', () {
    test('detects CAS login form markup', () {
      expect(
        looksLikeUnifiedAuthLoginHtml('''
          <html>
            <form id="fm1">
              <input type="hidden" name="lt" value="LT-1" />
              <input type="hidden" name="execution" value="e1s1" />
            </form>
          </html>
        '''),
        isTrue,
      );
    });

    test('ignores downstream service html', () {
      expect(
        looksLikeUnifiedAuthLoginHtml('<html><body>欢迎进入服务大厅</body></html>'),
        isFalse,
      );
    });
  });

  group('Unified auth login result parsing', () {
    test('accepts a WebVPN service redirect carrying a CAS ticket', () {
      expect(
        UnifiedAuthService.instance.isLoginSuccess(
          302,
          'https://webvpn.zjxu.edu.cn/login?cas_login=true&ticket=ST-1-test',
          '',
        ),
        isTrue,
      );
    });

    test('rejects a WebVPN redirect without a CAS ticket', () {
      expect(
        UnifiedAuthService.instance.isLoginSuccess(
          302,
          'https://webvpn.zjxu.edu.cn/login?cas_login=true',
          '',
        ),
        isFalse,
      );
    });

    test('prefers the real password error over captcha form labels', () {
      expect(
        UnifiedAuthService.instance.extractLoginFailureMessage(
          '<div>验证码</div><span>用户名或密码错误!</span>',
        ),
        '一卡通账号或密码错误，请检查后重试',
      );
    });

    test('recognizes an explicit captcha error', () {
      expect(
        UnifiedAuthService.instance.extractLoginFailureMessage(
          '<span>验证码错误!</span>',
        ),
        '验证码错误或已过期，请刷新后重试',
      );
    });
  });

  group('UnifiedAuthService session short-circuit', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      UnifiedAuthService.instance.debugReset();
    });

    test(
      'prepareLogin returns true immediately when session is active',
      () async {
        UnifiedAuthService.instance.debugSetSession(
          active: true,
          account: '1234567890',
        );
        expect(UnifiedAuthService.instance.isLoggedIn, isTrue);

        final result = await UnifiedAuthService.instance.prepareLogin();
        expect(result, isTrue);
      },
    );

    test('isLoggedIn is false after debugReset', () {
      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
    });

    test('debug session tracks account independently', () {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '00213544',
      );

      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      expect(UnifiedAuthService.instance.currentAccount, '00213544');

      UnifiedAuthService.instance.debugReset();

      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
      expect(UnifiedAuthService.instance.currentAccount, isNull);
    });

    test('active session without account is not logged in', () {
      UnifiedAuthService.instance.debugSetSession(active: true);
      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
      expect(UnifiedAuthService.instance.currentAccount, isNull);
    });

    test(
      'coalesces concurrent validation independently for each service',
      () async {
        final pending = <String, Completer<bool?>>{};
        final calls = <String, int>{};
        UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
        UnifiedAuthService.instance.debugSessionValidator = (serviceUrl) {
          calls[serviceUrl] = (calls[serviceUrl] ?? 0) + 1;
          return (pending[serviceUrl] ??= Completer<bool?>()).future;
        };

        final a1 = UnifiedAuthService.instance.validateSession(serviceUrl: 'A');
        final b = UnifiedAuthService.instance.validateSession(serviceUrl: 'B');
        final a2 = UnifiedAuthService.instance.validateSession(serviceUrl: 'A');

        expect(calls, {'A': 1, 'B': 1});
        pending['A']!.complete(true);
        pending['B']!.complete(true);
        expect(await Future.wait([a1, a2, b]), [true, true, true]);
      },
    );

    test('validator exceptions become unknown instead of escaping', () async {
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      UnifiedAuthService.instance.debugSessionValidator = (_) async {
        throw StateError('initialization failed');
      };

      final result = await UnifiedAuthService.instance.validateSession();

      expect(result, isNull);
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
    });

    test(
      'validateSession does not promote a blank account to logged in',
      () async {
        UnifiedAuthService.instance.debugSetSession(active: true);
        UnifiedAuthService.instance.debugSessionValidator = (_) async => true;

        expect(await UnifiedAuthService.instance.validateSession(), isFalse);
        expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
        expect(UnifiedAuthService.instance.currentAccount, isNull);
      },
    );

    test('current-identity failed validation still logs out', () async {
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      UnifiedAuthService.instance.debugSessionValidator = (_) async => false;

      expect(await UnifiedAuthService.instance.validateSession(), isFalse);
      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
      expect(UnifiedAuthService.instance.currentAccount, isNull);
    });

    test('stale failed validation must not log out a newer identity', () async {
      final gate = Completer<bool?>();
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      UnifiedAuthService.instance.debugSessionValidator = (_) => gate.future;

      final pending = UnifiedAuthService.instance.validateSession();
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
      gate.complete(false);

      expect(await pending, isNull);
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      expect(UnifiedAuthService.instance.currentAccount, 'B');
    });

    test(
      'stale successful validation must not revive a logged-out session',
      () async {
        final gate = Completer<bool?>();
        UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
        UnifiedAuthService.instance.debugSessionValidator = (_) => gate.future;

        final pending = UnifiedAuthService.instance.validateSession();
        await UnifiedAuthService.instance.markLoggedOut();
        gate.complete(true);

        expect(await pending, isNull);
        expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
        expect(UnifiedAuthService.instance.currentAccount, isNull);
      },
    );

    test(
      'stale successful validation must not rewrite a newer identity',
      () async {
        final gate = Completer<bool?>();
        UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
        UnifiedAuthService.instance.debugSessionValidator = (_) => gate.future;

        final pending = UnifiedAuthService.instance.validateSession();
        UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
        gate.complete(true);

        expect(await pending, isNull);
        expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
        expect(UnifiedAuthService.instance.currentAccount, 'B');
      },
    );

    test(
      'same service does not reuse a pending validation after identity change',
      () async {
        final pending = <Completer<bool?>>[];
        var calls = 0;
        UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
        UnifiedAuthService.instance.debugSessionValidator = (_) {
          calls++;
          final completer = Completer<bool?>();
          pending.add(completer);
          return completer.future;
        };

        final first = UnifiedAuthService.instance.validateSession(
          serviceUrl: 'svc',
        );
        UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
        final second = UnifiedAuthService.instance.validateSession(
          serviceUrl: 'svc',
        );
        expect(calls, 2);

        // 旧校验清理不得删掉新身份的 in-flight future。
        pending[0].complete(false);
        expect(await first, isNull);
        final third = UnifiedAuthService.instance.validateSession(
          serviceUrl: 'svc',
        );
        expect(calls, 2);

        pending[1].complete(true);
        expect(await second, isTrue);
        expect(await third, isTrue);
        expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
        expect(UnifiedAuthService.instance.currentAccount, 'B');
      },
    );
  });

  group('UnifiedAuthService redirect chain', () {
    late Directory cookieDirectory;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      UnifiedAuthService.instance.debugReset();
      NetworkSettings.instance.debugReset();
      DioClient.instance.debugReset();
      cookieDirectory = await Directory.systemTemp.createTemp(
        'unified_auth_redirect_test_',
      );
      DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async {
        return '${cookieDirectory.path}/$folderName/';
      };
      await DioClient.instance.ensureInitialized();
    });

    tearDown(() async {
      debugSystemProxyLookup = null;
      UnifiedAuthService.instance.debugReset();
      DioClient.instance.debugReset();
      NetworkSettings.instance.debugReset();
      if (await cookieDirectory.exists()) {
        await cookieDirectory.delete(recursive: true);
      }
    });

    test('requests downstream ticket URL before confirming session', () async {
      const serviceUrl = 'https://webvpn.zjxu.edu.cn/login?cas_login=true';
      const ticketUrl =
          'https://webvpn.zjxu.edu.cn/login?cas_login=true&ticket=ST-1-test';
      final requestedUris = <Uri>[];
      final adapter = MockHttpClientAdapter()
        ..register('GET', '/cas/login', (options) async {
          requestedUris.add(options.uri);
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': [ticketUrl],
            },
          );
        })
        ..register('GET', '/login', (options) async {
          requestedUris.add(options.uri);
          return ResponseBody.fromString(
            '<html><body>WebVPN session ready</body></html>',
            200,
          );
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'test-account',
      );

      final result = await UnifiedAuthService.instance.validateSession(
        serviceUrl: serviceUrl,
        syncWebViewCookies: false,
      );

      expect(result, isTrue);
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      expect(
        requestedUris,
        contains(
          isA<Uri>()
              .having((uri) => uri.host, 'host', 'webvpn.zjxu.edu.cn')
              .having((uri) => uri.path, 'path', '/login')
              .having(
                (uri) => uri.queryParameters['ticket'],
                'ticket',
                'ST-1-test',
              ),
        ),
      );
      expect(adapter.requestLog, ['GET /cas/login', 'GET /login']);
    });

    test(
      'cancels timed out transport instead of leaving the request alive',
      () async {
        await NetworkSettings.instance.setIgnoreSystemProxy(false);
        final pending = Completer<ResponseBody>();
        final started = Completer<CancelToken>();
        final adapter = MockHttpClientAdapter()
          ..register('GET', '/cas/login', (options) {
            started.complete(options.cancelToken!);
            return pending.future;
          });
        DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
        final result = expectLater(
          UnifiedAuthService.instance.prepareLogin(),
          throwsA(isA<TimeoutException>()),
        );
        final token = await started.future;
        await result;
        expect(token.isCancelled, isTrue);
        pending.complete(ResponseBody.fromString('late response', 200));
      },
    );

    test('caller cancellation stops CAS without proxy retry', () async {
      debugSystemProxyLookup = (_) async => 'PROXY 127.0.0.1:8888';
      final pending = Completer<ResponseBody>();
      final started = Completer<CancelToken>();
      final adapter = MockHttpClientAdapter()
        ..register('GET', '/cas/login', (options) {
          started.complete(options.cancelToken!);
          return pending.future;
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
      UnifiedAuthService.instance.debugProxyFallbackAdapter = adapter;
      final cancelToken = CancelToken();
      final result = expectLater(
        UnifiedAuthService.instance.prepareLogin(cancelToken: cancelToken),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      final transportToken = await started.future;
      cancelToken.cancel('page closed');
      await result;
      expect(transportToken.isCancelled, isTrue);
      expect(adapter.requestLog, ['GET /cas/login']);
      pending.complete(ResponseBody.fromString('late response', 200));
    });

    test(
      'does not retry the same DIRECT request when no proxy matches',
      () async {
        final seen = <Uri>[];
        debugSystemProxyLookup = (uri) async {
          seen.add(uri);
          return 'DIRECT';
        };
        final adapter = MockHttpClientAdapter()
          ..register('GET', '/cas/login', (options) async {
            throw const SocketException('Failed host lookup');
          });
        DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
        UnifiedAuthService.instance.debugProxyFallbackAdapter = adapter;

        await expectLater(
          UnifiedAuthService.instance.prepareLogin(),
          throwsA(isA<DioException>()),
        );

        expect(adapter.requestLog, ['GET /cas/login']);
        expect(seen, isNotEmpty);
        expect(seen.first.host, 'newca.zjxu.edu.cn');
      },
    );

    test('retries only when the request uri has a non-DIRECT proxy', () async {
      debugSystemProxyLookup = (uri) async {
        if (uri.host == 'newca.zjxu.edu.cn') {
          return 'PROXY 127.0.0.1:8888';
        }
        return 'DIRECT';
      };
      var calls = 0;
      final adapter = MockHttpClientAdapter()
        ..register('GET', '/cas/login', (options) async {
          calls++;
          if (calls == 1) {
            throw const SocketException('Failed host lookup');
          }
          return ResponseBody.fromString(
            '<html><body>CAS login</body></html>',
            200,
            headers: {
              'set-cookie': [
                'CASTGC=ticket-1; Path=/cas; Domain=newca.zjxu.edu.cn',
              ],
            },
          );
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
      UnifiedAuthService.instance.debugProxyFallbackAdapter = adapter;

      await UnifiedAuthService.instance.prepareLogin();

      expect(adapter.requestLog, ['GET /cas/login', 'GET /cas/login']);
      final unifiedCookies = await DioClient.instance.unifiedAuthCookieJar
          .loadForRequest(Uri.parse('https://newca.zjxu.edu.cn/cas/login'));
      final zhengfangCookies = await DioClient.instance.zhengfangCookieJar
          .loadForRequest(Uri.parse('https://newca.zjxu.edu.cn/cas/login'));
      expect(unifiedCookies.map((cookie) => cookie.name), contains('CASTGC'));
      expect(zhengfangCookies, isEmpty);
    });

    test(
      'respects NO_PROXY for the actual target instead of a CAS probe host',
      () async {
        debugSystemProxyLookup = (uri) async {
          if (uri.host == 'newca.zjxu.edu.cn') return 'DIRECT';
          return 'PROXY 127.0.0.1:8888';
        };
        final adapter = MockHttpClientAdapter()
          ..register('GET', '/cas/login', (options) async {
            throw const SocketException('Failed host lookup');
          });
        DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
        UnifiedAuthService.instance.debugProxyFallbackAdapter = adapter;

        await expectLater(
          UnifiedAuthService.instance.prepareLogin(),
          throwsA(isA<DioException>()),
        );

        expect(adapter.requestLog, ['GET /cas/login']);
      },
    );

    test('does not treat HTTP 500 as an active session', () async {
      final adapter = MockHttpClientAdapter()
        ..register('GET', '/cas/login', (options) async {
          return ResponseBody.fromString('server error', 500);
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'test-account',
      );

      final result = await UnifiedAuthService.instance.validateSession(
        syncWebViewCookies: false,
      );

      expect(result, isFalse);
      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
    });

    test(
      'prepareLogin restores trusted session metadata without guessing',
      () async {
        await CredentialStore.instance.saveUnifiedAuthSession('A');

        final result = await UnifiedAuthService.instance.prepareLogin();

        expect(result, isTrue);
        expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
        expect(UnifiedAuthService.instance.currentAccount, 'A');
      },
    );

    test('login 无当前 challenge：拒绝为过期且不绑定输入账号', () async {
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');

      final switched = await UnifiedAuthService.instance.login(
        'B',
        'unused',
        'unused',
      );
      expect(switched, isA<UnifiedAuthLoginFailure>());
      expect(
        (switched as UnifiedAuthLoginFailure).kind,
        AuthFailureKind.staleOperation,
      );
      // 未重新初始化上下文、未改写身份，也未把输入账号绑到旧 session。
      expect(UnifiedAuthService.instance.currentAccount, 'A');
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
    });

    test('login 无当前 challenge 等待 restore 时迟到 restore 不得覆盖新身份', () async {
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');

      final started = Completer<void>();
      final loadGate = Completer<void>();
      UnifiedAuthService.instance.debugSessionMetadataLoader = () async {
        if (!started.isCompleted) started.complete();
        await loadGate.future;
        return 'STALE';
      };
      final restore = UnifiedAuthService.instance.restoreSession(
        syncWebViewCookies: false,
      );
      await started.future;

      UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
      loadGate.complete();
      await restore;

      expect(UnifiedAuthService.instance.currentAccount, 'B');
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
    });

    test(
      'orphan CAS cookie without metadata must yield a submit form',
      () async {
        const loginHtml = '''
          <html>
            <form id="fm1" action="/cas/login">
              <input type="hidden" name="lt" value="LT-1" />
              <input type="hidden" name="execution" value="e1s1" />
            </form>
          </html>
        ''';
        final adapter = MockHttpClientAdapter()
          ..register('GET', '/cas/login', (options) async {
            return ResponseBody.fromString(loginHtml, 200);
          });
        DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
        final jar = DioClient.instance.unifiedAuthCookieJar;
        final casUri = Uri.parse('https://newca.zjxu.edu.cn/cas/login');
        final hallUri = Uri.parse('https://mobilehall.zjxu.edu.cn/');
        await jar.saveFromResponse(casUri, [
          Cookie('CASTGC', 'orphan-ticket')..path = '/cas',
          Cookie('JSESSIONID', 'cas-session')..path = '/',
          Cookie('CASTGC', 'domain-tgc')
            ..domain = 'newca.zjxu.edu.cn'
            ..path = '/cas',
        ]);
        await jar.saveFromResponse(hallUri, [
          Cookie('FR_SESSION', 'hall-session')..path = '/',
        ]);
        await jar.saveFromResponse(casUri, [
          Cookie('CAMPUS_SHARED', 'keep-me')
            ..domain = '.zjxu.edu.cn'
            ..path = '/',
        ]);

        final prepared = await UnifiedAuthService.instance.prepareLogin();
        expect(prepared, isFalse);
        expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
        expect(UnifiedAuthService.instance.currentAccount, isNull);

        final casCookies = await jar.loadForRequest(casUri);
        expect(
          casCookies.map((cookie) => cookie.name),
          isNot(contains('CASTGC')),
        );
        expect(
          casCookies.map((cookie) => cookie.name),
          isNot(contains('JSESSIONID')),
        );
        expect(
          casCookies.map((cookie) => cookie.name),
          contains('CAMPUS_SHARED'),
        );
        final hallCookies = await jar.loadForRequest(hallUri);
        expect(
          hallCookies.map((cookie) => cookie.name),
          containsAll(['FR_SESSION', 'CAMPUS_SHARED']),
        );
        expect(adapter.requestLog, ['GET /cas/login']);
      },
    );

    test('unknown-identity CAS redirect is not written as logged in', () async {
      const ticketUrl =
          'https://newca.zjxu.edu.cn/casClient/login/ydd?ticket=ST-1-test';
      final adapter = MockHttpClientAdapter()
        ..register('GET', '/cas/login', (options) async {
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': [ticketUrl],
            },
          );
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      expect(await UnifiedAuthService.instance.prepareLogin(), isFalse);
      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
      expect(UnifiedAuthService.instance.currentAccount, isNull);
    });

    test(
      'stale login-context response must not overwrite a newer identity',
      () async {
        const loginHtml = '''
          <html>
            <form id="fm1" action="/cas/login">
              <input type="hidden" name="lt" value="LT-1" />
              <input type="hidden" name="execution" value="e1s1" />
            </form>
          </html>
        ''';
        final started = Completer<void>();
        final gate = Completer<void>();
        final adapter = MockHttpClientAdapter()
          ..register('GET', '/cas/login', (options) async {
            if (!started.isCompleted) started.complete();
            await gate.future;
            return ResponseBody.fromString(loginHtml, 200);
          });
        DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

        final pending = UnifiedAuthService.instance.prepareLogin();
        await started.future;
        UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
        gate.complete();

        expect(await pending, isFalse);
        expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
        expect(UnifiedAuthService.instance.currentAccount, 'B');
      },
    );
  });

  group('UnifiedAuthService.restoreSession 身份通知与 revision guard', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      UnifiedAuthService.instance.debugReset();
    });

    test('同账号已有会话重复 restore：不重复通知（epoch 守卫不误判）', () async {
      await CredentialStore.instance.saveUnifiedAuthSession('A');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      var notifications = 0;
      void listener() => notifications++;
      UnifiedAuthService.instance.addListener(listener);

      await UnifiedAuthService.instance.restoreSession(
        syncWebViewCookies: false,
      );

      UnifiedAuthService.instance.removeListener(listener);
      expect(notifications, 0);
      expect(UnifiedAuthService.instance.currentAccount, 'A');
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
    });

    test('空白账号 metadata 不得恢复成已登录', () async {
      UnifiedAuthService.instance.debugSessionMetadataLoader = () async => '  ';

      await UnifiedAuthService.instance.restoreSession(
        syncWebViewCookies: false,
      );

      UnifiedAuthService.instance.debugSessionMetadataLoader = null;
      expect(UnifiedAuthService.instance.currentAccount, isNull);
      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
    });

    test('未登录冷恢复命中 stored session：真正身份变化才通知一次', () async {
      await CredentialStore.instance.saveUnifiedAuthSession('A');
      var notifications = 0;
      void listener() => notifications++;
      UnifiedAuthService.instance.addListener(listener);

      await UnifiedAuthService.instance.restoreSession(
        syncWebViewCookies: false,
      );

      UnifiedAuthService.instance.removeListener(listener);
      expect(notifications, 1);
      expect(UnifiedAuthService.instance.currentAccount, 'A');
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
    });

    test('存储读取等待期间外部 logout：不复活旧 session', () async {
      UnifiedAuthService.instance.debugSessionMetadataLoader = () async {
        // 模拟存储读取等待期间发生外部登出（清内存态 + 递增 revision）
        await UnifiedAuthService.instance.markLoggedOut();
        return 'A'; // 过期 metadata
      };
      var notifications = 0;
      void listener() => notifications++;
      UnifiedAuthService.instance.addListener(listener);

      await UnifiedAuthService.instance.restoreSession(
        syncWebViewCookies: false,
      );

      UnifiedAuthService.instance.removeListener(listener);
      UnifiedAuthService.instance.debugSessionMetadataLoader = null;
      // 仅 markLoggedOut 自己的通知；restore 放弃套用旧 metadata，不再通知
      expect(notifications, 1);
      expect(UnifiedAuthService.instance.currentAccount, isNull);
      expect(UnifiedAuthService.instance.isLoggedIn, isFalse);
    });

    test('存储读取等待期间外部 login(B)：不被过期 metadata 覆盖', () async {
      UnifiedAuthService.instance.debugSessionMetadataLoader = () async {
        UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
        return 'A'; // 过期 metadata
      };

      await UnifiedAuthService.instance.restoreSession(
        syncWebViewCookies: false,
      );

      UnifiedAuthService.instance.debugSessionMetadataLoader = null;
      expect(UnifiedAuthService.instance.currentAccount, 'B');
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
    });

    test('restore 等待中外部合法状态变更不被旧 metadata 覆盖', () async {
      Future<void> runCase({
        required Future<void> Function() mutate,
        required String? expectedAccount,
        required bool expectedLoggedIn,
      }) async {
        UnifiedAuthService.instance.debugReset();
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStorage.setMockInitialValues({});
        final started = Completer<void>();
        final loadGate = Completer<void>();
        UnifiedAuthService.instance.debugSessionMetadataLoader = () async {
          if (!started.isCompleted) started.complete();
          await loadGate.future;
          return 'STALE';
        };

        final restore = UnifiedAuthService.instance.restoreSession(
          syncWebViewCookies: false,
        );
        await started.future;
        await mutate();
        loadGate.complete();
        await restore;

        expect(UnifiedAuthService.instance.currentAccount, expectedAccount);
        expect(UnifiedAuthService.instance.isLoggedIn, expectedLoggedIn);
      }

      await runCase(
        mutate: UnifiedAuthService.instance.markLoggedOut,
        expectedAccount: null,
        expectedLoggedIn: false,
      );
      await runCase(
        mutate: () async {
          UnifiedAuthService.instance.debugSetSession(
            active: true,
            account: 'B',
          );
        },
        expectedAccount: 'B',
        expectedLoggedIn: true,
      );
      await runCase(
        mutate: () async {
          UnifiedAuthService.instance.debugSetSession(
            active: true,
            account: 'A',
          );
          UnifiedAuthService.instance.debugSetSession(
            active: true,
            account: 'B',
          );
        },
        expectedAccount: 'B',
        expectedLoggedIn: true,
      );
      await runCase(
        mutate: () async {
          UnifiedAuthService.instance.debugSetSession(active: false);
          UnifiedAuthService.instance.debugSetSession(
            active: true,
            account: 'A',
          );
        },
        expectedAccount: 'A',
        expectedLoggedIn: true,
      );
    });
  });
}
