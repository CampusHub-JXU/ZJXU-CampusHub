import 'package:flutter/foundation.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../logging/app_logger.dart';
import 'cookie_interceptor.dart';
import 'network_settings.dart';
import 'proxy_mode.dart';

class DioClient {
  DioClient._();
  static final DioClient instance = DioClient._();
  static const defaultZhengfangBaseUrl = 'https://jwzx.zjxu.edu.cn/jwglxt';
  static const _zhengfangCookieFolderName = '.cookies';
  static const _unifiedAuthCookieFolderName = '.cookies_unified_auth';
  static const _requestStartTimeKey = 'app_logger_request_start_time';

  PersistCookieJar? _zhengfangCookieJar;
  PersistCookieJar? _unifiedAuthCookieJar;
  Dio? _zhengfangDio;
  Dio? _unifiedAuthDio;
  Future<void>? _initFuture;
  Future<void>? _reloadFuture;
  VoidCallback? _proxyModeListener;

  PersistCookieJar get zhengfangCookieJar =>
      _zhengfangCookieJar ??
      (throw StateError('DioClient has not been initialized.'));

  PersistCookieJar get unifiedAuthCookieJar =>
      _unifiedAuthCookieJar ??
      (throw StateError('DioClient has not been initialized.'));

  Dio get dio =>
      _zhengfangDio ??
      (throw StateError('DioClient has not been initialized.'));

  Dio get unifiedAuthDio =>
      _unifiedAuthDio ??
      (throw StateError('DioClient has not been initialized.'));

  Future<void> ensureInitialized() async {
    final existing = _initFuture;
    if (existing != null) return existing;

    final future = _initialize();
    _initFuture = future;
    try {
      await future;
    } catch (_) {
      if (identical(_initFuture, future)) {
        _initFuture = null;
      }
      rethrow;
    }
  }

  Future<void> _initialize() async {
    if (_zhengfangDio != null &&
        _unifiedAuthDio != null &&
        _zhengfangCookieJar != null &&
        _unifiedAuthCookieJar != null) {
      return;
    }

    await NetworkSettings.instance.ensureInitialized();
    // 路径解析保持原样（含测试环境未注册 path_provider 时抛错的既有行为），
    // 只替换存储后端。
    final zhengfangCookieDir = await _resolveCookieDirectoryPath(
      _zhengfangCookieFolderName,
    );
    final unifiedAuthCookieDir = await _resolveCookieDirectoryPath(
      _unifiedAuthCookieFolderName,
    );
    final Storage zhengfangCookieStorage = debugUseMemoryCookieStorage
        ? _InMemoryCookieStorage()
        : FileStorage(zhengfangCookieDir);
    final Storage unifiedAuthCookieStorage = debugUseMemoryCookieStorage
        ? _InMemoryCookieStorage()
        : FileStorage(unifiedAuthCookieDir);
    _zhengfangCookieJar = PersistCookieJar(
      storage: zhengfangCookieStorage,
      persistSession: true,
    );
    _unifiedAuthCookieJar = PersistCookieJar(
      storage: unifiedAuthCookieStorage,
      persistSession: true,
    );
    _zhengfangDio = _createDio(
      jar: _zhengfangCookieJar!,
      baseUrl: defaultZhengfangBaseUrl,
    );
    _unifiedAuthDio = _createDio(
      jar: _unifiedAuthCookieJar!,
      baseUrl: 'https://newca.zjxu.edu.cn',
    );
    _listenProxyModeOnce();
  }

  /// 重新从磁盘加载两个持久 Cookie jar 的内存缓存。
  ///
  /// **调用条件（生命周期协调器）**：在**新一轮网络同步开始之前**调用，用于
  /// 吸收其它 isolate / 进程对同一 cookie 目录的合法改动（登录、登出、换号），
  /// 避免本轮请求带着旧身份的内存 cookie 发出。
  ///
  /// 行为：先 [ensureInitialized]，再对两个已存在的 [PersistCookieJar] 只清空
  /// 内存 `hostCookies` / `domainCookies` 并 `forceInit()` 重读 `.index` /
  /// `.domains`；之后的 `loadForRequest` 会按 host 懒加载磁盘文件。**不**删除
  /// 任何磁盘 cookie 文件，**不**替换 jar / Dio 对象，也不关闭 adapter（其它
  /// client 已捕获现有 jar / interceptor）。
  ///
  /// 同 isolate 并发调用会合并到同一轮 reload；该轮失败后引用被清理，下次调用
  /// 可重试。异常一律向上抛出，调用方本轮应停止后续同步，不得保留旧身份继续
  /// 发请求。
  ///
  /// **边界（不得夸大）**：这不是跨 isolate 原子事务，也不保证本轮开始前已经
  /// 在途的响应不会写回 cookie；因此不能声称全局 cookie 竞争已消除。
  Future<void> reloadPersistedCookies() async {
    final existing = _reloadFuture;
    if (existing != null) return existing;

    final future = _reloadPersistedCookiesInternal();
    _reloadFuture = future;
    try {
      await future;
    } finally {
      if (identical(_reloadFuture, future)) {
        _reloadFuture = null;
      }
    }
  }

  Future<void> _reloadPersistedCookiesInternal() async {
    await ensureInitialized();
    final jars = <PersistCookieJar>[
      ?_zhengfangCookieJar,
      ?_unifiedAuthCookieJar,
    ];
    for (final jar in jars) {
      await reloadPersistedCookieJar(jar);
    }
  }

  /// 生产与测试共用的单 jar reload 实现：先清空内存 `hostCookies` /
  /// `domainCookies`，再 `forceInit()` 重读 `.index` / `.domains`。
  ///
  /// `PersistCookieJar.forceInit` 只重读 `.index` / `.domains`，**不会**清空
  /// `hostCookies`；当 `.domains` 文件缺失时也**不会**清空 `domainCookies`。
  /// 因此必须在此显式清空，否则会保留已被外部合法删除的旧身份 cookie。
  @visibleForTesting
  static Future<void> reloadPersistedCookieJar(PersistCookieJar jar) async {
    jar.hostCookies.clear();
    jar.domainCookies.clear();
    final beforeInit = debugBeforeForceInit;
    if (beforeInit != null) await beforeInit(jar);
    await jar.forceInit();
  }

  /// 测试注入：在清空内存之后、`forceInit()` 之前执行，用于验证并发合并与
  /// 失败可重试；生产路径不设置时无副作用。
  @visibleForTesting
  static Future<void> Function(PersistCookieJar jar)? debugBeforeForceInit;

  void applyProxyMode() {
    final zhengfangClient = _zhengfangDio;
    if (zhengfangClient != null) {
      _applyProxyMode(zhengfangClient);
    }
    final unifiedAuthClient = _unifiedAuthDio;
    if (unifiedAuthClient != null) {
      _applyProxyMode(unifiedAuthClient);
    }
  }

  void _listenProxyModeOnce() {
    if (_proxyModeListener != null) return;
    final settings = NetworkSettings.instance.ignoreSystemProxy;
    void listener() => applyProxyMode();
    settings.addListener(listener);
    _proxyModeListener = listener;
  }

  void _removeProxyModeListener() {
    final listener = _proxyModeListener;
    if (listener == null) return;
    NetworkSettings.instance.ignoreSystemProxy.removeListener(listener);
    _proxyModeListener = null;
  }

  void updateBaseUrl(String baseUrl) {
    final client = _zhengfangDio;
    if (client == null || client.options.baseUrl == baseUrl) return;
    client.options.baseUrl = baseUrl;
    AppLogger.instance.network(LogLevel.info, '教务请求基础地址已更新为: $baseUrl');
  }

  void _applyProxyMode(Dio client) {
    final previous = client.httpClientAdapter;
    applyProxyModeToDio(
      client,
      ignoreSystemProxy: NetworkSettings.instance.ignoreSystemProxy.value,
    );
    if (!identical(previous, client.httpClientAdapter)) {
      // Close idle sockets only. force:true would abort in-flight requests.
      previous.close();
    }
  }

  Dio _createDio({required PersistCookieJar jar, required String baseUrl}) {
    final client = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        },
        followRedirects: false,
        validateStatus: (status) => status != null && status < 400,
      ),
    );
    client.interceptors.add(buildCookieInterceptor(jar));
    client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.extra[_requestStartTimeKey] = DateTime.now();
          if (AppLogger.instance.config.value.networkVerboseEnabled) {
            AppLogger.instance.network(
              LogLevel.debug,
              '→ ${options.method} ${options.uri}',
            );
          }
          handler.next(options);
        },
        onResponse: (response, handler) {
          final code = response.statusCode;
          final requestOptions = response.requestOptions;
          final uri = requestOptions.uri;
          final duration = _elapsedTimeLabel(requestOptions);
          if (code == 302 || code == 303) {
            final location = response.headers.value('location') ?? '';
            AppLogger.instance.network(
              LogLevel.info,
              '← $code ${requestOptions.method} $uri ($duration) → $location',
            );
            final normalizedLocation = location.toLowerCase();
            final redirectUri = Uri.tryParse(location);
            final casTicket = redirectUri?.queryParameters['ticket'] ?? '';
            final isCasServiceRedirect = casTicket.startsWith('ST-');
            if (normalizedLocation.contains('webvpn.zjxu.edu.cn/login') &&
                !isCasServiceRedirect) {
              AppLogger.instance.network(
                LogLevel.warn,
                '检测到重定向到 WebVPN 登录页，当前会话可能已失效或需要重新认证',
              );
            } else if (normalizedLocation.contains('login_slogin') ||
                normalizedLocation.contains('kaptcha')) {
              AppLogger.instance.network(
                LogLevel.warn,
                '检测到重定向到教务登录/验证码页，可能未在校园网环境或需要重新登录',
              );
            }
          } else if (AppLogger.instance.config.value.networkVerboseEnabled) {
            AppLogger.instance.network(
              LogLevel.debug,
              '← $code ${requestOptions.method} $uri ($duration)',
            );
          }
          handler.next(response);
        },
        onError: (error, handler) {
          final duration = _elapsedTimeLabel(error.requestOptions);
          final msg =
              '请求失败: ${error.type} - ${error.requestOptions.method} ${error.requestOptions.uri} ($duration) - ${error.message}';
          if (error.type == DioExceptionType.connectionError ||
              error.type == DioExceptionType.connectionTimeout ||
              error.type == DioExceptionType.receiveTimeout) {
            AppLogger.instance.network(LogLevel.warn, msg);
          } else {
            AppLogger.instance.network(LogLevel.error, msg);
          }
          handler.next(error);
        },
      ),
    );
    _applyProxyMode(client);
    return client;
  }

  String _elapsedTimeLabel(RequestOptions options) {
    final startedAt = options.extra[_requestStartTimeKey];
    if (startedAt is! DateTime) {
      return 'n/a';
    }
    final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
    return '${elapsed}ms';
  }

  Future<String> _resolveCookieDirectoryPath(String folderName) async {
    final override = debugCookieDirectoryPathProvider;
    if (override != null) {
      return override(folderName);
    }

    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/$folderName/';
  }

  @visibleForTesting
  bool get debugHasProxyModeListener => _proxyModeListener != null;

  @visibleForTesting
  Future<String> Function(String folderName)? debugCookieDirectoryPathProvider;

  /// 测试钩子：用内存 Cookie 存储替代文件存储。
  ///
  /// widget 测试运行在 fake-async 区内，`PersistCookieJar` 的读盘 future 不会
  /// 完成，导致请求卡在 CookieManager 拦截器、`pumpAndSettle` 超时（CI 上
  /// library 页面测试即因此常年变红）。测试统一置 true 后不再触碰文件系统。
  @visibleForTesting
  bool debugUseMemoryCookieStorage = false;

  @visibleForTesting
  void debugReset() {
    _removeProxyModeListener();
    _zhengfangCookieJar = null;
    _unifiedAuthCookieJar = null;
    _zhengfangDio = null;
    _unifiedAuthDio = null;
    _initFuture = null;
    _reloadFuture = null;
    debugBeforeForceInit = null;
    debugCookieDirectoryPathProvider = null;
    debugUseMemoryCookieStorage = false;
  }
}

/// 纯内存 Cookie 存储（仅测试路径使用）。
///
/// `cookie_jar` 只提供 `FileStorage`；widget 测试的 fake-async 区内它的读盘
/// future 永不完成，请求会卡在 CookieManager 拦截器。这里给出零 I/O 实现。
class _InMemoryCookieStorage extends Storage {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<void> init(bool persistSession, bool ignoreExpires) async {}

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<void> deleteAll(List<String> keys) async {
    for (final key in keys) {
      _values.remove(key);
    }
  }
}
