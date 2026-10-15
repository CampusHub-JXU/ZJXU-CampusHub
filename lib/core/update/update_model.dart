class AppRelease {
  const AppRelease({
    required this.version,
    required this.changelog,
    required this.downloadUrl,
    required this.releaseUrl,
    required this.publishedAt,
    this.canonicalAssetUrl,
    this.assetId,
    this.assetFileName,
    this.assetSizeBytes,
    this.assetSha256,
    this.r2MirrorAvailable = false,
  });

  final String version;
  final String changelog;

  /// 面向外部浏览器的下载地址（可能经镜像改写）；既有行为不变。
  final String downloadUrl;
  final String releaseUrl;
  final DateTime publishedAt;

  /// 公开分发仓库 Release 资产的**规范官方 URL**（未经过镜像改写）。
  ///
  /// 仅用于应用内受管下载；使用前必须经 `ApkUpdateUrlPolicy` 校验为可信
  /// 仓库（`github.com/FHfanshu/ZJXU-CampusHub/releases/download/<tag>/<apk>`）。
  /// 未提供 / 未选中 APK 资产时为 null。
  final String? canonicalAssetUrl;

  /// GitHub Release 资产 id（可选）。
  final int? assetId;

  /// 选中资产的原始文件名（可选，例如 `JXU-CampusHub-v0.2.7-arm64-v8a.apk`）。
  final String? assetFileName;

  /// 选中资产字节数；仅当来源提供且为正整数时非 null。
  final int? assetSizeBytes;

  /// 选中资产的 SHA-256（小写 64 位 hex）；无法解析时为 null。
  ///
  /// 接受 `sha256:<hex>` 前缀形态；格式不合法一律忽略（不因此让整条清单失败）。
  final String? assetSha256;

  /// 该 Release 是否带有 R2 镜像标记资产（发布流水线在 R2 对象上传并校验成功
  /// 后才附加）。为 false 时应用**不**尝试 R2 线路，只剩 EdgeOne；元数据不
  /// 指向未确认存在的对象。
  final bool r2MirrorAvailable;

  bool get hasDownloadUrl => downloadUrl.isNotEmpty;

  String get launchUrl => hasDownloadUrl ? downloadUrl : releaseUrl;

  factory AppRelease.fromJson(Map<String, dynamic> json) {
    final version = normalizeVersion((json['version'] as String? ?? '').trim());
    final changelog = (json['changelog'] as String? ?? '').trim();
    final downloadUrl = (json['downloadUrl'] as String? ?? '').trim();
    final releaseUrl = (json['releaseUrl'] as String? ?? '').trim();
    final publishedAt = DateTime.tryParse(
      (json['publishedAt'] as String? ?? '').trim(),
    );

    if (version.isEmpty) {
      throw const FormatException('更新清单缺少 version。');
    }
    if (downloadUrl.isEmpty && releaseUrl.isEmpty) {
      throw const FormatException('更新清单缺少 downloadUrl/releaseUrl。');
    }

    final assetSizeRaw = json['assetSizeBytes'];
    return AppRelease(
      version: version,
      changelog: changelog,
      downloadUrl: downloadUrl,
      releaseUrl: releaseUrl,
      publishedAt: publishedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      canonicalAssetUrl: _optionalString(json['canonicalAssetUrl']),
      assetId: json['assetId'] is int ? json['assetId'] as int : null,
      assetFileName: _optionalString(json['assetFileName']),
      assetSizeBytes: (assetSizeRaw is int && assetSizeRaw > 0)
          ? assetSizeRaw
          : null,
      assetSha256: normalizeSha256(json['assetSha256']),
      r2MirrorAvailable: json['r2MirrorAvailable'] == true,
    );
  }

  bool isNewerThan(String currentVersion) =>
      isVersionNewer(version, currentVersion);

  /// [candidate] 是否严格新于 [currentVersion]（均按 [normalizeVersion] 规范化，
  /// 数字段逐段比较；任一侧无法解析时退回字符串比较）。
  static bool isVersionNewer(String candidate, String currentVersion) {
    final latest = normalizeVersion(candidate);
    final latestSegments = tryParseVersionSegments(latest);
    final currentSegments = tryParseVersionSegments(
      normalizeVersion(currentVersion),
    );
    if (latestSegments == null || currentSegments == null) {
      return latest.compareTo(normalizeVersion(currentVersion)) > 0;
    }

    final maxLength = latestSegments.length > currentSegments.length
        ? latestSegments.length
        : currentSegments.length;
    for (var index = 0; index < maxLength; index++) {
      final latest = index < latestSegments.length ? latestSegments[index] : 0;
      final current = index < currentSegments.length
          ? currentSegments[index]
          : 0;
      if (latest == current) continue;
      return latest > current;
    }
    return false;
  }

  static String normalizeVersion(String value) {
    var normalized = value.trim();
    if (normalized.startsWith('v') || normalized.startsWith('V')) {
      normalized = normalized.substring(1);
    }
    final plusIndex = normalized.indexOf('+');
    if (plusIndex >= 0) {
      normalized = normalized.substring(0, plusIndex);
    }
    return normalized.trim();
  }

  static List<int>? tryParseVersionSegments(String value) {
    if (value.isEmpty) return null;
    final result = <int>[];
    for (final part in value.split('.')) {
      final parsed = int.tryParse(part.trim());
      if (parsed == null) return null;
      result.add(parsed);
    }
    return result.isEmpty ? null : result;
  }

  /// 规范化 SHA-256 摘要：接受裸 64 位 hex 或 `sha256:<hex>` 前缀形态，
  /// 统一转小写；任何不合法输入（长度 / 字符 / 非字符串）返回 null。
  static String? normalizeSha256(Object? raw) {
    if (raw is! String) return null;
    var value = raw.trim();
    if (value.toLowerCase().startsWith(_sha256Prefix)) {
      value = value.substring(_sha256Prefix.length).trim();
    }
    if (!_sha256Pattern.hasMatch(value)) return null;
    return value.toLowerCase();
  }

  static const String _sha256Prefix = 'sha256:';
  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-fA-F]{64}$');
}

String? _optionalString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
