import 'package:jxu_campus_hub/core/auth/cas_routed_access.dart';
import 'package:jxu_campus_hub/core/auth/connect_mode_resolver.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';

/// 畅行嘉大测试的选路夹具：统一认证会话校验恒通过，目标直连可达（校内）。
///
/// 必须在 `resetTestEnvironment()` 之后调用（它会清掉这些钩子）。
void installDirectChangxingRoute() {
  UnifiedAuthService.instance.debugSessionValidator = (_) async => true;
  ConnectModeResolver.instance.targetDirectReachabilityChecker = (_) async =>
      true;
  ConnectModeResolver.instance.webVpnReachabilityChecker = () async => false;
  CasRoutedAccess.debugGatewayEnsurer = null;
}

/// 校外夹具：目标直连不可达、WebVPN 可达；网关会话补建记录到 [gatewayCalls]。
void installWebVpnChangxingRoute({List<String>? gatewayCalls}) {
  UnifiedAuthService.instance.debugSessionValidator = (_) async => true;
  ConnectModeResolver.instance.targetDirectReachabilityChecker = (_) async =>
      false;
  ConnectModeResolver.instance.webVpnReachabilityChecker = () async => true;
  CasRoutedAccess.debugGatewayEnsurer = (cancelToken, deadline) async {
    gatewayCalls?.add('gateway');
  };
}

void resetChangxingRouteHooks() {
  CasRoutedAccess.debugGatewayEnsurer = null;
}
