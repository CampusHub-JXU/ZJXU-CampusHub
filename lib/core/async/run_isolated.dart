import '../logging/app_logger.dart';

/// 单项异步任务的异常隔离：捕获并记录后继续，绝不向上抛出，
/// 因此不会中断同批次其它任务。
///
/// [message] 由调用方决定日志文案（默认 `「$label」失败，已隔离继续`），
/// [category] / [level] 决定日志归类与级别。
Future<void> runIsolated(
  String label,
  Future<void> Function() action, {
  LogCategory category = LogCategory.general,
  LogLevel level = LogLevel.warn,
  String Function(String label)? message,
}) async {
  try {
    await action();
  } catch (error, stackTrace) {
    AppLogger.instance.log(
      level,
      category,
      message?.call(label) ?? '「$label」失败，已隔离继续',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
