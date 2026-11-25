/// 原生导入页（两步向导，Issue #117）：
/// Step 1 题库名称 + 选文件 → `parseForPreview`；
/// Step 2 解析预览（题数 / 去重 / 缺答案 / 拒绝原因）→ 可选「AI 补全缺失答案」
/// → `commitPreview` 落库 → 类型化报告与快捷开练。
library;

import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_app_bar.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../../shared/widgets/plain_list.dart';
import '../ai/shuati_ai_models.dart';
import '../domain/shuati_models.dart';
import '../import/ai_convert_prompt.dart';
import '../import/import_models.dart';
import '../import/import_service.dart';
import '../persistence/shuati_store.dart';
import 'shuati_services.dart';

class ShuatiNativeImportPage extends StatefulWidget {
  const ShuatiNativeImportPage({super.key});

  @override
  State<ShuatiNativeImportPage> createState() => _ShuatiNativeImportPageState();
}

class _ShuatiNativeImportPageState extends State<ShuatiNativeImportPage> {
  final _nameController = TextEditingController();
  ShuatiStore? _store;
  ShuatiImportService? _importService;

  /// 0 = 选文件；1 = 解析预览；报告非空时展示结果视图。
  int _step = 0;
  bool _busy = false;
  bool _enriching = false;
  PickedShuatiFile? _file;
  ShuatiImportPreview? _preview;
  Map<int, AiQuestionPatch> _patches = const {};
  Set<int> _patchChecked = const {};
  String? _enrichError;
  ShuatiImportReport? _report;
  String? _failure;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<ShuatiStore> _ensureStore() async =>
      _store ??= await ShuatiServices.instance.store();

  Future<void> _pickAndPreview() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final file = await ShuatiServices.instance.io.pickFile(
        extensions: const ['json', 'csv', 'xlsx', 'docx', 'txt', 'md'],
      );
      if (file == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final store = await _ensureStore();
      final service = _importService ??= ShuatiImportService(store);
      final preview = await service.parseForPreview(
        bytes: file.bytes,
        fileName: file.name,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _step = 1;
        _file = file;
        _preview = preview;
        _patches = const {};
        _patchChecked = const {};
        _enrichError = null;
        _report = null;
        // JSON 里 `name` 或文件名解析出的默认题库名回填给可编辑框。
        if (_nameController.text.trim().isEmpty) {
          _nameController.text = preview.bankName;
        }
      });
    } on ShuatiImportFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failure = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failure = '导入失败，请重试';
      });
    }
  }

  Future<void> _enrichMissingAnswers() async {
    final preview = _preview;
    if (preview == null || _enriching) return;
    setState(() {
      _enriching = true;
      _enrichError = null;
    });
    try {
      final store = await _ensureStore();
      final ai = ShuatiServices.instance.createAiService(store);
      final patches = await ai.enrichMissingAnswers(
        questions: preview.questions,
      );
      if (!mounted) return;
      setState(() {
        _patches = patches;
        _patchChecked = patches.keys.toSet();
      });
    } on ShuatiAiFailure catch (e) {
      if (mounted) setState(() => _enrichError = e.message);
    } catch (_) {
      if (mounted) setState(() => _enrichError = 'AI 补全失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _enriching = false);
    }
  }

  Future<void> _commit() async {
    final preview = _preview;
    final service = _importService;
    if (preview == null || service == null || _busy) return;
    setState(() => _busy = true);
    try {
      final overrides = [
        for (final e in _patches.entries)
          if (_patchChecked.contains(e.key))
            ParsedQuestionOverride(
              index: e.key,
              answer: e.value.answer,
              explanation: e.value.explanation,
            ),
      ];
      final report = await service.commitPreview(
        preview: preview,
        bankName: _nameController.text,
        overrides: overrides,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _report = report;
      });
    } on ShuatiImportFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failure = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failure = '导入失败，请重试';
      });
    }
  }

  void _restart() {
    setState(() {
      _step = 0;
      _busy = false;
      _enriching = false;
      _file = null;
      _preview = null;
      _patches = const {};
      _patchChecked = const {};
      _enrichError = null;
      _report = null;
      _failure = null;
    });
  }

  Future<void> _copyAiPrompt() async {
    try {
      await Clipboard.setData(
        const ClipboardData(text: kShuatiAiConvertPrompt),
      );
      if (!mounted) return;
      AppFeedback.toast(context, '已复制 AI 转换提示词');
    } on PlatformException {
      if (!mounted) return;
      AppFeedback.toast(context, '复制失败，请查看内容后手动复制');
    }
  }

  Future<void> _showAiPromptSheet() {
    return AppFeedback.sheet<void>(
      context,
      scrollControlled: true,
      builder: (sheetContext) => _AiConvertPromptSheet(
        onCopy: () {
          Navigator.of(sheetContext).pop();
          _copyAiPrompt();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final importedBank = report?.bank;
    return Scaffold(
      appBar: AppAppBar(
        title: Text(_step == 0 ? '导入题库' : '解析预览'),
        leading: _step == 1 && report == null
            ? IconButton(
                tooltip: '返回重新选文件',
                icon: const Icon(Icons.arrow_back),
                onPressed: _busy ? null : _restart,
              )
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.listGutter,
          AppSpacing.md,
          AppSpacing.listGutter,
          AppSpacing.xl,
        ),
        children: [
          if (_step == 0 || report != null) _buildStepPick(context),
          if (_preview != null && report == null) _buildStepPreview(context),
          if (_failure != null) ...[
            const SizedBox(height: AppSpacing.lg),
            Text(
              _failure!,
              style: context.appText.secondary.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          if (report != null) ...[
            const SizedBox(height: AppSpacing.xl),
            ShuatiImportReportView(report: report),
            const SizedBox(height: AppSpacing.lg),
            if (importedBank != null && importedBank.questionCount > 0)
              FilledButton.tonal(
                onPressed: () => context.pushNamed(
                  'shuati-practice-session',
                  pathParameters: {
                    'bankId': importedBank.id,
                    'mode': PracticeMode.sequential.name,
                  },
                ),
                child: const Text('开始练习'),
              ),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton(onPressed: _restart, child: const Text('再导入一份')),
          ],
        ],
      ),
    );
  }

  Widget _buildStepPick(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _nameController,
          enabled: !_busy && _step == 0,
          decoration: const InputDecoration(
            labelText: '题库名称（可选）',
            hintText: '留空则使用文件名',
          ),
        ),
        if (_step == 0) ...[
          const SizedBox(height: AppSpacing.lg),
          FilledButton.icon(
            onPressed: _busy ? null : _pickAndPreview,
            icon: const Icon(Icons.file_open_outlined),
            label: Text(_busy ? '正在解析…' : '选择文件'),
          ),
        ],
        if (_busy && _step == 0) ...[
          const SizedBox(height: AppSpacing.md),
          const LinearProgressIndicator(),
        ],
        if (_step == 0 && _report == null) ...[
          const SizedBox(height: AppSpacing.xl),
          _AiConvertHelperSection(
            onCopy: _copyAiPrompt,
            onView: _showAiPromptSheet,
          ),
        ],
      ],
    );
  }

  Widget _buildStepPreview(BuildContext context) {
    final preview = _preview!;
    final text = context.appText;
    final cs = Theme.of(context).colorScheme;
    final missing = preview.missingAnswerIndexes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.md),
        Text(_file!.name, style: text.secondary),
        const SizedBox(height: AppSpacing.md),
        PlainSectionHeader(preview.updatesExisting ? '解析预览（更新既有题库）' : '解析预览'),
        PlainListGroup(
          children: [
            if (preview.updatesExisting)
              PlainListRow(
                title: '同名题库',
                value: preview.existingBankName ?? '',
              ),
            PlainListRow(title: '识别题目', value: '${preview.questions.length}'),
            PlainListRow(title: '预计新增', value: '${preview.newQuestionCount}'),
            if (preview.duplicates > 0)
              PlainListRow(title: '重复跳过', value: '${preview.duplicates}'),
            if (preview.conflicts > 0)
              PlainListRow(title: '答案冲突', value: '${preview.conflicts}'),
            if (missing.isNotEmpty)
              PlainListRow(
                title: '缺答案',
                value: '${missing.length}',
                emphasizeValue: true,
              ),
            PlainListRow(title: '无效条目', value: '${preview.invalid}'),
            for (final entry in preview.rejectionCounts.entries)
              PlainListRow(
                title: '无效 · ${ShuatiImportReportView.reasonLabel(entry.key)}',
                value: '${entry.value}',
              ),
            for (final warning in preview.warnings)
              PlainListRow(title: ShuatiImportReportView.warningLabel(warning)),
          ],
        ),
        if (missing.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          if (_patches.isEmpty)
            FilledButton.tonalIcon(
              icon: const Icon(Icons.auto_awesome_outlined, size: 18),
              label: Text(
                _enriching ? 'AI 补全中…' : 'AI 补全缺失答案（${missing.length} 题）',
              ),
              onPressed: _enriching ? null : _enrichMissingAnswers,
            )
          else
            _buildPatchList(text, cs),
          if (_enrichError != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              _enrichError!,
              style: text.secondary.copyWith(color: cs.error),
            ),
          ],
          if (_enriching) ...[
            const SizedBox(height: AppSpacing.xs),
            const LinearProgressIndicator(minHeight: 2),
          ],
        ],
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          onPressed: _busy || _enriching ? null : _commit,
          child: Text(_busy ? '正在导入…' : '确认导入'),
        ),
      ],
    );
  }

  /// AI 补全建议列表：逐题默认勾选，可取消后不带入导入。
  Widget _buildPatchList(AppTypography text, ColorScheme cs) {
    final preview = _preview!;
    final entries = _patches.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PlainSectionHeader('AI 补全建议（已勾选 ${_patchChecked.length} 条）'),
        PlainListGroup(
          children: [
            for (final e in entries)
              _PatchRow(
                number: e.key + 1,
                question: preview.questions[e.key],
                patch: e.value,
                checked: _patchChecked.contains(e.key),
                onChanged: _busy
                    ? null
                    : (value) => setState(() {
                        if (value) {
                          _patchChecked = {..._patchChecked, e.key};
                        } else {
                          _patchChecked = {..._patchChecked}..remove(e.key);
                        }
                      }),
              ),
          ],
        ),
      ],
    );
  }
}

class _PatchRow extends StatelessWidget {
  const _PatchRow({
    required this.number,
    required this.question,
    required this.patch,
    required this.checked,
    required this.onChanged,
  });

  final int number;
  final Question question;
  final AiQuestionPatch patch;
  final bool checked;
  final ValueChanged<bool>? onChanged;

  String _answerLabel() {
    final answer = patch.answer;
    if (answer == null || answer.isEmpty) return '建议：仅解析';
    if (question.type == QuestionType.judge) {
      return '建议：${answer.first == 'true' ? '对' : '错'}';
    }
    return '建议：${answer.join('、')}';
  }

  @override
  Widget build(BuildContext context) {
    final text = context.appText;
    final cs = Theme.of(context).colorScheme;
    final explanation = patch.explanation;
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged!(!checked),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(kPlainListRowInset, 8, 4, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('第 $number 题', style: text.meta),
                  const SizedBox(height: 2),
                  Text(
                    question.question,
                    style: text.listTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _answerLabel(),
                    style: text.secondary.copyWith(color: cs.primary),
                  ),
                  if (explanation != null && explanation.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      explanation,
                      style: text.meta,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            Checkbox(
              value: checked,
              onChanged: onChanged == null
                  ? null
                  : (v) => onChanged!(v ?? false),
            ),
          ],
        ),
      ),
    );
  }
}

/// 导入报告：计数 + 拒绝原因 + 提示。不含题目内容。
class ShuatiImportReportView extends StatelessWidget {
  const ShuatiImportReportView({super.key, required this.report});

  final ShuatiImportReport report;

  static String reasonLabel(ImportRejectionReason reason) => switch (reason) {
    ImportRejectionReason.notAnObject => '不是题目对象',
    ImportRejectionReason.missingQuestionText => '缺少题干',
    ImportRejectionReason.invalidOptions => '选项格式不合法',
    ImportRejectionReason.unexpectedError => '解析出错',
  };

  static String warningLabel(ImportWarning warning) => switch (warning) {
    ImportWarning.decodedAsGbk => '文件按 GBK 解码',
    ImportWarning.lossyDecoding => '部分字节无法解码',
    ImportWarning.questionsWithoutAnswer => '部分题目没有答案，无法作答',
    ImportWarning.idsRegenerated => '部分题目编号冲突，已重新生成',
    ImportWarning.allDuplicates => '全部是重复题，未创建题库',
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PlainSectionHeader(report.bank?.name ?? '导入结果'),
        PlainListGroup(
          children: [
            PlainListRow(title: '新增题目', value: '${report.added}'),
            PlainListRow(title: '重复跳过', value: '${report.duplicates}'),
            if (report.conflicts > 0)
              PlainListRow(title: '答案冲突（已导入）', value: '${report.conflicts}'),
            if (report.updatedExisting)
              PlainListRow(
                title: '同源更新',
                value:
                    '覆盖 ${report.updatedQuestions} · 删除 ${report.removedQuestions}',
              ),
            PlainListRow(title: '无效条目', value: '${report.invalid}'),
            for (final entry in report.rejectionCounts.entries)
              PlainListRow(
                title: '无效 · ${reasonLabel(entry.key)}',
                value: '${entry.value}',
              ),
            for (final warning in report.warnings)
              PlainListRow(title: warningLabel(warning)),
          ],
        ),
      ],
    );
  }
}

/// 外部 AI 题库转换辅助区：引导用户将原始题库交给外部 AI 生成标准 JSON。
class _AiConvertHelperSection extends StatelessWidget {
  const _AiConvertHelperSection({required this.onCopy, required this.onView});

  final VoidCallback onCopy;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    final text = context.appText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PlainSectionHeader('外部 AI 题库转换'),
        PlainListGroup(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: kPlainListRowInset,
                vertical: AppSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '支持将 PDF / Word / 截图发给豆包工作、DeepSeek 等外部 AI，转为标准 .json 题库后再回来导入。',
                    style: text.secondary,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: onCopy,
                        icon: const Icon(Icons.content_copy_outlined, size: 18),
                        label: const Text('一键复制提示词'),
                      ),
                      TextButton(onPressed: onView, child: const Text('查看内容')),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 只读展示外部 AI 转换提示词全文的底部弹层。
class _AiConvertPromptSheet extends StatelessWidget {
  const _AiConvertPromptSheet({required this.onCopy});

  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final text = context.appText;
    final cs = Theme.of(context).colorScheme;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pageMargin,
            0,
            AppSpacing.pageMargin,
            AppSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('外部 AI 转换提示词', style: text.section),
              const SizedBox(height: AppSpacing.xs),
              Text('连同原始题库文件一并发送给豆包工作、DeepSeek 等 AI 助手。', style: text.meta),
              const SizedBox(height: AppSpacing.md),
              Flexible(
                child: Container(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
                    borderRadius: AppRadius.cardBorder,
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: SelectableText(
                      kShuatiAiConvertPrompt,
                      style: text.meta.copyWith(
                        color: cs.onSurface,
                        height: 1.55,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onCopy,
                      icon: const Icon(Icons.content_copy_outlined, size: 18),
                      label: const Text('复制全部提示词'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
