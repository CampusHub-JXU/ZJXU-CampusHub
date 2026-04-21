class AppRelease {
  const AppRelease({
    required this.version,
    required this.changelog,
    required this.downloadUrl,
    required this.releaseUrl,
    required this.publishedAt,
  });

  final String version;
  final String changelog;
  final String downloadUrl;
  final String releaseUrl;
  final DateTime publishedAt;

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

    return AppRelease(
      version: version,
      changelog: changelog,
      downloadUrl: downloadUrl,
      releaseUrl: releaseUrl,
      publishedAt: publishedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  bool isNewerThan(String currentVersion) {
    final latestSegments = tryParseVersionSegments(version);
    final currentSegments = tryParseVersionSegments(
      normalizeVersion(currentVersion),
    );
    if (latestSegments == null || currentSegments == null) {
      return version.compareTo(normalizeVersion(currentVersion)) > 0;
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
}
