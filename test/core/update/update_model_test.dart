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
}
