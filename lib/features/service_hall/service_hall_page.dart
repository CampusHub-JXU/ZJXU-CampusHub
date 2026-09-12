import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/actions/campus_action_executor.dart';
import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/network/dio_client.dart';
import '../../shared/widgets/unified_auth_protected_webview_page.dart';

class ServiceHallPage extends StatefulWidget {
  const ServiceHallPage({super.key});

  static const titleText = '服务大厅';

  /// 直连入口（校园网内可用，也用作微信侧打开的目标）。
  static const homeUrl =
      'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home';
  static const authLoginDescription = '服务大厅经 WebVPN 访问，请先完成统一认证登录';

  /// 测试替身：跳过真实网关/CAS 网络准备。
  @visibleForTesting
  static Future<String> Function()? debugPrepareEntryOverride;

  /// 站内入口准备（PRD 0.7.0 §27）。
  ///
  /// 设备抓包（2026-09-12）显示：直连 mobilehall 会 302 到 WebVPN 网关，
  /// 而服务大厅 SPA 自身跳的 CAS service 是 ydd 通道
  /// （`https://newca.zjxu.edu.cn/casClient/login/ydd`）。所以校外访问要先
  /// 建好 wengine 网关会话 + ydd 通道会话，再按选路结果给出最终地址。
  /// 流程与校园卡账单页 `prepareStatusPage` 保持一致。
  static Future<String> prepareEntry() async {
    final override = debugPrepareEntryOverride;
    if (override != null) return override();

    await DioClient.instance.ensureInitialized();
    await UnifiedAuthService.instance.restoreSession(syncWebViewCookies: false);
    if (!UnifiedAuthService.instance.isLoggedIn) {
      throw const CasAuthExpiredException();
    }

    final gateway = await ZhengfangAuth.instance
        .ensureWebVpnGatewaySessionResult(
          syncWebViewCookies: true,
          targetUrl: homeUrl,
        );
    if (gateway.ready == false) throw const CasAuthExpiredException();
    if (gateway.ready == null) throw TimeoutException('服务大厅网关暂时无法连接');

    final sessionStatus = await CasSession.ensure(
      CasService.ydd.serviceUrl,
      syncWebViewCookies: false,
    );
    if (sessionStatus == CasSessionStatus.inactive) {
      throw const CasAuthExpiredException();
    }
    if (sessionStatus == CasSessionStatus.unknown) {
      throw TimeoutException('服务大厅认证暂时无法连接');
    }

    final url = gateway.selectedMode == ZhengfangMode.webVpn
        ? ZhengfangAuth.instance.buildWebVpnProxyUrl(homeUrl)
        : homeUrl;
    await UnifiedAuthService.instance.syncCookiesToWebViewForUrl(url);
    return url;
  }

  @override
  State<ServiceHallPage> createState() => _ServiceHallPageState();
}

class _ServiceHallPageState extends State<ServiceHallPage> {
  bool _openingInWeChat = false;

  // PRD 0.7.0 §27：移除进入即自动拉起微信，微信入口改为用户明确点击。
  Future<void> _openInWeChat() async {
    if (_openingInWeChat) return;
    setState(() {
      _openingInWeChat = true;
    });

    AppLogger.instance.webview(
      LogLevel.info,
      '服务大厅尝试在微信中打开: ${ServiceHallPage.homeUrl}',
    );

    await CampusActionExecutor.instance.executeWechat(
      context,
      url: ServiceHallPage.homeUrl,
      title: '服务大厅',
      successMessage: '已打开微信，请在学校公众号服务中继续',
    );
    if (!mounted) return;

    setState(() {
      _openingInWeChat = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return UnifiedAuthProtectedWebViewPage(
      title: ServiceHallPage.titleText,
      url: ServiceHallPage.homeUrl,
      serviceUrl: CasService.ydd.serviceUrl,
      prepareAuthenticatedUrl: ServiceHallPage.prepareEntry,
      loginDescription: ServiceHallPage.authLoginDescription,
      showWebViewBottomBackButton: true,
      onHomePressed: () => context.goNamed('home'),
      appBarActions: [
        IconButton(
          tooltip: '在微信中打开',
          icon: const Icon(Icons.open_in_new),
          onPressed: _openingInWeChat ? null : () => unawaited(_openInWeChat()),
        ),
      ],
    );
  }
}
