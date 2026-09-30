import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/logging/app_logger.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_service.dart';

import '../../helpers/gated_secure_storage.dart';
import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';
import 'changxing_route_test_helpers.dart';

/// 注册一条最小 CAS SSO 链路：最终换取 [jwtToken]。
void _registerSsoChain(MockHttpClientAdapter adapter, String jwtToken) {
  adapter
    ..registerText(
      'GET',
      '/api/cas_wap_login',
      '',
      statusCode: 302,
      headers: {
        'location': [
          'https://newca.zjxu.edu.cn/cas/login?service=https%3A%2F%2Fzhx.zjxu.edu.cn%2Fapi%2Fcas_wap_login',
        ],
      },
    )
    ..registerText(
      'GET',
      '/cas/login',
      '',
      statusCode: 302,
      headers: {
        'location': [
          'http://zhx.zjxu.edu.cn:8443/api/wap/cas_login_back?tokenId=T-1',
        ],
      },
    )
    ..registerJson('GET', '/api/getToken', {
      'data': {'code': '20000', 'token': jwtToken},
    });
}

ResponseBody _jsonBody(Object? data) => ResponseBody.fromString(
  jsonEncode(data),
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

/// 协作式让出事件循环：在 A 的 in-flight 临界区被挂起期间，让 B 的 SSO
/// 链路有足够机会推进到「请求保存 token」这一步（B 被串行队列挡住时不会
/// 产生任何平台层写入，因此用有界让出而不是等待平台事件）。
Future<void> _pumpEventLoop({int turns = 64}) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _seedStoredToken({
  required String owner,
  required String token,
}) async {
  await const FlutterSecureStorage().write(
    key: ChangxingJiadaService.tokenStorageKeyV2,
    value: ChangxingJiadaService.encodeTokenEnvelope(
      owner: owner,
      token: token,
    ),
  );
}

Future<String?> _readStoredEnvelope() => const FlutterSecureStorage().read(
  key: ChangxingJiadaService.tokenStorageKeyV2,
);

void main() {
  group('Changxing unified auth response detection', () {
    test('treats CAS login form html as expired unified auth session', () {
      expect(
        ChangxingJiadaService.isUnifiedAuthLoginFormResponse('https://newca.zjxu.edu.cn/cas/login?service=http%3A%2F%2Fzhx.zjxu.edu.cn%3A8443%2Fapi%2Fwap%2Fcas_login_back', '''
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

    test('does not treat service hall bridge page as expired session', () {
      expect(
        ChangxingJiadaService.isUnifiedAuthLoginFormResponse(
          'https://mobilehall.zjxu.edu.cn/mportal/start/ssoLogin.html?username=00213544&services=%2Fbusiness%2Fydd%2Fportal%2Fhome',
          '<html><body>service hall relay</body></html>',
        ),
        isFalse,
      );
    });

    test('does not treat CAS client ticket callback as expired session', () {
      expect(
        ChangxingJiadaService.isUnifiedAuthLoginFormResponse(
          'https://newca.zjxu.edu.cn/casClient/login/ydd?ticket=ST-1',
          '<html><body>redirecting...</body></html>',
        ),
        isFalse,
      );
    });

    test(
      'treats proxied CAS login form html as expired unified auth session',
      () {
        expect(
          ChangxingJiadaService.isUnifiedAuthLoginFormResponse('https://webvpn.zjxu.edu.cn/https/77726476706e69737468656265737421fef2569f267e725a661dc7a99c406d362a/cas/login?service=http%3A%2F%2Fzhx.zjxu.edu.cn%3A8443%2Fapi%2Fwap%2Fcas_login_back', '''
          <html>
            <form id="fm1">
              <input type="hidden" name="lt" value="LT-1" />
              <input type="hidden" name="execution" value="e1s1" />
            </form>
          </html>
          '''),
          isTrue,
        );
      },
    );
  });

  group('Changxing SSO redirect normalization', () {
    test('unwraps proxied newca login to direct unified auth url', () {
      expect(
        ChangxingJiadaService.normalizeSsoRedirectUrl(
          'https://webvpn.zjxu.edu.cn/https/77726476706e69737468656265737421fef2569f267e725a661dc7a99c406d362a/cas/login?service=http%3A%2F%2Fzhx.zjxu.edu.cn%3A8443%2Fapi%2Fwap%2Fcas_login_back',
        ),
        'https://newca.zjxu.edu.cn/cas/login?service=http%3A%2F%2Fzhx.zjxu.edu.cn%3A8443%2Fapi%2Fwap%2Fcas_login_back',
      );
    });

    test('rewrites raw changxing callback through webvpn', () {
      const callbackUrl =
          'http://zhx.zjxu.edu.cn:8443/api/wap/cas_login_back?ticket=ST-1';

      expect(
        ChangxingJiadaService.normalizeSsoRedirectUrl(callbackUrl),
        ZhengfangAuth.instance.buildWebVpnProxyUrl(callbackUrl),
      );
    });
  });

  group('Changxing CAS login flow', () {
    setUp(() async {
      await resetTestEnvironment();
      DioClient.instance.debugCookieDirectoryPathProvider = (
        folderName,
      ) async => 'test/$folderName';
      await DioClient.instance.ensureInitialized();
      installDirectChangxingRoute();
    });

    test('refuses SSO without a trusted unified auth identity', () async {
      final adapter = MockHttpClientAdapter();
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await expectLater(
        ChangxingJiadaService.instance.loginViaCas(),
        throwsA(isA<ChangxingNeedUnifiedAuthException>()),
      );

      expect(adapter.requestLog, isEmpty);
      expect(ChangxingJiadaService.instance.hasToken, isFalse);
    });

    test('captures token from first SSO redirect chain', () async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '20260001',
      );
      final adapter = MockHttpClientAdapter();
      _registerSsoChain(adapter, 'jwt-token');

      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await ChangxingJiadaService.instance.loginViaCas();

      expect(ChangxingJiadaService.instance.hasToken, isTrue);
      expect(adapter.requestLog, [
        'GET /api/cas_wap_login',
        'GET /cas/login',
        'GET /api/getToken',
      ]);
      expect(jsonDecode((await _readStoredEnvelope())!), {
        'owner': '20260001',
        'token': 'jwt-token',
      });
    });

    test('asks for unified auth when SSO chain ends on login form', () async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '20260001',
      );
      const casLoginLocation =
          'https://newca.zjxu.edu.cn/cas/login?service=https%3A%2F%2Fzhx.zjxu.edu.cn%2Fapi%2Fcas_wap_login';
      const loginHtml = '''
        <html>
          <form id="fm1">
            <input type="hidden" name="lt" value="LT-1" />
            <input type="hidden" name="execution" value="e1s1" />
          </form>
        </html>
      ''';

      final adapter = MockHttpClientAdapter()
        ..registerText(
          'GET',
          '/api/cas_wap_login',
          '',
          statusCode: 302,
          headers: {
            'location': [casLoginLocation],
          },
        )
        ..registerText('GET', '/cas/login', loginHtml);

      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await expectLater(
        ChangxingJiadaService.instance.loginViaCas(),
        throwsA(isA<ChangxingNeedUnifiedAuthException>()),
      );

      // 首轮落到登录页 → 一次恢复（会话校验仍通过）→ 仅重试一次，随后引导重登。
      expect(adapter.requestLog, [
        'GET /api/cas_wap_login',
        'GET /cas/login',
        'GET /api/cas_wap_login',
        'GET /cas/login',
      ]);
    });
  });

  group('Changxing token owner binding', () {
    late GatedSecureStoragePlatform storage;

    setUp(() async {
      await resetTestEnvironment();
      storage = GatedSecureStoragePlatform()..install();
      DioClient.instance.debugCookieDirectoryPathProvider = (
        folderName,
      ) async => 'test/$folderName';
      await DioClient.instance.ensureInitialized();
      installDirectChangxingRoute();
    });

    test('legacy unowned token is refused and deleted', () async {
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '20260001',
      );
      await const FlutterSecureStorage().write(
        key: ChangxingJiadaService.legacyTokenStorageKey,
        value: 'legacy-token',
      );
      final adapter = MockHttpClientAdapter()
        ..registerJson('GET', '/api/msg/getNoReadCount', {
          'data': {'code': '20000', 'count': 3},
        });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await ChangxingJiadaService.instance.restoreSession();

      // 无 owner 的旧 token 一律不可用：既不读出，也不发出任何请求。
      expect(ChangxingJiadaService.instance.hasToken, isFalse);
      await expectLater(
        ChangxingJiadaService.instance.fetchUnreadCount(),
        throwsA(isA<ChangxingAuthExpiredException>()),
      );
      expect(adapter.requestLog, isEmpty);
      expect(
        await const FlutterSecureStorage().read(
          key: ChangxingJiadaService.legacyTokenStorageKey,
        ),
        isNull,
      );
      expect(await _readStoredEnvelope(), isNull);
    });

    test('restore waits for CAS identity and binds owner', () async {
      await _seedStoredToken(owner: '20260001', token: 'token-a');

      // 身份未就绪：不恢复、不标记完成。
      await ChangxingJiadaService.instance.restoreSession();
      expect(ChangxingJiadaService.instance.hasToken, isFalse);
      expect(ChangxingJiadaService.instance.debugBoundOwner, isNull);

      // 身份就绪后再次恢复（页面会再次调用）：绑定到正确 owner。
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: '20260001',
      );
      await ChangxingJiadaService.instance.restoreSession();
      expect(ChangxingJiadaService.instance.hasToken, isTrue);
      expect(ChangxingJiadaService.instance.debugBoundOwner, '20260001');
    });

    test('stored token owned by another account stays unreadable', () async {
      await _seedStoredToken(owner: 'A', token: 'token-a');
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');

      await ChangxingJiadaService.instance.restoreSession();

      expect(ChangxingJiadaService.instance.hasToken, isFalse);
      expect(ChangxingJiadaService.instance.debugBoundOwner, isNull);
    });

    test(
      'A→B switch cannot read or send A token and late A 500001 keeps B token',
      () async {
        UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
        final adapter = MockHttpClientAdapter();
        _registerSsoChain(adapter, 'token-a');

        final gate = Completer<void>();
        final requestStarted = Completer<void>();
        final seenTokens = <String?>[];
        var countCalls = 0;
        adapter.register('GET', '/api/msg/getNoReadCount', (options) async {
          countCalls++;
          seenTokens.add(options.headers['token']?.toString());
          if (countCalls == 1) {
            if (!requestStarted.isCompleted) requestStarted.complete();
            await gate.future;
            return _jsonBody({
              'data': {'code': '500001', 'msg': '令牌错误'},
            });
          }
          return _jsonBody({
            'data': {'code': '20000', 'count': 3},
          });
        });
        DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

        await ChangxingJiadaService.instance.loginViaCas();
        expect(ChangxingJiadaService.instance.hasToken, isTrue);
        expect(ChangxingJiadaService.instance.debugBoundOwner, 'A');

        // A 的在途请求（携带 A token）。
        final pending = ChangxingJiadaService.instance.fetchUnreadCount();
        await requestStarted.future;
        expect(seenTokens.single, 'token-a');

        // A → B：B 身份下不得读取 / 发送 A 的 token。
        UnifiedAuthService.instance.debugSetSession(
          active: false,
          account: null,
        );
        UnifiedAuthService.instance.notifyListeners();
        UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
        UnifiedAuthService.instance.notifyListeners();
        expect(ChangxingJiadaService.instance.hasToken, isFalse);

        await expectLater(
          ChangxingJiadaService.instance.fetchUnreadCount(),
          throwsA(isA<ChangxingAuthExpiredException>()),
        );
        expect(seenTokens, hasLength(1));

        // B 重新走 CAS，落盘 token 必须绑定 B。
        adapter.registerJson('GET', '/api/getToken', {
          'data': {'code': '20000', 'token': 'token-b'},
        });
        await ChangxingJiadaService.instance.loginViaCas();
        expect(ChangxingJiadaService.instance.debugBoundOwner, 'B');
        expect(jsonDecode((await _readStoredEnvelope())!), {
          'owner': 'B',
          'token': 'token-b',
        });

        // A 请求迟到的 500001 不得清掉 B 的 token。
        gate.complete();
        await expectLater(
          pending,
          throwsA(isA<ChangxingAuthExpiredException>()),
        );
        expect(ChangxingJiadaService.instance.hasToken, isTrue);
        expect(ChangxingJiadaService.instance.debugBoundOwner, 'B');

        // B 的后续请求只带 B 的 token。
        expect(await ChangxingJiadaService.instance.fetchUnreadCount(), 3);
        expect(seenTokens.last, 'token-b');
      },
    );

    test(
      'same-account relogin drops the late response of the old session',
      () async {
        UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
        final adapter = MockHttpClientAdapter();
        _registerSsoChain(adapter, 'token-a');

        final gate = Completer<void>();
        final requestStarted = Completer<void>();
        var countCalls = 0;
        adapter.register('GET', '/api/msg/getNoReadCount', (options) async {
          countCalls++;
          if (countCalls == 1) {
            if (!requestStarted.isCompleted) requestStarted.complete();
            await gate.future;
            return _jsonBody({
              'data': {'code': '20000', 'count': 9},
            });
          }
          return _jsonBody({
            'data': {'code': '20000', 'count': 3},
          });
        });
        DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

        await ChangxingJiadaService.instance.loginViaCas();
        final pending = ChangxingJiadaService.instance.fetchUnreadCount();
        await requestStarted.future;

        // 同账号重登：登出 + 再登录，sessionRevision 推进。
        UnifiedAuthService.instance.debugSetSession(
          active: false,
          account: null,
        );
        UnifiedAuthService.instance.notifyListeners();
        UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
        UnifiedAuthService.instance.notifyListeners();
        // 重登后旧绑定立即失效（owner 相同但 revision 已推进），必须重新恢复。
        expect(ChangxingJiadaService.instance.hasToken, isFalse);
        await ChangxingJiadaService.instance.restoreSession();
        expect(ChangxingJiadaService.instance.hasToken, isTrue);

        // 旧会话的迟到数据不得返回。
        gate.complete();
        await expectLater(
          pending,
          throwsA(isA<ChangxingAuthExpiredException>()),
        );

        // 新会话仍可正常请求。
        expect(await ChangxingJiadaService.instance.fetchUnreadCount(), 3);
      },
    );

    test(
      'logout drops the in-flight response and clears the binding',
      () async {
        UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
        final adapter = MockHttpClientAdapter();
        _registerSsoChain(adapter, 'token-a');

        final gate = Completer<void>();
        final requestStarted = Completer<void>();
        adapter.register('GET', '/api/msg/getNoReadCount', (options) async {
          if (!requestStarted.isCompleted) requestStarted.complete();
          await gate.future;
          return _jsonBody({
            'data': {'code': '20000', 'count': 9},
          });
        });
        DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

        await ChangxingJiadaService.instance.loginViaCas();
        final pending = ChangxingJiadaService.instance.fetchUnreadCount();
        await requestStarted.future;

        // 登出：刷新 token 的绑定与落盘 envelope 一并清理。
        await ChangxingJiadaService.instance.logout();
        expect(ChangxingJiadaService.instance.hasToken, isFalse);
        expect(await _readStoredEnvelope(), isNull);

        // 迟到响应必须被丢弃，不得复活已登出的会话。
        gate.complete();
        await expectLater(
          pending,
          throwsA(isA<ChangxingAuthExpiredException>()),
        );
        expect(ChangxingJiadaService.instance.hasToken, isFalse);
      },
    );

    test('in-flight A login save cannot overwrite B envelope and B sends its own token', () async {
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      final adapter = MockHttpClientAdapter();
      _registerSsoChain(adapter, 'token-a');
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      storage.operationLog.clear();
      final heldA = storage.holdNext(
        SecureStorageOperation.write,
        ChangxingJiadaService.tokenStorageKeyV2,
      );
      final loginA = ChangxingJiadaService.instance.loginViaCas();
      // A 已取到 token，落盘写入被挂起（仍在 A 的串行化临界区内）。
      await heldA.started.future;

      // A → B：B 身份下不得读取 / 发送 A 的 token。
      UnifiedAuthService.instance.debugSetSession(active: false, account: null);
      UnifiedAuthService.instance.notifyListeners();
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
      UnifiedAuthService.instance.notifyListeners();
      expect(ChangxingJiadaService.instance.hasToken, isFalse);

      adapter.registerJson('GET', '/api/getToken', {
        'data': {'code': '20000', 'token': 'token-b'},
      });
      final loginB = ChangxingJiadaService.instance.loginViaCas();

      // 串行化：B 的写入必须排在 A 的临界区之后，此刻平台层仍只有 A 的一次写。
      await _pumpEventLoop();
      expect(
        storage.operationLog.where((entry) => entry.startsWith('write:')),
        hasLength(1),
      );

      heldA.release();
      await expectLater(loginA, throwsA(isA<ChangxingCasLoginException>()));
      await loginB;

      // B 赢：落盘 envelope / 内存绑定都属于 B。
      expect(jsonDecode((await _readStoredEnvelope())!), {
        'owner': 'B',
        'token': 'token-b',
      });
      expect(ChangxingJiadaService.instance.debugBoundOwner, 'B');
      expect(ChangxingJiadaService.instance.hasToken, isTrue);

      // B 的后续请求只携带 B 的 token。
      final seenTokens = <String?>[];
      adapter.register('GET', '/api/msg/getNoReadCount', (options) async {
        seenTokens.add(options.headers['token']?.toString());
        return _jsonBody({
          'data': {'code': '20000', 'count': 3},
        });
      });
      expect(await ChangxingJiadaService.instance.fetchUnreadCount(), 3);
      expect(seenTokens, ['token-b']);
    });

    test(
      'in-flight explicit logout cannot delete the B envelope saved afterwards',
      () async {
        UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
        final adapter = MockHttpClientAdapter();
        _registerSsoChain(adapter, 'token-a');
        DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

        await ChangxingJiadaService.instance.loginViaCas();
        expect(jsonDecode((await _readStoredEnvelope())!), {
          'owner': 'A',
          'token': 'token-a',
        });
        final writesBeforeLogout = storage.operationLog
            .where((entry) => entry.startsWith('write:'))
            .length;

        // 明确登出的删除被挂起：模拟 logout 的临界区在途。
        final heldDelete = storage.holdNext(
          SecureStorageOperation.delete,
          ChangxingJiadaService.tokenStorageKeyV2,
        );
        final logout = ChangxingJiadaService.instance.logout();
        await heldDelete.started.future;

        // 用户切到 B 并重新登录。
        UnifiedAuthService.instance.debugSetSession(
          active: false,
          account: null,
        );
        UnifiedAuthService.instance.notifyListeners();
        UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
        UnifiedAuthService.instance.notifyListeners();
        adapter.registerJson('GET', '/api/getToken', {
          'data': {'code': '20000', 'token': 'token-b'},
        });
        final loginB = ChangxingJiadaService.instance.loginViaCas();

        // B 的写入必须等 logout 的临界区结束，不能与删除交错。
        await _pumpEventLoop();
        expect(
          storage.operationLog.where((entry) => entry.startsWith('write:')),
          hasLength(writesBeforeLogout),
        );

        heldDelete.release();
        await logout;
        await loginB;

        // B 赢：B 的 envelope 必须完好，不被在途 / 迟到的 A 清理删除。
        expect(jsonDecode((await _readStoredEnvelope())!), {
          'owner': 'B',
          'token': 'token-b',
        });
        expect(ChangxingJiadaService.instance.hasToken, isTrue);
        expect(ChangxingJiadaService.instance.debugBoundOwner, 'B');
      },
    );

    test('A-started submit POST is never dispatched with B token when identity switches before restore', () async {
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      UnifiedAuthService.instance.notifyListeners();

      // 盘上留有 B 的历史业务 token：pre-fix 会在身份切到 B 后恢复它，
      // 然后把 A 的 payload 以 B 的 token 发出。
      await _seedStoredToken(owner: 'B', token: 'token-b');
      ChangxingJiadaService.instance.debugReset();

      final adapter = MockHttpClientAdapter();
      final sentTokens = <String?>[];
      final sentBodies = <Object?>[];
      adapter.register('POST', '/api/approvalForm/overtime/add', (
        options,
      ) async {
        sentTokens.add(options.headers['token']?.toString());
        sentBodies.add(options.data);
        return _jsonBody({
          'data': {'code': '20000'},
        });
      });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      final heldRead = storage.holdNext(
        SecureStorageOperation.read,
        ChangxingJiadaService.tokenStorageKeyV2,
      );
      // A 发起提交：入口身份必须在任何 await 之前捕获。
      final submit = ChangxingJiadaService.instance.submitOvertime(
        descr: 'A 的加班申请',
      );
      // 立即挂上期望，避免错误在无监听窗口内被当作未处理异步错误上报。
      final submitExpectation = expectLater(
        submit,
        throwsA(isA<ChangxingAuthExpiredException>()),
      );

      // 在 ensureInitialized 之后的窗口内同步切到 B。
      UnifiedAuthService.instance.debugSetSession(active: false, account: null);
      UnifiedAuthService.instance.notifyListeners();
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
      UnifiedAuthService.instance.notifyListeners();

      await _pumpEventLoop();
      final restoreReadStarted = heldRead.started.isCompleted;
      heldRead.release();

      await submitExpectation;

      // 断言的是「业务 POST 根本没有发出」，不是迟到结果被丢弃。
      expect(restoreReadStarted, isFalse);
      expect(adapter.requestLog, isEmpty);
      expect(sentTokens, isEmpty);
      expect(sentBodies, isEmpty);
    });

    test('A-started attachment upload is never dispatched with B token when identity switches before restore', () async {
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      UnifiedAuthService.instance.notifyListeners();

      await _seedStoredToken(owner: 'B', token: 'token-b');
      ChangxingJiadaService.instance.debugReset();

      final tempDir = await Directory.systemTemp.createTemp('cx_upload_');
      addTearDown(() async {
        try {
          if (tempDir.existsSync()) await tempDir.delete(recursive: true);
        } on FileSystemException {
          // Windows 上上传流的文件句柄可能尚未释放；临时目录交给系统清理。
        }
      });
      final file = File('${tempDir.path}${Platform.pathSeparator}note.txt');
      await file.writeAsString('attachment-payload');

      final adapter = MockHttpClientAdapter();
      final sentTokens = <String?>[];
      adapter.register('POST', '/api/image/add/single', (options) async {
        sentTokens.add(options.headers['token']?.toString());
        return _jsonBody({
          'data': {
            'code': '20000',
            'data': {'md5': 'm1', 'base64': ''},
          },
        });
      });
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      final heldRead = storage.holdNext(
        SecureStorageOperation.read,
        ChangxingJiadaService.tokenStorageKeyV2,
      );
      final upload = ChangxingJiadaService.instance.uploadAttachment(
        file.path,
        'note.txt',
      );
      // 立即挂上期望，避免错误在无监听窗口内被当作未处理异步错误上报。
      final uploadExpectation = expectLater(
        upload,
        throwsA(isA<ChangxingAuthExpiredException>()),
      );

      // 身份在 ensureInitialized 窗口内切到 B；pre-fix 会在 restore 之后
      // 以 B 的 token 把 A 发起的附件发出。
      UnifiedAuthService.instance.debugSetSession(active: false, account: null);
      UnifiedAuthService.instance.notifyListeners();
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
      UnifiedAuthService.instance.notifyListeners();

      await _pumpEventLoop();
      final restoreReadStarted = heldRead.started.isCompleted;
      heldRead.release();

      await uploadExpectation;

      // 附件上传根本没有发出，而不是迟到结果被丢弃。
      expect(restoreReadStarted, isFalse);
      expect(adapter.requestLog, isEmpty);
      expect(sentTokens, isEmpty);
    });

    test('identity binding never writes raw token material to logs', () async {
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'A');
      await const FlutterSecureStorage().write(
        key: ChangxingJiadaService.legacyTokenStorageKey,
        value: 'legacy-secret-token',
      );
      final adapter = MockHttpClientAdapter();
      _registerSsoChain(adapter, 'raw-token-a');
      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await ChangxingJiadaService.instance.restoreSession();
      await ChangxingJiadaService.instance.loginViaCas();
      UnifiedAuthService.instance.debugSetSession(active: false, account: null);
      UnifiedAuthService.instance.notifyListeners();
      UnifiedAuthService.instance.debugSetSession(active: true, account: 'B');
      UnifiedAuthService.instance.notifyListeners();
      adapter.registerJson('GET', '/api/getToken', {
        'data': {'code': '20000', 'token': 'raw-token-b'},
      });
      await ChangxingJiadaService.instance.loginViaCas();

      final logged = AppLogger.instance.entries
          .map((entry) => '${entry.message} ${entry.error ?? ''}')
          .join('\n');
      expect(logged, isNot(contains('raw-token-a')));
      expect(logged, isNot(contains('raw-token-b')));
      expect(logged, isNot(contains('legacy-secret-token')));
    });
  });
}
