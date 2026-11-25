import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/auth/cas_routed_access.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/route_failure.dart';

import '../../helpers/test_setup.dart';

void main() {
  late int gatewayCalls;

  setUp(() async {
    await resetTestEnvironment();
    gatewayCalls = 0;
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'TEST_STUDENT_0001',
    );
    UnifiedAuthService.instance.debugSessionValidator = (_) async => true;
    ConnectModeResolver.instance.targetDirectReachabilityChecker = (_) async =>
        true;
    CasRoutedAccess.debugGatewayEnsurer = (_, _) async => gatewayCalls++;
  });

  tearDown(() {
    CasRoutedAccess.debugGatewayEnsurer = null;
  });

  test('直连可达：返回直连路由，不建网关，URL 原样', () async {
    final route = await CasRoutedAccess.prepare(
      service: CasService.physicalTest,
      targetUrl: 'http://jkjy.zjxu.edu.cn/weixin/main.jsp',
    );

    expect(route.mode, ZhengfangMode.direct);
    expect(gatewayCalls, 0);
    expect(
      route.url('http://jkjy.zjxu.edu.cn/weixin/main.jsp'),
      'http://jkjy.zjxu.edu.cn/weixin/main.jsp',
    );
  });

  test('直连不可达走 WebVPN：先建网关，URL 重建为代理地址，且不写全局 mode', () async {
    ConnectModeResolver.instance.targetDirectReachabilityChecker = (_) async =>
        false;
    ConnectModeResolver.instance.webVpnReachabilityChecker = () async => true;
    final globalBefore = ZhengfangAuth.instance.mode;

    final route = await CasRoutedAccess.prepare(
      service: CasService.physicalTest,
      targetUrl: 'http://jkjy.zjxu.edu.cn/weixin/main.jsp',
    );

    expect(route.mode, ZhengfangMode.webVpn);
    expect(gatewayCalls, 1);
    expect(
      Uri.parse(route.url('http://jkjy.zjxu.edu.cn/weixin/main.jsp')).host,
      'webvpn.zjxu.edu.cn',
    );
    expect(ZhengfangAuth.instance.mode, globalBefore);
  });

  test('统一认证明确失效抛 CasAuthExpiredException，未知抛 TimeoutException', () async {
    UnifiedAuthService.instance.debugSessionValidator = (_) async => false;
    await expectLater(
      CasRoutedAccess.prepare(
        service: CasService.physicalTest,
        targetUrl: 'http://jkjy.zjxu.edu.cn/weixin/main.jsp',
      ),
      throwsA(isA<CasAuthExpiredException>()),
    );

    // 明确失效已让统一认证标记登出；恢复会话后再测「校验不确定」。
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'TEST_STUDENT_0001',
    );
    UnifiedAuthService.instance.debugSessionValidator = (_) async => null;
    await expectLater(
      CasRoutedAccess.prepare(
        service: CasService.physicalTest,
        targetUrl: 'http://jkjy.zjxu.edu.cn/weixin/main.jsp',
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('直连与 WebVPN 都不可达：TimeoutException（不代表登录过期）', () async {
    ConnectModeResolver.instance.targetDirectReachabilityChecker = (_) async =>
        false;
    ConnectModeResolver.instance.webVpnReachabilityChecker = () async => false;

    await expectLater(
      CasRoutedAccess.prepare(
        service: CasService.physicalTest,
        targetUrl: 'http://jkjy.zjxu.edu.cn/weixin/main.jsp',
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(gatewayCalls, 0);
  });

  test('recover：WebVPN 重建网关后重验 service；直连只重验 service', () async {
    await CasRoutedAccess.recover(
      const CasRoute(ZhengfangMode.direct),
      service: CasService.physicalTest,
    );
    expect(gatewayCalls, 0);

    await CasRoutedAccess.recover(
      const CasRoute(ZhengfangMode.webVpn),
      service: CasService.physicalTest,
    );
    expect(gatewayCalls, 1);

    UnifiedAuthService.instance.debugSessionValidator = (_) async => false;
    await expectLater(
      CasRoutedAccess.recover(
        const CasRoute(ZhengfangMode.direct),
        service: CasService.physicalTest,
      ),
      throwsA(isA<CasAuthExpiredException>()),
    );
  });

  test('网关失败只重探一次，直连确认可用后返回直连路由', () async {
    const target = 'http://jkjy.zjxu.edu.cn/weixin/main.jsp';
    var probes = 0;
    ConnectModeResolver.instance.directVerdictChecker = (_) async =>
        ++probes == 1 ? RouteVerdict.webVpnRedirected : RouteVerdict.direct;
    CasRoutedAccess.debugGatewayEnsurer = (_, _) async {
      gatewayCalls++;
      throw TimeoutException('mock gateway timeout');
    };

    final route = await CasRoutedAccess.prepare(
      service: CasService.physicalTest,
      targetUrl: target,
    );
    expect(route.mode, ZhengfangMode.direct);
    expect(route.url(target), target);
    expect(probes, 2);
    expect(gatewayCalls, 1);
  });

  test('网关失败且直连仍被改道时保留网关错误', () async {
    const target = 'http://jkjy.zjxu.edu.cn/weixin/main.jsp';
    ConnectModeResolver.instance.directVerdictChecker = (_) async =>
        RouteVerdict.webVpnRedirected;
    CasRoutedAccess.debugGatewayEnsurer = (_, _) async =>
        throw StateError('mock malformed redirect');
    await expectLater(
      CasRoutedAccess.prepare(
        service: CasService.physicalTest,
        targetUrl: target,
      ),
      throwsA(
        isA<RouteFailure>().having(
          (error) => error.reason,
          'reason',
          RouteFailureReason.webVpnGatewayFailed,
        ),
      ),
    );
  });
}
