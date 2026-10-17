import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/auth/cas_auth_broker.dart';
import '../../core/auth/cas_routed_access.dart';
import '../../core/auth/login_page_detection.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/network/dio_client.dart';
import 'changxing_api_client.dart';
import 'changxing_jiada_exceptions.dart';
import 'changxing_jiada_token_binding.dart';
import 'changxing_sso_urls.dart';

/// 畅行嘉大 CAS SSO 登录：会话确认 + 选路、逐跳取 tokenId、换 JWT token 并
/// 绑定 owner 落盘。与 API 管线共用 [ChangxingApiClient] 的选路状态。
class ChangxingCasLogin {
  ChangxingCasLogin(this._api);

  final ChangxingApiClient _api;

  ChangxingTokenBinding get _tokenBinding => _api.tokenBinding;

  /// 一次 CAS 登录的总预算（含网关会话、逐跳跟随与一次恢复）。
  static const _loginBudget = Duration(seconds: 30);

  /// 测试用：缩短登录总预算（生产恒为 [_loginBudget]）。
  Duration? debugLoginBudget;

  /// 通过 CAS SSO 登录畅行嘉大。
  /// 前提：用户已通过 UnifiedAuthService 完成一卡通登录；校内直连、校外经
  /// WebVPN 由 [CasRoutedAccess] 按目标 origin 选路（不读写全局模式）。
  /// 全程绑定发起时的 owner + `sessionRevision`：每个 await 边界之后复核，
  /// 任一环节发现身份变化即放弃，且**绝不**把旧身份的 token 写入新会话。
  Future<void> loginViaCas() async {
    final owner = _tokenBinding.currentOwner;
    final revisionAtStart = UnifiedAuthService.instance.sessionRevision;
    if (owner == null) {
      // 没有可信的统一认证身份：token 无归属可绑，不发起无主 SSO。
      throw ChangxingNeedUnifiedAuthException();
    }

    await DioClient.instance.ensureInitialized();
    final dio = DioClient.instance.unifiedAuthDio;

    void ensureIdentityCurrent() {
      if (_tokenBinding.isCurrent(owner, revisionAtStart)) return;
      AppLogger.instance.auth(LogLevel.warn, '畅行嘉大 CAS 登录放弃：统一认证身份或会话修订已变化');
      throw ChangxingCasLoginException('登录状态已变化，请重试');
    }

    ensureIdentityCurrent();

    // 统一认证失效时 broker 可能已撤销会话（身份随之变空）：此时应引导
    // 重新登录；只有已切换到另一身份（仍处于登录态）才算「状态已变化」。
    void ensureNotSwitched() {
      if (_tokenBinding.isCurrent(owner, revisionAtStart)) return;
      if (!UnifiedAuthService.instance.isLoggedIn) return;
      ensureIdentityCurrent();
    }

    final cancelToken = CancelToken();
    final budget = debugLoginBudget ?? _loginBudget;
    final deadline = DateTime.now().add(budget);
    // getResource / prepare 返回时会取消各自的预算计时器，之后的 /getToken
    // 不再受约束：这里持有覆盖整次登录的计时器，到期统一取消共享 token。
    final budgetTimer = Timer(budget, () {
      if (!cancelToken.isCancelled) {
        cancelToken.cancel('changxing login budget exceeded');
      }
    });
    try {
      // 1. 会话确认 + 选路（WebVPN 时先补网关会话）。
      final route = await CasRoutedAccess.prepare(
        service: CasService.changxing,
        targetUrl: ChangxingApiClient.casLoginUrl,
        cancelToken: cancelToken,
        deadline: deadline,
      );
      ensureIdentityCurrent();

      // 2. 发起 CAS 登录并在重定向链里提取 tokenId（命中即停，不消费后续 ticket）。
      // 命中登录 bounce 时只做一次恢复 + 重试，仍失效则引导重新登录一卡通。
      // 第二次仍失效时 CasAuthExpiredException 上抛，由下方外层 catch 统一映射为
      // 「需要重新登录一卡通」。
      final tokenId = await CasRoutedAccess.withRecoverOnce<String?>(
        route: route,
        service: CasService.changxing,
        cancelToken: cancelToken,
        deadline: deadline,
        attempt: () async {
          final id = await _fetchTokenId(
            route,
            cancelToken: cancelToken,
            deadline: deadline,
          );
          ensureIdentityCurrent();
          return id;
        },
        beforeRecover: ensureNotSwitched,
        afterRecover: ensureIdentityCurrent,
      );

      if (tokenId == null || tokenId.isEmpty) {
        AppLogger.instance.auth(LogLevel.warn, '畅行嘉大：SSO 链路结束但未获取到 tokenId');
        throw ChangxingCasLoginException('畅行嘉大登录未完成，请稍后重试');
      }

      // 3. 用 tokenId 换取 JWT token。
      final tokenResp = await dio.getUri<dynamic>(
        Uri.parse(route.url('${ChangxingApiClient.baseUrl}/getToken'))
            .replace(queryParameters: {'tokenId': tokenId}),
        cancelToken: cancelToken,
        options: _api.apiOptions(headers: {'token': '0'}),
      );
      ensureIdentityCurrent();

      final Map<String, dynamic> json;
      try {
        json = _api.jsonOrBounce(tokenResp);
      } on ChangxingApiLoginBounce {
        _api.invalidateRouteLease();
        throw ChangxingCasLoginException('畅行嘉大登录未完成，请稍后重试');
      }
      final data = json['data'] as Map<String, dynamic>? ?? {};
      final code = data['code']?.toString() ?? '';
      if (code != '20000') {
        final msg = data['msg']?.toString() ?? '获取 token 失败';
        throw ChangxingCasLoginException(msg);
      }

      final jwtToken = data['token']?.toString().trim() ?? '';
      if (jwtToken.isEmpty) {
        throw ChangxingCasLoginException('CAS 认证成功但未获取到 token');
      }

      // 写入前最后一次复核：身份已变化则拒绝保存（含绑定 owner）。
      final saved = await _tokenBinding.saveIfCurrent(
        token: jwtToken,
        owner: owner,
        revision: revisionAtStart,
      );
      if (!saved) {
        AppLogger.instance.auth(LogLevel.warn, '畅行嘉大 CAS 登录放弃：写入前身份已变化');
        throw ChangxingCasLoginException('登录状态已变化，请重试');
      }
      // 本次选路已被完整链路验证：供后续 API 调用短期复用。
      _api.rememberRoute(route: route, owner: owner, revision: revisionAtStart);
      AppLogger.instance.auth(LogLevel.info, '畅行嘉大 CAS SSO 登录成功');
    } on CasAuthExpiredException {
      // prepare / recover 明确判定统一认证失效（broker 对显式失效的既有
      // 处理可能已撤销会话）。本层不清全局会话、不 markLoggedOut。
      ensureNotSwitched();
      AppLogger.instance.auth(LogLevel.warn, '畅行嘉大：统一认证会话已失效，需要重新登录一卡通');
      throw ChangxingNeedUnifiedAuthException();
    } on TimeoutException catch (e) {
      // 网络不确定（探测 / 网关 / 统一认证暂不可达）：可重试，不算登录过期。
      throw ChangxingCasLoginException(e.message ?? '服务暂时无法连接，请稍后重试');
    } on StateError catch (e) {
      AppLogger.instance.auth(LogLevel.warn, '畅行嘉大：SSO 链路异常 ${e.message}');
      throw ChangxingCasLoginException('畅行嘉大登录未完成，请稍后重试');
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        AppLogger.instance.auth(LogLevel.warn, '畅行嘉大 CAS 登录超时或被取消');
        throw ChangxingCasLoginException('畅行嘉大登录超时，请稍后重试');
      }
      AppLogger.instance.auth(
        LogLevel.error,
        '畅行嘉大 CAS 登录网络异常: ${e.type} ${e.message}',
      );
      throw ChangxingCasLoginException('网络异常：${e.message}');
    } finally {
      budgetTimer.cancel();
      if (!cancelToken.isCancelled) cancelToken.cancel('changxing login done');
    }
  }

  /// 沿 `cas_wap_login` 走 CAS 链路并返回 tokenId；链路落到登录页 / 网关
  /// 登录页时抛 [CasAuthExpiredException]，链路结束却没有 tokenId 返回 null。
  ///
  /// 经 [CasAuthBroker.getResource] 逐跳跟随，命中带 tokenId 的 Location 即停。
  /// WebVPN 下网关对 newca 的代理登录页（`/https/<enc>/cas/login`，共享
  /// 中间层只识别 http 形态）与站点回调（直连形态
  /// `http://zhx...:8443/...?ticket=`）都需要按本次路由改写后续走：
  /// 在这两处停下，分别还原真实 newca 登录入口 / 改写为代理回调地址，
  /// 绝不回退直连。
  Future<String?> _fetchTokenId(
    CasRoute route, {
    required CancelToken cancelToken,
    required DateTime deadline,
  }) async {
    var url = route.url(ChangxingApiClient.casLoginUrl);
    for (var leg = 0; leg < 5; leg++) {
      final response = await CasAuthBroker.getResource(
        url,
        cancelToken: cancelToken,
        deadline: deadline,
        needsLogin: _isLoginBounce,
        stopAtRedirect: (next) =>
            _extractTokenId(
                  normalizeChangxingSsoRedirectUrl(next.toString()),
                ) !=
                null ||
            (route.isWebVpn && _needsRouteRewrite(next)),
      );

      final status = response.statusCode ?? 0;
      final location = response.headers.value('location') ?? '';
      if (status >= 300 && status < 400 && location.isNotEmpty) {
        final next = response.realUri.resolve(location);
        final normalized = normalizeChangxingSsoRedirectUrl('$next');
        final tokenId = _extractTokenId(normalized);
        if (tokenId != null) return tokenId;
        if (route.isWebVpn && _isProxiedCasLogin(next)) {
          url = normalized;
          continue;
        }
        if (route.isWebVpn && _isDirectCasCallback(next)) {
          url = route.url('$next');
          continue;
        }
        return null;
      }

      // 非重定向终点：兜底检查最终 URL 是否带 tokenId。
      return _extractTokenId(
        normalizeChangxingSsoRedirectUrl(response.realUri.toString()),
      );
    }
    return null;
  }

  bool _needsRouteRewrite(Uri uri) =>
      _isProxiedCasLogin(uri) || _isDirectCasCallback(uri);

  /// WebVPN 网关代理的统一认证登录页（没有 newca 的 SSO Cookie）。
  bool _isProxiedCasLogin(Uri uri) =>
      uri.host.toLowerCase() == 'webvpn.zjxu.edu.cn' &&
      uri.path.toLowerCase().endsWith('/cas/login');

  /// 站点 CAS 回调（直连形态）：WebVPN 路由下需改写后再请求。
  bool _isDirectCasCallback(Uri uri) =>
      uri.host.toLowerCase() == 'zhx.zjxu.edu.cn' &&
      uri.path.contains('/cas_login_back');

  /// 登录页判定：统一认证登录页 / WebVPN 网关登录页（会话缺失的 bounce）。
  bool _isLoginBounce(Response<List<int>> response) {
    final html = utf8.decode(response.data ?? const [], allowMalformed: true);
    return classifyLoginExchange(
          realUrl: response.realUri.toString(),
          html: html,
          kinds: casAndGatewayLoginKinds,
        ) !=
        null;
  }

  String? _extractTokenId(String url) {
    final uri = Uri.tryParse(url);
    final tokenId = uri?.queryParameters['tokenId']?.trim() ?? '';
    return tokenId.isEmpty ? null : tokenId;
  }
}
