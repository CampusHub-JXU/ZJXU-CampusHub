import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/protected_web_entry_preparer.dart';
import '../../shared/widgets/unified_auth_protected_webview_page.dart';
import 'library_service.dart';
import 'library_session.dart';

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  static const titleText = '图书馆';

  /// 图书馆站点根：WebView 的兜底地址与业务主页。
  ///
  /// 它不是 CAS service，也不是 SSO 入口（站点根只渲染站点自带的
  /// 一卡通/密码登录页）。图书馆的 CAS 校验入口是
  /// `Info/Thirdparty/ssoFromDingDing`（见 [prepareEntry]）。
  static const libraryUrl = 'https://libapp.zjxu.edu.cn/';

  static const authLoginDescription = '图书馆经 WebVPN 访问，请先完成统一认证登录';

  /// 测试替身：跳过真实网关/CAS 网络准备。
  @visibleForTesting
  static Future<String> Function()? debugPrepareEntryOverride;

  /// 站内入口准备（PRD 0.7.0 §32）。
  ///
  /// 图书馆的 CAS service 是 `Info/Thirdparty/ssoFromDingDing`：抓包实证
  /// （2026-09-12）直连该地址会 302 到 `newca.zjxu.edu.cn/cas/login` 并把
  /// 该地址作为 `service` 参数；设备日志（2026-09-13）确认 CAS 签发的 ticket
  /// 同样回投该地址。名称中的 DingDing 只是历史命名，并非钉钉容器专属。
  ///
  /// 因此这里只准备注册的精确 service：[ProtectedWebEntryPreparer.prepare]
  /// 内部按「统一认证主会话 → WebVPN 网关 → [CasSession.ensure]（精确 service）
  /// → 同步 WebView Cookie」执行。ensure 的 ticket 回调本身就是图书馆业务
  /// 会话的建立过程，三步全部成功后才返回可打开的地址。
  ///
  /// 服务 URL 是 ticket 消费者而不是业务资源，进入 WebView 前不得再对它调用
  /// [CasAuthBroker.getResource]：那等于在 ensure 之后重跑一次 SSO，真实日志
  /// 里该链最终回落到 `https://webvpn.zjxu.edu.cn` 门户页并被误判成
  /// 「统一认证登录已失效」，预热被吞掉后 WebView 只能再次落到 CAS。会话是
  /// 否就绪一律由 ensure 三态决定：inactive → [CasAuthExpiredException] 走
  /// 原生登录引导，unknown → [TimeoutException] 给网络重试，都不交给
  /// WebView 继续 SSO。
  static Future<String> prepareEntry() async {
    final override = debugPrepareEntryOverride;
    if (override != null) return override();

    return ProtectedWebEntryPreparer.prepare(
      targetUrl: CasService.librarySso.serviceUrl,
      serviceUrl: CasService.librarySso.serviceUrl,
      // 设备日志：libapp 直连探测 302「可达」，但 WebView 直连必被断开
      // （net::ERR_CONNECTION_CLOSED），所以图书馆固定走 WebVPN 代理。
      forceWebVpn: true,
      gatewayTimeoutMessage: '图书馆网关暂时无法连接',
      authTimeoutMessage: '图书馆认证暂时无法连接',
    );
  }

  @override
  Widget build(BuildContext context) {
    return UnifiedAuthProtectedWebViewPage(
      title: titleText,
      url: libraryUrl,
      serviceUrl: CasService.librarySso.serviceUrl,
      prepareAuthenticatedUrl: prepareEntry,
      loginDescription: authLoginDescription,
      // prepareEntry 已用注册 service 的 CasSession.ensure 确认统一认证主会话
      // 有效；此后 WebView 再被 CAS 弹回属于业务 / 网关 Cookie 问题，不是主
      // 会话过期。停在原生认证视图等用户显式重试，不清全局统一认证会话。
      preserveSessionOnAuthBounce: true,
      // 图书馆 SSO 经 CAS `oauth/forward`。App 注入的 dd mock 会让该页误判
      // 钉钉容器并自动改走钉钉 OAuth，随后固定 onFail 卡死（设备实测
      // 2026-09-12；体测页同为该问题，关闭模拟后恢复）。图书馆站点本身
      // 不依赖钉钉，关闭模拟让 CAS 流程正常走完。
      emulateDingTalkEnvironment: false,
      // 不开快速填充：图书馆登录页由自研 lrnw 框架控制，只有真实键盘输入
      // 才会写入它的表单模型；JS 写 value 会让「登录」按钮永久 disabled
      // （设备实测 2026-09-12），反而误导用户。详见 E3/E4 进展记录。
      showWebViewBottomBackButton: true,
      onHomePressed: () => context.goNamed('home'),
      // 「我的借阅」已是原生页（PRD 0.7.0 §34）：借阅/续借走汇图接口，
      // 令牌从这个 WebView 自己的 localStorage 取（隐藏 WebView 取不到，
      // 见 LibrarySession 说明）。
      onLoadStop: (controller, url) =>
          LibrarySession.instance.captureFrom(controller),
      appBarActions: <Widget>[
        IconButton(
          tooltip: '我的借阅',
          icon: const Icon(Icons.menu_book_outlined),
          onPressed: () => context.pushNamed('library-borrows'),
        ),
      ],
      // 书目详情改由原生页接管（PRD 0.7.0 §34）：汇图接口免登录即可给出
      // 索书号、馆藏位置与可借册数，比 H5 页面更直接。
      onNavigationRequest: (controller, uri) async {
        final bid = LibraryService.bidFromDetailUrl(uri);
        if (bid == null) return null;
        await context.pushNamed(
          'library-book',
          pathParameters: <String, String>{'bid': bid},
        );
        return NavigationActionPolicy.CANCEL;
      },
    );
  }
}
