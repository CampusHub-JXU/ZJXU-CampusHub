import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/logging/app_logger.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_surface_tokens.dart';
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
    AppFeedback.toastOn(messenger, copied ? '已复制纯文本' : '复制失败');
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
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(
                        Icons.privacy_tip_outlined,
                        size: 15,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        '勾选的内容会写进同一份纯文本，仅含本机已加载或刚获取的数据，'
                        '不含学号、姓名等身份信息。',
                        style: context.appText.meta,
                      ),
                    ),
                  ],
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
    return AppTextScaleGuard.chrome(
      child: SegmentedButton<ExportPreset>(
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
      ),
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
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ModuleStatusDot(
            color: _statusColorFor(context, kind, slot),
            muted: !checked,
          ),
          if (kind == ExportRowKind.loading) ...[
            const SizedBox(width: AppSpacing.sm),
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ] else if (label != null) ...[
            const SizedBox(width: AppSpacing.sm),
            TextButton(
              key: Key('ai_export_action_${module.key}'),
              onPressed: onPressed,
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: Text(label),
            ),
          ],
        ],
      ),
    );
  }

  /// 行尾状态色点的取色：就绪绿、需登录 / 过期 / 部分黄、失败红、
  /// 未获取灰、获取中 brand——与右值文案同一语义，但先于文字给出判断。
  Color _statusColorFor(
    BuildContext context,
    ExportRowKind kind,
    ExportSlot slot,
  ) {
    final sf = context.appSurfaces;
    final cs = Theme.of(context).colorScheme;
    return switch (kind) {
      ExportRowKind.loading => cs.primary,
      ExportRowKind.needsLogin => sf.warning,
      ExportRowKind.failed => sf.danger,
      ExportRowKind.missing => sf.neutral,
      ExportRowKind.ready =>
        slot.data!.status == ExportModuleStatus.stale || slot.data!.isPartial
            ? sf.warning
            : sf.success,
    };
  }

  // ── 预览 ────────────────────────────────────────────────────────────────

  /// 预览做成「一份成品文件」的样子：标题行给真实文件名与放大入口，
  /// 下方白卡承载按层级着色的纯文本。文件名 Text 必须留在
  /// `ai_export_preview` 容器之外——测试按树序收集容器内的文本节点，
  /// 正文必须始终是第一个。
  Widget _buildPreview(ColorScheme cs) {
    final sf = context.appSurfaces;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: AppSpacing.xl,
              height: AppSpacing.xl,
              decoration: BoxDecoration(
                color: sf.brandTint,
                borderRadius: BorderRadius.circular(AppRadius.badgeSmall),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.description_outlined,
                size: 15,
                color: cs.primary,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                _fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.appText.tag.copyWith(
                  color: sf.ink2,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            IconButton(
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
                        _ExportPlainTextFullscreenPage(content: _content),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Container(
          key: const Key('ai_export_preview'),
          height: 280,
          decoration: BoxDecoration(
            color: sf.card,
            borderRadius: AppRadius.cardBorder,
            border: Border.all(color: cs.outlineVariant, width: 0.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: _ExportPlainText(
            data: _content,
            padding: const EdgeInsets.all(AppSpacing.md),
          ),
        ),
      ],
    );
  }

  Widget _buildActions() {
    final enabled = _actionable;
    final sf = context.appSurfaces;
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: sf.card,
        border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
      ),
      child: SafeArea(
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
                child: FilledButton.icon(
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
                child: OutlinedButton.icon(
                  onPressed: enabled ? _share : null,
                  icon: const Icon(Icons.ios_share_rounded, size: 18),
                  label: const Text('分享'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 模块行右侧的 8dp 状态色点（见 `_AiExportPageState._statusColorFor`）。
/// [muted] 在模块未勾选时把色点压淡，与置灰的标题同一层级。
class _ModuleStatusDot extends StatelessWidget {
  const _ModuleStatusDot({required this.color, required this.muted});

  final Color color;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: AppSpacing.sm,
      height: AppSpacing.sm,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: muted ? color.withValues(alpha: 0.35) : color,
      ),
    );
  }
}

/// 「导出给 AI」预览的纯文本渲染体：不做 Markdown AST 解析，避免大文本
/// 渲染卡顿；逐行转成 TextSpan——`[节标]` 取品牌色、首行文档名略大、
/// `键: 值` 的键加粗——让长文档在视觉上有层级。整块可选中复制，
/// 滚动由外层提供。
class _ExportPlainText extends StatelessWidget {
  const _ExportPlainText({required this.data, this.padding});

  final String data;
  final EdgeInsets? padding;

  /// `键:` 前缀的判定：行首、不含空格 / 竖线、最多 14 个字符。
  /// 表格数据行（含 `|`）天然不满足，不会被误加粗。
  static final RegExp _keyValueSep = RegExp(r'^[^\s|:]{1,14}: ');

  @override
  Widget build(BuildContext context) {
    final text = context.appText;
    final cs = Theme.of(context).colorScheme;
    final sf = context.appSurfaces;
    final base = text.meta.copyWith(color: sf.ink1, height: 1.55);
    return SingleChildScrollView(
      padding: padding ?? const EdgeInsets.all(AppSpacing.md),
      child: SelectableText.rich(
        TextSpan(children: _buildSpans(base, cs, sf, text)),
      ),
    );
  }

  List<TextSpan> _buildSpans(
    TextStyle base,
    ColorScheme cs,
    AppSurfaces sf,
    AppTypography text,
  ) {
    final lines = data.split('\n');
    final spans = <TextSpan>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final tail = i == lines.length - 1 ? '' : '\n';
      if (line.isEmpty) {
        spans.add(TextSpan(text: tail, style: base));
        continue;
      }
      if (line.startsWith('[') && line.endsWith(']')) {
        final docTitle = line == '[学业数据导出]';
        spans.add(
          TextSpan(
            text: '$line$tail',
            style: (docTitle ? text.rowTitleStrong : text.group).copyWith(
              color: cs.primary,
              height: 1.6,
            ),
          ),
        );
        continue;
      }
      final key = _keyValueSep.firstMatch(line);
      if (key != null) {
        spans.add(
          TextSpan(
            children: [
              TextSpan(
                text: key.group(0),
                style: base.copyWith(
                  fontWeight: FontWeight.w600,
                  color: sf.ink2,
                ),
              ),
              TextSpan(text: '${line.substring(key.end)}$tail', style: base),
            ],
          ),
        );
        continue;
      }
      spans.add(TextSpan(text: '$line$tail', style: base));
    }
    return spans;
  }
}

/// 全屏只读预览：与卡片内同一份纯文本。
class _ExportPlainTextFullscreenPage extends StatelessWidget {
  const _ExportPlainTextFullscreenPage({required this.content});

  final String content;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('ai_export_preview_fullscreen'),
      appBar: AppAppBar(title: const Text('预览')),
      body: SafeArea(
        top: false,
        child: _ExportPlainText(
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
