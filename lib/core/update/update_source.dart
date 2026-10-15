import 'dart:ffi' show Abi;

import 'package:dio/dio.dart';

import '../config/app_config.dart';
import 'update_model.dart';

abstract interface class UpdateSource {
  Future<AppRelease> fetchLatestRelease();
}

class UpdateSourceUnavailableException implements Exception {
  const UpdateSourceUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DisabledUpdateSource implements UpdateSource {
  const DisabledUpdateSource();

  @override
  Future<AppRelease> fetchLatestRelease() {
    throw StateError('在线更新未启用。');
  }
}

class RemoteManifestUpdateSource implements UpdateSource {
  const RemoteManifestUpdateSource({
    required this.dio,
    required this.manifestUrl,
  });

  final Dio dio;
  final String manifestUrl;

  @override
  Future<AppRelease> fetchLatestRelease() async {
    final response = await dio.get<Map<String, dynamic>>(manifestUrl);
    final data = response.data;
    if (data == null) {
      throw const FormatException('更新清单响应为空。');
    }
    return AppRelease.fromJson(data);
  }
}

class GitHubReleaseUpdateSource implements UpdateSource {
  const GitHubReleaseUpdateSource({
    required this.dio,
    required this.latestReleaseApiUrl,
    this.latestReleaseFallbackApiUrls = const <String>[],
    required this.releaseMirrorPrefix,
    this.deviceAbiProvider = deviceAbiSuffix,
  });

  final Dio dio;
  final String latestReleaseApiUrl;
  final List<String> latestReleaseFallbackApiUrls;
  final String releaseMirrorPrefix;
  final String? Function() deviceAbiProvider;

  @override
  Future<AppRelease> fetchLatestRelease() async {
    Object? lastFailure;
    for (final apiUrl in _candidateApiUrls()) {
      try {
        final response = await dio.get<Map<String, dynamic>>(
          apiUrl,
          options: Options(validateStatus: (status) => status != null),
        );
        final statusCode = response.statusCode ?? 0;
        if (statusCode < 200 || statusCode >= 300) {
          lastFailure = 'HTTP $statusCode';
          continue;
        }
        return _parseRelease(response.data);
      } on DioException catch (error) {
        lastFailure = error.message ?? error.type.name;
      }
    }
    final suffix = lastFailure == null ? '' : ': $lastFailure';
    throw UpdateSourceUnavailableException('GitHub Release 暂不可用$suffix');
  }

  List<String> _candidateApiUrls() {
    final seen = <String>{};
    return <String>[latestReleaseApiUrl, ...latestReleaseFallbackApiUrls]
        .map((url) => url.trim())
        .where((url) => url.isNotEmpty && seen.add(url))
        .toList(growable: false);
  }

  AppRelease _parseRelease(Map<String, dynamic>? data) {
    if (data == null) {
      throw const FormatException('GitHub Release 响应为空。');
    }

    final tagName = (data['tag_name'] as String? ?? '').trim();
    final releaseUrl = _mirrorUrl((data['html_url'] as String? ?? '').trim());
    final assets = data['assets'] is List
        ? (data['assets'] as List).whereType<Map<String, dynamic>>().toList()
        : const <Map<String, dynamic>>[];
    final selectedApk = _bestApkAssetForDevice(assets);
    final apkAsset = selectedApk ?? _firstOrNull(assets);
    final fallbackAsset = _firstOrNull(assets);
    final downloadUrl = _mirrorUrl(
      ((apkAsset ?? fallbackAsset)?['browser_download_url'] as String? ?? '')
          .trim(),
    );
    if (tagName.isEmpty) {
      throw const FormatException('GitHub Release 缺少 tag_name。');
    }
    if (downloadUrl.isEmpty && releaseUrl.isEmpty) {
      throw const FormatException('GitHub Release 缺少下载地址。');
    }

    return AppRelease(
      version: AppRelease.normalizeVersion(tagName),
      changelog: (data['body'] as String? ?? '').trim(),
      downloadUrl: downloadUrl,
      releaseUrl: releaseUrl,
      publishedAt:
          DateTime.tryParse((data['published_at'] as String? ?? '').trim()) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      // 应用内受管下载只信任**选中 APK 资产**的规范官方 URL（未镜像改写）；
      // 其余可选元数据缺失 / 非法时静默为 null，不影响整条清单。
      canonicalAssetUrl: _assetString(selectedApk, 'browser_download_url'),
      assetId: selectedApk?['id'] is int ? selectedApk!['id'] as int : null,
      assetFileName: _assetString(selectedApk, 'name'),
      assetSizeBytes: _assetPositiveInt(selectedApk, 'size'),
      assetSha256: AppRelease.normalizeSha256(selectedApk?['digest']),
      r2MirrorAvailable: _hasR2MirrorMarker(assets),
    );
  }

  /// 发布流水线只有在 R2 对象上传并校验成功后才附加标记资产；仅检查资产名，
  /// 不额外请求其内容。
  bool _hasR2MirrorMarker(List<Map<String, dynamic>> assets) {
    for (final asset in assets) {
      if (asset['name'] == AppConfig.updateR2MirrorMarkerAssetName) return true;
    }
    return false;
  }

  String? _assetString(Map<String, dynamic>? asset, String key) {
    final value = asset?[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  int? _assetPositiveInt(Map<String, dynamic>? asset, String key) {
    final value = asset?[key];
    if (value is! int || value <= 0) return null;
    return value;
  }

  bool _isApkAsset(Map<String, dynamic> asset) {
    final name = (asset['name'] as String? ?? '').toLowerCase();
    return name.endsWith('.apk');
  }

  /// Pick the best APK asset for this device's ABI.
  /// Priority: matching arch-specific APK > first APK.
  Map<String, dynamic>? _bestApkAssetForDevice(
    List<Map<String, dynamic>> assets,
  ) {
    final apks = assets.where(_isApkAsset).toList();
    if (apks.isEmpty) return null;

    final deviceAbi = deviceAbiProvider();

    // 1. Try arch-specific match first.
    if (deviceAbi != null) {
      for (final asset in apks) {
        final name = (asset['name'] as String? ?? '').toLowerCase();
        if (name.contains(deviceAbi)) return asset;
      }
    }

    // 2. Fall back to first APK.
    return apks.first;
  }

  /// Returns the ABI suffix used in our APK filenames, or null if unknown.
  String _mirrorUrl(String rawUrl) {
    if (rawUrl.isEmpty) return '';
    if (releaseMirrorPrefix.isEmpty || rawUrl.startsWith(releaseMirrorPrefix)) {
      return rawUrl;
    }
    return '$releaseMirrorPrefix$rawUrl';
  }

  Map<String, dynamic>? _firstOrNull(Iterable<Map<String, dynamic>> values) {
    final iterator = values.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

/// 当前设备 ABI 对应的 APK 文件名后缀（`arm64-v8a` / `armeabi-v7a`），
/// 未知 ABI（含非 Android / 桌面测试环境）返回 null。
///
/// 供 GitHub Release 资产选择与应用内受管下载复用，保持同一套 ABI 逻辑。
String? deviceAbiSuffix() {
  final abi = Abi.current();
  if (abi == Abi.androidArm64) return 'arm64-v8a';
  if (abi == Abi.androidArm) return 'armeabi-v7a';
  return null;
}
