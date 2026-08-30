import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_service.dart';

import '../../helpers/mock_http_client_adapter.dart';
import '../../helpers/test_setup.dart';

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
    });

    test('captures token from first SSO redirect chain', () async {
      const casLoginLocation =
          'https://newca.zjxu.edu.cn/cas/login?service=https%3A%2F%2Fzhx.zjxu.edu.cn%2Fapi%2Fcas_wap_login';
      const tokenCallback =
          'http://zhx.zjxu.edu.cn:8443/api/wap/cas_login_back?tokenId=T-1';

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
        ..registerText(
          'GET',
          '/cas/login',
          '',
          statusCode: 302,
          headers: {
            'location': [tokenCallback],
          },
        )
        ..registerJson('GET', '/api/getToken', {
          'data': {'code': '20000', 'token': 'jwt-token'},
        });

      DioClient.instance.unifiedAuthDio.httpClientAdapter = adapter;

      await ChangxingJiadaService.instance.loginViaCas();

      expect(ChangxingJiadaService.instance.hasToken, isTrue);
      expect(adapter.requestLog, [
        'GET /api/cas_wap_login',
        'GET /cas/login',
        'GET /api/getToken',
      ]);
    });

    test('asks for unified auth when SSO chain ends on login form', () async {
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

      expect(adapter.requestLog, ['GET /api/cas_wap_login', 'GET /cas/login']);
    });
  });
}
