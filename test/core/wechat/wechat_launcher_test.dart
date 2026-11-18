import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/config/app_config.dart';
import 'package:jxu_campus_hub/core/wechat/wechat_launcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    WechatLauncher.instance.setGatewayForTesting(null);
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
    test('passes sanitized url to the injected gateway', () async {
      final gateway = _FakeWechatGateway()
        ..nextResult = const WechatLaunchResult(
          status: WechatLaunchStatus.launched,
          sanitizedUrl: '',
        );
      WechatLauncher.instance.setGatewayForTesting(gateway);

      final result = await WechatLauncher.instance.openUrlDetailed(
        'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0&code=abc'
        '#/hd-detail?hdId=1&ticket=t',
      );

      expect(result.status, WechatLaunchStatus.launched);
      expect(result.isLaunchRequested, isTrue);
      expect(gateway.urls, hasLength(1));
      expect(gateway.openAppCalls, 0);
      // 一次性凭证不得下发到原生侧 / 微信。
      expect(
        gateway.urls.single,
        'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0#/hd-detail?hdId=1',
      );
    });

    test('forwards the gateway result verbatim', () async {
      final gateway = _FakeWechatGateway()
        ..nextResult = const WechatLaunchResult(
          status: WechatLaunchStatus.noHandler,
          sanitizedUrl: 'native-url',
          route: 'r0',
          detail: 'no external handler',
        );
      WechatLauncher.instance.setGatewayForTesting(gateway);

      final result = await WechatLauncher.instance.openUrlDetailed(
        'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0',
      );

      expect(result.status, WechatLaunchStatus.noHandler);
      expect(result.route, 'r0');
      expect(result.detail, 'no external handler');
      // gateway 结果原样透传，不再由通道回值反推 sanitizedUrl。
      expect(result.sanitizedUrl, 'native-url');
    });

    test('returns channelUnavailable when no gateway is injected', () async {
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
      'rejects empty and unsupported schemes without touching the gateway',
      () async {
        final gateway = _FakeWechatGateway();
        WechatLauncher.instance.setGatewayForTesting(gateway);

        for (final url in ['', '   ', 'ftp://a.cn/x', 'javascript:alert(1)']) {
          final result = await WechatLauncher.instance.openUrlDetailed(url);
          expect(result.status, WechatLaunchStatus.unsupportedUrl, reason: url);
          expect(result.isLaunchRequested, isFalse);
        }
        expect(gateway.urls, isEmpty);
        expect(gateway.openAppCalls, 0);
      },
    );
  });

  group('openWeChatApp', () {
    test('delegates to gateway.openApp and forwards its result', () async {
      for (final status in WechatLaunchStatus.values) {
        final gateway = _FakeWechatGateway()
          ..nextAppResult = WechatLaunchResult(
            status: status,
            sanitizedUrl: '',
            route: 'r0',
          );
        WechatLauncher.instance.setGatewayForTesting(gateway);

        final result = await WechatLauncher.instance.openWeChatApp();

        expect(result.status, status, reason: status.name);
        expect(result.isLaunchRequested, status == WechatLaunchStatus.launched);
        expect(result.sanitizedUrl, isEmpty);
        expect(result.route, 'r0');
        expect(gateway.openAppCalls, 1);
        expect(gateway.urls, isEmpty);
      }
    });

    test('returns channelUnavailable when no gateway is injected', () async {
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
        final gateway = _FakeWechatGateway()
          ..nextResult = const WechatLaunchResult(
            status: WechatLaunchStatus.launched,
            sanitizedUrl: '',
          );
        WechatLauncher.instance.setGatewayForTesting(gateway);
        expect(
          await WechatLauncher.instance.openUrl(
            'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0',
          ),
          isTrue,
        );

        gateway.nextResult = const WechatLaunchResult(
          status: WechatLaunchStatus.noHandler,
          sanitizedUrl: '',
        );
        expect(
          await WechatLauncher.instance.openUrl(
            'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0',
          ),
          isFalse,
        );
      },
    );

    test('returns false when no gateway is injected', () async {
      final opened = await WechatLauncher.instance.openUrl(
        'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0',
      );

      expect(opened, isFalse);
    });
  });
}

/// 记录式 WechatGateway 替身：捕获下发的干净链接与拉起次数，结果可配置。
class _FakeWechatGateway implements WechatGateway {
  final urls = <String>[];
  int openAppCalls = 0;

  WechatLaunchResult? nextResult;
  WechatLaunchResult? nextAppResult;

  @override
  Future<WechatLaunchResult> openUrl(String sanitizedUrl) async {
    urls.add(sanitizedUrl);
    return nextResult ??
        WechatLaunchResult(
          status: WechatLaunchStatus.launched,
          sanitizedUrl: sanitizedUrl,
        );
  }

  @override
  Future<WechatLaunchResult> openApp() async {
    openAppCalls++;
    return nextAppResult ??
        const WechatLaunchResult(
          status: WechatLaunchStatus.launched,
          sanitizedUrl: '',
        );
  }
}
