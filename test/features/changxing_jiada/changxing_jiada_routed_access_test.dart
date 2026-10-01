import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/auth/cas_routed_access.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_service.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';
import '../../helpers/changxing_route_test_helpers.dart';

const _callback = 'http://zhx.zjxu.edu.cn:8443/api/wap/cas_login_back';
const _loginHtml = '''
<html>
  <form id="fm1">
    <input type="hidden" name="lt" value="LT-1" />
    <input type="hidden" name="execution" value="e1s1" />
  </form>
</html>
''';

String _proxy(String directUrl) =>
    ZhengfangAuth.instance.buildWebVpnProxyUrl(directUrl);

String _proxyPath(String directUrl) => Uri.parse(_proxy(directUrl)).path;

ResponseBody _redirect(String location) => ResponseBody.fromString(
  '',
  302,
  headers: {
    'location': [location],
  },
);

ResponseBody _json(Object? data) => ResponseBody.fromString(
  jsonEncode(data),
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

Future<void> _seedToken(String owner, String token) =>
    const FlutterSecureStorage().write(
      key: ChangxingJiadaService.tokenStorageKeyV2,
      value: ChangxingJiadaService.encodeTokenEnvelope(
        owner: owner,
        token: token,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async =>
        'test/$folderName';
    await DioClient.instance.ensureInitialized();
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '20260001',
    );
  });

  tearDown(resetChangxingRouteHooks);

  group('直连（校内）', () {
    test('登录与 API 全程使用直连 URL，不触碰网关', () async {
      final gatewayCalls = <String>[];
      installDirectChangxingRoute();
      CasRoutedAccess.debugGatewayEnsurer = (cancelToken, deadline) async {
        gatewayCalls.add('gateway');
      };
      final uris = <Uri>[];
      final adapter = MockHttpClientAdapter()
        ..register('GET', '/api/cas_wap_login', (options) async {
          uris.add(options.uri);
          return _redirect(
            'https://newca.zjxu.edu.cn/cas/login'
            '?service=http%3A%2F%2Fzhx.zjxu.edu.cn%3A8443%2Fapi%2Fwap%2Fcas_login_back',
          );
        })
        ..register('GET', '/cas/login', (options) async {
          uris.add(options.uri);
          return _redirect('$_callback?tokenId=T-1');
        })
        ..register('GET', '/api/getToken', (options) async {
          uris.add(options.uri);
          return _json({
            'data': {'code': '20000', 'token': 'jwt'},
          });
        })
        ..register('GET', '/api/msg/getNoReadCount', (options) async {
          uris.add(options.uri);
          return _json({
            'data': {'code': '20000', 'count': 2},
          });
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await ChangxingJiadaService.instance.loginViaCas();
      expect(await ChangxingJiadaService.instance.fetchUnreadCount(), 2);

      expect(gatewayCalls, isEmpty);
      expect(
        uris.where((uri) => uri.host != 'newca.zjxu.edu.cn').map((u) => u.host),
        everyElement('zhx.zjxu.edu.cn'),
      );
      expect(uris.last.path, '/api/msg/getNoReadCount');
      expect(ZhengfangAuth.instance.mode, ZhengfangMode.direct);
    });

    test('tokenId 命中即停：不请求携带 tokenId 的下一跳', () async {
      installDirectChangxingRoute();
      final adapter = MockHttpClientAdapter()
        ..registerText(
          'GET',
          '/api/cas_wap_login',
          '',
          statusCode: 302,
          headers: {
            'location': [
              'https://newca.zjxu.edu.cn/cas/login?service=http%3A%2F%2Fzhx.zjxu.edu.cn%3A8443%2Fapi%2Fwap%2Fcas_login_back',
            ],
          },
        )
        ..register('GET', '/cas/login', (_) async {
          return _redirect('$_callback?tokenId=T-ONCE');
        })
        ..register('GET', '/api/wap/cas_login_back', (_) async {
          throw StateError('tokenId 一次性参数所在的下一跳不得被请求');
        })
        ..register('GET', '/api/getToken', (options) async {
          expect(options.uri.queryParameters['tokenId'], 'T-ONCE');
          return _json({
            'data': {'code': '20000', 'token': 'jwt'},
          });
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await ChangxingJiadaService.instance.loginViaCas();

      expect(adapter.requestLog, [
        'GET /api/cas_wap_login',
        'GET /cas/login',
        'GET /api/getToken',
      ]);
      expect(ChangxingJiadaService.instance.hasToken, isTrue);
    });
  });

  group('WebVPN（校外）', () {
    test('先建网关会话；登录链路与 getToken 全部改写到 webvpn', () async {
      final gatewayCalls = <String>[];
      installWebVpnChangxingRoute(gatewayCalls: gatewayCalls);

      final loginPath = _proxyPath('https://zhx.zjxu.edu.cn/api/cas_wap_login');
      final callbackPath = _proxyPath(_callback);
      final tokenPath = _proxyPath('https://zhx.zjxu.edu.cn/api/getToken');
      Uri? tokenUri;

      final adapter = MockHttpClientAdapter()
        ..register('GET', loginPath, (_) async {
          expect(gatewayCalls, ['gateway'], reason: '网关会话必须先于业务请求');
          // 网关把 newca 的登录页代理成 https 形态（共享中间层只认 http 形态）。
          return _redirect(
            'https://webvpn.zjxu.edu.cn/https/'
            '77726476706e69737468656265737421fef2569f267e725a661dc7a99c406d362a'
            '/cas/login?service=http%3A%2F%2Fzhx.zjxu.edu.cn%3A8443%2Fapi%2Fwap%2Fcas_login_back',
          );
        })
        ..register('GET', '/cas/login', (_) async {
          // 必须回到真实 newca 登录入口（WebVPN 代理域没有 SSO Cookie）。
          return _redirect('$_callback?ticket=ST-1');
        })
        ..register('GET', callbackPath, (_) async {
          return _redirect(
            'https://webvpn.zjxu.edu.cn/https/ENCRYPTED/wap?type=x&tokenId=T-9',
          );
        })
        ..register('GET', tokenPath, (options) async {
          tokenUri = options.uri;
          return _json({
            'data': {'code': '20000', 'token': 'jwt-token'},
          });
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await ChangxingJiadaService.instance.loginViaCas();

      expect(adapter.requestLog, [
        'GET $loginPath',
        'GET /cas/login',
        'GET $callbackPath',
        'GET $tokenPath',
      ]);
      // 直连形态的回调路径从未被直接请求。
      expect(
        adapter.requestLog,
        isNot(contains('GET /api/wap/cas_login_back')),
      );
      expect(tokenUri?.host, 'webvpn.zjxu.edu.cn');
      expect(tokenUri?.queryParameters['tokenId'], 'T-9');
      expect(ChangxingJiadaService.instance.hasToken, isTrue);
      // 选路只作用于本次调用：全局教务模式不被改写。
      expect(ZhengfangAuth.instance.mode, ZhengfangMode.direct);
    });

    test('API 与附件上传 URL 改写为 webvpn，路由短期复用不重复建网关', () async {
      final gatewayCalls = <String>[];
      installWebVpnChangxingRoute(gatewayCalls: gatewayCalls);
      await _seedToken('20260001', 'test-token');

      final countPath = _proxyPath(
        'https://zhx.zjxu.edu.cn/api/msg/getNoReadCount',
      );
      final uploadPath = _proxyPath(
        'https://zhx.zjxu.edu.cn/api/image/add/single',
      );
      final hosts = <String>[];
      final adapter = MockHttpClientAdapter()
        ..register('GET', countPath, (options) async {
          hosts.add(options.uri.host);
          return _json({
            'data': {'code': '20000', 'count': 4},
          });
        })
        ..register('POST', uploadPath, (options) async {
          hosts.add(options.uri.host);
          expect(options.headers['token'], 'test-token');
          return _json({
            'data': {
              'code': '20000',
              'data': {'md5': 'm1', 'base64': ''},
            },
          });
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      expect(await ChangxingJiadaService.instance.fetchUnreadCount(), 4);
      expect(await ChangxingJiadaService.instance.fetchUnreadCount(), 4);
      expect(gatewayCalls, ['gateway']);

      final tempDir = await Directory.systemTemp.createTemp('cx_route_');
      addTearDown(() async {
        try {
          if (tempDir.existsSync()) await tempDir.delete(recursive: true);
        } on FileSystemException {
          // Windows 上传流句柄可能尚未释放，交给系统清理。
        }
      });
      final file = File('${tempDir.path}${Platform.pathSeparator}note.txt');
      await file.writeAsString('payload');
      final result = await ChangxingJiadaService.instance.uploadAttachment(
        file.path,
        'note.txt',
      );

      expect(result.md5, 'm1');
      expect(hosts, everyElement('webvpn.zjxu.edu.cn'));
      expect(adapter.requestLog, [
        'GET $countPath',
        'GET $countPath',
        'POST $uploadPath',
      ]);
      expect(gatewayCalls, ['gateway']);
    });

    test('WebVPN 与直连都不可达：可重试失败，不发业务请求', () async {
      installDirectChangxingRoute();
      ConnectModeResolver.instance.targetDirectReachabilityChecker = (
        _,
      ) async => false;
      ConnectModeResolver.instance.webVpnReachabilityChecker = () async =>
          false;
      final adapter = MockHttpClientAdapter();
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await expectLater(
        ChangxingJiadaService.instance.loginViaCas(),
        throwsA(isA<ChangxingCasLoginException>()),
      );
      expect(adapter.requestLog, isEmpty);
    });
  });

  group('登录 bounce 与恢复', () {
    test('首轮落到登录页：一次恢复后重试成功', () async {
      installDirectChangxingRoute();
      var loginHits = 0;
      final adapter = MockHttpClientAdapter()
        ..registerText(
          'GET',
          '/api/cas_wap_login',
          '',
          statusCode: 302,
          headers: {
            'location': [
              'https://newca.zjxu.edu.cn/cas/login?service=http%3A%2F%2Fzhx.zjxu.edu.cn%3A8443%2Fapi%2Fwap%2Fcas_login_back',
            ],
          },
        )
        ..register('GET', '/cas/login', (_) async {
          loginHits++;
          if (loginHits == 1) {
            return ResponseBody.fromString(_loginHtml, 200);
          }
          return _redirect('$_callback?tokenId=T-2');
        })
        ..registerJson('GET', '/api/getToken', {
          'data': {'code': '20000', 'token': 'jwt'},
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await ChangxingJiadaService.instance.loginViaCas();

      expect(loginHits, 2);
      expect(ChangxingJiadaService.instance.hasToken, isTrue);
    });

    test('统一认证会话明确失效：NeedUnifiedAuth，不发任何业务请求', () async {
      installDirectChangxingRoute();
      UnifiedAuthService.instance.debugSessionValidator = (_) async => false;
      final adapter = MockHttpClientAdapter();
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await expectLater(
        ChangxingJiadaService.instance.loginViaCas(),
        throwsA(isA<ChangxingNeedUnifiedAuthException>()),
      );
      expect(adapter.requestLog, isEmpty);
      expect(ChangxingJiadaService.instance.hasToken, isFalse);
    });

    test('恢复时会话校验判定失效：不再重试 CAS 链路', () async {
      installDirectChangxingRoute();
      var validations = 0;
      UnifiedAuthService.instance.debugSessionValidator = (_) async {
        validations++;
        return validations == 1;
      };
      final adapter = MockHttpClientAdapter()
        ..registerText(
          'GET',
          '/api/cas_wap_login',
          '',
          statusCode: 302,
          headers: {
            'location': [
              'https://newca.zjxu.edu.cn/cas/login?service=http%3A%2F%2Fzhx.zjxu.edu.cn%3A8443%2Fapi%2Fwap%2Fcas_login_back',
            ],
          },
        )
        ..registerText('GET', '/cas/login', _loginHtml);
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await expectLater(
        ChangxingJiadaService.instance.loginViaCas(),
        throwsA(isA<ChangxingNeedUnifiedAuthException>()),
      );
      expect(adapter.requestLog, ['GET /api/cas_wap_login', 'GET /cas/login']);
    });

    test('统一认证校验网络不确定：可重试失败而非登录过期', () async {
      installDirectChangxingRoute();
      UnifiedAuthService.instance.debugSessionValidator = (_) async => null;
      DioClient.instance.unifiedAuthDio.httpClientAdapter =
          MockHttpClientAdapter();

      await expectLater(
        ChangxingJiadaService.instance.loginViaCas(),
        throwsA(isA<ChangxingCasLoginException>()),
      );
    });

    test('链路中途身份变化：丢弃 token，不写入新身份', () async {
      installDirectChangxingRoute();
      final adapter = MockHttpClientAdapter()
        ..registerText(
          'GET',
          '/api/cas_wap_login',
          '',
          statusCode: 302,
          headers: {
            'location': [
              'https://newca.zjxu.edu.cn/cas/login?service=http%3A%2F%2Fzhx.zjxu.edu.cn%3A8443%2Fapi%2Fwap%2Fcas_login_back',
            ],
          },
        )
        ..register('GET', '/cas/login', (_) async {
          // A → B：A 发起的登录在途时身份切换。
          UnifiedAuthService.instance.debugSetSession(
            active: false,
            account: null,
          );
          UnifiedAuthService.instance.notifyListeners();
          UnifiedAuthService.instance.debugSetSession(
            active: true,
            account: '20269999',
          );
          UnifiedAuthService.instance.notifyListeners();
          return _redirect('$_callback?tokenId=T-A');
        })
        ..register('GET', '/api/getToken', (_) async {
          throw StateError('身份已变化后不得继续换取 token');
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await expectLater(
        ChangxingJiadaService.instance.loginViaCas(),
        throwsA(isA<ChangxingCasLoginException>()),
      );

      expect(adapter.requestLog, isNot(contains('GET /api/getToken')));
      expect(ChangxingJiadaService.instance.hasToken, isFalse);
      expect(
        await const FlutterSecureStorage().read(
          key: ChangxingJiadaService.tokenStorageKeyV2,
        ),
        isNull,
      );
    });
  });

  group('API 登录页 bounce', () {
    test('302 到统一认证登录页 → AuthExpired；不清全局会话', () async {
      installDirectChangxingRoute();
      await _seedToken('20260001', 'test-token');
      final adapter = MockHttpClientAdapter()
        ..register('GET', '/api/msg/getNoReadCount', (_) async {
          return _redirect(
            'https://newca.zjxu.edu.cn/cas/login?service=https%3A%2F%2Fzhx.zjxu.edu.cn%2Fapi',
          );
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await expectLater(
        ChangxingJiadaService.instance.fetchUnreadCount(),
        throwsA(isA<ChangxingAuthExpiredException>()),
      );

      // 只丢弃本地业务选路，不标记登出、不清 CAS 会话。
      expect(adapter.requestLog, ['GET /api/msg/getNoReadCount']);
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      expect(UnifiedAuthService.instance.currentAccount, '20260001');
    });

    test('302 到 WebVPN 网关登录页 → AuthExpired，下次调用重建网关会话', () async {
      final gatewayCalls = <String>[];
      installWebVpnChangxingRoute(gatewayCalls: gatewayCalls);
      await _seedToken('20260001', 'test-token');
      final countPath = _proxyPath(
        'https://zhx.zjxu.edu.cn/api/msg/getNoReadCount',
      );
      var hits = 0;
      final adapter = MockHttpClientAdapter()
        ..register('GET', countPath, (_) async {
          hits++;
          if (hits == 1) return _redirect('https://webvpn.zjxu.edu.cn/login');
          return _json({
            'data': {'code': '20000', 'count': 1},
          });
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await expectLater(
        ChangxingJiadaService.instance.fetchUnreadCount(),
        throwsA(isA<ChangxingAuthExpiredException>()),
      );
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      expect(gatewayCalls, ['gateway']);

      expect(await ChangxingJiadaService.instance.fetchUnreadCount(), 1);
      expect(gatewayCalls, ['gateway', 'gateway']);
    });

    test('200 统一认证登录页 HTML → AuthExpired', () async {
      installDirectChangxingRoute();
      await _seedToken('20260001', 'test-token');
      final adapter = MockHttpClientAdapter()
        ..registerText('GET', '/api/msg/getNoReadCount', _loginHtml);
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await expectLater(
        ChangxingJiadaService.instance.fetchUnreadCount(),
        throwsA(isA<ChangxingAuthExpiredException>()),
      );
    });
  });

  group('WebVPN 代理登录页 bounce', () {
    test('302 到代理形态 newca 登录页（/https/<enc>/cas/login）→ AuthExpired', () async {
      final gatewayCalls = <String>[];
      installWebVpnChangxingRoute(gatewayCalls: gatewayCalls);
      await _seedToken('20260001', 'test-token');
      final countPath = _proxyPath(
        'https://zhx.zjxu.edu.cn/api/msg/getNoReadCount',
      );
      var hits = 0;
      final adapter = MockHttpClientAdapter()
        ..register('GET', countPath, (_) async {
          hits++;
          if (hits == 1) {
            return _redirect(
              'https://webvpn.zjxu.edu.cn/https/'
              '77726476706e69737468656265737421fef2569f267e725a661dc7a99c406d362a'
              '/cas/login?service=http%3A%2F%2Fzhx.zjxu.edu.cn%3A8443%2Fapi%2Fwap%2Fcas_login_back',
            );
          }
          return _json({
            'data': {'code': '20000', 'count': 1},
          });
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await expectLater(
        ChangxingJiadaService.instance.fetchUnreadCount(),
        throwsA(isA<ChangxingAuthExpiredException>()),
      );
      expect(UnifiedAuthService.instance.isLoggedIn, isTrue);
      // 登录页 bounce 已被识别：未被当作普通 3xx 继续跟随。
      expect(adapter.requestLog, ['GET $countPath']);
      // 选路缓存已丢弃：下次调用重新建网关会话。
      expect(await ChangxingJiadaService.instance.fetchUnreadCount(), 1);
      expect(gatewayCalls, ['gateway', 'gateway']);
    });
  });

  group('登录总预算', () {
    test('getToken 过慢：在总预算内以超时失败，不保存 token', () async {
      installDirectChangxingRoute();
      final service = ChangxingJiadaService.instance;
      service.debugLoginBudget = const Duration(milliseconds: 300);
      addTearDown(() => service.debugLoginBudget = null);
      final adapter = MockHttpClientAdapter()
        ..register(
          'GET',
          '/api/cas_wap_login',
          (_) async => _redirect(
            'https://newca.zjxu.edu.cn/cas/login'
            '?service=http%3A%2F%2Fzhx.zjxu.edu.cn%3A8443%2Fapi%2Fwap%2Fcas_login_back',
          ),
        )
        ..register(
          'GET',
          '/cas/login',
          (_) async => _redirect('$_callback?tokenId=T-1'),
        )
        ..register('GET', '/api/getToken', (_) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return _json({
            'data': {'code': '20000', 'token': 'jwt'},
          });
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      final sw = Stopwatch()..start();
      await expectLater(
        service.loginViaCas(),
        throwsA(
          isA<ChangxingCasLoginException>().having(
            (e) => e.message,
            'message',
            contains('超时'),
          ),
        ),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
      expect(adapter.requestLog, contains('GET /api/getToken'));
      expect(service.hasToken, isFalse);
    });
  });

  group('API 重定向', () {
    test('GET 同源 302 有界跟随并保持 token 头', () async {
      installDirectChangxingRoute();
      await _seedToken('20260001', 'test-token');
      final tokens = <Object?>[];
      final adapter = MockHttpClientAdapter()
        ..register('GET', '/api/msg/getNoReadCount', (options) async {
          tokens.add(options.headers['token']);
          return _redirect('/api/msg/getNoReadCount/');
        })
        ..register('GET', '/api/msg/getNoReadCount/', (options) async {
          tokens.add(options.headers['token']);
          return _json({
            'data': {'code': '20000', 'count': 6},
          });
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      expect(await ChangxingJiadaService.instance.fetchUnreadCount(), 6);
      expect(adapter.requestLog, [
        'GET /api/msg/getNoReadCount',
        'GET /api/msg/getNoReadCount/',
      ]);
      expect(tokens, ['test-token', 'test-token']);
    });

    test('WebVPN 下 GET 重定向到直连 zhx 地址会按路由改写', () async {
      installWebVpnChangxingRoute();
      await _seedToken('20260001', 'test-token');
      final countPath = _proxyPath(
        'https://zhx.zjxu.edu.cn/api/msg/getNoReadCount',
      );
      final slashPath = _proxyPath(
        'https://zhx.zjxu.edu.cn/api/msg/getNoReadCount/',
      );
      final adapter = MockHttpClientAdapter()
        ..register('GET', countPath, (_) async {
          return _redirect('https://zhx.zjxu.edu.cn/api/msg/getNoReadCount/');
        })
        ..register('GET', slashPath, (_) async {
          return _json({
            'data': {'code': '20000', 'count': 8},
          });
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      expect(await ChangxingJiadaService.instance.fetchUnreadCount(), 8);
      expect(adapter.requestLog, ['GET $countPath', 'GET $slashPath']);
    });

    test('直连：https 默认端口同主机重定向可跟随', () async {
      installDirectChangxingRoute();
      await _seedToken('20260001', 'test-token');
      final adapter = MockHttpClientAdapter()
        ..register('GET', '/api/msg/getNoReadCount', (_) async {
          return _redirect(
            'https://zhx.zjxu.edu.cn:443/api/msg/getNoReadCount/',
          );
        })
        ..register('GET', '/api/msg/getNoReadCount/', (_) async {
          return _json({
            'data': {'code': '20000', 'count': 4},
          });
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      expect(await ChangxingJiadaService.instance.fetchUnreadCount(), 4);
      expect(adapter.requestLog, hasLength(2));
    });

    for (final target in {
      '同主机 http 降级': 'http://zhx.zjxu.edu.cn/leak',
      '同主机替代端口': 'https://zhx.zjxu.edu.cn:8443/leak',
      '子域名': 'https://evil.zhx.zjxu.edu.cn/leak',
    }.entries) {
      test('直连：${target.key}不跟随（token 不外泄）', () async {
        installDirectChangxingRoute();
        await _seedToken('20260001', 'test-token');
        final adapter = MockHttpClientAdapter()
          ..register('GET', '/api/msg/getNoReadCount', (_) async {
            return _redirect(target.value);
          })
          ..register('GET', '/leak', (_) async {
            throw StateError('不得请求不可信目标');
          });
        DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

        await expectLater(
          ChangxingJiadaService.instance.fetchUnreadCount(),
          throwsA(isA<ChangxingCasLoginException>()),
        );
        expect(adapter.requestLog, ['GET /api/msg/getNoReadCount']);
      });
    }

    test('WebVPN：同 zhx 代理前缀下的重定向可跟随，token 头保持', () async {
      installWebVpnChangxingRoute();
      await _seedToken('20260001', 'test-token');
      final countPath = _proxyPath(
        'https://zhx.zjxu.edu.cn/api/msg/getNoReadCount',
      );
      final slashPath = _proxyPath(
        'https://zhx.zjxu.edu.cn/api/msg/getNoReadCount/',
      );
      final tokens = <Object?>[];
      final adapter = MockHttpClientAdapter()
        ..register('GET', countPath, (o) async {
          tokens.add(o.headers['token']);
          return _redirect(
            _proxy('https://zhx.zjxu.edu.cn/api/msg/getNoReadCount/'),
          );
        })
        ..register('GET', slashPath, (o) async {
          tokens.add(o.headers['token']);
          return _json({
            'data': {'code': '20000', 'count': 9},
          });
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      expect(await ChangxingJiadaService.instance.fetchUnreadCount(), 9);
      expect(adapter.requestLog, ['GET $countPath', 'GET $slashPath']);
      expect(tokens, ['test-token', 'test-token']);
    });

    final webVpnUntrusted = <String, String Function()>{
      '同代理主机 http 降级': () => _proxy(
        'https://zhx.zjxu.edu.cn/leak',
      ).replaceFirst('https://webvpn.zjxu.edu.cn', 'http://webvpn.zjxu.edu.cn'),
      '网关替代端口': () =>
          _proxy('https://zhx.zjxu.edu.cn/leak')
              .replaceFirst('webvpn.zjxu.edu.cn', 'webvpn.zjxu.edu.cn:8443'),
      '另一代理前缀（zhx 的 http:8443 站点）': () =>
          _proxy('http://zhx.zjxu.edu.cn:8443/leak'),
      '另一代理前缀（未知加密主机段）': () {
        final u = Uri.parse(_proxy('https://zhx.zjxu.edu.cn/leak'));
        return u
            .replace(pathSegments: [u.pathSegments[0], 'deadbeef', 'leak'])
            .toString();
      },
      '网关根路径': () => 'https://webvpn.zjxu.edu.cn/leak',
      '直连 zhx 的 http 地址': () => 'http://zhx.zjxu.edu.cn/leak',
    };
    for (final target in webVpnUntrusted.entries) {
      test('WebVPN：${target.key}不跟随（token 不外泄）', () async {
        installWebVpnChangxingRoute();
        await _seedToken('20260001', 'test-token');
        final countPath = _proxyPath(
          'https://zhx.zjxu.edu.cn/api/msg/getNoReadCount',
        );
        final adapter = MockHttpClientAdapter()
          ..register('GET', countPath, (_) async {
            return _redirect(target.value());
          });
        DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

        await expectLater(
          ChangxingJiadaService.instance.fetchUnreadCount(),
          throwsA(isA<ChangxingCasLoginException>()),
        );
        expect(adapter.requestLog, ['GET $countPath']);
      });
    }

    test('跨站点重定向不跟随（token 不外泄）', () async {
      installDirectChangxingRoute();
      await _seedToken('20260001', 'test-token');
      final adapter = MockHttpClientAdapter()
        ..register('GET', '/api/msg/getNoReadCount', (_) async {
          return _redirect('https://evil.example.com/leak');
        })
        ..register('GET', '/leak', (_) async {
          throw StateError('不得请求跨站点目标');
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await expectLater(
        ChangxingJiadaService.instance.fetchUnreadCount(),
        throwsA(isA<ChangxingCasLoginException>()),
      );
      expect(adapter.requestLog, ['GET /api/msg/getNoReadCount']);
    });

    test('重定向环最多跟随 5 跳后干净失败', () async {
      installDirectChangxingRoute();
      await _seedToken('20260001', 'test-token');
      final adapter = MockHttpClientAdapter()
        ..register('GET', '/api/msg/getNoReadCount', (_) async {
          return _redirect('/api/msg/getNoReadCount');
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await expectLater(
        ChangxingJiadaService.instance.fetchUnreadCount(),
        throwsA(isA<ChangxingCasLoginException>()),
      );
      expect(adapter.requestLog, hasLength(6));
    });

    test('POST 遇到非登录 302：不跟随、不重试，明确报错', () async {
      installDirectChangxingRoute();
      await _seedToken('20260001', 'test-token');
      final adapter = MockHttpClientAdapter()
        ..register('POST', '/api/user/getUserDetail', (_) async {
          return _redirect('/api/user/getUserDetail/');
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await expectLater(
        ChangxingJiadaService.instance.fetchUserProfile(),
        throwsA(
          isA<ChangxingCasLoginException>().having(
            (e) => e.toString(),
            'message',
            contains('重定向'),
          ),
        ),
      );
      expect(adapter.requestLog, ['POST /api/user/getUserDetail']);
    });
  });

  group('传输层失败丢弃选路缓存', () {
    for (final type in [
      DioExceptionType.connectionError,
      DioExceptionType.connectionTimeout,
      DioExceptionType.receiveTimeout,
    ]) {
      test('GET $type 后下次调用重新选路', () async {
        final gatewayCalls = <String>[];
        installWebVpnChangxingRoute(gatewayCalls: gatewayCalls);
        await _seedToken('20260001', 'test-token');
        final countPath = _proxyPath(
          'https://zhx.zjxu.edu.cn/api/msg/getNoReadCount',
        );
        var hits = 0;
        final adapter = MockHttpClientAdapter()
          ..register('GET', countPath, (options) async {
            hits++;
            if (hits == 1) {
              throw DioException(requestOptions: options, type: type);
            }
            return _json({
              'data': {'code': '20000', 'count': 3},
            });
          });
        DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

        await expectLater(
          ChangxingJiadaService.instance.fetchUnreadCount(),
          throwsA(isA<DioException>()),
        );
        expect(gatewayCalls, ['gateway']);

        expect(await ChangxingJiadaService.instance.fetchUnreadCount(), 3);
        expect(gatewayCalls, ['gateway', 'gateway']);
      });
    }

    test('上传连接失败同样丢弃选路缓存', () async {
      final gatewayCalls = <String>[];
      installWebVpnChangxingRoute(gatewayCalls: gatewayCalls);
      await _seedToken('20260001', 'test-token');
      final uploadPath = _proxyPath(
        'https://zhx.zjxu.edu.cn/api/image/add/single',
      );
      final adapter = MockHttpClientAdapter()
        ..register('POST', uploadPath, (options) async {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          );
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;
      final tempDir = await Directory.systemTemp.createTemp('cx_route_up_');
      addTearDown(() async {
        try {
          if (tempDir.existsSync()) await tempDir.delete(recursive: true);
        } on FileSystemException {
          // Windows 上传流句柄可能尚未释放，交给系统清理。
        }
      });
      final file = File('${tempDir.path}${Platform.pathSeparator}a.txt');
      await file.writeAsString('x');

      await expectLater(
        ChangxingJiadaService.instance.uploadAttachment(file.path, 'a.txt'),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        ChangxingJiadaService.instance.uploadAttachment(file.path, 'a.txt'),
        throwsA(isA<DioException>()),
      );
      expect(gatewayCalls, ['gateway', 'gateway']);
    });
  });

  test('CasService.changxing 注册为站点 CAS 回调（资源入口不是 service）', () {
    expect(CasService.changxing.serviceUrl, _callback);
    expect(CasService.changxing.serviceUrl, isNot(contains('cas_wap_login')));
    // WebVPN 下该回调按 host 映射 + 端口段改写。
    expect(
      _proxy(CasService.changxing.serviceUrl),
      startsWith('https://webvpn.zjxu.edu.cn/http-8443/'),
    );
  });
}
