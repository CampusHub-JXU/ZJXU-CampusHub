import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/second_classroom/second_classroom_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const wechatChannel = MethodChannel('edu.zjxu.jxucampushub/wechat');

  setUpAll(() {
    InAppWebViewPlatform.instance = _FakeInAppWebViewPlatform();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wechatChannel, null);
  });

  test('detects second classroom auth provider entry urls', () {
    expect(
      isSecondClassroomAuthProviderEntryUrl(
        '${SecondClassroomPage.authEntryUrl}test-code',
      ),
      isTrue,
    );
    expect(
      isSecondClassroomAuthProviderEntryUrl(SecondClassroomPage.initialUrl),
      isFalse,
    );
  });

  test('detects second classroom landing root urls', () {
    expect(
      isSecondClassroomLandingRootUrl('https://twdekt.zjxu.edu.cn/dekt/'),
      isTrue,
    );
    expect(
      isSecondClassroomLandingRootUrl('https://twdekt.zjxu.edu.cn/dekt'),
      isTrue,
    );
    expect(
      isSecondClassroomLandingRootUrl(SecondClassroomPage.initialUrl),
      isFalse,
    );
  });

  test('detects WeChat OAuth urls', () {
    expect(
      isSecondClassroomWeChatAuthUri(
        Uri.parse(
          'https://open.weixin.qq.com/connect/oauth2/authorize?appid=wx123',
        ),
      ),
      isTrue,
    );
    expect(
      isSecondClassroomWeChatAuthUri(
        Uri.parse('https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0'),
      ),
      isFalse,
    );
  });

  test('detects anonymous second classroom state', () {
    expect(isSecondClassroomAnonymousState({'hasAnonymous': true}), isTrue);
    expect(isSecondClassroomAnonymousState({'hasGuest': true}), isTrue);
    expect(isSecondClassroomAnonymousState({'hasMyPage': true}), isFalse);
  });

  testWidgets('opens second classroom in WeChat from app bar', (tester) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wechatChannel, (call) async {
          calls.add(call);
          return true;
        });

    await tester.pumpWidget(const MaterialApp(home: SecondClassroomPage()));
    await tester.pump();

    await tester.tap(find.byTooltip('在微信中打开'));
    await tester.pumpAndSettle();

    expect(calls.map((call) => call.method), contains('openUrlInWeChat'));
    expect(
      (calls.last.arguments as Map<Object?, Object?>)['url'],
      SecondClassroomPage.initialUrl,
    );
    expect(find.text('已打开微信，请在微信中完成第二课堂授权'), findsOneWidget);
  });
}

class _FakeInAppWebViewPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    return _FakePlatformInAppWebViewWidget(params);
  }
}

class _FakePlatformInAppWebViewWidget extends PlatformInAppWebViewWidget {
  _FakePlatformInAppWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) {
    throw UnimplementedError('Controller is not used by this test fake.');
  }

  @override
  void dispose() {}
}
