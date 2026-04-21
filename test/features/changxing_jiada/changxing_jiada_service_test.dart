import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_service.dart';

void main() {
  group('Changxing unified auth response detection', () {
    test('treats CAS login form html as expired unified auth session', () {
      expect(
        ChangxingJiadaService.isUnifiedAuthLoginFormResponse(
          'https://newca.zjxu.edu.cn/cas/login?service=http%3A%2F%2Fzhx.zjxu.edu.cn%3A8443%2Fapi%2Fwap%2Fcas_login_back',
          '''
          <html>
            <form id="fm1">
              <input type="hidden" name="lt" value="LT-1" />
              <input type="hidden" name="execution" value="e1s1" />
            </form>
          </html>
          ''',
        ),
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
          ChangxingJiadaService.isUnifiedAuthLoginFormResponse(
            'https://webvpn.zjxu.edu.cn/https/77726476706e69737468656265737421fef2569f267e725a661dc7a99c406d362a/cas/login?service=http%3A%2F%2Fzhx.zjxu.edu.cn%3A8443%2Fapi%2Fwap%2Fcas_login_back',
            '''
          <html>
            <form id="fm1">
              <input type="hidden" name="lt" value="LT-1" />
              <input type="hidden" name="execution" value="e1s1" />
            </form>
          </html>
          ''',
          ),
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
}
