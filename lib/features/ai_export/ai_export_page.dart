import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/logging/app_logger.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_banner.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/app_filter_chips.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/plain_list.dart';
import 'export_builder.dart';
import 'export_controller.dart';
import 'export_document.dart';
import 'export_model.dart';
import 'export_output.dart';
import 'export_text.dart';

/// 「去登录」的执行者：返回登录是否成功。生产默认见 [defaultExportLoginHandler]；
/// 导出页本身**从不**自动登录，只在用户点按「去登录」时才走这里。
typedef ExportLoginHandler = Future<bool> Function(
  BuildContext context,
  ExportAuthDomain domain,
);

/// 默认登录入口：复用既有的教务 / 统一认证登录弹窗；第二课堂是微信授权，
/// 没有应用内登录，打开第二课堂页由用户在那里授权。
Future<bool> defaultExportLoginHandler(
  BuildContext context,
  ExportAuthDomain domain,
) async {
  switch (domain) {
    case ExportAuthDomain.academic:
      return showAcademicSystemLoginModal(context);
    case ExportAuthDomain.unified:
      return showUnifiedAuthLoginModal(
        context,
        title: '登录统一认证',
        description: '登录后可获取教务处通知与体测成绩',
      );
    case ExportAuthDomain.session:
      await context.pushNamed('second-classroom');
      return false;
  }
}

/// 「导出给 AI」页：按用途预设选内容，缺的模块按需获取，复制 / 保存 / 分享。
class AiExportPage extends StatefulWidget {
  const AiExportPage({
    super.key,
    this.sources = const [],
    this.controller,
    this.loginHandler,
  });

  /// 各模块的取数来源，由 `lib/app` 注入。[controller] 非空时忽略。
  final Iterable<ExportModuleSource> sources;

  /// 测试 / 外部持有的控制器；传入时页面不负责释放。
  final AiExportController? controller;

  final ExportLoginHandler? loginHandler;

  @override
  State<AiExportPage> createState() => _AiExportPageState();
}

class _AiExportPageState extends State<AiExportPage> {
  late final AiExportController _controller;
  late final bool _ownsController;

  ExportFormat _format = ExportFormat.markdown;
  ExportModule? _csvModule;
  bool _expanded = false;

  late AiExportDocument _document;
  late String _content;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ?? AiExportController(sources: widget.sources);
    _controller.addListener(_onControllerChanged);
    _recompute();
    unawaited(_controller.initialize());
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(_recompute);
  }

  void _recompute() {
    _document = _controller.buildDocument();
    // CSV 目标模块必须在所选模块内。
    final inDoc = _document.modules.map((m) => m.module).toSet();
    if (_csvModule == null || !inDoc.contains(_csvModule)) {
      _csvModule = ExportBuilder.csvTarget(_document, null)?.module;
    }
    _content = ExportBuilder.encode(_format, _document, csvModule: _csvModule);
  }

  String get _fileName =>
      ExportBuilder.fileName(_format, _document, csvModule: _csvModule);

  bool get _actionable => _document.hasAnyData;

  // ── 动作 ────────────────────────────────────────────────────────────────

  Future<void> _copy() async {
    setState(_recompute);
    if (!_actionable) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final label = _format.label;
    var copied = false;
    try {
      await Clipboard.setData(ClipboardData(text: _content));
      copied = true;
    } on PlatformException {
      copied = false;
    }
    if (messenger == null) return;
    AppFeedback.toastOn(messenger, copied ? '已复制$label' : '复制失败');
  }

  Future<void> _save() async {
    setState(_recompute);
    if (!_actionable) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final path = await exportFileSaver(
        _fileName,
        _format.extension,
        Uint8List.fromList(utf8.encode(_content)),
      );
      if (messenger == null) return;
      // 用户取消不算保存成功，也不提示。
      if (path == null) return;
      AppFeedback.toastOn(messenger, '已保存到 $path');
    } catch (e) {
      // 只记录异常类型（不含路径 / 内容），提示给用户的是可理解的文案。
      AppLogger.instance.warn('ai export save failed: ${e.runtimeType}');
      if (messenger == null) return;
      AppFeedback.toastOn(messenger, '保存失败，请重试或改用复制');
    }
  }

  Future<void> _share() async {
    setState(_recompute);
    if (!_actionable) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final asText = _format == ExportFormat.markdown;
    final mime = switch (_format) {
      ExportFormat.markdown => 'text/markdown',
      ExportFormat.json => 'application/json',
      ExportFormat.csv => 'text/csv',
    };
    try {
      final outcome = await exportSharer(
        ExportSharePayload(
          fileName: _fileName,
          mimeType: mime,
          text: _content,
          asText: asText,
        ),
      );
      if (messenger == null) return;
      switch (outcome) {
        case ExportShareOutcome.shared:
          AppFeedback.toastOn(messenger, '已交给所选应用，其后续处理受对方平台政策约束');
        case ExportShareOutcome.unavailable:
          AppFeedback.toastOn(messenger, '已打开系统分享菜单');
        case ExportShareOutcome.dismissed:
          // 取消分享：没有任何数据交出，不提示成功。
          break;
      }
    } catch (e) {
      AppLogger.instance.warn('ai export share failed: ${e.runtimeType}');
      if (messenger == null) return;
      AppFeedback.toastOn(messenger, '无法打开系统分享，请改用复制或保存');
    }
  }

  Future<void> _login(ExportModule module) async {
    final handler = widget.loginHandler ?? defaultExportLoginHandler;
    final ok = await handler(context, module.domain);
    if (!mounted || !ok) return;
    unawaited(_controller.fetch(module));
  }

  void _selectFormat(ExportFormat format) {
    setState(() {
      _format = format;
      _recompute();
    });
  }

  // ── 构建 ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppAppBar(title: const Text('导出给 AI')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                kPlainListGutter,
                AppSpacing.sm,
                kPlainListGutter,
                AppSpacing.lg,
              ),
              children: [
                Text(
                  '仅含本机已加载或刚获取的数据，不含学号、姓名等身份信息。',
                  style: context.appText.meta,
                ),
                if (_controller.identityReset) ...[
                  const SizedBox(height: AppSpacing.sm),
                  AppBanner(
                    message: '账号已变化或已登出，已清除上一账号的数据。',
                    tone: AppBannerTone.error,
                    icon: Icons.lock_outline_rounded,
                    actionLabel: '知道了',
                    onAction: _controller.acknowledgeIdentityReset,
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                _buildPresetSelector(),
                const SizedBox(height: kPlainListGroupGap),
                const PlainSectionHeader('内容'),
                PlainListGroup(
                  children: [
                    for (final module in ExportModule.values)
                      if (_controller.selected.contains(module))
                        _buildModuleRow(module),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                _buildAdjust(),
                const SizedBox(height: kPlainListGroupGap),
                _buildFormatSelector(),
                if (_format == ExportFormat.csv) ..._buildCsvPicker(),
                const SizedBox(height: AppSpacing.md),
                _buildPreview(cs),
              ],
            ),
          ),
          _buildActions(),
        ],
      ),
    );
  }

  Widget _buildPresetSelector() {
    final preset = _controller.preset;
    return SegmentedButton<ExportPreset>(
      key: const Key('ai_export_presets'),
      showSelectedIcon: false,
      emptySelectionAllowed: true,
      segments: [
        for (final p in ExportPreset.values)
          ButtonSegment(value: p, label: Text(p.label)),
      ],
      selected: preset == null ? const {} : {preset},
      onSelectionChanged: (s) {
        // 自定义状态下点已选之外的段才会进来；空集（再点已选）忽略。
        if (s.isEmpty) return;
        _controller.selectPreset(s.first);
      },
    );
  }

  Widget _buildAdjust() {
    return PlainListGroup(
      children: [
        PlainListRow(
          key: const Key('ai_export_adjust'),
          title: '调整内容',
          value: _expanded ? null : '${_controller.selected.length} 项',
          showChevron: false,
          trailing: AnimatedRotation(
            turns: _expanded ? 0.25 : 0,
            duration: AppMotion.quick,
            child: Icon(
              Icons.chevron_right,
              size: 20,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: AppFilterChips<ExportModule>.multi(
              key: const Key('ai_export_modules'),
              wrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              options: [
                for (final m in _controller.availableModules)
                  AppFilterOption(m, m.label),
              ],
              selectedValues: _controller.selected,
              onSelected: _controller.toggleModule,
            ),
          ),
      ],
    );
  }

  Widget _buildModuleRow(ExportModule module) {
    final slot = _controller.slotOf(module);
    final kind = _controller.rowKindOf(module);
    final data = slot.data;
    final count = data?.itemCount;
    final held = count == null ? '' : '，保留 $count 条';
    final value = switch (kind) {
      ExportRowKind.loading => '获取中…',
      ExportRowKind.needsLogin => '需登录$held',
      ExportRowKind.failed => '${slot.message ?? '获取失败'}$held',
      ExportRowKind.missing => ExportModuleStatus.missing.label,
      ExportRowKind.ready => '${data!.status.label} · ${count ?? 0} 条',
    };
    final (String? label, VoidCallback? onPressed) = switch (kind) {
      ExportRowKind.loading => (null, null),
      ExportRowKind.missing => ('获取', () => _controller.fetch(module)),
      ExportRowKind.failed => ('重试', () => _controller.fetch(module)),
      ExportRowKind.needsLogin => ('去登录', () => _login(module)),
      ExportRowKind.ready =>
        data!.status == ExportModuleStatus.stale
            ? ('刷新', () => _controller.fetch(module))
            : (null, null),
    };
    return PlainListRow(
      key: Key('ai_export_row_${module.key}'),
      title: module.label,
      value: value,
      valueKey: Key('ai_export_status_${module.key}'),
      showChevron: false,
      trailing: kind == ExportRowKind.loading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : (label == null
                ? null
                : TextButton(
                    key: Key('ai_export_action_${module.key}'),
                    onPressed: onPressed,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(label),
                  )),
    );
  }

  Widget _buildFormatSelector() {
    return SegmentedButton<ExportFormat>(
      key: const Key('ai_export_format'),
      showSelectedIcon: false,
      segments: [
        for (final f in ExportFormat.values)
          ButtonSegment(value: f, label: Text(f.label)),
      ],
      selected: {_format},
      onSelectionChanged: (s) => _selectFormat(s.first),
    );
  }

  List<Widget> _buildCsvPicker() {
    final modules = _document.modules.map((m) => m.module).toList();
    return [
      const SizedBox(height: AppSpacing.sm),
      Text('CSV 每次导出一个模块，仅含数据表。', style: context.appText.meta),
      if (modules.length > 1) ...[
        const SizedBox(height: AppSpacing.sm),
        AppFilterChips<ExportModule>(
          key: const Key('ai_export_csv_module'),
          wrap: true,
          padding: EdgeInsets.zero,
          options: [for (final m in modules) AppFilterOption(m, m.label)],
          selected: _csvModule ?? modules.first,
          onSelected: (m) => setState(() {
            _csvModule = m;
            _recompute();
          }),
        ),
      ],
    ];
  }

  Widget _buildPreview(ColorScheme cs) {
    return Container(
      height: 220,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: AppRadius.cardBorder,
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: SingleChildScrollView(
        child: SelectableText(
          _content,
          key: const Key('ai_export_preview'),
          style: context.appText.meta.copyWith(
            fontFamily: 'monospace',
            color: cs.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _buildActions() {
    final enabled = _actionable;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageMargin,
          AppSpacing.sm,
          AppSpacing.pageMargin,
          AppSpacing.md,
        ),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: enabled ? _copy : null,
                icon: const Icon(Icons.content_copy_rounded, size: 18),
                label: const Text('复制'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: enabled ? _save : null,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('保存'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: FilledButton.icon(
                onPressed: enabled ? _share : null,
                icon: const Icon(Icons.ios_share_rounded, size: 18),
                label: const Text('分享'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
