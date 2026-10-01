import 'dart:async';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';

import '../logging/app_logger.dart';
import 'cancel_token_x.dart';
import 'cookie_interceptor.dart';
import 'network_settings.dart';
import 'proxy_mode.dart';

/// 先按当前代理设置发送；若失败且错误属于「强制直连导致」的类别，并且真实
/// 请求 URI 命中 `HTTP_PROXY`/`NO_PROXY` 规则，再用 [createFallback] 构造的
/// 系统代理 Dio 重试一次。
///
/// 统一认证、教务与隔离验证码会话共用这一份实现（过去各自复制）。
/// - 调用方 [cancelToken] 取消时绝不重试，直接抛取消错误；
/// - 每次发送都派生独立 token，结束（含 [timeout]）时取消底层传输，避免
///   socket 悬挂；
/// - [onRequestUri] 在每次实际发出请求时回调（隔离会话用它记录触碰过的 URI）；
/// - 回退 Dio 用完即 `close(force: true)`。
Future<Response<T>> sendWithSystemProxyFallback<T>({
  required Dio primary,
  required Dio Function() createFallback,
  required String label,
  required Future<Response<T>> Function(Dio dio, CancelToken token) request,
  CancelToken? cancelToken,
  Duration? timeout,
  void Function(Uri uri)? onRequestUri,
}) async {
  Uri? requestUri;
  // ponytail: overlapping sends on the same Dio can clobber requestUri.
  final capture = InterceptorsWrapper(
    onRequest: (options, handler) {
      requestUri = options.uri;
      onRequestUri?.call(options.uri);
      handler.next(options);
    },
  );

  Future<Response<T>> send(Dio client) async {
    cancelToken.throwIfCancelled();
    final token = CancelToken();
    unawaited(cancelToken?.whenCancel.then((error) => token.cancel(error)));
    client.interceptors.add(capture);
    try {
      final future = request(client, token);
      return timeout == null ? await future : await future.timeout(timeout);
    } finally {
      client.interceptors.remove(capture);
      // Future.timeout/cancel 必须同时取消底层请求，避免 socket 悬挂。
      token.cancel('$label finished');
    }
  }

  try {
    return await send(primary);
  } catch (error) {
    cancelToken.throwIfCancelled();
    final retryable = shouldRetryWithSystemProxyForError(
      error,
      ignoreSystemProxy: NetworkSettings.instance.ignoreSystemProxy.value,
    );
    if (!retryable) rethrow;
    final target =
        requestUri ?? (error is DioException ? error.requestOptions.uri : null);
    if (target == null || await resolveHttpProxyForUri(target) == null) {
      rethrow;
    }
    final reason = describeSystemProxyRetryReason(error);
    AppLogger.instance.auth(
      LogLevel.warn,
      '$label 直连失败（$reason），尝试通过 HTTP_PROXY 环境代理重试',
    );
    final fallback = createFallback();
    try {
      return await send(fallback);
    } finally {
      fallback.close(force: true);
    }
  }
}

/// 复制 [template] 的 BaseOptions 子集（baseUrl / 三类超时 / headers 副本 /
/// followRedirects / validateStatus），供一次性或隔离 Dio 复用。
BaseOptions cloneBaseOptions(Dio template) {
  final baseOptions = template.options;
  return BaseOptions(
    baseUrl: baseOptions.baseUrl,
    connectTimeout: baseOptions.connectTimeout,
    receiveTimeout: baseOptions.receiveTimeout,
    sendTimeout: baseOptions.sendTimeout,
    headers: Map<String, dynamic>.from(baseOptions.headers),
    followRedirects: baseOptions.followRedirects,
    validateStatus: baseOptions.validateStatus,
  );
}

/// 以 [template] 的 BaseOptions 构造走系统代理的一次性回退 Dio，cookie 读写
/// [jar]。[adapterOverride] 仅供测试替换传输层。
Dio createSystemProxyFallbackDio({
  required Dio template,
  required CookieJar jar,
  HttpClientAdapter? adapterOverride,
}) {
  final client = Dio(cloneBaseOptions(template));
  client.interceptors.add(buildCookieInterceptor(jar));
  applyProxyModeToDio(client, ignoreSystemProxy: false);
  if (adapterOverride != null) {
    client.httpClientAdapter.close();
    client.httpClientAdapter = adapterOverride;
  }
  return client;
}
