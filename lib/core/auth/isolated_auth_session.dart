import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';

import '../network/cookie_interceptor.dart';
import '../network/proxy_fallback.dart';

/// 一次验证码事务的**隔离网络会话**：独立内存 [CookieJar] + 冻结的 [Dio]。
///
/// 动机：验证码图片与登录表单（lt/execution/csrftoken）绑定在服务端 session
/// 上。若 prepare A 与 prepare B 共用可变 CookieJar，会出现
/// `context_A + cookie_B + image_B` 的串扰。这里为每个 challenge 建独立 jar，
/// 并在 prepare 时从**可信来源**快照初始 cookie（CAS 当前 unified jar /
/// 教务当前模式对应 jar / WebVPN 网关 cookie），此后该 challenge 的所有请求
/// 只读写自己的 jar。
///
/// 成功提交时才把该 jar 的 cookie 合并回共享 jar（由调用方在 epoch 条件
/// 提交内执行），因此提交期间其他 refresh/mode/logout 无法改动本会话 cookie。
///
/// **跨 isolate 边界未消除**：共享 `PersistCookieJar` 的文件竞争仍存在，
/// 本类只保证单个 challenge 内部不与其它 challenge 混用。
class IsolatedAuthSession {
  IsolatedAuthSession._({
    required CookieJar sessionJar,
    required Dio client,
    required Dio templateDio,
    required HttpClientAdapter? fallback,
    required List<Uri> seedUris,
  }) : _jar = sessionJar,
       _dio = client,
       _template = templateDio,
       _fallbackAdapter = fallback,
       _touchedUris = <Uri>{...seedUris};

  final CookieJar _jar;
  final Dio _dio;
  final Dio _template;
  final HttpClientAdapter? _fallbackAdapter;
  final Set<Uri> _touchedUris;

  /// 从 [sourceJar] 为 [seedUris] 快照 cookie，构造独立会话。
  ///
  /// [template] 提供 BaseOptions 与初始 adapter（冻结，不随代理模式切换）。
  static Future<IsolatedAuthSession> create({
    required CookieJar sourceJar,
    required List<Uri> seedUris,
    required Dio template,
    HttpClientAdapter? fallbackAdapter,
  }) async {
    final jar = CookieJar();
    for (final uri in seedUris) {
      final cookies = await sourceJar.loadForRequest(uri);
      if (cookies.isNotEmpty) {
        await jar.saveFromResponse(uri, cookies);
      }
    }

    final baseOptions = template.options;
    final dio = Dio(
      BaseOptions(
        baseUrl: baseOptions.baseUrl,
        connectTimeout: baseOptions.connectTimeout,
        receiveTimeout: baseOptions.receiveTimeout,
        sendTimeout: baseOptions.sendTimeout,
        headers: Map<String, dynamic>.from(baseOptions.headers),
        followRedirects: baseOptions.followRedirects,
        validateStatus: baseOptions.validateStatus,
      ),
    );
    dio.interceptors.add(buildCookieInterceptor(jar));
    // 冻结 adapter：复用 template 当前 adapter，不因后续代理模式切换而变。
    // 共享引用，禁止对本 Dio 调用 close(force:true)（会关闭共享 adapter）。
    dio.httpClientAdapter = template.httpClientAdapter;

    return IsolatedAuthSession._(
      sessionJar: jar,
      client: dio,
      templateDio: template,
      fallback: fallbackAdapter,
      seedUris: seedUris,
    );
  }

  /// 与共享代理回退同语义（[sendWithSystemProxyFallback]），但只作用于
  /// 隔离 dio/jar，并记录本会话触碰过的 URI。
  Future<Response<T>> send<T>({
    required String label,
    required Future<Response<T>> Function(Dio dio, CancelToken token) request,
    CancelToken? cancelToken,
    Duration? requestTimeout,
  }) => sendWithSystemProxyFallback<T>(
    primary: _dio,
    createFallback: () => createSystemProxyFallbackDio(
      template: _template,
      jar: _jar,
      adapterOverride: _fallbackAdapter,
    ),
    label: label,
    request: request,
    cancelToken: cancelToken,
    timeout: requestTimeout,
    onRequestUri: _touchedUris.add,
  );

  /// 把本会话 cookie 合并回共享 jar（成功提交时调用）。
  Future<void> commitTo(CookieJar target) async {
    for (final uri in _touchedUris) {
      final cookies = await _jar.loadForRequest(uri);
      if (cookies.isEmpty) continue;
      await target.saveFromResponse(uri, cookies);
    }
  }
}
