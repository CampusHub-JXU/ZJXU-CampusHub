import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:go_router/go_router.dart';

import '../../core/logging/app_logger.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_banner.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/plain_list.dart';
import 'export_builder.dart';
import 'export_controller.dart';
import 'export_document.dart';
import 'export_model.dart';
import 'export_output.dart';

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

/// 「导出给 AI」页：按用途预设勾选内容，缺的模块按需获取，复制 / 保存 / 分享。
///
/// 「内容」是可勾选清单：所有可用模块平铺，勾选 = 进入导出文档，取消勾选
/// 即从导出剔除；预览实时渲染最终 Markdown（勾选变化立即联动）。
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
    _content = ExportBuilder.markdown(_document);
  }

  String get _fileName => ExportBuilder.fileName(_document);

  bool get _actionable => _document.hasAnyData;

  // ── 动作 ────────────────────────────────────────────────────────────────

  Future<void> _copy() async {
    setState(_recompute);
    if (!_actionable) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    var copied = false;
    try {
      await Clipboard.setData(ClipboardData(text: _content));
      copied = true;
    } on PlatformException {
      copied = false;
    }
    if (messenger == null) return;
    AppFeedback.toastOn(messenger, copied ? '已复制Markdown' : '复制失败');
  }

  Future<void> _save() async {
    setState(_recompute);
    if (!_actionable) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final path = await exportFileSaver(
        _fileName,
        kExportExtension,
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
    try {
      final outcome = await exportSharer(
        ExportSharePayload(
          fileName: _fileName,
          mimeType: kExportMimeType,
          text: _content,
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
                  '勾选的内容会写进同一份 Markdown，仅含本机已加载或刚获取的数据，'
                  '不含学号、姓名等身份信息。',
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
                    for (final module in _controller.availableModules)
                      _buildModuleRow(module),
                  ],
                ),
                const SizedBox(height: kPlainListGroupGap),
                const PlainSectionHeader('预览'),
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

  Widget _buildModuleRow(ExportModule module) {
    final cs = Theme.of(context).colorScheme;
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
      ExportRowKind.ready =>
        '${data!.status.label} · ${count ?? 0} 条'
            '${data.isPartial ? ' · 可能不全' : ''}',
    };
    final (String? label, VoidCallback? onPressed) = switch (kind) {
      ExportRowKind.loading => (null, null),
      ExportRowKind.missing => ('获取', () => _controller.fetch(module)),
      ExportRowKind.failed => ('重试', () => _controller.fetch(module)),
      ExportRowKind.needsLogin => ('去登录', () => _login(module)),
      ExportRowKind.ready =>
        data!.status == ExportModuleStatus.stale
            ? ('刷新', () => _controller.fetch(module))
            : data.isPartial
            ? ('重新获取', () => _controller.fetch(module))
            : (null, null),
    };
    final checked = _controller.selected.contains(module);
    // 已勾选项只剩最后一个时不能再取消：导出至少留一项（见
    // AiExportController.toggleModule 的契约注释）。
    final toggleable = checked ? _controller.selected.length > 1 : true;
    return PlainListRow(
      key: Key('ai_export_row_${module.key}'),
      title: module.label,
      value: value,
      valueKey: Key('ai_export_status_${module.key}'),
      showChevron: false,
      titleColor: checked ? null : cs.onSurfaceVariant,
      leading: Checkbox(
        key: Key('ai_export_check_${module.key}'),
        value: checked,
        onChanged: toggleable ? (_) => _controller.toggleModule(module) : null,
        visualDensity: VisualDensity.compact,
      ),
      onTap: toggleable ? () => _controller.toggleModule(module) : null,
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

  // ── 预览 ────────────────────────────────────────────────────────────────

  /// 预览卡片：真·Markdown 渲染（`flutter_markdown_plus`，表格 / 标题 /
  /// 列表真渲染），整块可选中复制；右上角全屏按钮打开只读放大页。
  Widget _buildPreview(ColorScheme cs) {
    return Container(
      key: const Key('ai_export_preview'),
      height: 264,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: AppRadius.cardBorder,
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: _ExportMarkdown(
              data: _content,
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.xxl,
                AppSpacing.md,
              ),
            ),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: IconButton(
              key: const Key('ai_export_preview_expand'),
              icon: const Icon(Icons.open_in_full_rounded, size: 18),
              tooltip: '放大预览',
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                foregroundColor: cs.onSurfaceVariant,
                minimumSize: const Size(34, 34),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => unawaited(
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) =>
                        _ExportMarkdownFullscreenPage(content: _content),
                  ),
                ),
              ),
            ),
          ),
        ],
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

/// 「导出给 AI」预览的 Markdown 渲染体：样式接 AppTypography / 主题色。
/// 用 `MarkdownBody`（一次构建全部块）而非 `Markdown`（懒加载 ListView），
/// 保证全文都在树里、可被整体选中复制；滚动由外层提供。
class _ExportMarkdown extends StatelessWidget {
  const _ExportMarkdown({required this.data, this.padding});

  final String data;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    return SingleChildScrollView(
      padding: padding ?? const EdgeInsets.all(AppSpacing.md),
      child: MarkdownBody(
        data: data,
        selectable: true,
        styleSheet: _exportMarkdownStyleSheet(cs, text),
      ),
    );
  }
}

/// 全屏只读预览：与卡片内同一份 Markdown、同一套样式。
class _ExportMarkdownFullscreenPage extends StatelessWidget {
  const _ExportMarkdownFullscreenPage({required this.content});

  final String content;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('ai_export_preview_fullscreen'),
      appBar: AppAppBar(title: const Text('预览')),
      body: SafeArea(
        top: false,
        child: _ExportMarkdown(
          data: content,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pageMargin,
            AppSpacing.sm,
            AppSpacing.pageMargin,
            AppSpacing.md,
          ),
        ),
      ),
    );
  }
}

MarkdownStyleSheet _exportMarkdownStyleSheet(
  ColorScheme cs,
  AppTypography text,
) {
  return MarkdownStyleSheet(
    p: text.body,
    a: text.body.copyWith(color: cs.primary),
    h1: text.section,
    h2: text.rowTitleStrong,
    h3: text.group.copyWith(color: cs.onSurface),
    h4: text.rowTitleStrong,
    h5: text.body.copyWith(fontWeight: FontWeight.w600),
    h6: text.body,
    listBullet: text.body,
    blockquote: text.body.copyWith(color: cs.onSurfaceVariant),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: cs.outlineVariant, width: 3)),
    ),
    code: text.body.copyWith(
      fontFamily: 'monospace',
      color: cs.onSurface,
      backgroundColor: cs.surfaceContainerLowest,
    ),
    codeblockDecoration: BoxDecoration(
      color: cs.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(AppRadius.control),
    ),
    tableHead: text.meta.copyWith(
      fontWeight: FontWeight.w600,
      color: cs.onSurface,
    ),
    tableBody: text.meta.copyWith(color: cs.onSurface),
    tableBorder: TableBorder.all(color: cs.outlineVariant, width: 0.5),
    tableColumnWidth: const IntrinsicColumnWidth(),
    tableCellsPadding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.sm,
      vertical: AppSpacing.xs,
    ),
  );
}
