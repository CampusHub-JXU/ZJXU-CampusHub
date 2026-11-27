import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/features/service_hall/service_hall_page.dart';

import '../../helpers/fake_inappwebview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    InAppWebViewPlatform.instance = FakeInAppWebViewPlatform();
  });

  tearDown(() {
    UnifiedAuthService.instance.debugReset();
    CasAuthBroker.debugGetResourceOverride = null;
    ServiceHallPage.debugPrepareEntryOverride = null;
  });

  test('uses the expected service hall protected webview configuration', () {
    expect(ServiceHallPage.titleText, '服务大厅');
    expect(
      ServiceHallPage.homeUrl,
      'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home',
    );
    // PRD 0.7.0 §27 审计：服务大厅 SPA 自身跳的 CAS service 就是 ydd 通道。
    expect(
      CasService.ydd.serviceUrl,
      'https://newca.zjxu.edu.cn/casClient/login/ydd',
    );
    expect(ServiceHallPage.authLoginDescription, contains('统一认证'));
  });

  testWidgets('does not render open in wechat button in app bar', (
    tester,
  ) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2024001',
    );
    UnifiedAuthService.instance.debugSessionMetadataLoader = () async =>
        '2024001';
    UnifiedAuthService.instance.debugSessionValidator = (_) async => true;
    ServiceHallPage.debugPrepareEntryOverride = () async =>
        ServiceHallPage.homeUrl;
    UnifiedAuthService.instance.debugSyncCookiesToWebViewForUrlOverride = (
      _,
    ) async {};

    await tester.pumpWidget(const MaterialApp(home: ServiceHallPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byTooltip('在微信中打开'), findsNothing);
  });
}
