import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LogLevel { debug, info, warn, error }

enum LogCategory { auth, network, webview, ui, storage, bootstrap, general }

class LogConfig {
  const LogConfig({
    required this.minimumLevel,
    required this.enabledCategories,
    required this.webviewConsoleEnabled,
    required this.webviewLifecycleEnabled,
    required this.networkVerboseEnabled,
  });

  const LogConfig.defaults()
    : minimumLevel = LogLevel.info,
      enabledCategories = const {
        LogCategory.auth,
        LogCategory.network,
        LogCategory.webview,
        LogCategory.ui,
        LogCategory.storage,
        LogCategory.bootstrap,
        LogCategory.general,
      },
      webviewConsoleEnabled = false,
      webviewLifecycleEnabled = false,
      networkVerboseEnabled = false;

  final LogLevel minimumLevel;
  final Set<LogCategory> enabledCategories;
  final bool webviewConsoleEnabled;
  final bool webviewLifecycleEnabled;
  final bool networkVerboseEnabled;

  LogConfig copyWith({
    LogLevel? minimumLevel,
    Set<LogCategory>? enabledCategories,
    bool? webviewConsoleEnabled,
    bool? webviewLifecycleEnabled,
    bool? networkVerboseEnabled,
  }) {
    return LogConfig(
      minimumLevel: minimumLevel ?? this.minimumLevel,
      enabledCategories: enabledCategories ?? this.enabledCategories,
      webviewConsoleEnabled:
          webviewConsoleEnabled ?? this.webviewConsoleEnabled,
      webviewLifecycleEnabled:
          webviewLifecycleEnabled ?? this.webviewLifecycleEnabled,
      networkVerboseEnabled:
          networkVerboseEnabled ?? this.networkVerboseEnabled,
    );
  }
}

class LogEntry {
  static const String logPrefix = '[JXU]';

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.category,
    required this.message,
    this.error,
    this.stackTrace,
  });

  final DateTime timestamp;
  final LogLevel level;
  final LogCategory category;
  final String message;
  final String? error;
  final String? stackTrace;

  String get formatted {
    final ts = timestamp.toIso8601String();
    final tag = level.name.toUpperCase();
    final categoryTag = category.name;
    final errorSuffix = error == null || error!.isEmpty
        ? ''
        : ' | error=$error';
    final stackSuffix = stackTrace == null || stackTrace!.isEmpty
        ? ''
        : '\n$stackTrace';
    return '$logPrefix [$ts] [$tag] [$categoryTag] $message$errorSuffix$stackSuffix';
  }

  @override
  String toString() => formatted;
}

class AppLogger {
  AppLogger._();

  static final AppLogger instance = AppLogger._();

  static const int _bufferCapacity = 500;
  static const int _retentionDays = 3;
  static const String _prefsEnabledKey = 'app_logger_enabled';
  static const String _prefsMinLevelKey = 'app_logger_min_level';
  static const String _prefsEnabledCategoriesKey =
      'app_logger_enabled_categories';
  static const String _prefsWebviewConsoleKey = 'app_logger_webview_console';
  static const String _prefsWebviewLifecycleKey =
      'app_logger_webview_lifecycle';
  static const String _prefsNetworkVerboseKey = 'app_logger_network_verbose';

  /// Release 构建的完整诊断日志开关（默认关闭）。Debug 构建始终记录。
  static const String _prefsDiagnosticCaptureKey =
      'app_logger_diagnostic_capture';

  static final RegExp _studentIdPattern = RegExp(r'\d{10,12}');
  static final RegExp _mmPattern = RegExp(r'mm=[^\s&;]+');
  static final RegExp _passwordPattern = RegExp(r'password=[^\s&;]+');
  static final RegExp _sessionIdPattern = RegExp(r'JSESSIONID=[^\s;]+');
  static final RegExp _ticketPattern = RegExp(r'ticket=[^\s&;]+');
  static final RegExp _tokenIdPattern = RegExp(
    r'tokenId=[^\s&;]+',
    caseSensitive: false,
  );
  static final RegExp _usernamePattern = RegExp(r'username=[^\s&;]+');
  static final RegExp _sysDatePattern = RegExp(r'sysDate=[^\s&;]+');
  static final RegExp _verifyPattern = RegExp(r'verify=[^\s&;]+');
  static final RegExp _phonePattern = RegExp(r'1[3-9]\d{9}');

  final ListQueue<LogEntry> _buffer = ListQueue<LogEntry>(_bufferCapacity);

  /// 认证诊断轨迹容量：release 包也记录，只在内存（进程被杀即丢），不落盘。
  static const int authTrailCapacity = 300;

  /// 认证轨迹：不受 kDebugMode / 调试日志开关 / 最低级别影响，只收 auth 类
  /// info 及以上，与主缓冲一样经 [_scrub] 脱敏，且不保留堆栈。用于 release
  /// 真机复现登录问题后由用户手动复制导出。
  final ListQueue<LogEntry> _authTrail = ListQueue<LogEntry>(authTrailCapacity);

  final ValueNotifier<bool> loggingEnabled = ValueNotifier<bool>(true);

  /// 用户是否要求在本机保留完整诊断日志（网络 / UI / 启动等）。
  ///
  /// **仅 Release / Profile 需要**：Debug 构建无论如何都会记录（受
  /// [loggingEnabled] 控制）。开启后日志会写入应用私有目录的按日文件，
  /// 保留 3 天；导出入口在「关于 → 诊断」。
  final ValueNotifier<bool> diagnosticCapture = ValueNotifier<bool>(false);

  /// 当前是否实际记录完整诊断日志（Debug 始终为 true）。
  bool get diagnosticCaptureActive => kDebugMode || diagnosticCapture.value;
  final ValueNotifier<LogConfig> config = ValueNotifier<LogConfig>(
    const LogConfig.defaults(),
  );

  Directory? _logDir;
  SharedPreferences? _prefs;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    _prefs = await SharedPreferences.getInstance();
    final prefs = _prefs!;
    loggingEnabled.value = prefs.getBool(_prefsEnabledKey) ?? true;
    config.value = LogConfig(
      minimumLevel: _parseLevel(
        prefs.getString(_prefsMinLevelKey),
        fallback: const LogConfig.defaults().minimumLevel,
      ),
      enabledCategories: _parseCategories(
        prefs.getStringList(_prefsEnabledCategoriesKey),
      ),
      webviewConsoleEnabled:
          prefs.getBool(_prefsWebviewConsoleKey) ??
          const LogConfig.defaults().webviewConsoleEnabled,
      webviewLifecycleEnabled:
          prefs.getBool(_prefsWebviewLifecycleKey) ??
          const LogConfig.defaults().webviewLifecycleEnabled,
      networkVerboseEnabled:
          prefs.getBool(_prefsNetworkVerboseKey) ??
          const LogConfig.defaults().networkVerboseEnabled,
    );

    diagnosticCapture.value =
        prefs.getBool(_prefsDiagnosticCaptureKey) ?? false;

    if (diagnosticCaptureActive) {
      await _prepareLogDir();
    }
  }

  /// 按需准备按日日志目录（Debug 或 Release 开启完整诊断日志时）。
  Future<void> _prepareLogDir() async {
    if (_logDir != null) return;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      _logDir = Directory('${appDir.path}/logs');
      if (!_logDir!.existsSync()) {
        _logDir!.createSync(recursive: true);
      }
      await _cleanupOldLogs();
    } catch (_) {
      // File system unavailable (e.g. tests) - silently degrade.
    }
  }

  /// 开启/关闭 Release 完整诊断日志。Debug 构建始终记录，此开关无害。
  Future<void> setDiagnosticCapture(bool value) async {
    if (diagnosticCapture.value == value) return;
    diagnosticCapture.value = value;
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    await prefs.setBool(_prefsDiagnosticCaptureKey, value);
    if (value) {
      await _prepareLogDir();
      log(LogLevel.info, LogCategory.bootstrap, '完整诊断日志采集已开启', force: true);
    } else {
      log(LogLevel.info, LogCategory.bootstrap, '完整诊断日志采集已关闭', force: true);
      if (!kDebugMode) _logDir = null;
    }
  }

  Future<void> setEnabled(bool value) async {
    loggingEnabled.value = value;
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    await prefs.setBool(_prefsEnabledKey, value);
  }

  Future<void> updateConfig(LogConfig nextConfig) async {
    config.value = nextConfig;
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    await prefs.setString(_prefsMinLevelKey, nextConfig.minimumLevel.name);
    await prefs.setStringList(
      _prefsEnabledCategoriesKey,
      nextConfig.enabledCategories.map((category) => category.name).toList(),
    );
    await prefs.setBool(
      _prefsWebviewConsoleKey,
      nextConfig.webviewConsoleEnabled,
    );
    await prefs.setBool(
      _prefsWebviewLifecycleKey,
      nextConfig.webviewLifecycleEnabled,
    );
    await prefs.setBool(
      _prefsNetworkVerboseKey,
      nextConfig.networkVerboseEnabled,
    );
  }

  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_buffer.toList());

  List<LogEntry> get authTrail =>
      List<LogEntry>.unmodifiable(_authTrail.toList());

  /// 认证轨迹的纯文本导出（已脱敏）。
  String formatAuthTrail() {
    if (_authTrail.isEmpty) return '（本次启动后暂无认证日志）';
    return _authTrail.map((entry) => entry.formatted).join('\n');
  }

  /// 导出用的 Markdown 报告：内存报告 +（开启完整采集时）今天的持久化日志尾部。
  ///
  /// 持久化部分可能包含本次启动之前的记录，也可能与内存部分重复；它只在
  /// Release 开启 [diagnosticCapture] 或 Debug 构建中存在。读取失败不影响
  /// 内存报告。报告只在本机生成，不联网、不上传。
  Future<String> buildDiagnosticReport({String appVersion = 'unknown'}) async {
    final report = formatDiagnosticReport(appVersion: appVersion);
    if (!diagnosticCaptureActive) return report;
    final tail = await _readTodayPersistedLogTail();
    if (tail == null || tail.isEmpty) return report;
    final buffer = StringBuffer(report)
      ..writeln()
      ..writeln('## 持久化日志（今日最后 200 行）')
      ..writeln()
      ..writeln('> 可能与本文件上方的最近日志重复。');
    _writeLogBlock(buffer, tail);
    return buffer.toString();
  }

  Future<String?> _readTodayPersistedLogTail({int maxLines = 200}) async {
    final dir = _logDir;
    if (dir == null) return null;
    try {
      final file = _logFileForDate(DateTime.now());
      if (!await file.exists()) return null;
      final lines = await file.readAsLines();
      if (lines.isEmpty) return null;
      return lines
          .skip(lines.length > maxLines ? lines.length - maxLines : 0)
          .join('\n');
    } catch (_) {
      return null;
    }
  }

  /// 完整诊断报告（Markdown）：环境元数据 + 认证轨迹 + 最近的非认证日志。
  ///
  /// 报告只读内存，不联网、不上传；所有条目已经过 [_scrub]。非认证部分在
  /// Release 默认只含强制错误，开启 [diagnosticCapture] 后包含网络 / 启动 /
  /// UI 等常规日志。标题层级供用户直接保存为 `.md` 阅读。
  String formatDiagnosticReport({String appVersion = 'unknown'}) {
    final now = DateTime.now();
    final nonAuth = _buffer
        .where((entry) => entry.category != LogCategory.auth)
        .toList(growable: false);
    final buffer = StringBuffer()
      ..writeln('# JXU 完整诊断日志')
      ..writeln()
      ..writeln(
        '> 本文件由 App 在本机生成，不会自动上传。日志已按 AppLogger 规则脱敏；'
        '如含课程名、URL 等业务文本，分享前请自行确认。',
      )
      ..writeln()
      ..writeln('## 环境')
      ..writeln()
      ..writeln('- 生成时间：`${now.toIso8601String()}`')
      ..writeln('- 时区：${now.timeZoneName}（${now.timeZoneOffset.inMinutes} 分钟）')
      ..writeln('- 应用：$appVersion')
      ..writeln(
        '- 平台：${Platform.operatingSystem} '
        '${_singleLine(Platform.operatingSystemVersion)}',
      )
      ..writeln('- Dart：${_singleLine(Platform.version)}')
      ..writeln(
        '- 构建：${kReleaseMode
            ? 'release'
            : kProfileMode
            ? 'profile'
            : 'debug'}',
      )
      ..writeln(
        '- 完整采集：${diagnosticCapture.value}'
        '（active=$diagnosticCaptureActive）',
      )
      ..writeln('- 日志开关：${loggingEnabled.value}')
      ..writeln('- 最低级别：${config.value.minimumLevel.name}')
      ..writeln(
        '- 分类：${config.value.enabledCategories.map((c) => c.name).join(', ')}',
      )
      ..writeln(
        '- WebView：lifecycle=${config.value.webviewLifecycleEnabled}, '
        'console=${config.value.webviewConsoleEnabled}',
      )
      ..writeln('- 网络详细日志：${config.value.networkVerboseEnabled}')
      ..writeln('- 条数：认证 ${_authTrail.length} 条 / 其他 ${nonAuth.length} 条')
      ..writeln()
      ..writeln('## 认证轨迹（${_authTrail.length} 条）');
    _writeLogBlock(
      buffer,
      _authTrail.map((entry) => entry.formatted).join('\n'),
    );
    buffer
      ..writeln()
      ..writeln('## 最近日志（非认证，${nonAuth.length} 条）');
    _writeLogBlock(buffer, nonAuth.map((entry) => entry.formatted).join('\n'));
    return buffer.toString();
  }

  static String _singleLine(String value) =>
      value.replaceAll('\r', ' ').replaceAll('\n', ' ');

  /// 用围栏包住原始日志；围栏长度会避开内容里已有的反引号串。
  void _writeLogBlock(StringBuffer buffer, String content) {
    var fence = '```';
    while (content.contains(fence)) {
      fence = '$fence`';
    }
    buffer
      ..writeln(fence)
      ..writeln(content.isEmpty ? '（无）' : content)
      ..writeln(fence);
  }

  void debug(String message) {
    log(LogLevel.debug, LogCategory.general, message);
  }

  void info(String message) {
    log(LogLevel.info, LogCategory.general, message);
  }

  void warn(String message) {
    log(LogLevel.warn, LogCategory.general, message);
  }

  void log(
    LogLevel level,
    LogCategory category,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    bool force = false,
  }) {
    if (category == LogCategory.auth && level.index >= LogLevel.info.index) {
      _recordAuthTrail(level, message, error);
    }
    // Debug 构建始终记录；Release / Profile 仅在用户开启完整诊断日志时记录。
    // force（未捕获异常等）在任何构建都保留。
    if (!diagnosticCaptureActive && !force) return;
    if (!loggingEnabled.value && !force) return;

    final activeConfig = config.value;
    if (!_shouldLog(level, category, activeConfig, force: force)) {
      return;
    }

    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      category: category,
      message: _scrub(message),
      error: error == null ? null : _scrub('$error'),
      stackTrace: stackTrace == null ? null : _scrub('$stackTrace'),
    );

    if (_buffer.length >= _bufferCapacity) {
      _buffer.removeFirst();
    }
    _buffer.addLast(entry);

    debugPrint(entry.formatted);
    _appendToFile(entry);
  }

  void _recordAuthTrail(LogLevel level, String message, Object? error) {
    if (_authTrail.length >= authTrailCapacity) {
      _authTrail.removeFirst();
    }
    _authTrail.addLast(
      LogEntry(
        timestamp: DateTime.now(),
        level: level,
        category: LogCategory.auth,
        message: _scrub(message),
        error: error == null ? null : _scrub('$error'),
      ),
    );
  }

  void auth(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    bool force = false,
  }) {
    log(
      level,
      LogCategory.auth,
      message,
      error: error,
      stackTrace: stackTrace,
      force: force,
    );
  }

  void network(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    bool force = false,
  }) {
    log(
      level,
      LogCategory.network,
      message,
      error: error,
      stackTrace: stackTrace,
      force: force,
    );
  }

  void webview(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    bool force = false,
  }) {
    log(
      level,
      LogCategory.webview,
      message,
      error: error,
      stackTrace: stackTrace,
      force: force,
    );
  }

  void ui(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    bool force = false,
  }) {
    log(
      level,
      LogCategory.ui,
      message,
      error: error,
      stackTrace: stackTrace,
      force: force,
    );
  }

  void storage(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    bool force = false,
  }) {
    log(
      level,
      LogCategory.storage,
      message,
      error: error,
      stackTrace: stackTrace,
      force: force,
    );
  }

  void bootstrap(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    bool force = false,
  }) {
    log(
      level,
      LogCategory.bootstrap,
      message,
      error: error,
      stackTrace: stackTrace,
      force: force,
    );
  }

  bool _shouldLog(
    LogLevel level,
    LogCategory category,
    LogConfig activeConfig, {
    required bool force,
  }) {
    if (force || level == LogLevel.error) {
      return true;
    }
    if (level.index < activeConfig.minimumLevel.index) {
      return false;
    }
    return activeConfig.enabledCategories.contains(category);
  }

  String _scrub(String input) {
    var result = input;
    result = result.replaceAll(_sessionIdPattern, 'JSESSIONID=[REDACTED]');
    result = result.replaceAll(_ticketPattern, 'ticket=[REDACTED]');
    result = result.replaceAll(_tokenIdPattern, 'tokenId=[REDACTED]');
    result = result.replaceAll(_usernamePattern, 'username=[REDACTED]');
    result = result.replaceAll(_sysDatePattern, 'sysDate=[REDACTED]');
    result = result.replaceAll(_verifyPattern, 'verify=[REDACTED]');
    result = result.replaceAll(_passwordPattern, 'password=[REDACTED]');
    result = result.replaceAll(_mmPattern, 'mm=[REDACTED]');
    result = result.replaceAll(_phonePattern, '[REDACTED]');
    result = result.replaceAll(_studentIdPattern, '[REDACTED]');
    return result;
  }

  LogLevel _parseLevel(String? name, {required LogLevel fallback}) {
    for (final level in LogLevel.values) {
      if (level.name == name) {
        return level;
      }
    }
    return fallback;
  }

  Set<LogCategory> _parseCategories(List<String>? names) {
    if (names == null || names.isEmpty) {
      return const LogConfig.defaults().enabledCategories;
    }

    final categories = <LogCategory>{};
    for (final name in names) {
      for (final category in LogCategory.values) {
        if (category.name == name) {
          categories.add(category);
        }
      }
    }
    return categories.isEmpty
        ? const LogConfig.defaults().enabledCategories
        : categories;
  }

  Future<void> _appendToFile(LogEntry entry) async {
    final dir = _logDir;
    if (dir == null) return;

    try {
      final file = _logFileForDate(entry.timestamp);
      await file.writeAsString(
        '${entry.formatted}\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (_) {
      // Non-blocking - swallow file write failures.
    }
  }

  File _logFileForDate(DateTime date) {
    final stamp =
        '${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';
    return File('${_logDir!.path}/app_$stamp.log');
  }

  Future<void> _cleanupOldLogs() async {
    final dir = _logDir;
    if (dir == null) return;

    final cutoff = DateTime.now().subtract(
      const Duration(days: _retentionDays),
    );

    try {
      final files = dir.listSync().whereType<File>();
      for (final file in files) {
        final name = file.uri.pathSegments.last;
        final match = RegExp(r'app_(\d{8})\.log').firstMatch(name);
        if (match == null) continue;

        final dateStr = match.group(1)!;
        final year = int.tryParse(dateStr.substring(0, 4));
        final month = int.tryParse(dateStr.substring(4, 6));
        final day = int.tryParse(dateStr.substring(6, 8));
        if (year == null || month == null || day == null) continue;

        final fileDate = DateTime(year, month, day);
        if (fileDate.isBefore(cutoff)) {
          await file.delete();
        }
      }
    } catch (_) {
      // Best-effort cleanup.
    }
  }

  @visibleForTesting
  void debugReset() {
    _buffer.clear();
    _authTrail.clear();
    loggingEnabled.value = true;
    diagnosticCapture.value = false;
    config.value = const LogConfig.defaults();
    _logDir = null;
    _prefs = null;
    _initialized = false;
  }
}
