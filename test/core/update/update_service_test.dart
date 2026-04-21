import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/update/update_model.dart';
import 'package:jxu_campus_hub/core/update/update_source.dart';
import 'package:jxu_campus_hub/core/update/update_service.dart';

class _FakeUpdateSource implements UpdateSource {
  const _FakeUpdateSource(this.loader);

  final Future<AppRelease> Function() loader;

  @override
  Future<AppRelease> fetchLatestRelease() => loader();
}

void main() {
  setUp(() {
    UpdateService.instance.debugReset();
  });

  tearDown(() {
    UpdateService.instance.debugReset();
  });

  test('returns release when github version is newer', () async {
    final release = AppRelease(
      version: '0.1.3',
      changelog: '',
      downloadUrl: '',
      releaseUrl: 'https://example.com',
      publishedAt: DateTime(2026),
    );
    UpdateService.instance.debugReleaseProvider = () async => release;
    UpdateService.instance.debugCurrentVersionProvider = () async => '0.1.2';

    final result = await UpdateService.instance.checkForUpdate();

    expect(result, same(release));
  });

  test('returns null when current version is already latest', () async {
    final release = AppRelease(
      version: '0.1.3',
      changelog: '',
      downloadUrl: '',
      releaseUrl: 'https://example.com',
      publishedAt: DateTime(2026),
    );
    UpdateService.instance.debugReleaseProvider = () async => release;
    UpdateService.instance.debugCurrentVersionProvider = () async => '0.1.3';

    final result = await UpdateService.instance.checkForUpdate();

    expect(result, isNull);
  });

  test('throws when release loading fails', () async {
    UpdateService.instance.debugReleaseProvider = () async {
      throw StateError('failed');
    };
    UpdateService.instance.debugCurrentVersionProvider = () async => '0.1.0';

    expect(UpdateService.instance.checkForUpdate(), throwsStateError);
  });

  test('fetches latest release through configured source', () async {
    final release = AppRelease(
      version: '0.1.4',
      changelog: '',
      downloadUrl: 'https://example.com/app.apk',
      releaseUrl: 'https://example.com/release',
      publishedAt: DateTime(2026),
    );
    UpdateService.instance.debugSource = _FakeUpdateSource(() async => release);
    UpdateService.instance.debugIsRemoteUpdateEnabled = true;

    final result = await UpdateService.instance.fetchLatestRelease();

    expect(result, same(release));
  });

  test('reports remote update disabled by default', () {
    expect(UpdateService.instance.isRemoteUpdateEnabled, isFalse);
  });
}
