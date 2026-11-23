import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/ai/llm_client.dart';
import '../../core/ai/llm_config_controller.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../widgets/app_feedback.dart';
import 'ai_chat_controller.dart';
import 'ai_chat_widgets.dart';

/// 可复用的底部 AI 对话面板：0.85 屏高可拖拽圆角面板，自适应键盘高度，
/// 支持隐藏/可预览 `initialContext` 与空态一键提问 `initialPrompt`。
class AiChatSheet extends StatefulWidget {
  const AiChatSheet({
    super.key,
    this.title,
    this.initialContext,
    this.initialPrompt,
    this.onOpenSettings,
    this.configController,
    this.llmClient,
  });

  final String? title;
  final String? initialContext;
  final String? initialPrompt;
  final VoidCallback? onOpenSettings;
  final LlmConfigController? configController;
  final LlmClient? llmClient;

  /// 弹出 0.85 屏高可拖拽/自适应键盘的圆角 AI 对话面板。
  static Future<void> show(
    BuildContext context, {
    String? title,
    String? initialContext,
    String? initialPrompt,
    VoidCallback? onOpenSettings,
    LlmConfigController? configController,
    LlmClient? llmClient,
  }) {
    return AppFeedback.sheet<void>(
      context,
      scrollControlled: true,
      dragHandle: true,
      useSafeArea: true,
      builder: (_) => AiChatSheet(
        title: title,
        initialContext: initialContext,
        initialPrompt: initialPrompt,
        onOpenSettings: onOpenSettings,
        configController: configController,
        llmClient: llmClient,
      ),
    );
  }

  @override
  State<AiChatSheet> createState() => _AiChatSheetState();
}

class _AiChatSheetState extends State<AiChatSheet> {
  late final AiChatController _controller;
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  bool _contextPreviewExpanded = false;
  int _lastMessageCount = 0;

  bool get _hasContext =>
      widget.initialContext != null && widget.initialContext!.trim().isNotEmpty;

  bool get _hasInitialPrompt =>
      widget.initialPrompt != null && widget.initialPrompt!.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller = AiChatController(
      configController: widget.configController,
      llmClient: widget.llmClient,
      fixedContext: widget.initialContext,
    );
    _controller.addListener(_onControllerChanged);
    unawaited(_controller.initialize());
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _inputController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final count = _controller.messages.length;
    final appended = count > _lastMessageCount;
    _lastMessageCount = count;
    setState(() {});
    if (appended || _controller.isGenerating) {
      _scrollToBottomIfNearEnd(force: appended);
    }
  }

  void _scrollToBottomIfNearEnd({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (!force && (position.maxScrollExtent - position.pixels) > 120) {
        return;
      }
      final reduced = AppMotion.reduced(context);
      if (reduced) {
        _scrollController.jumpTo(position.maxScrollExtent);
      } else {
        unawaited(
          _scrollController.animateTo(
            position.maxScrollExtent,
            duration: AppMotion.quick,
            curve: AppMotion.standard,
          ),
        );
      }
    });
  }

  Future<void> _send([String? overrideText]) async {
    final text = overrideText ?? _inputController.text;
    if (text.trim().isEmpty || _controller.isGenerating) return;
    if (overrideText == null) {
      _inputController.clear();
    }
    await _controller.sendMessage(text);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final cs = Theme.of(context).colorScheme;
    final targetHeight = media.size.height * 0.85;
    final availableHeight = math.max(
      200.0,
      media.size.height - media.viewInsets.bottom - media.padding.top - 40.0,
    );
    final sheetHeight = math.min(targetHeight, availableHeight);

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SizedBox(
        height: sheetHeight,
        child: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(cs),
              if (!_controller.isConfigured)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.pageMargin,
                    AppSpacing.xs,
                    AppSpacing.pageMargin,
                    AppSpacing.xs,
                  ),
                  child: AiChatUnconfiguredBanner(
                    key: const Key('ai_chat_sheet_unconfigured_banner'),
                    onOpenSettings: widget.onOpenSettings,
                  ),
                ),
              if (_hasContext) _buildContextPreview(cs),
              Expanded(
                child: _controller.messages.isEmpty
                    ? _buildEmptyState(cs)
                    : SelectionArea(
                        child: ListView.separated(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.pageMargin,
                            AppSpacing.sm,
                            AppSpacing.pageMargin,
                            AppSpacing.md,
                          ),
                          itemCount: _controller.messages.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: AppSpacing.md),
                          itemBuilder: (context, index) {
                            final msg = _controller.messages[index];
                            final isLast =
                                index == _controller.messages.length - 1;
                            return AiChatMessageBubble(
                              key: Key('ai_chat_sheet_msg_${msg.id}'),
                              message: msg,
                              onRetry: isLast && msg.hasError
                                  ? () => unawaited(_controller.retryLast())
                                  : null,
                            );
                          },
                        ),
                      ),
              ),
              AiChatComposer(
                controller: _inputController,
                focusNode: _inputFocusNode,
                isGenerating: _controller.isGenerating,
                onSend: () => unawaited(_send()),
                onStop: _controller.stopGeneration,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme cs) {
    final text = context.appText;
    final profile = _controller.activeProfile;
    final configured = _controller.isConfigured;
    final modelLabel = (profile != null && profile.model.trim().isNotEmpty)
        ? profile.model.trim()
        : '未配置模型';
    final canClear =
        _controller.messages.isNotEmpty || _controller.isGenerating;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        0,
        AppSpacing.xs,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.title?.trim().isNotEmpty == true
                      ? widget.title!.trim()
                      : 'AI 助手',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.section,
                ),
                const SizedBox(height: 2),
                Material(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppRadius.tag),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: widget.onOpenSettings,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: 2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: configured ? cs.primary : cs.error,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.xs + 1),
                          Flexible(
                            child: Text(
                              modelLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.tag.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('ai_chat_sheet_clear_button'),
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: canClear ? _controller.clear : null,
          ),
          IconButton(
            key: const Key('ai_chat_sheet_close_button'),
            tooltip: '关闭',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildContextPreview(ColorScheme cs) {
    final text = context.appText;
    final reduced = AppMotion.reduced(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.xs,
        AppSpacing.pageMargin,
        AppSpacing.xs,
      ),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: cs.surfaceContainerHighest,
          shape: RoundedSuperellipseBorder(borderRadius: AppRadius.chipBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              key: const Key('ai_chat_sheet_context_toggle'),
              customBorder: RoundedSuperellipseBorder(
                borderRadius: AppRadius.chipBorder,
              ),
              onTap: () => setState(
                () => _contextPreviewExpanded = !_contextPreviewExpanded,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    Icon(Icons.article_outlined, size: 15, color: cs.primary),
                    const SizedBox(width: AppSpacing.xs + 2),
                    Expanded(
                      child: Text(
                        '已附带上下文',
                        style: text.meta.copyWith(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Text(
                      _contextPreviewExpanded ? '收起' : '预览',
                      style: text.tag.copyWith(color: cs.primary),
                    ),
                    const SizedBox(width: 2),
                    AnimatedRotation(
                      turns: _contextPreviewExpanded ? 0.5 : 0,
                      duration: reduced ? Duration.zero : AppMotion.quick,
                      curve: AppMotion.standard,
                      child: Icon(
                        Icons.expand_more_rounded,
                        size: 16,
                        color: cs.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: reduced ? Duration.zero : AppMotion.quick,
              curve: AppMotion.standard,
              alignment: Alignment.topCenter,
              child: _contextPreviewExpanded
                  ? ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 140),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.md,
                          0,
                          AppSpacing.md,
                          AppSpacing.sm + 2,
                        ),
                        child: Text(
                          widget.initialContext!.trim(),
                          style: text.meta.copyWith(
                            color: cs.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme cs) {
    final text = context.appText;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.listGutter,
          vertical: AppSpacing.lg,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.auto_awesome_outlined,
                  size: 20,
                  color: cs.primary,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                _hasContext ? '已准备好结合当前上下文为你解答' : '输入你的问题开始对话',
                textAlign: TextAlign.center,
                style: text.meta,
              ),
              if (_hasInitialPrompt) ...[
                const SizedBox(height: AppSpacing.md),
                FilledButton.tonalIcon(
                  key: const Key('ai_chat_sheet_initial_prompt'),
                  onPressed: () =>
                      unawaited(_send(widget.initialPrompt!.trim())),
                  icon: const Icon(Icons.auto_awesome_rounded, size: 17),
                  label: Text(widget.initialPrompt!.trim()),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
