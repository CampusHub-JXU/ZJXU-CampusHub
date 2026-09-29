import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/logging/app_logger.dart';

void main() {
  setUp(() {
    AppLogger.instance.debugReset();
  });

  test('scrubs session password phone and student id', () {
    AppLogger.instance.log(
      LogLevel.info,
      LogCategory.auth,
      'sid=2025000123 password=secret mm=token JSESSIONID=abcdef 13812345678',
      force: true,
    );

    final entry = AppLogger.instance.entries.single;
    expect(entry.message, contains('password=[REDACTED]'));
    expect(entry.message, contains('mm=[REDACTED]'));
    expect(entry.message, contains('JSESSIONID=[REDACTED]'));
    expect(entry.message, isNot(contains('13812345678')));
    expect(entry.message, isNot(contains('2025000123')));
  });

  test('formats entries with app prefix for filtering', () {
    AppLogger.instance.log(
      LogLevel.info,
      LogCategory.network,
      'hello',
      force: true,
    );

    final entry = AppLogger.instance.entries.single;
    expect(entry.formatted, startsWith('[JXU] ['));
    expect(entry.formatted, contains(' [INFO] [network] hello'));
  });

  test('defaults keep noisy diagnostics opt-in', () {
    const defaults = LogConfig.defaults();

    expect(defaults.minimumLevel, LogLevel.info);
    expect(defaults.webviewLifecycleEnabled, isFalse);
    expect(defaults.webviewConsoleEnabled, isFalse);
    expect(defaults.networkVerboseEnabled, isFalse);
  });

  test('respects minimum level and category unless forced', () {
    AppLogger.instance.config.value = const LogConfig.defaults().copyWith(
      minimumLevel: LogLevel.warn,
      enabledCategories: {LogCategory.network},
    );

    AppLogger.instance.log(LogLevel.info, LogCategory.network, 'skip me');
    AppLogger.instance.log(LogLevel.warn, LogCategory.ui, 'skip category');
    AppLogger.instance.log(LogLevel.warn, LogCategory.network, 'keep me');
    AppLogger.instance.log(
      LogLevel.info,
      LogCategory.ui,
      'forced',
      force: true,
    );

    expect(AppLogger.instance.entries.map((entry) => entry.message), [
      'keep me',
      'forced',
    ]);
  });

  test('always keeps error logs even when category disabled', () {
    AppLogger.instance.config.value = const LogConfig.defaults().copyWith(
      minimumLevel: LogLevel.error,
      enabledCategories: {LogCategory.network},
    );

    AppLogger.instance.log(LogLevel.error, LogCategory.ui, 'must keep');

    expect(AppLogger.instance.entries.single.message, 'must keep');
  });

  test('evicts oldest entries when buffer exceeds capacity', () {
    for (var index = 0; index < 505; index++) {
      AppLogger.instance.log(
        LogLevel.info,
        LogCategory.general,
        'entry-$index',
        force: true,
      );
    }

    expect(AppLogger.instance.entries, hasLength(500));
    expect(AppLogger.instance.entries.first.message, 'entry-5');
    expect(AppLogger.instance.entries.last.message, 'entry-504');
  });

  test('auth trail records auth info+ even when logging is disabled', () {
    AppLogger.instance.loggingEnabled.value = false;
    AppLogger.instance.auth(LogLevel.debug, 'too-verbose');
    AppLogger.instance.auth(
      LogLevel.warn,
      '教务登录失败 sid=2025000123 mm=secret',
      error: 'password=pw',
    );
    AppLogger.instance.network(LogLevel.error, 'not-auth');

    final trail = AppLogger.instance.authTrail;
    expect(trail, hasLength(1));
    expect(trail.single.message, isNot(contains('2025000123')));
    expect(trail.single.message, contains('mm=[REDACTED]'));
    expect(trail.single.error, 'password=[REDACTED]');
    expect(AppLogger.instance.entries, isEmpty);
    expect(AppLogger.instance.formatAuthTrail(), contains('[auth]'));
  });

  test('auth trail evicts oldest entries beyond capacity', () {
    for (var i = 0; i < AppLogger.authTrailCapacity + 3; i++) {
      AppLogger.instance.auth(LogLevel.info, 'trail-$i');
    }
    final trail = AppLogger.instance.authTrail;
    expect(trail, hasLength(AppLogger.authTrailCapacity));
    expect(trail.first.message, 'trail-3');
  });
}
