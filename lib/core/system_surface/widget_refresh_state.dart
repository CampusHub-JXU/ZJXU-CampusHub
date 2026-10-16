import 'dart:io';

import '../auth/auth_file_lock.dart';
import '../storage/atomic_json_file.dart';

/// 后台刷新记录不含账号或凭据，读取始终走磁盘，跨引擎不缓存。
enum WidgetRefreshOutcome {
  ok,
  partial,
  authFailed,
  offline,
  error,
  skippedForeground,
}

class WidgetRefreshRecord {
  const WidgetRefreshRecord({
    required this.lastAttemptAt,
    required this.lastOutcome,
    this.lastSuccessAt,
  });
  final DateTime lastAttemptAt;
  final DateTime? lastSuccessAt;
  final WidgetRefreshOutcome lastOutcome;
}

class WidgetRefreshState {
  WidgetRefreshState({Future<Directory> Function()? directory})
    : _io = AtomicJsonFile('widget_refresh_state.json', directory: directory);
  static final instance = WidgetRefreshState();
  final AtomicJsonFile _io;

  Future<WidgetRefreshRecord?> load() async {
    try {
      return await _io.read<WidgetRefreshRecord?>(
        await _io.file(),
        absent: null,
        decode: (raw) {
          if (raw is! Map || raw['v'] != 1) return null;
          final at = DateTime.tryParse(raw['lastAttemptAt'] as String? ?? '');
          final outcome = WidgetRefreshOutcome.values
              .where((o) => o.name == raw['lastOutcome'])
              .firstOrNull;
          if (at == null || outcome == null) return null;
          return WidgetRefreshRecord(
            lastAttemptAt: at,
            lastOutcome: outcome,
            lastSuccessAt: DateTime.tryParse(
              raw['lastSuccessAt'] as String? ?? '',
            ),
          );
        },
        onCorrupt: (_, _) => null,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> record(WidgetRefreshOutcome outcome, {DateTime? at}) async {
    final lock = AuthFileLock(
      lockFile: await _io.siblingFile('widget_refresh_state.lock'),
    );
    await lock.withLock(() async {
      final previous = await load();
      final now = at ?? DateTime.now();
      // 较早启动、较晚完成的任务不能盖掉新一轮结果。
      if (previous != null && previous.lastAttemptAt.isAfter(now)) return;
      final success =
          outcome == WidgetRefreshOutcome.ok ||
          outcome == WidgetRefreshOutcome.partial;
      await AtomicJsonFile.write(await _io.file(), {
        'v': 1,
        'lastAttemptAt': now.toIso8601String(),
        'lastOutcome': outcome.name,
        'lastSuccessAt': (success ? now : previous?.lastSuccessAt)
            ?.toIso8601String(),
      });
    });
  }
}
