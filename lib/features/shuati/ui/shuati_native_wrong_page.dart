/// 原生错题本页：永久错题列表、搜索、详情预览、显式移出与重做入口。
///
/// 错题规则沿用 PWA：答错即入本，之后答对**不会**自动移除；移除是原生新增的
/// 显式操作（PWA UI 没有入口，见 docs/shuati-native-parity.md §8）。
library;

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_app_bar.dart';
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../../shared/widgets/app_search_field.dart';
import '../../../shared/widgets/app_status_tag.dart';
import '../../../shared/widgets/plain_list.dart';
import '../domain/shuati_models.dart';
import '../domain/wrong_question.dart';
import 'shuati_ai_section.dart';
import 'shuati_services.dart';

class ShuatiNativeWrongPage extends StatefulWidget {
  const ShuatiNativeWrongPage({super.key, required this.bankId});

  final String bankId;

  @override
  State<ShuatiNativeWrongPage> createState() => _ShuatiNativeWrongPageState();
}

class _ShuatiNativeWrongPageState extends State<ShuatiNativeWrongPage> {
  final _search = TextEditingController();
  List<WrongQuestionListItem>? _items;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final store = await ShuatiServices.instance.store();
      final items = await store.searchWrongQuestions(
        widget.bankId,
        query: _search.text,
      );
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _remove(WrongQuestionListItem item) async {
    final confirmed = await AppFeedback.confirm(
      context,
      title: '移出错题本？',
      message: '只移出错题本，做题记录会保留。',
      confirmLabel: '移出',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final store = await ShuatiServices.instance.store();
    await store.wrongQuestions.remove(widget.bankId, item.question.id);
    if (mounted) await _load();
  }

  Future<void> _showDetail(WrongQuestionListItem item) async {
    final q = item.question;
    await AppFeedback.sheet<void>(
      context,
      scrollControlled: true,
      builder: (sheetContext) {
        final text = sheetContext.appText;
        final cs = Theme.of(sheetContext).colorScheme;
        final optEntries = q.type == QuestionType.judge
            ? const [('true', '正确'), ('false', '错误')]
            : [
                for (final e in (q.options ?? const <String, String>{}).entries)
                  if (e.value.trim().isNotEmpty) (e.key, e.value),
              ];
        final explanation = q.explanation?.trim() ?? '';
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.lg,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      AppStatusTag(q.type.label),
                      const SizedBox(width: AppSpacing.sm),
                      Text(_meta(item), style: text.meta),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(q.question, style: text.rowTitle),
                  if (optEntries.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.md),
                    for (final (key, label) in optEntries) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                        child: Text(
                          q.type == QuestionType.judge ? label : '$key. $label',
                          style: q.answer.contains(key)
                              ? text.body.copyWith(color: cs.primary)
                              : text.secondary,
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: AppSpacing.md),
                  Text('参考答案', style: text.label),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    q.type == QuestionType.judge
                        ? (q.answer.contains('true') ? '正确' : '错误')
                        : q.answer.join(' / '),
                    style: text.rowTitle.copyWith(color: cs.primary),
                  ),
                  if (explanation.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.md),
                    Text('解析', style: text.label),
                    const SizedBox(height: AppSpacing.xs),
                    Text(explanation, style: text.secondary),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  ShuatiAiSection(question: q),
                  const SizedBox(height: AppSpacing.lg),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            Navigator.of(sheetContext).pop();
                            _remove(item);
                          },
                          child: const Text('移出错题本'),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: FilledButton(
                          onPressed: () {
                            Navigator.of(sheetContext).pop();
                            _openWrongPractice();
                          },
                          child: const Text('重做错题'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openWrongPractice() async {
    await context.pushNamed(
      'shuati-practice-session',
      pathParameters: {'bankId': widget.bankId, 'mode': 'wrong'},
    );
    if (mounted) await _load();
  }

  String _meta(WrongQuestionListItem item) {
    final at = DateTime.fromMillisecondsSinceEpoch(item.entry.lastWrongAt);
    return '错 ${item.entry.wrongCount} 次 · ${at.month}/${at.day}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(
        title: const Text('错题本'),
        actions: [
          TextButton(
            onPressed: (_items?.isEmpty ?? true) ? null : _openWrongPractice,
            child: const Text('重做'),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return AppErrorView(message: '无法读取错题', onRetry: _load);
    }
    final items = _items;
    if (items == null) return const Center(child: CircularProgressIndicator());
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pageMargin,
            AppSpacing.sm,
            AppSpacing.pageMargin,
            AppSpacing.sm,
          ),
          child: AppSearchField(
            controller: _search,
            hintText: '搜索错题',
            onChanged: (_) => _load(),
            onClear: () {
              _search.clear();
              _load();
            },
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const AppEmptyView(
                  title: '没有错题',
                  icon: Icons.check_circle_outline,
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.listGutter,
                    AppSpacing.xs,
                    AppSpacing.listGutter,
                    AppSpacing.xl,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: PlainListGroup(
                        children: [
                          PlainListRow(
                            title: item.question.question,
                            subtitle: _meta(item),
                            showChevron: false,
                            onTap: () => _showDetail(item),
                            trailing: IconButton(
                              tooltip: '移出错题本',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _remove(item),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
