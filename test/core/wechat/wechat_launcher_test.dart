import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/config/app_config.dart';
import 'package:jxu_campus_hub/core/wechat/wechat_launcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const wechatChannel = MethodChannel('edu.zjxu.jxucampushub/wechat');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wechatChannel, null);
  });

  test('xiaofubao recharge uri keeps required wechat parameters', () {
    final uri = AppConfig.xiaofubaoRechargeUri;

    expect(uri.toString(), startsWith(AppConfig.xiaofubaoRechargeBaseUrl));
    expect(uri.queryParameters['platform'], 'WECHAT_H5');
    expect(uri.queryParameters['schoolCode'], AppConfig.xiaofubaoSchoolCode);
    expect(uri.queryParameters['thirdAppid'], AppConfig.xiaofubaoThirdAppId);
  });

  group('sanitizeWechatShareUrl', () {
    test('剥离主 URL query 中的一次性认证参数并保留业务参数', () {
      expect(
        sanitizeWechatShareUrl(
          'https://webapp.xiaofubao.com/pay?schoolCode=001&platform=WECHAT_H5'
          '&ticket=t-123&thirdAppid=wx1',
        ),
        'https://webapp.xiaofubao.com/pay?schoolCode=001&platform=WECHAT_H5'
        '&thirdAppid=wx1',
      );
    });

    test('剥离 hash 路由内部 query 的认证参数并保留路由与业务参数', () {
      expect(
        sanitizeWechatShareUrl(
          'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0'
          '#/hd-detail?hdId=2485&code=abc&state=s1',
        ),
        'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0'
        '#/hd-detail?hdId=2485',
      );
    });

    test('认证参数匹配大小写不敏感', () {
      expect(
        sanitizeWechatShareUrl('https://a.cn/x?TICKET=1&Code=2&hdId=3'),
        'https://a.cn/x?hdId=3',
      );
    });

    test('fragment 中无 query 或非认证参数时原样保留', () {
      expect(
        sanitizeWechatShareUrl('https://a.cn/x#/portal/home'),
        'https://a.cn/x#/portal/home',
      );
      expect(
        sanitizeWechatShareUrl('https://a.cn/x#/p?hdId=1&foo=bar'),
        'https://a.cn/x#/p?hdId=1&foo=bar',
      );
    });

    test('无认证参数时输出不变', () {
      const url = 'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0';
      expect(sanitizeWechatShareUrl(url), url);
    });
  });

  group('openUrlDetailed', () {
    test(
      'opens url through native WeChat channel with sanitized url',
      () async {
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(wechatChannel, (call) async {
              calls.add(call);
              return true;
            });

        final result = await WechatLauncher.instance.openUrlDetailed(
          'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0&code=abc'
          '#/hd-detail?hdId=1&ticket=t',
        );

        expect(result.status, WechatLaunchStatus.launched);
        expect(result.isLaunchRequested, isTrue);
        expect(calls, hasLength(1));
        expect(calls.single.method, 'openUrlInWeChat');
        // 一次性凭证不得下发到原生侧 / 微信。
        expect(calls.single.arguments, {
          'url': 'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0#/hd-detail?hdId=1',
        });
      },
    );

    test('maps native status strings to launch statuses', () async {
      const cases = <String, WechatLaunchStatus>{
        'launched': WechatLaunchStatus.launched,
        'not_installed': WechatLaunchStatus.notInstalled,
        'unsupported_url': WechatLaunchStatus.unsupportedUrl,
        'no_handler': WechatLaunchStatus.noHandler,
        'launch_failed': WechatLaunchStatus.launchFailed,
      };
      for (final entry in cases.entries) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              wechatChannel,
              (call) async => {'status': entry.key, 'route': 'r0'},
            );
        final result = await WechatLauncher.instance.openUrlDetailed(
          'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0',
        );
        expect(result.status, entry.value, reason: entry.key);
        expect(result.route, 'r0');
        expect(
          result.sanitizedUrl,
          'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0',
        );
      }
    });

    test(
      'bool channel reply maps true/false to launched/launchFailed',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(wechatChannel, (call) async => false);
        final result = await WechatLauncher.instance.openUrlDetailed(
          'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0',
        );
        expect(result.status, WechatLaunchStatus.launchFailed);
        expect(result.isLaunchRequested, isFalse);
      },
    );

    test('returns channelUnavailable when native channel is missing', () async {
      final result = await WechatLauncher.instance.openUrlDetailed(
        'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0',
      );

      expect(result.status, WechatLaunchStatus.channelUnavailable);
      expect(result.isLaunchRequested, isFalse);
      expect(
        result.sanitizedUrl,
        'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0',
      );
    });

    test(
      'rejects empty and unsupported schemes without touching channel',
      () async {
        var called = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(wechatChannel, (call) async {
              called = true;
              return true;
            });

        for (final url in ['', '   ', 'ftp://a.cn/x', 'javascript:alert(1)']) {
          final result = await WechatLauncher.instance.openUrlDetailed(url);
          expect(result.status, WechatLaunchStatus.unsupportedUrl, reason: url);
          expect(result.isLaunchRequested, isFalse);
        }
        expect(called, isFalse);
      },
    );
  });

  group('openWeChatApp', () {
    test('invokes openWeChatApp method and maps native status', () async {
      const cases = <String, WechatLaunchStatus>{
        'launched': WechatLaunchStatus.launched,
        'not_installed': WechatLaunchStatus.notInstalled,
        'unsupported_url': WechatLaunchStatus.unsupportedUrl,
        'no_handler': WechatLaunchStatus.noHandler,
        'launch_failed': WechatLaunchStatus.launchFailed,
      };
      for (final entry in cases.entries) {
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(wechatChannel, (call) async {
              calls.add(call);
              return {'status': entry.key, 'route': 'r0'};
            });
        final result = await WechatLauncher.instance.openWeChatApp();
        expect(result.status, entry.value, reason: entry.key);
        expect(
          result.isLaunchRequested,
          entry.value == WechatLaunchStatus.launched,
        );
        expect(result.sanitizedUrl, isEmpty);
        expect(result.route, 'r0');
        expect(calls.map((call) => call.method), ['openWeChatApp']);
      }
    });

    test(
      'bool channel reply maps true/false to launched/launchFailed',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(wechatChannel, (call) async => true);
        var result = await WechatLauncher.instance.openWeChatApp();
        expect(result.status, WechatLaunchStatus.launched);
        expect(result.isLaunchRequested, isTrue);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(wechatChannel, (call) async => false);
        result = await WechatLauncher.instance.openWeChatApp();
        expect(result.status, WechatLaunchStatus.launchFailed);
        expect(result.isLaunchRequested, isFalse);
      },
    );

    test('returns channelUnavailable when native channel is missing', () async {
      final result = await WechatLauncher.instance.openWeChatApp();

      expect(result.status, WechatLaunchStatus.channelUnavailable);
      expect(result.isLaunchRequested, isFalse);
      expect(result.sanitizedUrl, isEmpty);
    });
  });

  group('openUrl', () {
    test(
      'delegates to openUrlDetailed and reports launch request only',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              wechatChannel,
              (call) async => {'status': 'launched'},
            );
        expect(
          await WechatLauncher.instance.openUrl(
            'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0',
          ),
          isTrue,
        );

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              wechatChannel,
              (call) async => {'status': 'no_handler'},
            );
        expect(
          await WechatLauncher.instance.openUrl(
            'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0',
          ),
          isFalse,
        );
      },
    );

    test('returns false when native WeChat channel is unavailable', () async {
      final opened = await WechatLauncher.instance.openUrl(
        'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0',
      );

      expect(opened, isFalse);
    });
  });
}
