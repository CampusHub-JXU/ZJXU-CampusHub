import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'frame_timing_collector.dart';
import 'frame_timing_stats.dart';

/// 报告 schema 版本。字段只增不改名；消费方按版本判断。
const int kPerfReportSchemaVersion = 1;

/// 配置基线（**不是**运行时探测值）。
///
/// Flutter 没有可用的运行时版本常量；`Platform.version` 会带上主机名 /
/// 用户名等无界字符串，禁止写进报告。这里写仓库当前工具链基线，并附出处，
/// 让读报告的人知道它是「构建基线」而非「本机实测」。
const String kPerfConfiguredFlutterBaseline = '3.47.2';
const String kPerfConfiguredFlutterBaselineProvenance =
    'configured toolchain baseline (docs/agents/build-and-run.md); not runtime-detected';

/// `device_info_plus` 不在依赖里（已核对 pubspec），所以 Android SDK / 机型
/// 无法在运行时取得，统一记为 `unknown`，不猜测、不为它新增依赖。
const String kPerfUnknown = 'unknown';

String get perfBuildMode {
  if (kReleaseMode) return 'release';
  if (kProfileMode) return 'profile';
  return 'debug';
}

/// 报告元数据（白名单，固定键；不含任何身份 / 账号 / URL / 日志内容）。
Map<String, Object?> buildPerfMetadata(PerfRunResult result) {
  final rate = result.metadata.displayRefreshRate;
  final safeRate = (rate != null && rate.isFinite && rate > 0) ? rate : null;
  final shaderFps = result.metadata.shaderFps;
  return <String, Object?>{
    'buildMode': perfBuildMode,
    'displayRefreshRate': safeRate,
    'displayRefreshRateNote': '开始瞬间快照；LTPO / 省电 / 温控会让它随场景变化，不代表真实面板帧率',
    'flutterBaseline': kPerfConfiguredFlutterBaseline,
    'flutterBaselineProvenance': kPerfConfiguredFlutterBaselineProvenance,
    'androidSdk': kPerfUnknown,
    'deviceModel': kPerfUnknown,
    'impellerBackend': kPerfUnknown,
    'gpuModel': kPerfUnknown,
    'batteryTemperatureC': kPerfUnknown,
    'shaderFps': shaderFps,
  };
}

Map<String, Object?> buildPerfStatsMap(FrameTimingStats stats) {
  Map<String, Object?> p(double? p50, double? p95, double? p99, double? max) =>
      <String, Object?>{'p50': p50, 'p95': p95, 'p99': p99, 'max': max};
  return <String, Object?>{
    'count': stats.count,
    'budgetMs': stats.budgetMs,
    'overBudgetLabel': kPerfOverBudgetLabel,
    'uiBuildMs': p(
      stats.uiBuildP50,
      stats.uiBuildP95,
      stats.uiBuildP99,
      stats.uiBuildMax,
    ),
    'rasterMs': p(
      stats.rasterP50,
      stats.rasterP95,
      stats.rasterP99,
      stats.rasterMax,
    ),
    'totalSpanMs': p(
      stats.totalSpanP50,
      stats.totalSpanP95,
      stats.totalSpanP99,
      stats.totalSpanMax,
    ),
    'vsyncOverheadMs': p(
      stats.vsyncOverheadP50,
      stats.vsyncOverheadP95,
      stats.vsyncOverheadP99,
      stats.vsyncOverheadMax,
    ),
    'buildOverBudgetFraction': stats.buildOverBudgetFraction,
    'rasterOverBudgetFraction': stats.rasterOverBudgetFraction,
    'totalOverBudgetFraction': stats.totalOverBudgetFraction,
  };
}

/// 完整报告（结构化、无原始逐帧表）。原始逐帧走 [buildPerfRunCsv]。
Map<String, Object?> buildPerfRunReport(PerfRunResult result) {
  final stats = result.stats;
  final offsets = result.samples
      .map((s) => s.vsyncOffsetMicros)
      .toList(growable: false);
  final minOffset = offsets.isEmpty
      ? null
      : offsets.reduce((a, b) => a < b ? a : b) / 1000.0;
  final maxOffset = offsets.isEmpty
      ? null
      : offsets.reduce((a, b) => a > b ? a : b) / 1000.0;

  return <String, Object?>{
    'schemaVersion': kPerfReportSchemaVersion,
    'tool': 'frame-timing-diagnostics',
    'scenario': result.metadata.scenario.id,
    'scenarioLabel': result.metadata.scenario.label,
    'stopReason': result.stopReason.id,
    'stopReasonLabel': result.stopReason.label,
    'startedAt': result.startedAt.toUtc().toIso8601String(),
    'endedAt': result.endedAt.toUtc().toIso8601String(),
    'durationMs': result.duration.inMilliseconds,
    'settlingWindowMs': kPerfSettlingWindowMs,
    'sampleCount': result.samples.length,
    'droppedLateSamples': result.droppedLateSamples,
    'invalidSamples': result.invalidSamples,
    'sampleVsyncOffsetRangeMs': <String, Object?>{
      'min': minOffset,
      'max': maxOffset,
    },
    'metadata': buildPerfMetadata(result),
    'stats': buildPerfStatsMap(stats),
  };
}

/// 缩进 JSON 文本（剪贴板 / 文件共用）。
String buildPerfRunJson(PerfRunResult result) =>
    const JsonEncoder.withIndent('  ').convert(buildPerfRunReport(result));

const List<String> _csvColumns = <String>[
  'scenario',
  'index',
  'vsync_offset_ms',
  'ui_build_ms',
  'raster_ms',
  'total_span_ms',
  'vsync_overhead_ms',
];

/// 原始逐帧 CSV（最多 [kPerfMaxSamples] 行，已由采集器上限保证）。
///
/// 所有单元格都是固定枚举串或数字，无自由文本；仍做转义 + 公式注入防护
/// （以 `= + - @` 开头的字段加前缀），保证被表格软件打开也不会执行公式。
String buildPerfRunCsv(PerfRunResult result) {
  final buffer = StringBuffer()..writeln(_csvColumns.join(','));
  final scenario = result.metadata.scenario.id;
  var index = 0;
  for (final s in result.samples) {
    buffer.writeln(
      <String>[
        perfCsvCell(scenario),
        '$index',
        _num(s.vsyncOffsetMicros / 1000.0),
        _num(s.uiBuildMs),
        _num(s.rasterMs),
        _num(s.totalSpanMs),
        _num(s.vsyncOverheadMs),
      ].join(','),
    );
    index++;
  }
  return buffer.toString();
}

String _num(double value) => value.isFinite ? value.toStringAsFixed(3) : '';

/// CSV 单元格转义 + 公式注入防护（以 `= + - @` 开头时加前缀 `'`）。
///
/// 当前所有单元格都是固定枚举串或数字，不会触发；保留该防护并测试，
/// 防止以后有人往 CSV 里塞自由文本。
@visibleForTesting
String perfCsvCell(String value) {
  final needsGuard =
      value.startsWith('=') ||
      value.startsWith('+') ||
      value.startsWith('-') ||
      value.startsWith('@');
  final guarded = needsGuard ? "'$value" : value;
  if (guarded.contains(',') ||
      guarded.contains('"') ||
      guarded.contains('\n') ||
      guarded.contains('\r')) {
    return '"${guarded.replaceAll('"', '""')}"';
  }
  return guarded;
}

/// 导出落盘的极简文件接口（可注入内存替身，避免测试碰真实磁盘）。
abstract interface class PerfExportStore {
  Future<void> write(String fileName, String content);
  Future<String?> read(String fileName);
  Future<void> delete(String fileName);
}

/// 真实实现：App 私有支持目录下固定子目录 `perf_diagnostics`，固定文件名。
///
/// 目录与文件名硬编码，不接受任意用户路径。写入用「临时文件 + rename」，
/// 与 [AtomicJsonFile] 同一套原子替换思路——但**不复用** [AtomicJsonFile]，
/// 因为它的 `write` 会对入参做 `jsonEncode`，而这里已经是序列化好的文本
/// （JSON 文本 / CSV 文本），再编码会多一层引号。
class PerfFileExportStore implements PerfExportStore {
  PerfFileExportStore([this._directory]);

  static const String directoryName = 'perf_diagnostics';

  final Future<Directory> Function()? _directory;

  Future<Directory> _resolve() async {
    final base = await (_directory?.call() ?? getApplicationSupportDirectory());
    final dir = Directory(
      '${base.path}${Platform.pathSeparator}$directoryName',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file(String fileName) async {
    final dir = await _resolve();
    return File('${dir.path}${Platform.pathSeparator}$fileName');
  }

  @override
  Future<void> write(String fileName, String content) async {
    final target = await _file(fileName);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<String?> read(String fileName) async {
    final target = await _file(fileName);
    if (!await target.exists()) return null;
    return target.readAsString();
  }

  @override
  Future<void> delete(String fileName) async {
    final target = await _file(fileName);
    if (await target.exists()) await target.delete();
  }
}

/// 一次导出写了哪些文件（只有固定文件名，无绝对路径）。
class PerfExportOutcome {
  const PerfExportOutcome({
    required this.slot,
    required this.jsonFileName,
    required this.csvFileName,
  });

  final int slot;
  final String jsonFileName;
  final String csvFileName;
}

/// 导出编排：固定 3 个槽位轮转，永远只保留最近 3 次，不会无限增长。
class PerfRunExporter {
  PerfRunExporter(this.store);

  static const int slotCount = 3;
  static const String _base = 'perf_diagnostics';

  static String jsonSlot(int slot) => '${_base}_$slot.json';
  static String csvSlot(int slot) => '${_base}_$slot.csv';

  final PerfExportStore store;

  Future<PerfExportOutcome> export(PerfRunResult result) async {
    final json = buildPerfRunJson(result);
    final csv = buildPerfRunCsv(result);
    await _rotate(jsonSlot);
    await _rotate(csvSlot);
    await store.write(jsonSlot(1), json);
    await store.write(csvSlot(1), csv);
    return PerfExportOutcome(
      slot: 1,
      jsonFileName: jsonSlot(1),
      csvFileName: csvSlot(1),
    );
  }

  Future<void> _rotate(String Function(int slot) slot) async {
    await store.delete(slot(slotCount));
    for (var i = slotCount - 1; i >= 1; i--) {
      final content = await store.read(slot(i));
      if (content == null) {
        await store.delete(slot(i + 1));
        continue;
      }
      await store.write(slot(i + 1), content);
    }
  }
}
