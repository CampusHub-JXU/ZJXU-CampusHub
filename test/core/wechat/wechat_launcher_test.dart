import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/config/app_config.dart';
import 'package:jxu_campus_hub/core/wechat/wechat_launcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const wechatChannel = MethodChannel('edu.zjxu.jxucampushub/wechat');

  test('xiaofubao recharge uri keeps required wechat parameters', () {
    final uri = AppConfig.xiaofubaoRechargeUri;

    expect(uri.toString(), startsWith(AppConfig.xiaofubaoRechargeBaseUrl));
    expect(uri.queryParameters['platform'], 'WECHAT_H5');
    expect(uri.queryParameters['schoolCode'], AppConfig.xiaofubaoSchoolCode);
    expect(uri.queryParameters['thirdAppid'], AppConfig.xiaofubaoThirdAppId);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wechatChannel, null);
  });

  test('opens url through native WeChat channel', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wechatChannel, (call) async {
          calls.add(call);
          return true;
        });

    final opened = await WechatLauncher.instance.openUrl(
      'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0',
    );

    expect(opened, isTrue);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'openUrlInWeChat');
    expect(calls.single.arguments, {
      'url': 'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0',
    });
  });

  test('returns false when native WeChat channel is unavailable', () async {
    final opened = await WechatLauncher.instance.openUrl(
      'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0',
    );

    expect(opened, isFalse);
  });
}
