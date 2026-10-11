import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/perf/frame_timing_collector.dart';
import '../../core/perf/frame_timing_report.dart';
import '../../core/perf/frame_timing_stats.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/personalization_controller.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_dropdown.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/plain_list.dart';

/// 「性能诊断」内部页（默认隐藏，`--dart-define=JXU_PERF_DIAGNOSTICS=true` 才可用）。
///
/// 只做离线帧时采集：不联网、不上传、不读账号 / 日志 / 业务数据。采集器是
/// App 级单例，**离开本页不会停止采集**——用户需要先开始，再回到首页按场景
/// 操作，最后回来停止并导出。
///
/// 采集必须显式开始；未启用时本页 fail closed（只显示未启用提示，不提供任何
/// 开启采样的开关）。
class PerformanceDiagnosticsPage extends StatefulWidget {
  const PerformanceDiagnosticsPage({
    super.key,
    this.collector,
    this.clock,
    this.exporter,
  });

  /// 测试注入；生产用 [FrameTimingCollector.instance]。
  final FrameTimingCollector? collector;

  /// 测试注入时钟（用于验证 ≤1Hz 节流）。生产用 `DateTime.now`。
  final DateTime Function()? clock;

  /// 测试注入导出编排（避免测试碰真实磁盘）。生产用应用私有目录。
  final PerfRunExporter? exporter;

  @override
  State<PerformanceDiagnosticsPage> createState() =>
      _PerformanceDiagnosticsPageState();
}

class _PerformanceDiagnosticsPageState
    extends State<PerformanceDiagnosticsPage> {
  /// 界面刷新节流窗口：逐帧回调也不会逐帧 setState（避免自造掉帧）。
  static const Duration _uiRefreshWindow = Duration(milliseconds: 900);

  late final FrameTimingCollector _collector =
      widget.collector ?? FrameTimingCollector.instance;
  late final DateTime Function() _clock = widget.clock ?? DateTime.now;
  late final PerfRunExporter _exporter =
      widget.exporter ?? PerfRunExporter(PerfFileExportStore());

  PerfScenario _scenario = PerfScenario.idleHome;
  DateTime _lastUiRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  bool _lastRunning = false;
  bool _exporting = false;
  String? _exportError;
  String? _exportOk;

  bool get _running => _collector.isRunning;
  PerfRunResult? get _lastResult => _collector.lastResult;

  @override
  void initState() {
    super.initState();
    _lastRunning = _collector.isRunning;
    _collector.revision.addListener(_onRevision);
  }

  @override
  void dispose() {
    // 只注销界面监听；采集器继续运行（用户离开页面去操作场景是设计行为）。
    _collector.revision.removeListener(_onRevision);
    super.dispose();
  }

  void _onRevision() {
    if (!mounted) return;
    // 采样状态变化（开始 / 停止 / 自动停止）必须立刻反映；
    // 只有「帧数增长」这类高频变化才走 ≤1Hz 节流，避免逐帧 setState。
    final running = _collector.isRunning;
    final now = _clock();
    if (running == _lastRunning &&
        now.difference(_lastUiRefresh) < _uiRefreshWindow) {
      return;
    }
    _lastRunning = running;
    _lastUiRefresh = now;
    setState(() {});
  }

  void _refreshNow() {
    _lastRunning = _collector.isRunning;
    _lastUiRefresh = _clock();
    if (mounted) setState(() {});
  }

  void _start() {
    final rate = View.maybeOf(context)?.display.refreshRate;
    final ok = _collector.start(
      PerfRunMetadata(
        scenario: _scenario,
        displayRefreshRate: rate,
        shaderFps: PersonalizationController.instance.shaderFps.value,
      ),
    );
    _exportError = null;
    _exportOk = null;
    _refreshNow();
    if (!ok && mounted) {
      AppFeedback.toast(context, '无法开始：应用不在前台或已在采集中');
    }
  }

  void _stop() {
    _collector.stop();
    _refreshNow();
  }

  void _goHome() {
    GoRouter.maybeOf(context)?.goNamed('home');
  }

  Future<void> _copyJson() async {
    final result = _lastResult;
    if (result == null) return;
    await _copy(buildPerfRunJson(result), 'JSON 报告已复制');
  }

  Future<void> _copyCsv() async {
    final result = _lastResult;
    if (result == null) return;
    await _copy(buildPerfRunCsv(result), 'CSV 原始帧已复制');
  }

  Future<void> _copy(String payload, String okMessage) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await Clipboard.setData(ClipboardData(text: payload));
      if (messenger != null) AppFeedback.toastOn(messenger, okMessage);
    } on PlatformException {
      if (messenger != null) AppFeedback.toastOn(messenger, '复制失败');
    }
  }

  Future<void> _exportToFile() async {
    final result = _lastResult;
    if (result == null || _exporting) return;
    setState(() {
      _exporting = true;
      _exportError = null;
      _exportOk = null;
    });
    try {
      final outcome = await _exporter.export(result);
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _exportOk =
            '已导出 ${outcome.jsonFileName} / ${outcome.csvFileName}（仅保留最近 3 次）';
      });
    } on FileSystemException {
      if (!mounted) return;
      // 不打印绝对路径 / 异常细节，避免泄漏用户名与目录结构。
      setState(() {
        _exporting = false;
        _exportError = '导出失败，请稍后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_collector.enabled) return _buildDisabled(context);
    return Scaffold(
      appBar: const AppAppBar(title: Text('性能诊断')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          kPlainListGutter,
          8,
          kPlainListGutter,
          32,
        ),
        children: [
          _buildIntro(context),
          const SizedBox(height: kPlainListGroupGap),
          _buildScenarioSection(context),
          const SizedBox(height: kPlainListGroupGap),
          _buildCaptureSection(context),
          const SizedBox(height: kPlainListGroupGap),
          _buildStepsSection(context),
          const SizedBox(height: kPlainListGroupGap),
          _buildResultSection(context),
          const SizedBox(height: kPlainListGroupGap),
          _buildExportSection(context),
        ],
      ),
    );
  }

  Widget _buildDisabled(BuildContext context) {
    return Scaffold(
      appBar: const AppAppBar(title: Text('性能诊断')),
      body: const AppEmptyView(
        title: '性能诊断未启用',
        message:
            '这是内部诊断工具，需要以 '
            '--dart-define=JXU_PERF_DIAGNOSTICS=true 构建才会启用。',
        icon: Icons.monitor_heart_outlined,
      ),
    );
  }

  Widget _buildIntro(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const PlainTag('内部工具'),
            const SizedBox(width: 8),
            Expanded(child: Text('离线帧时诊断', style: context.appText.rowTitle)),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '在真机上按场景采集 Flutter 帧时，导出 JSON / CSV 自行分析。'
          '不联网、不上传、不读账号与日志。',
          style: context.appText.secondary,
        ),
      ],
    );
  }

  Widget _buildScenarioSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PlainSectionHeader('场景'),
        AppDropdown<PerfScenario>(
          value: _scenario,
          label: '测量场景',
          expanded: true,
          onChanged: _running
              ? null
              : (value) {
                  if (value == null) return;
                  setState(() => _scenario = value);
                },
          items: [
            for (final scenario in PerfScenario.values)
              AppDropdownItem<PerfScenario>(
                value: scenario,
                label: scenario.label,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(_scenario.hint, style: context.appText.meta),
      ],
    );
  }

  Widget _buildCaptureSection(BuildContext context) {
    final running = _running;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PlainSectionHeader('采集'),
        PlainListGroup(
          children: [
            PlainListRow(
              title: '状态',
              value: running ? '采集中' : '未开始',
              valueKey: const Key('perf_state_value'),
              emphasizeValue: running,
              showChevron: false,
            ),
            PlainListRow(
              title: '已采集帧',
              value: formatPerfCount(_collector.sampleCount),
              valueKey: const Key('perf_frames_value'),
              showChevron: false,
            ),
            PlainListRow(
              title: '已运行',
              value: formatPerfDuration(_collector.elapsed),
              valueKey: const Key('perf_elapsed_value'),
              showChevron: false,
            ),
            const PlainListRow(
              title: '上限',
              value: '5000 帧 / 60 秒',
              showChevron: false,
            ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('perf_start_button'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: running ? null : _start,
          child: const Text('开始采样'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const Key('perf_stop_button'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: running ? _stop : null,
          child: const Text('停止采样'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const Key('perf_home_button'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: running ? _goHome : null,
          child: const Text('回到首页采样'),
        ),
      ],
    );
  }

  Widget _buildStepsSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PlainSectionHeader('步骤'),
        PlainListGroup(
          children: const [
            PlainListRow(
              title: '1  开始采样',
              subtitle: '选好场景后点「开始采样」，前 2 秒是导航/首帧沉降，判读时避开。',
              showChevron: false,
            ),
            PlainListRow(
              title: '2  离开本页操作场景',
              subtitle: '返回首页按场景提示滚动 / 切换 tab。离开本页不会停止采集。',
              showChevron: false,
            ),
            PlainListRow(
              title: '3  回来停止',
              subtitle: '回到本页点「停止采样」；到 60 秒 / 5000 帧或退到后台会自动停止。',
              showChevron: false,
            ),
            PlainListRow(
              title: '4  导出',
              subtitle: '复制 JSON / CSV，或导出到应用私有目录留档。',
              showChevron: false,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildResultSection(BuildContext context) {
    final result = _lastResult;
    if (result == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PlainSectionHeader('结果'),
          PlainListGroup(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: kPlainListRowInset,
                  vertical: 12,
                ),
                child: Text('还没有完成的采集。', style: context.appText.secondary),
              ),
            ],
          ),
        ],
      );
    }

    final stats = result.stats;
    String triple(double? p50, double? p95, double? p99) =>
        '${formatPerfMs(p50)} / ${formatPerfMs(p95)} / ${formatPerfMs(p99)} ms';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PlainSectionHeader('结果（最近一次）'),
        PlainListGroup(
          children: [
            _PerfStatRow(
              label: '场景 / 结束原因',
              value:
                  '${result.metadata.scenario.label} · '
                  '${result.stopReason.label}',
            ),
            _PerfStatRow(
              label: '样本数',
              value:
                  '${formatPerfCount(stats.count)} 帧'
                  '（丢弃迟到 ${result.droppedLateSamples} / 非法 '
                  '${result.invalidSamples}）',
            ),
            _PerfStatRow(
              label: 'UI build p50 / p95 / p99',
              value: triple(
                stats.uiBuildP50,
                stats.uiBuildP95,
                stats.uiBuildP99,
              ),
            ),
            _PerfStatRow(
              label: 'Raster p50 / p95 / p99',
              value: triple(stats.rasterP50, stats.rasterP95, stats.rasterP99),
              note: '光栅线程耗时，含滤镜 / 模糊重采样',
            ),
            _PerfStatRow(
              label: '总跨度 p50 / p95 / p99',
              value: triple(
                stats.totalSpanP50,
                stats.totalSpanP95,
                stats.totalSpanP99,
              ),
              note: 'vsync 到光栅结束的流水线跨度，不是 build + raster，也不是 GPU 真实耗时',
            ),
            _PerfStatRow(
              label: '超过 120Hz 理论间隔（build / raster / 总跨度）',
              value:
                  '${formatPerfPercent(stats.buildOverBudgetFraction)} / '
                  '${formatPerfPercent(stats.rasterOverBudgetFraction)} / '
                  '${formatPerfPercent(stats.totalOverBudgetFraction)}',
              note:
                  '$kPerfOverBudgetLabel'
                  '（预算 ${stats.budgetMs.toStringAsFixed(2)} ms）',
            ),
            _PerfStatRow(
              label: '设备刷新率快照 / 构建模式',
              value: '${_rateText(result)} · $perfBuildMode',
              note:
                  '开始瞬间快照；LTPO / 省电 / 温控会让它变化，'
                  '不代表真实面板帧率，也不代表 120 FPS 已达标',
            ),
          ],
        ),
      ],
    );
  }

  String _rateText(PerfRunResult result) {
    final rate = result.metadata.displayRefreshRate;
    if (rate == null || !rate.isFinite || rate <= 0) return '刷新率未知';
    return '${rate.toStringAsFixed(0)} Hz';
  }

  Widget _buildExportSection(BuildContext context) {
    final hasResult = _lastResult != null;
    final canAct = hasResult && !_exporting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PlainSectionHeader('导出'),
        FilledButton.tonal(
          key: const Key('perf_copy_json_button'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: canAct ? _copyJson : null,
          child: const Text('复制 JSON 报告'),
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(
          key: const Key('perf_copy_csv_button'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: canAct ? _copyCsv : null,
          child: const Text('复制 CSV 原始帧'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const Key('perf_export_button'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: canAct ? _exportToFile : null,
          child: const Text('导出到文件'),
        ),
        const SizedBox(height: 8),
        Text(
          '复制的内容可直接粘贴发送，不需要电脑或数据线。文件写在应用私有目录，'
          '其它应用与电脑无法直接读取，仅作本机留档。',
          style: context.appText.meta,
        ),
        if (_exportOk != null) ...[
          const SizedBox(height: 8),
          Text(
            _exportOk!,
            key: const Key('perf_export_ok'),
            style: context.appText.secondary,
          ),
        ],
        if (_exportError != null) ...[
          const SizedBox(height: 8),
          Text(
            _exportError!,
            key: const Key('perf_export_error'),
            style: context.appText.secondary.copyWith(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

/// 结果读数行：标签 + 值 + 可选说明，值可换行，长文本不截断。
class _PerfStatRow extends StatelessWidget {
  const _PerfStatRow({required this.label, required this.value, this.note});

  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final text = context.appText;
    final noteText = note;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kPlainListRowInset,
        vertical: 8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: text.meta),
          const SizedBox(height: 2),
          Text(value, style: text.rowTitle),
          if (noteText != null) ...[
            const SizedBox(height: 2),
            Text(noteText, style: text.meta),
          ],
        ],
      ),
    );
  }
}
