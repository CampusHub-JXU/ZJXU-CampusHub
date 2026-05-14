import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/logging/app_logger.dart';
import 'package:jxu_campus_hub/core/update/update_checker.dart';
import 'package:jxu_campus_hub/core/update/update_model.dart';
import 'package:jxu_campus_hub/core/update/update_service.dart';
import 'package:jxu_campus_hub/core/update/update_source.dart';

void main() {
  setUp(() {
    AppLogger.instance.debugReset();
    UpdateService.instance.debugReset();
    UpdateChecker.instance.debugReset();
  });

  tearDown(() {
    AppLogger.instance.debugReset();
    UpdateService.instance.debugReset();
    UpdateChecker.instance.debugReset();
  });

  test('stores available release when update is found', () async {
    final release = AppRelease(
      version: '0.1.3',
      changelog: '',
      downloadUrl: '',
      releaseUrl: 'https://example.com',
      publishedAt: DateTime(2026),
    );
    UpdateService.instance.debugReleaseProvider = () async => release;
    UpdateService.instance.debugCurrentVersionProvider = () async => '0.1.0';
    UpdateService.instance.debugIsRemoteUpdateEnabled = true;

    final result = await UpdateChecker.instance.check();

    expect(result.status, UpdateCheckStatus.updateAvailable);
    expect(result.release, same(release));
    expect(UpdateChecker.instance.availableRelease.value, same(release));
    expect(UpdateChecker.instance.isChecking.value, isFalse);
  });

  test('returns disabled when remote update is turned off', () async {
    final staleRelease = AppRelease(
      version: '0.1.3',
      changelog: '',
      downloadUrl: '',
      releaseUrl: 'https://example.com',
      publishedAt: DateTime(2026),
    );
    UpdateService.instance.debugIsRemoteUpdateEnabled = false;
    UpdateChecker.instance.availableRelease.value = staleRelease;

    final result = await UpdateChecker.instance.check();

    expect(result.status, UpdateCheckStatus.disabled);
    expect(UpdateChecker.instance.availableRelease.value, isNull);
    expect(UpdateChecker.instance.isChecking.value, isFalse);
  });

  test('clears available release when already up to date', () async {
    final staleRelease = AppRelease(
      version: '0.1.2',
      changelog: '',
      downloadUrl: '',
      releaseUrl: 'https://example.com',
      publishedAt: DateTime(2026),
    );
    UpdateChecker.instance.availableRelease.value = staleRelease;
    UpdateService.instance.debugReleaseProvider = () async => staleRelease;
    UpdateService.instance.debugCurrentVersionProvider = () async => '0.1.2';
    UpdateService.instance.debugIsRemoteUpdateEnabled = true;

    final result = await UpdateChecker.instance.check();

    expect(result.status, UpdateCheckStatus.upToDate);
    expect(UpdateChecker.instance.availableRelease.value, isNull);
  });

  test('keeps previous release when checking fails', () async {
    final existingRelease = AppRelease(
      version: '0.1.3',
      changelog: '',
      downloadUrl: '',
      releaseUrl: 'https://example.com',
      publishedAt: DateTime(2026),
    );
    UpdateChecker.instance.availableRelease.value = existingRelease;
    UpdateService.instance.debugReleaseProvider = () async {
      throw StateError('failed');
    };
    UpdateService.instance.debugCurrentVersionProvider = () async => '0.1.0';
    UpdateService.instance.debugIsRemoteUpdateEnabled = true;

    final result = await UpdateChecker.instance.check();

    expect(result.status, UpdateCheckStatus.error);
    expect(
      UpdateChecker.instance.availableRelease.value,
      same(existingRelease),
    );
    expect(UpdateChecker.instance.isChecking.value, isFalse);
  });

  test(
    'treats unavailable update source as non-warning check failure',
    () async {
      UpdateService.instance.debugReleaseProvider = () async {
        throw const UpdateSourceUnavailableException('GitHub Release 暂不可用');
      };
      UpdateService.instance.debugCurrentVersionProvider = () async => '0.1.0';
      UpdateService.instance.debugIsRemoteUpdateEnabled = true;
      AppLogger.instance.config.value = const LogConfig.defaults().copyWith(
        minimumLevel: LogLevel.debug,
      );

      final result = await UpdateChecker.instance.check();

      expect(result.status, UpdateCheckStatus.error);
      expect(
        AppLogger.instance.entries.map((entry) => entry.level),
        isNot(contains(LogLevel.warn)),
      );
      expect(
        AppLogger.instance.entries.map((entry) => entry.message),
        contains(contains('更新源暂不可用')),
      );
    },
  );
}
