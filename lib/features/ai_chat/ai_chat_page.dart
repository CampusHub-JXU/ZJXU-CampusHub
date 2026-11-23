import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/ai/llm_client.dart';
import '../../core/ai/llm_config_controller.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/ai_chat/ai_chat_context.dart';
import '../../shared/ai_chat/ai_chat_controller.dart';
import '../../shared/ai_chat/ai_chat_widgets.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_banner.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/app_surface_style.dart';

/// 全局 AI 助手页：流式多轮对话、可折叠学业上下文芯片栏与导出兜底入口。
///
/// 学业上下文经 [AiChatContextProvider] 抽象注入（组合层在 `lib/app`
/// 装配 `ai_export` 桥接），本页不依赖任何其它 feature。
class AiChatPage extends StatefulWidget {
  const AiChatPage({
    super.key,
    this.contextProvider,
    this.configController,
    this.llmClient,
    this.onOpenSettings,
    this.onOpenExport,
  });

  /// 学业上下文提供者；为 `null` 时隐藏上下文芯片栏。
  /// 传入时由本页持有并释放。
  final AiChatContextProvider? contextProvider;
  final LlmConfigController? configController;
  final LlmClient? llmClient;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onOpenExport;

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage> {
  static const List<String> _quickPrompts = [
    '总结本学期成绩与绩点',
    '查看本周剩余课程',
    '梳理近期待办与考试',
  ];

  AiChatContextProvider? get _contextProvider => widget.contextProvider;

  late final AiChatController _chatController;
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  bool _contextExpanded = false;
  int _lastObservedMessageCount = 0;

  @override
  void initState() {
    super.initState();
    _chatController = AiChatController(
      configController: widget.configController,
      llmClient: widget.llmClient,
      contextProvider: widget.contextProvider,
    );
    _chatController.addListener(_onControllerChanged);
    widget.contextProvider?.addListener(_onContextChanged);
    unawaited(_chatController.initialize());
  }

  @override
  void dispose() {
    widget.contextProvider?.removeListener(_onContextChanged);
    _chatController.removeListener(_onControllerChanged);
    _chatController.dispose();
    // 页面持有注入的上下文提供者（与原先持有导出控制器一致）。
    widget.contextProvider?.dispose();
    _inputController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final count = _chatController.messages.length;
    final appended = count > _lastObservedMessageCount;
    _lastObservedMessageCount = count;
    setState(() {});
    if (appended || _chatController.isGenerating) {
      _scrollToBottomIfNearEnd(force: appended);
    }
  }

  void _onContextChanged() {
    if (mounted) setState(() {});
  }

  void _scrollToBottomIfNearEnd({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      final distanceFromBottom = position.maxScrollExtent - position.pixels;
      if (!force && distanceFromBottom > 120) return;
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
    if (text.trim().isEmpty || _chatController.isGenerating) return;
    if (overrideText == null) {
      _inputController.clear();
    }
    await _chatController.sendMessage(text);
  }

  Future<void> _confirmClear() async {
    if (_chatController.messages.isEmpty && !_chatController.isGenerating) {
      return;
    }
    if (_chatController.messages.isEmpty) {
      _chatController.clear();
      return;
    }
    final confirmed = await AppFeedback.confirm(
      context,
      title: '清空当前对话？',
      message: '将清除所有对话记录，已加载的学业上下文不受影响。',
      confirmLabel: '清空',
      destructive: true,
    );
    if (!mounted || !confirmed) return;
    _chatController.clear();
  }

  /// 芯片右侧动作：「需登录」走登录桥接，其余补获取（未勾选先勾选）。
  Future<void> _onContextModuleAction(AiChatContextModule module) async {
    final provider = _contextProvider;
    if (provider == null) return;
    if (module.error == kAiChatContextNeedsLogin) {
      await provider.requestLogin(context, module.id);
      return;
    }
    if (!module.selected) {
      provider.toggleModule(module.id, true);
    }
    unawaited(provider.ensureSelectedReady());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final provider = _contextProvider;
    final messages = _chatController.messages;
    final canClear = messages.isNotEmpty || _chatController.isGenerating;

    return Scaffold(
      appBar: AppAppBar(
        centerTitle: true,
        title: _buildAppBarTitle(context),
        actions: [
          IconButton(
            key: const Key('ai_chat_export_button'),
            tooltip: '导出文本',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: widget.onOpenExport,
          ),
          IconButton(
            key: const Key('ai_chat_clear_button'),
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: canClear ? _confirmClear : null,
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_chatController.isConfigured)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.pageMargin,
                AppSpacing.sm,
                AppSpacing.pageMargin,
                0,
              ),
              child: AiChatUnconfiguredBanner(
                key: const Key('ai_chat_unconfigured_banner'),
                onOpenSettings: widget.onOpenSettings,
                onOpenExport: widget.onOpenExport,
              ),
            ),
          if (provider?.identityReset ?? false)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.pageMargin,
                AppSpacing.sm,
                AppSpacing.pageMargin,
                0,
              ),
              child: AppBanner(
                message: '账号已变化或已登出，已清除上一账号的数据。',
                tone: AppBannerTone.error,
                icon: Icons.lock_outline_rounded,
                actionLabel: '知道了',
                onAction: provider!.acknowledgeIdentityReset,
              ),
            ),
          Expanded(
            child: messages.isEmpty
                ? _buildEmptyState(context)
                : SelectionArea(
                    child: ListView.separated(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.pageMargin,
                        AppSpacing.md,
                        AppSpacing.pageMargin,
                        AppSpacing.lg,
                      ),
                      itemCount: messages.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: AppSpacing.md),
                      itemBuilder: (context, index) {
                        final msg = messages[index];
                        final isLast = index == messages.length - 1;
                        return AiChatMessageBubble(
                          key: Key('ai_chat_msg_${msg.id}'),
                          message: msg,
                          onRetry: isLast && msg.hasError
                              ? () => unawaited(_chatController.retryLast())
                              : null,
                        );
                      },
                    ),
                  ),
          ),
          _buildDockPanel(cs),
        ],
      ),
    );
  }

  Widget _buildAppBarTitle(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final profile = _chatController.activeProfile;
    final configured = _chatController.isConfigured;
    final modelLabel = (profile != null && profile.model.trim().isNotEmpty)
        ? profile.model.trim()
        : '未配置模型';

    return AppTextScaleGuard.chrome(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'AI 助手',
            style: AppChromeType.topBar.copyWith(color: cs.onSurface),
          ),
          const SizedBox(height: 2),
          Material(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppRadius.tag),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const Key('ai_chat_model_chip'),
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
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 160),
                      child: Text(
                        modelLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.tag.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ),
                    if (widget.onOpenSettings != null) ...[
                      const SizedBox(width: 2),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 13,
                        color: cs.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final provider = _contextProvider;
    final readyCount = provider?.readyCount ?? 0;
    final selectedCount = provider?.selectedCount ?? 0;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.listGutter,
          vertical: AppSpacing.lg,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.auto_awesome_outlined,
                  color: cs.primary,
                  size: 22,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text('AI 学业助手', textAlign: TextAlign.center, style: text.section),
              const SizedBox(height: AppSpacing.xs),
              Text(
                selectedCount == 0
                    ? '未勾选学业上下文，可展开下方栏按需附加'
                    : '已勾选 $selectedCount 项上下文（$readyCount 项本机就绪）',
                textAlign: TextAlign.center,
                style: text.meta,
              ),
              const SizedBox(height: AppSpacing.lg),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < _quickPrompts.length; i++) ...[
                    if (i > 0) const SizedBox(height: AppSpacing.sm),
                    _QuickPromptChip(
                      key: Key('ai_chat_quick_prompt_$i'),
                      label: _quickPrompts[i],
                      onTap: () => unawaited(_send(_quickPrompts[i])),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDockPanel(ColorScheme cs) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dockColor = isDark
        ? cs.surfaceContainerLow
        : cs.surfaceContainerLowest;
    return DecoratedBox(
      decoration: BoxDecoration(color: dockColor),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildAcademicContextBar(cs),
            AiChatComposer(
              controller: _inputController,
              focusNode: _inputFocusNode,
              isGenerating: _chatController.isGenerating,
              onSend: () => unawaited(_send()),
              onStop: _chatController.stopGeneration,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAcademicContextBar(ColorScheme cs) {
    final provider = _contextProvider;
    if (provider == null) return const SizedBox.shrink();
    final modules = provider.modules;
    if (modules.isEmpty) return const SizedBox.shrink();

    final text = context.appText;
    final reduced = AppMotion.reduced(context);
    final selectedCount = provider.selectedCount;
    final readyCount = provider.readyCount;
    final anyLoading = modules.any((m) => m.isLoading);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: const Key('ai_chat_context_toggle'),
          onTap: () => setState(() => _contextExpanded = !_contextExpanded),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.pageMargin,
              AppSpacing.sm,
              AppSpacing.pageMargin,
              AppSpacing.xs,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.layers_outlined,
                  size: 16,
                  color: readyCount > 0 ? cs.primary : cs.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.xs + 2),
                Text('学业上下文', style: text.group),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    selectedCount == 0
                        ? '未勾选'
                        : '已选 $selectedCount · $readyCount 就绪',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.meta,
                  ),
                ),
                if (anyLoading) ...[
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: cs.primary,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                ],
                Text(
                  _contextExpanded ? '收起' : '展开',
                  style: text.meta.copyWith(color: cs.primary),
                ),
                AnimatedRotation(
                  turns: _contextExpanded ? 0.5 : 0,
                  duration: reduced ? Duration.zero : AppMotion.quick,
                  curve: AppMotion.standard,
                  child: Icon(
                    Icons.expand_more_rounded,
                    size: 18,
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
          child: _contextExpanded
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.pageMargin,
                    AppSpacing.xs,
                    AppSpacing.pageMargin,
                    AppSpacing.xs,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 140),
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.sm,
                        children: [
                          for (final module in modules)
                            _ContextModuleChip(
                              key: Key('ai_chat_context_chip_${module.id}'),
                              module: module,
                              onToggle: () => provider.toggleModule(
                                module.id,
                                !module.selected,
                              ),
                              onAction: () =>
                                  unawaited(_onContextModuleAction(module)),
                            ),
                        ],
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _QuickPromptChip extends StatelessWidget {
  const _QuickPromptChip({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final text = context.appText;

    return Material(
      color: isDark ? cs.surfaceContainerLow : cs.surfaceContainerLowest,
      shape: RoundedSuperellipseBorder(
        borderRadius: AppRadius.chipBorder,
        side: BorderSide(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : appHardTileBorderColor(cs),
          width: 0.8,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md + 2,
            vertical: AppSpacing.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: text.body.copyWith(color: cs.onSurface),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Icon(
                Icons.arrow_forward_rounded,
                size: 16,
                color: cs.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContextModuleChip extends StatelessWidget {
  const _ContextModuleChip({
    super.key,
    required this.module,
    required this.onToggle,
    required this.onAction,
  });

  final AiChatContextModule module;
  final VoidCallback onToggle;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;

    final String statusLabel;
    final VoidCallback? action;
    if (module.isLoading) {
      statusLabel = '获取中';
      action = null;
    } else if (module.error == kAiChatContextNeedsLogin) {
      statusLabel = '需登录';
      action = onAction;
    } else if (module.isReady) {
      if (module.error == kAiChatContextStale) {
        statusLabel = '已过期·刷新';
        action = onAction;
      } else {
        statusLabel = '已就绪';
        action = null;
      }
    } else if (module.error != null) {
      statusLabel = '失败·重试';
      action = onAction;
    } else {
      statusLabel = '未获取·获取';
      action = onAction;
    }

    final selected = module.selected;
    final bgColor = selected
        ? cs.secondaryContainer
        : cs.surfaceContainerHighest;
    final fgColor = selected ? cs.onSecondaryContainer : cs.onSurfaceVariant;

    return Material(
      color: bgColor,
      shape: RoundedSuperellipseBorder(borderRadius: AppRadius.chipBorder),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.sm + 2,
                AppSpacing.xs + 2,
                AppSpacing.sm,
                AppSpacing.xs + 2,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 15,
                    color: selected ? cs.primary : cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.xs + 1),
                  Text(
                    module.label,
                    style: text.meta.copyWith(
                      color: selected ? cs.onSecondaryContainer : cs.onSurface,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
          InkWell(
            key: Key('ai_chat_context_action_${module.id}'),
            onTap: action,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xs,
                AppSpacing.xs + 2,
                AppSpacing.sm + 2,
                AppSpacing.xs + 2,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (module.isLoading) ...[
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: fgColor,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                  ],
                  Text(
                    statusLabel,
                    style: text.tag.copyWith(
                      color: action != null ? cs.primary : fgColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
