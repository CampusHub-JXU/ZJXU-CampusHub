import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_surface_style.dart';
import 'ai_chat_controller.dart';

/// 复制对话文本到剪贴板并给出轻提示；缺少 ScaffoldMessenger 时静默降级。
Future<void> copyChatTextWithFeedback(
  BuildContext context,
  String text, {
  String doneLabel = '已复制回复',
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  var copied = false;
  try {
    await Clipboard.setData(ClipboardData(text: text));
    copied = true;
  } on PlatformException {
    copied = false;
  }
  if (messenger == null) return;
  AppFeedback.toastOn(messenger, copied ? doneLabel : '复制失败');
}

/// 单条聊天消息气泡：区分用户与助手风格，支持长按/按钮复制、可折叠思考过程与轻量 Markdown。
class AiChatMessageBubble extends StatelessWidget {
  const AiChatMessageBubble({super.key, required this.message, this.onRetry});

  final AiChatMessage message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return switch (message.role) {
      AiChatRole.user => _UserBubble(message: message),
      AiChatRole.assistant => _AssistantBubble(
        message: message,
        onRetry: onRetry,
      ),
    };
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.message});

  final AiChatMessage message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final maxWidth = (MediaQuery.sizeOf(context).width * 0.78).clamp(
      200.0,
      540.0,
    );

    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: GestureDetector(
          onLongPress: () => copyChatTextWithFeedback(
            context,
            message.content,
            doneLabel: '已复制提问',
          ),
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: cs.primary,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(AppRadius.card),
                  topRight: Radius.circular(AppRadius.card),
                  bottomLeft: Radius.circular(AppRadius.card),
                  bottomRight: Radius.circular(AppRadius.tag),
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md + 2,
                vertical: AppSpacing.sm + 2,
              ),
              child: Text(
                message.content,
                style: text.body.copyWith(color: cs.onPrimary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({required this.message, this.onRetry});

  final AiChatMessage message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final text = context.appText;
    final canCopy = !message.isStreaming && message.content.trim().isNotEmpty;
    final cardColor = isDark
        ? cs.surfaceContainerLow
        : cs.surfaceContainerLowest;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : appHardTileBorderColor(cs);

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: GestureDetector(
          onLongPress: canCopy
              ? () => copyChatTextWithFeedback(context, message.content)
              : null,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: cardColor,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(AppRadius.tag),
                  topRight: Radius.circular(AppRadius.card),
                  bottomLeft: Radius.circular(AppRadius.card),
                  bottomRight: Radius.circular(AppRadius.card),
                ),
                side: BorderSide(color: borderColor, width: isDark ? 0.5 : 0.8),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.hasReasoning) ...[
                    AiReasoningBlock(
                      key: Key('ai_chat_reasoning_${message.id}'),
                      reasoningContent: message.reasoningContent!,
                      isStreamingReasoning:
                          message.isStreaming && message.content.isEmpty,
                    ),
                    if (message.content.isNotEmpty || message.hasError)
                      const SizedBox(height: AppSpacing.sm),
                  ],
                  if (message.isStreaming &&
                      message.content.isEmpty &&
                      !message.hasReasoning)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.8,
                            color: cs.primary,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text('正在思考…', style: text.meta),
                      ],
                    ),
                  if (message.content.isNotEmpty)
                    AiMarkdownText(data: message.content),
                  if (message.hasError) ...[
                    if (message.content.isNotEmpty)
                      const SizedBox(height: AppSpacing.sm),
                    _AssistantErrorBox(
                      message: message.errorMessage!,
                      onRetry: onRetry,
                    ),
                  ],
                  if (canCopy) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _CompactCopyButton(
                          key: Key('ai_chat_copy_${message.id}'),
                          onPressed: () => copyChatTextWithFeedback(
                            context,
                            message.content,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AssistantErrorBox extends StatelessWidget {
  const _AssistantErrorBox({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: cs.errorContainer,
        shape: RoundedSuperellipseBorder(borderRadius: AppRadius.chipBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 16,
              color: cs.onErrorContainer,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                style: text.meta.copyWith(color: cs.onErrorContainer),
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(width: AppSpacing.xs),
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: cs.onErrorContainer,
                ),
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CompactCopyButton extends StatelessWidget {
  const _CompactCopyButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.tag),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm - 2,
            vertical: AppSpacing.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.content_copy_rounded,
                size: 13,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.xs),
              Text('复制', style: text.tag.copyWith(color: cs.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 默认折叠的「思考过程」区块，支持点击展开/收起。
class AiReasoningBlock extends StatefulWidget {
  const AiReasoningBlock({
    super.key,
    required this.reasoningContent,
    this.isStreamingReasoning = false,
  });

  final String reasoningContent;
  final bool isStreamingReasoning;

  @override
  State<AiReasoningBlock> createState() => _AiReasoningBlockState();
}

class _AiReasoningBlockState extends State<AiReasoningBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final reduced = AppMotion.reduced(context);

    return DecoratedBox(
      decoration: ShapeDecoration(
        color: cs.surfaceContainerHighest,
        shape: RoundedSuperellipseBorder(borderRadius: AppRadius.chipBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            expanded: _expanded,
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              customBorder: RoundedSuperellipseBorder(
                borderRadius: AppRadius.chipBorder,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md - 2,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.psychology_alt_outlined,
                      size: 16,
                      color: widget.isStreamingReasoning
                          ? cs.primary
                          : cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.sm - 2),
                    Expanded(
                      child: Text(
                        widget.isStreamingReasoning ? '思考中…' : '思考过程',
                        style: text.meta.copyWith(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (widget.isStreamingReasoning) ...[
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: cs.primary,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm - 2),
                    ],
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: reduced ? Duration.zero : AppMotion.quick,
                      curve: AppMotion.standard,
                      child: Icon(
                        Icons.expand_more_rounded,
                        size: 18,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: reduced ? Duration.zero : AppMotion.quick,
            curve: AppMotion.standard,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md - 2,
                      0,
                      AppSpacing.md - 2,
                      AppSpacing.sm + 2,
                    ),
                    child: Text(
                      widget.reasoningContent.trim(),
                      style: text.meta.copyWith(
                        color: cs.onSurfaceVariant,
                        height: 1.55,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// 未配置 API Key 时的紧凑提示条。
class AiChatUnconfiguredBanner extends StatelessWidget {
  const AiChatUnconfiguredBanner({
    super.key,
    this.onOpenSettings,
    this.onOpenExport,
  });

  final VoidCallback? onOpenSettings;
  final VoidCallback? onOpenExport;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;

    return DecoratedBox(
      decoration: ShapeDecoration(
        color: cs.surfaceContainerHigh,
        shape: RoundedSuperellipseBorder(borderRadius: AppRadius.chipBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.key_off_outlined, size: 17, color: cs.error),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  Text(
                    '未配置 API Key',
                    style: text.meta.copyWith(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (onOpenSettings != null)
                    TextButton(
                      onPressed: onOpenSettings,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                        ),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('去配置'),
                    ),
                  if (onOpenExport != null)
                    TextButton(
                      onPressed: onOpenExport,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                        ),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('导出给外部 AI'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部输入框 + 发送 / 停止按钮。
class AiChatComposer extends StatelessWidget {
  const AiChatComposer({
    super.key,
    required this.controller,
    this.focusNode,
    required this.isGenerating,
    required this.onSend,
    required this.onStop,
    this.hintText = '输入问题…',
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool isGenerating;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.sm,
        AppSpacing.pageMargin,
        AppSpacing.sm + 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              key: const Key('ai_chat_input'),
              controller: controller,
              focusNode: focusNode,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              style: text.body,
              decoration: InputDecoration(
                hintText: hintText,
                hintStyle: text.body.copyWith(color: cs.onSurfaceVariant),
                filled: true,
                fillColor: cs.surfaceContainerHighest,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md + 2,
                  vertical: AppSpacing.sm + 3,
                ),
                border: OutlineInputBorder(
                  borderRadius: AppRadius.cardBorder,
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: AppRadius.cardBorder,
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: AppRadius.cardBorder,
                  borderSide: BorderSide(color: cs.primary, width: 1.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (isGenerating)
            FilledButton.tonalIcon(
              key: const Key('ai_chat_stop_button'),
              onPressed: onStop,
              style: FilledButton.styleFrom(
                backgroundColor: cs.errorContainer,
                foregroundColor: cs.onErrorContainer,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm + 2,
                ),
                minimumSize: const Size(0, 42),
                shape: RoundedRectangleBorder(
                  borderRadius: AppRadius.cardBorder,
                ),
              ),
              icon: const Icon(Icons.stop_rounded, size: 18),
              label: const Text('停止'),
            )
          else
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                final canSend = value.text.trim().isNotEmpty;
                return IconButton.filled(
                  key: const Key('ai_chat_send_button'),
                  tooltip: '发送',
                  onPressed: canSend ? onSend : null,
                  style: IconButton.styleFrom(
                    backgroundColor: canSend
                        ? cs.primary
                        : cs.surfaceContainerHigh,
                    foregroundColor: canSend
                        ? cs.onPrimary
                        : cs.onSurfaceVariant,
                    minimumSize: const Size(42, 42),
                    shape: RoundedRectangleBorder(
                      borderRadius: AppRadius.cardBorder,
                    ),
                  ),
                  icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                );
              },
            ),
        ],
      ),
    );
  }
}

// ── 轻量 Markdown 渲染器（零外部依赖） ──────────────────────────────────────

/// 轻量 Markdown 文本渲染器：支持 `**加粗**`、`` `行内代码` ``、
/// ```` ```代码块``` ````、`- / 1.` 列表与 `#` 标题加粗。
class AiMarkdownText extends StatelessWidget {
  const AiMarkdownText({super.key, required this.data, this.baseStyle});

  final String data;
  final TextStyle? baseStyle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final bodyStyle = baseStyle ?? text.body;
    final blocks = _parseMarkdownBlocks(data);

    if (blocks.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0)
            SizedBox(
              height: blocks[i] is _HeadingBlock
                  ? AppSpacing.md
                  : AppSpacing.sm,
            ),
          _buildBlock(context, blocks[i], bodyStyle, cs, text),
        ],
      ],
    );
  }

  Widget _buildBlock(
    BuildContext context,
    _MdBlock block,
    TextStyle bodyStyle,
    ColorScheme cs,
    AppTypography text,
  ) {
    switch (block) {
      case _HeadingBlock(:final level, :final content):
        final style = switch (level) {
          1 => text.section.copyWith(fontWeight: FontWeight.w700),
          2 => text.rowTitleStrong,
          _ => bodyStyle.copyWith(fontWeight: FontWeight.w600),
        };
        return Text.rich(
          TextSpan(children: _parseInlineSpans(content, style, cs)),
          style: style,
        );
      case _CodeBlock(:final language, :final code):
        return _MarkdownCodeBlock(language: language, code: code);
      case _ListBlock(:final items):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const SizedBox(height: AppSpacing.xs),
              _MarkdownListItemRow(
                item: items[i],
                bodyStyle: bodyStyle,
                colorScheme: cs,
              ),
            ],
          ],
        );
      case _ParagraphBlock(:final content):
        return Text.rich(
          TextSpan(children: _parseInlineSpans(content, bodyStyle, cs)),
          style: bodyStyle,
        );
    }
  }
}

class _MarkdownListItemRow extends StatelessWidget {
  const _MarkdownListItemRow({
    required this.item,
    required this.bodyStyle,
    required this.colorScheme,
  });

  final _ListItem item;
  final TextStyle bodyStyle;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final leftIndent = (item.indent * 6.0).clamp(0.0, 24.0);
    return Padding(
      padding: EdgeInsets.only(left: leftIndent),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm - 2),
            child: Text(
              item.marker,
              style: bodyStyle.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: _parseInlineSpans(
                  item.content,
                  bodyStyle,
                  colorScheme,
                ),
              ),
              style: bodyStyle,
            ),
          ),
        ],
      ),
    );
  }
}

class _MarkdownCodeBlock extends StatelessWidget {
  const _MarkdownCodeBlock({required this.language, required this.code});

  final String? language;
  final String code;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final lang = language?.trim();

    return DecoratedBox(
      decoration: ShapeDecoration(
        color: cs.surfaceContainerHighest,
        shape: RoundedSuperellipseBorder(borderRadius: AppRadius.chipBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.xs + 2,
              AppSpacing.xs,
              AppSpacing.xs,
            ),
            child: Row(
              children: [
                Text(
                  (lang == null || lang.isEmpty) ? '代码' : lang,
                  style: text.tag.copyWith(color: cs.onSurfaceVariant),
                ),
                const Spacer(),
                _CompactCopyButton(
                  onPressed: () => copyChatTextWithFeedback(
                    context,
                    code,
                    doneLabel: '已复制代码',
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.md,
            ),
            child: Text(
              code,
              style: text.meta.copyWith(
                fontFamily: 'monospace',
                color: cs.onSurface,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

sealed class _MdBlock {
  const _MdBlock();
}

final class _HeadingBlock extends _MdBlock {
  const _HeadingBlock(this.level, this.content);
  final int level;
  final String content;
}

final class _CodeBlock extends _MdBlock {
  const _CodeBlock(this.language, this.code);
  final String? language;
  final String code;
}

final class _ListItem {
  const _ListItem({
    required this.indent,
    required this.marker,
    required this.content,
  });
  final int indent;
  final String marker;
  final String content;
}

final class _ListBlock extends _MdBlock {
  const _ListBlock(this.items);
  final List<_ListItem> items;
}

final class _ParagraphBlock extends _MdBlock {
  const _ParagraphBlock(this.content);
  final String content;
}

final RegExp _headingPattern = RegExp(r'^(#{1,6})\s+(.+)$');
final RegExp _unorderedPattern = RegExp(r'^(\s*)[-*+]\s+(.+)$');
final RegExp _orderedPattern = RegExp(r'^(\s*)(\d+\.)\s+(.+)$');
final RegExp _fencePattern = RegExp(r'^```(.*)$');

List<_MdBlock> _parseMarkdownBlocks(String input) {
  final normalized = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = normalized.split('\n');
  final blocks = <_MdBlock>[];

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trim();

    if (trimmed.isEmpty) {
      i++;
      continue;
    }

    // 1. 代码块（支持流式阶段未闭合围栏）
    final fenceMatch = _fencePattern.firstMatch(trimmed);
    if (fenceMatch != null) {
      final lang = fenceMatch.group(1)?.trim();
      final codeLines = <String>[];
      i++;
      while (i < lines.length) {
        if (lines[i].trim().startsWith('```')) {
          i++;
          break;
        }
        codeLines.add(lines[i]);
        i++;
      }
      blocks.add(_CodeBlock(lang, codeLines.join('\n')));
      continue;
    }

    // 2. 标题
    final headingMatch = _headingPattern.firstMatch(trimmed);
    if (headingMatch != null) {
      blocks.add(
        _HeadingBlock(
          headingMatch.group(1)!.length,
          headingMatch.group(2)!.trim(),
        ),
      );
      i++;
      continue;
    }

    // 3. 无序 / 有序列表
    if (_unorderedPattern.hasMatch(line) || _orderedPattern.hasMatch(line)) {
      final items = <_ListItem>[];
      while (i < lines.length) {
        final current = lines[i];
        final uMatch = _unorderedPattern.firstMatch(current);
        if (uMatch != null) {
          items.add(
            _ListItem(
              indent: uMatch.group(1)!.length,
              marker: '•',
              content: uMatch.group(2)!.trim(),
            ),
          );
          i++;
          continue;
        }
        final oMatch = _orderedPattern.firstMatch(current);
        if (oMatch != null) {
          items.add(
            _ListItem(
              indent: oMatch.group(1)!.length,
              marker: oMatch.group(2)!,
              content: oMatch.group(3)!.trim(),
            ),
          );
          i++;
          continue;
        }
        break;
      }
      blocks.add(_ListBlock(items));
      continue;
    }

    // 4. 普通段落
    final paraLines = <String>[line];
    i++;
    while (i < lines.length) {
      final next = lines[i];
      final nextTrimmed = next.trim();
      if (nextTrimmed.isEmpty ||
          _fencePattern.hasMatch(nextTrimmed) ||
          _headingPattern.hasMatch(nextTrimmed) ||
          _unorderedPattern.hasMatch(next) ||
          _orderedPattern.hasMatch(next)) {
        break;
      }
      paraLines.add(next);
      i++;
    }
    blocks.add(_ParagraphBlock(paraLines.join('\n')));
  }
  return blocks;
}

List<InlineSpan> _parseInlineSpans(
  String text,
  TextStyle baseStyle,
  ColorScheme cs,
) {
  final spans = <InlineSpan>[];
  final buffer = StringBuffer();

  void flushPlain() {
    if (buffer.isEmpty) return;
    spans.add(TextSpan(text: buffer.toString(), style: baseStyle));
    buffer.clear();
  }

  var i = 0;
  while (i < text.length) {
    final ch = text[i];

    // 行内代码 `code`
    if (ch == '`') {
      final end = text.indexOf('`', i + 1);
      if (end > i + 1 && !text.substring(i + 1, end).contains('\n')) {
        flushPlain();
        spans.add(
          TextSpan(
            text: text.substring(i + 1, end),
            style: baseStyle.copyWith(
              fontFamily: 'monospace',
              backgroundColor: cs.surfaceContainerHighest,
              color: cs.onSurface,
            ),
          ),
        );
        i = end + 1;
        continue;
      }
    }

    // 加粗 **text** 或 __text__
    if ((ch == '*' || ch == '_') && i + 1 < text.length && text[i + 1] == ch) {
      final marker = '$ch$ch';
      final end = text.indexOf(marker, i + 2);
      if (end > i + 2) {
        flushPlain();
        final inner = text.substring(i + 2, end);
        final boldStyle = baseStyle.copyWith(fontWeight: FontWeight.w600);
        spans.addAll(_parseInlineSpans(inner, boldStyle, cs));
        i = end + 2;
        continue;
      }
    }

    // 链接 [label](url)
    if (ch == '[') {
      final closeBracket = text.indexOf(']', i + 1);
      if (closeBracket > i + 1 &&
          closeBracket + 1 < text.length &&
          text[closeBracket + 1] == '(') {
        final closeParen = text.indexOf(')', closeBracket + 2);
        if (closeParen > closeBracket + 2) {
          flushPlain();
          final label = text.substring(i + 1, closeBracket);
          spans.add(
            TextSpan(
              text: label,
              style: baseStyle.copyWith(
                color: cs.primary,
                decoration: TextDecoration.underline,
                decorationColor: cs.primary,
              ),
            ),
          );
          i = closeParen + 1;
          continue;
        }
      }
    }

    buffer.write(ch);
    i++;
  }
  flushPlain();
  return spans;
}
