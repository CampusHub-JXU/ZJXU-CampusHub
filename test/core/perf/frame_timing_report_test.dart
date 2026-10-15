import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/perf/frame_timing_collector.dart';
import 'package:jxu_campus_hub/core/perf/frame_timing_report.dart';
import 'package:jxu_campus_hub/core/perf/frame_timing_stats.dart';

import '../../helpers/perf_frame_timing_support.dart';

FrameTimingSample sample({double ui = 2, double raster = 3, double total = 5}) {
  return FrameTimingSample(
    vsyncOffsetMicros: 0,
    uiBuildMs: ui,
    rasterMs: raster,
    totalSpanMs: total,
    vsyncOverheadMs: 0.2,
  );
}

PerfRunResult runResult({
  PerfScenario scenario = PerfScenario.idleHome,
  PerfStopReason reason = PerfStopReason.userStop,
  List<FrameTimingSample>? samples,
  double? rate,
  int? shaderFps,
  int dropped = 0,
  int invalid = 0,
}) {
  return PerfRunResult(
    metadata: PerfRunMetadata(
      scenario: scenario,
      displayRefreshRate: rate,
      shaderFps: shaderFps,
    ),
    startedAt: DateTime.utc(2026, 1, 1, 12, 0, 0),
    endedAt: DateTime.utc(2026, 1, 1, 12, 0, 12, 345),
    stopReason: reason,
    samples: samples ?? <FrameTimingSample>[sample()],
    droppedLateSamples: dropped,
    invalidSamples: invalid,
  );
}

class FakeExportStore implements PerfExportStore {
  final Map<String, String> files = <String, String>{};
  int writes = 0;

  @override
  Future<void> write(String fileName, String content) async {
    writes++;
    files[fileName] = content;
  }

  @override
  Future<String?> read(String fileName) async => files[fileName];

  @override
  Future<void> delete(String fileName) async => files.remove(fileName);
}

void main() {
  group('报告结构（白名单）', () {
    test('顶层键恰好是白名单', () {
      final report = buildPerfRunReport(runResult());
      expect(report.keys.toSet(), <String>{
        'schemaVersion',
        'tool',
        'scenario',
        'scenarioLabel',
        'stopReason',
        'stopReasonLabel',
        'startedAt',
        'endedAt',
        'durationMs',
        'settlingWindowMs',
        'sampleCount',
        'droppedLateSamples',
        'invalidSamples',
        'sampleVsyncOffsetRangeMs',
        'metadata',
        'stats',
      });
      expect(report['schemaVersion'], kPerfReportSchemaVersion);
      expect(report['tool'], 'frame-timing-diagnostics');
      expect(report['settlingWindowMs'], 2000);
    });

    test('元数据键恰好是白名单，未知项显式为 unknown', () {
      final metadata = buildPerfMetadata(runResult());
      expect(metadata.keys.toSet(), <String>{
        'buildMode',
        'displayRefreshRate',
        'displayRefreshRateNote',
        'flutterBaseline',
        'flutterBaselineProvenance',
        'androidSdk',
        'deviceModel',
        'impellerBackend',
        'gpuModel',
        'batteryTemperatureC',
        'shaderFps',
      });
      expect(metadata['buildMode'], anyOf('debug', 'profile', 'release'));
      expect(metadata['androidSdk'], 'unknown');
      expect(metadata['deviceModel'], 'unknown');
      expect(metadata['impellerBackend'], 'unknown');
      expect(metadata['gpuModel'], 'unknown');
      expect(metadata['batteryTemperatureC'], 'unknown');
      expect(metadata['flutterBaseline'], '3.47.2');
      expect(metadata['flutterBaselineProvenance'], isNotEmpty);
      // 不猜 Adreno / 不写 GPU 型号。
      expect(metadata.toString().toLowerCase(), isNot(contains('adreno')));
    });

    test('统计键恰好是白名单，并带上诚实标签', () {
      final stats = buildPerfStatsMap(runResult().stats);
      expect(stats.keys.toSet(), <String>{
        'count',
        'budgetMs',
        'overBudgetLabel',
        'uiBuildMs',
        'rasterMs',
        'totalSpanMs',
        'vsyncOverheadMs',
        'buildOverBudgetFraction',
        'rasterOverBudgetFraction',
        'totalOverBudgetFraction',
      });
      expect(stats['overBudgetLabel'], kPerfOverBudgetLabel);
      expect(stats['budgetMs'], closeTo(8.3333, 0.0001));
    });

    test('刷新率只接受有限正值，其余为 null', () {
      expect(
        buildPerfMetadata(runResult(rate: 120))['displayRefreshRate'],
        120,
      );
      for (final bad in const [double.nan, double.infinity, 0.0, -60.0]) {
        expect(
          buildPerfMetadata(runResult(rate: bad))['displayRefreshRate'],
          isNull,
        );
      }
      expect(buildPerfMetadata(runResult())['displayRefreshRate'], isNull);
    });

    test('场景 / 结束原因用固定枚举 id，不用自由文本', () {
      final report = buildPerfRunReport(
        runResult(
          scenario: PerfScenario.tabReturn,
          reason: PerfStopReason.sampleCap,
        ),
      );
      expect(report['scenario'], 'tabReturn');
      expect(report['stopReason'], 'sampleCap');
    });

    test('样本偏移范围来自真实样本；空样本为 null', () {
      final report = buildPerfRunReport(runResult());
      final range = report['sampleVsyncOffsetRangeMs'] as Map<String, Object?>;
      expect(range['min'], 0);
      expect(range['max'], 0);

      final empty = buildPerfRunReport(
        runResult(samples: const <FrameTimingSample>[]),
      );
      final emptyRange =
          empty['sampleVsyncOffsetRangeMs'] as Map<String, Object?>;
      expect(emptyRange['min'], isNull);
      expect(emptyRange['max'], isNull);
    });

    test('时间戳是 ISO 字符串且为 UTC', () {
      final report = buildPerfRunReport(runResult());
      final started = report['startedAt']! as String;
      final ended = report['endedAt']! as String;
      expect(started, endsWith('Z'));
      expect(DateTime.parse(started).isUtc, isTrue);
      expect(DateTime.parse(ended).isAfter(DateTime.parse(started)), isTrue);
      expect(report['durationMs'], 12345);
    });
  });

  group('隐私', () {
    test('JSON 文本不含身份 / 账号 / URL / 日志字段名', () {
      final json = buildPerfRunJson(
        runResult(scenario: PerfScenario.homeScroll, rate: 120, shaderFps: 60),
      );
      final lower = json.toLowerCase();
      for (final forbidden in const [
        'studentid',
        'student_id',
        'account',
        'username',
        'password',
        'token',
        'cookie',
        'credential',
        'http',
        'url',
        'title',
        'schedule',
        'calendar',
        'notice',
        'loglevel',
        'logger',
        'androidid',
        'serial',
        'fingerprint',
        'locale',
      ]) {
        expect(lower, isNot(contains(forbidden)), reason: forbidden);
      }
    });

    test('JSON 可解析且数字 / null 结构稳定', () {
      final decoded = jsonDecode(
        buildPerfRunJson(runResult(rate: 120)),
      ) as Map<String, dynamic>;
      expect(decoded['metadata']['displayRefreshRate'], 120);
      expect(decoded['stats']['count'], 1);
    });

    test('报告源码不联网、不读日志', () {
      final src = dartCodeWithoutComments(
        File('lib/core/perf/frame_timing_report.dart').readAsStringSync(),
      );
      expect(src.contains('HttpClient'), isFalse);
      expect(src.contains('dio'), isFalse);
      expect(src.contains('http://'), isFalse);
      expect(src.contains('AppLogger'), isFalse);
    });
  });

  group('CSV', () {
    test('表头固定，行数 = 样本数 + 1', () {
      final csv = buildPerfRunCsv(
        runResult(samples: <FrameTimingSample>[sample(), sample(), sample()]),
      );
      final lines = csv.trimRight().split('\n');
      expect(
        lines.first,
        'scenario,index,vsync_offset_ms,ui_build_ms,'
        'raster_ms,total_span_ms,vsync_overhead_ms',
      );
      expect(lines.length, 4);
      expect(lines[1].startsWith('idleHome,0,'), isTrue);
      expect(lines[3].startsWith('idleHome,2,'), isTrue);
    });

    test('空样本只有表头', () {
      final csv = buildPerfRunCsv(
        runResult(samples: const <FrameTimingSample>[]),
      );
      expect(csv.trimRight().split('\n').length, 1);
    });

    test('非法数字输出空单元格而不是 NaN', () {
      final csv = buildPerfRunCsv(
        runResult(
          samples: <FrameTimingSample>[
            FrameTimingSample(
              vsyncOffsetMicros: 0,
              uiBuildMs: double.nan,
              rasterMs: 3,
              totalSpanMs: 5,
              vsyncOverheadMs: 0.2,
            ),
          ],
        ),
      );
      final row = csv.trimRight().split('\n')[1].split(',');
      expect(row[3], '');
      expect(csv.contains('NaN'), isFalse);
    });

    test('单元格转义与公式注入防护', () {
      expect(perfCsvCell('idleHome'), 'idleHome');
      expect(perfCsvCell('a,b'), '"a,b"');
      expect(perfCsvCell('a"b'), '"a""b"');
      expect(perfCsvCell('a\nb'), '"a\nb"');
      expect(perfCsvCell('=1+1'), "'=1+1");
      expect(perfCsvCell('@cmd'), "'@cmd");
      expect(perfCsvCell('-1'), "'-1");
      expect(perfCsvCell('+1'), "'+1");
    });
  });

  group('有界导出', () {
    test('轮转只保留最近 3 次，文件名固定', () async {
      final store = FakeExportStore();
      final exporter = PerfRunExporter(store);

      for (var i = 0; i < 5; i++) {
        await exporter.export(runResult(scenario: PerfScenario.idleHome));
      }

      expect(store.files.keys.toSet(), <String>{
        'perf_diagnostics_1.json',
        'perf_diagnostics_2.json',
        'perf_diagnostics_3.json',
        'perf_diagnostics_1.csv',
        'perf_diagnostics_2.csv',
        'perf_diagnostics_3.csv',
      });
      // 写入次数随次数线性增长但有界（每次最多 3 写 / 文件族），不会无限累积。
      expect(store.writes, lessThanOrEqualTo(5 * 6));
    });

    test('槽位 1 永远是最新，内容可解析', () async {
      final store = FakeExportStore();
      final exporter = PerfRunExporter(store);

      await exporter.export(runResult(scenario: PerfScenario.idleHome));
      await exporter.export(runResult(scenario: PerfScenario.settingsDialog));

      final latest = jsonDecode(
        store.files['perf_diagnostics_1.json']!,
      ) as Map<String, dynamic>;
      expect(latest['scenario'], 'settingsDialog');

      final previous = jsonDecode(
        store.files['perf_diagnostics_2.json']!,
      ) as Map<String, dynamic>;
      expect(previous['scenario'], 'idleHome');

      expect(store.files.containsKey('perf_diagnostics_3.json'), isFalse);
    });

    test('导出结果只暴露固定文件名，不含绝对路径', () async {
      final store = FakeExportStore();
      final outcome = await PerfRunExporter(store).export(runResult());
      expect(outcome.slot, 1);
      expect(outcome.jsonFileName, 'perf_diagnostics_1.json');
      expect(outcome.csvFileName, 'perf_diagnostics_1.csv');
      expect(outcome.jsonFileName.contains(Platform.pathSeparator), isFalse);
    });

    test('文件 store 的目录名硬编码，不接受任意用户路径', () {
      expect(PerfFileExportStore.directoryName, 'perf_diagnostics');
      final src = dartCodeWithoutComments(
        File('lib/core/perf/frame_timing_report.dart').readAsStringSync(),
      );
      expect(src.contains('getApplicationSupportDirectory'), isTrue);
    });
  });
}
