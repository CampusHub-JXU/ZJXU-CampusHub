import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/second_classroom/second_classroom_wechat_launcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const wechatChannel = MethodChannel('edu.zjxu.jxucampushub/wechat');

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

    final opened = await SecondClassroomWechatLauncher.instance.openUrl(
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
    final opened = await SecondClassroomWechatLauncher.instance.openUrl(
      'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0',
    );

    expect(opened, isFalse);
  });
}
