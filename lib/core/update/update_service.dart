import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../config/app_config.dart';
import '../logging/app_logger.dart';
import '../network/proxy_mode.dart';
import 'update_model.dart';
import 'update_source.dart';

class UpdateService {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  Dio? _dio;

  bool get isRemoteUpdateEnabled =>
      debugIsRemoteUpdateEnabled ??
      AppConfig.updateMode != AppUpdateMode.disabled;

  Future<AppRelease?> checkForUpdate() async {
    final release = await fetchLatestRelease();
    final currentVersion = await _loadCurrentVersion();
    if (release.isNewerThan(currentVersion)) {
      return release;
    }
    return null;
  }

  Future<AppRelease> fetchLatestRelease() async {
    final debugProvider = debugReleaseProvider;
    if (debugProvider != null) {
      return debugProvider();
    }
    final source = debugSource ?? _resolveSource();
    return source.fetchLatestRelease();
  }

  Future<String> _loadCurrentVersion() async {
    final debugProvider = debugCurrentVersionProvider;
    if (debugProvider != null) {
      return debugProvider();
    }
    final packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }

  Dio _createDio() {
    final client = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: const {
          'Accept': 'application/json',
          'User-Agent': 'JXU-CampusHub-App',
        },
      ),
    );
    // 更新检查始终独立遵循系统代理，不受教务直连开关影响。
    applyProxyModeToDio(client, ignoreSystemProxy: false);
    client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.extra['requestStartTime'] = DateTime.now();
          if (AppLogger.instance.config.value.networkVerboseEnabled) {
            AppLogger.instance.network(LogLevel.debug, '→ 更新清单 ${options.uri}');
          }
          handler.next(options);
        },
        onResponse: (response, handler) {
          if (AppLogger.instance.config.value.networkVerboseEnabled) {
            final startedAt = response.requestOptions.extra['requestStartTime'];
            final elapsed = startedAt is DateTime
                ? '${DateTime.now().difference(startedAt).inMilliseconds}ms'
                : 'n/a';
            AppLogger.instance.network(
              LogLevel.debug,
              '← 更新清单 ${response.statusCode} ${response.requestOptions.uri} ($elapsed)',
            );
          }
          handler.next(response);
        },
        onError: (error, handler) {
          final startedAt = error.requestOptions.extra['requestStartTime'];
          final elapsed = startedAt is DateTime
              ? '${DateTime.now().difference(startedAt).inMilliseconds}ms'
              : 'n/a';
          AppLogger.instance.network(
            LogLevel.warn,
            '更新清单请求失败: ${error.requestOptions.uri} ($elapsed) ${error.message}',
          );
          handler.next(error);
        },
      ),
    );
    return client;
  }

  UpdateSource _resolveSource() => _sourceFor(AppConfig.updateTestOrigin);

  /// [testOrigin] 非 null（仅调试构建且显式传入测试源定义，见
  /// [AppConfig.updateTestOrigin]）时，更新检查改为请求 `<origin>/latest.json`
  /// （GitHub Release API 同形 JSON）；release / profile 恒走正式配置。
  UpdateSource _sourceFor(String? testOrigin) {
    if (testOrigin != null) {
      return GitHubReleaseUpdateSource(
        dio: _dio ??= _createDio(),
        latestReleaseApiUrl: '$testOrigin/latest.json',
        // 测试源不走镜像改写，也没有备用 API 地址。
        releaseMirrorPrefix: '',
      );
    }
    return switch (AppConfig.updateMode) {
      AppUpdateMode.disabled => const DisabledUpdateSource(),
      AppUpdateMode.remoteManifest => RemoteManifestUpdateSource(
        dio: _dio ??= _createDio(),
        manifestUrl: AppConfig.updateManifestUrl,
      ),
      AppUpdateMode.githubRelease => GitHubReleaseUpdateSource(
        dio: _dio ??= _createDio(),
        latestReleaseApiUrl: AppConfig.updateGithubLatestReleaseApiUrl,
        latestReleaseFallbackApiUrls:
            AppConfig.updateGithubLatestReleaseFallbackApiUrls,
        releaseMirrorPrefix: AppConfig.updateGithubReleaseMirrorPrefix,
      ),
    };
  }

  @visibleForTesting
  UpdateSource debugSourceFor(String? testOrigin) => _sourceFor(testOrigin);

  @visibleForTesting
  Future<AppRelease> Function()? debugReleaseProvider;

  @visibleForTesting
  Future<String> Function()? debugCurrentVersionProvider;

  @visibleForTesting
  UpdateSource? debugSource;

  @visibleForTesting
  bool? debugIsRemoteUpdateEnabled;

  @visibleForTesting
  void debugReset() {
    _dio = null;
    debugReleaseProvider = null;
    debugCurrentVersionProvider = null;
    debugSource = null;
    debugIsRemoteUpdateEnabled = null;
  }
}
