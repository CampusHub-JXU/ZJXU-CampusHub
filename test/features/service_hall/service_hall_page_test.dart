import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/features/service_hall/service_hall_page.dart';

import '../../helpers/fake_inappwebview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const wechatChannel = MethodChannel('edu.zjxu.jxucampushub/wechat');

  setUpAll(() {
    InAppWebViewPlatform.instance = FakeInAppWebViewPlatform();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wechatChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
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

  testWidgets('wechat launch failure offers copy of exact home url', (
    tester,
  ) async {
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: '2024001',
    );
    UnifiedAuthService.instance.debugSessionMetadataLoader = () async =>
        '2024001';
    UnifiedAuthService.instance.debugSessionValidator = (_) async => true;
    // 入口准备在测试环境中不能走真实网关/CAS 网络。
    ServiceHallPage.debugPrepareEntryOverride = () async =>
        ServiceHallPage.homeUrl;
    UnifiedAuthService.instance.debugSyncCookiesToWebViewForUrlOverride = (
      _,
    ) async {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wechatChannel, (call) async => false);
    final clipboard = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });

    await tester.pumpWidget(const MaterialApp(home: ServiceHallPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // PRD 0.7.0 §27：不再进入即自动拉起微信，改由用户明确点击。
    await tester.tap(find.byTooltip('在微信中打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('未能打开页面，可复制链接后到微信中打开'), findsOneWidget);
    expect(find.textContaining('已安装微信'), findsNothing);
    expect(find.widgetWithText(SnackBarAction, '复制链接'), findsOneWidget);

    await tester.ensureVisible(find.widgetWithText(SnackBarAction, '复制链接'));
    await tester.tap(find.widgetWithText(SnackBarAction, '复制链接'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(clipboard, [ServiceHallPage.homeUrl]);
    expect(find.text('链接已复制'), findsOneWidget);
  });
}
