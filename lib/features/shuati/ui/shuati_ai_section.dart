/// AI 解析卡片区（Issue #117）：本地 `ai_explanations` 缓存自动展示、
/// 「AI 解析」生成 / 「重新生成」、以及经 [AiChatSheet] 的追问入口。
///
/// 做题页（答案揭示后）与错题详情弹层共用；每道题一份 State。
library;

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/ai_chat/ai_chat_sheet.dart';
import '../../../shared/widgets/plain_list.dart';
import '../ai/shuati_ai_models.dart';
import '../ai/shuati_ai_service.dart';
import '../domain/shuati_models.dart';
import 'shuati_services.dart';

class ShuatiAiSection extends StatefulWidget {
  const ShuatiAiSection({super.key, required this.question, this.userAnswer});

  final Question question;

  /// 用户已提交的作答文本（传给「追问 AI」上下文）。
  final String? userAnswer;

  @override
  State<ShuatiAiSection> createState() => _ShuatiAiSectionState();
}

class _ShuatiAiSectionState extends State<ShuatiAiSection> {
  AiExplanation? _explanation;
  String? _error;
  bool _loading = true;
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    _loadCached();
  }

  Future<ShuatiAiService> _service() async => ShuatiServices.instance
      .createAiService(await ShuatiServices.instance.store());

  /// 有缓存直接展示；没有则收起为「AI 解析」入口（失败静默，不打扰作答）。
  Future<void> _loadCached() async {
    try {
      final store = await ShuatiServices.instance.store();
      final cached = await store.aiExplanations.getCached(widget.question.id);
      if (!mounted) return;
      setState(() {
        _explanation = cached == null
            ? null
            : AiExplanation.fromStorage(
                cached.explanation,
                model: cached.model,
              );
        _loading = false;
      });
    } on Object {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _generate({required bool forceRefresh}) async {
    if (_generating) return;
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final service = await _service();
      final explanation = await service.getOrGenerateExplanation(
        question: widget.question,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() => _explanation = explanation);
    } on ShuatiAiFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on Object {
      if (mounted) setState(() => _error = 'AI 解析生成失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _askFollowUp() async {
    String contextText;
    try {
      final service = await _service();
      contextText = service.buildQuestionChatContext(
        widget.question,
        userAnswer: widget.userAnswer,
      );
    } on Object {
      // store 未就绪也能追问（上下文是纯文本组装）。
      contextText = buildShuatiQuestionContext(
        widget.question,
        userAnswer: widget.userAnswer,
      );
    }
    if (!mounted) return;
    AiChatSheet.show(
      context,
      title: 'AI 助教',
      initialContext: contextText,
      initialPrompt: '请帮我梳理这道题的解题思路和易错点',
      onOpenSettings: () => context.pushNamed('ai-settings'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = context.appText;
    final cs = Theme.of(context).colorScheme;
    final explanation = _explanation;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('AI 解析', style: text.label),
            if (explanation?.model case final model? when model.isNotEmpty) ...[
              const SizedBox(width: AppSpacing.sm),
              PlainTag(model),
            ],
            const Spacer(),
            IconButton(
              tooltip: '重新生成',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _generating
                  ? null
                  : () => _generate(forceRefresh: true),
            ),
          ],
        ),
        if (_generating)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (!_loading && explanation != null) ...[
          const SizedBox(height: AppSpacing.xs),
          _ExplanationBlock(explanation: explanation),
        ],
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            if (explanation == null && !_loading)
              FilledButton.tonalIcon(
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('AI 解析'),
                onPressed: _generating
                    ? null
                    : () => _generate(forceRefresh: false),
              ),
            OutlinedButton.icon(
              icon: const Icon(Icons.chat_bubble_outline, size: 18),
              label: const Text('追问 AI'),
              onPressed: _askFollowUp,
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(_error!, style: text.secondary.copyWith(color: cs.error)),
        ],
      ],
    );
  }
}

/// 已生成的解析主体：总解析 + 逐选项解析。
class _ExplanationBlock extends StatelessWidget {
  const _ExplanationBlock({required this.explanation});

  final AiExplanation explanation;

  @override
  Widget build(BuildContext context) {
    final text = context.appText;
    final cs = Theme.of(context).colorScheme;
    final options = explanation.optionExplanations ?? const <String, String>{};
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: ShapeDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        shape: RoundedSuperellipseBorder(borderRadius: AppRadius.tileBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(explanation.explanation, style: text.secondary),
          for (final e in options.entries) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${e.key}：${e.value}',
              style: text.meta.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}
