import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/update/update_model.dart';

void main() {
  test('parses manifest payload and picks download url', () {
    final release = AppRelease.fromJson({
      'version': 'v0.1.3',
      'releaseUrl': 'https://example.com/releases/v0.1.3',
      'downloadUrl': 'https://example.com/downloads/app-v0.1.3.apk',
      'changelog': '更新内容',
      'publishedAt': '2026-04-09T17:05:48Z',
    });

    expect(release.version, '0.1.3');
    expect(release.changelog, '更新内容');
    expect(release.hasDownloadUrl, isTrue);
    expect(release.launchUrl, endsWith('.apk'));
  });

  test('allows release page without download url', () {
    final release = AppRelease.fromJson({
      'version': 'v0.2.0',
      'releaseUrl': 'https://example.com/releases/v0.2.0',
      'changelog': '内部版本更新',
      'publishedAt': '2026-04-10T23:30:00+08:00',
    });

    expect(release.version, '0.2.0');
    expect(release.changelog, '内部版本更新');
    expect(release.releaseUrl, 'https://example.com/releases/v0.2.0');
    expect(release.downloadUrl, isEmpty);
  });

  test('throws when manifest omits both download and release urls', () {
    expect(
      () => AppRelease.fromJson({'version': '0.2.0'}),
      throwsFormatException,
    );
  });

  test('treats larger semantic version as newer', () {
    final release = AppRelease(
      version: '0.1.3',
      changelog: '',
      downloadUrl: '',
      releaseUrl: 'https://example.com',
      publishedAt: DateTime(2026),
    );

    expect(release.isNewerThan('0.1.2'), isTrue);
    expect(release.isNewerThan('0.1.3'), isFalse);
    expect(release.isNewerThan('0.2.0'), isFalse);
  });

  test('ignores build metadata while comparing versions', () {
    final release = AppRelease(
      version: '1.2.4',
      changelog: '',
      downloadUrl: '',
      releaseUrl: 'https://example.com',
      publishedAt: DateTime(2026),
    );

    expect(release.isNewerThan('1.2.3+9'), isTrue);
    expect(AppRelease.normalizeVersion('v1.2.3+9'), '1.2.3');
  });

  test('parses optional asset metadata and normalizes sha256', () {
    const canonical =
        'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/'
        'v0.2.7/JXU-CampusHub-v0.2.7-arm64-v8a.apk';
    final release = AppRelease.fromJson({
      'version': 'v0.2.7',
      'releaseUrl': 'https://example.com/releases/v0.2.7',
      'downloadUrl': 'https://example.com/downloads/app-v0.2.7.apk',
      'canonicalAssetUrl': canonical,
      'assetId': 123,
      'assetFileName': 'JXU-CampusHub-v0.2.7-arm64-v8a.apk',
      'assetSizeBytes': 52428800,
      'assetSha256': 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    });

    expect(release.canonicalAssetUrl, canonical);
    expect(release.assetId, 123);
    expect(release.assetFileName, 'JXU-CampusHub-v0.2.7-arm64-v8a.apk');
    expect(release.assetSizeBytes, 52428800);
    expect(
      release.assetSha256,
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
  });

  test('optional asset metadata is null when absent (backward compatible)', () {
    final release = AppRelease.fromJson({
      'version': 'v0.2.7',
      'releaseUrl': 'https://example.com/releases/v0.2.7',
    });

    expect(release.canonicalAssetUrl, isNull);
    expect(release.assetId, isNull);
    expect(release.assetFileName, isNull);
    expect(release.assetSizeBytes, isNull);
    expect(release.assetSha256, isNull);
  });

  test('ignores non-positive asset size', () {
    final release = AppRelease.fromJson({
      'version': 'v0.2.7',
      'releaseUrl': 'https://example.com/releases/v0.2.7',
      'assetSizeBytes': -5,
    });
    expect(release.assetSizeBytes, isNull);
  });

  test('normalizeSha256 accepts prefix form and rejects malformed digests', () {
    final hex = 'b' * 64;
    expect(AppRelease.normalizeSha256('sha256:$hex'), hex);
    expect(AppRelease.normalizeSha256('SHA256:$hex'), hex);
    expect(AppRelease.normalizeSha256(hex), hex);
    expect(AppRelease.normalizeSha256('a' * 63), isNull);
    expect(AppRelease.normalizeSha256('z' * 64), isNull);
    expect(AppRelease.normalizeSha256('sha256:nothex'), isNull);
    expect(AppRelease.normalizeSha256(null), isNull);
    expect(AppRelease.normalizeSha256(123), isNull);
  });

  test('isVersionNewer 与原生共用用例表（version_cases.tsv）逐行一致', () {
    // `tools/update_native_tests/version_cases.tsv`：candidate\tcurrent\texpected，
    // Kotlin 的 AppUpdateVersions 测试读同一张表；任一侧改判定必须两边同时通过。
    final file = File('tools/update_native_tests/version_cases.tsv');
    expect(file.existsSync(), isTrue, reason: '缺少共享用例表');
    var rows = 0;
    for (final raw in file.readAsLinesSync()) {
      final line = raw.trimRight();
      if (line.isEmpty || line.startsWith('#')) continue;
      final cells = line.split('\t');
      expect(cells, hasLength(3), reason: '用例表行格式错误: $line');
      final expected = switch (cells[2].trim()) {
        'true' => true,
        'false' => false,
        final other => fail('非法期望值 "$other"（行: $line）'),
      };
      expect(
        AppRelease.isVersionNewer(cells[0], cells[1]),
        expected,
        reason: 'isVersionNewer("${cells[0]}", "${cells[1]}")',
      );
      rows++;
    }
    expect(rows, greaterThan(5), reason: '用例表不应为空');
  });
}
