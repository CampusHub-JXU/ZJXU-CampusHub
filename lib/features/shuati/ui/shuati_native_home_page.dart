/// 原生刷题助手首页：学习概览、继续上次、题库搜索/列表、模式配置与题库管理。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/shortcut/app_shortcut_service.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_app_bar.dart';
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../../shared/widgets/app_filter_chips.dart';
import '../../../shared/widgets/app_search_field.dart';
import '../../../shared/widgets/glass_dialog_route.dart';
import '../../../shared/widgets/plain_list.dart';
import '../backup/backup_exporter.dart';
import '../domain/practice_stats.dart';
import '../domain/shuati_models.dart';
import 'shuati_services.dart';

class _BankEntry {
  const _BankEntry(this.bank, this.stats);

  final QuestionBank bank;
  final BankStats stats;
}

class _ResumeEntry {
  const _ResumeEntry(this.session, this.bank);

  final PracticeSessionRecord session;
  final QuestionBank bank;
}

enum _HomeMenuAction { addShortcut }

class ShuatiNativeHomePage extends StatefulWidget {
  const ShuatiNativeHomePage({super.key});

  @override
  State<ShuatiNativeHomePage> createState() => _ShuatiNativeHomePageState();
}

class _ShuatiNativeHomePageState extends State<ShuatiNativeHomePage> {
  final TextEditingController _searchController = TextEditingController();
  List<_BankEntry>? _entries;
  HomeStats? _homeStats;
  _ResumeEntry? _resumeEntry;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final store = await ShuatiServices.instance.store();
      final banks = await store.banks.getAllBanks();
      final records = await store.records.getAll();
      final lastSession = await store.sessions.load();
      final homeStats = computeHomeStats(banks: banks, records: records);
      final byBank = <String, List<PracticeRecord>>{};
      for (final r in records) {
        byBank.putIfAbsent(r.bankId, () => []).add(r);
      }
      final entries = [
        for (final b in banks)
          _BankEntry(b, computeBankStats(b, byBank[b.id] ?? const [])),
      ];
      _ResumeEntry? resumeEntry;
      if (lastSession != null && lastSession.questionIds.isNotEmpty) {
        for (final b in banks) {
          if (b.id == lastSession.bankId) {
            resumeEntry = _ResumeEntry(lastSession, b);
            break;
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _homeStats = homeStats;
        _resumeEntry = resumeEntry;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  /// 打开子页面，返回后刷新（数据可能已变化）。
  Future<void> _open(
    String name, {
    Map<String, String> params = const {},
    Map<String, String> query = const {},
  }) async {
    await context.pushNamed(
      name,
      pathParameters: params,
      queryParameters: query,
    );
    if (mounted) await _load();
  }

  Future<void> _requestShortcut() async {
    final result = await AppShortcutService.instance
        .requestShuatiShortcutResult();
    if (!mounted) return;
    AppFeedback.toast(
      context,
      result.message,
      actionLabel: result.canOpenPermissionSettings ? '去设置' : null,
      onAction: () {
        AppShortcutService.instance.openShortcutPermissionSettings();
      },
    );
  }

  Future<void> _showBankSheet(QuestionBank bank) async {
    final store = await ShuatiServices.instance.store();
    final questions = await store.questions.getByBank(bank.id);
    final records = await store.records.getByBank(bank.id);
    final wrongEntries = await store.wrongQuestions.entriesByBank(bank.id);
    final favoriteIds = await store.favorites.questionIds(bank.id);
    if (!mounted) return;

    await AppFeedback.sheet<void>(
      context,
      scrollControlled: true,
      builder: (sheetContext) => _BankActionSheet(
        bank: bank,
        questions: questions,
        records: records,
        wrongCount: wrongEntries.length,
        favoriteCount: favoriteIds.length,
        onStartPractice: (mode, query) {
          Navigator.of(sheetContext).pop();
          _open(
            'shuati-practice-session',
            params: {'bankId': bank.id, 'mode': mode.name},
            query: query,
          );
        },
        onOpenWrongBook: () {
          Navigator.of(sheetContext).pop();
          _open('shuati-wrong', params: {'bankId': bank.id});
        },
        onRename: () {
          Navigator.of(sheetContext).pop();
          _renameBank(bank);
        },
        onExportJson: () {
          Navigator.of(sheetContext).pop();
          _exportBankJson(bank);
        },
        onDelete: () {
          Navigator.of(sheetContext).pop();
          _confirmDelete(bank);
        },
      ),
    );
  }

  Future<void> _renameBank(QuestionBank bank) async {
    final nextName = await showGlassDialog<String>(
      context: context,
      builder: (_) => _TextPromptDialog(
        title: '重命名题库',
        initialValue: bank.name,
        hintText: '输入题库名称',
        confirmLabel: '保存',
      ),
    );
    if (nextName == null || nextName.isEmpty || nextName == bank.name) return;
    if (!mounted) return;
    final store = await ShuatiServices.instance.store();
    await store.banks.rename(bank.id, nextName);
    if (mounted) await _load();
  }

  Future<void> _exportBankJson(QuestionBank bank) async {
    await AppFeedback.sheet<void>(
      context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PlainSectionHeader('导出「${bank.name}」'),
              PlainListGroup(
                children: [
                  PlainListRow(
                    title: '保存题库 JSON 到文件',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _runExportBankJson(bank, share: false);
                    },
                  ),
                  PlainListRow(
                    title: '分享题库 JSON',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _runExportBankJson(bank, share: true);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _runExportBankJson(
    QuestionBank bank, {
    required bool share,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final store = await ShuatiServices.instance.store();
      final jsonText = await ShuatiBackupExporter(store)
          .exportBankQuestionsJson(bank.id);
      final bytes = Uint8List.fromList(utf8.encode(jsonText));
      final io = ShuatiServices.instance.io;
      final fileName = '${bank.name}.json';
      if (share) {
        await io.shareFile(fileName, bytes);
        return;
      }
      final path = await io.saveFile(fileName, bytes);
      if (path != null && messenger != null) {
        AppFeedback.toastOn(messenger, '题库已保存');
      }
    } catch (_) {
      if (messenger != null) AppFeedback.toastOn(messenger, '导出失败');
    }
  }

  Future<void> _confirmDelete(QuestionBank bank) async {
    final confirmed = await AppFeedback.confirm(
      context,
      title: '删除「${bank.name}」？',
      message: '题库、做题记录、收藏和错题将一并删除，无法撤销。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final store = await ShuatiServices.instance.store();
    await store.banks.deleteCascade(bank.id);
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final isAndroid = Theme.of(context).platform == TargetPlatform.android;
    return Scaffold(
      appBar: AppAppBar(
        title: const Text('刷题助手'),
        actions: [
          IconButton(
            tooltip: '添加题库',
            icon: const Icon(Icons.add),
            onPressed: () => _open('shuati-import'),
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _open('shuati-settings'),
          ),
          if (isAndroid)
            PopupMenuButton<_HomeMenuAction>(
              tooltip: '更多操作',
              onSelected: (action) {
                switch (action) {
                  case _HomeMenuAction.addShortcut:
                    _requestShortcut();
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem<_HomeMenuAction>(
                  value: _HomeMenuAction.addShortcut,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.add_to_home_screen_outlined),
                    title: Text('添加到桌面'),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_error != null) {
      return AppErrorView(message: '无法读取题库', onRetry: _load);
    }
    final entries = _entries;
    final homeStats = _homeStats;
    if (entries == null || homeStats == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (entries.isEmpty) {
      return AppEmptyView(
        title: '还没有题库',
        message: '支持 JSON、CSV、Excel、Word、TXT 和 Markdown 导入，也可在设置中恢复旧版备份',
        icon: Icons.menu_book_outlined,
        actionLabel: '导入题库',
        onAction: () => _open('shuati-import'),
      );
    }

    final query = _searchController.text.trim().toLowerCase();
    final filtered = query.isEmpty
        ? entries
        : [
            for (final e in entries)
              if (e.bank.name.toLowerCase().contains(query)) e,
          ];
    final resumeEntry = _resumeEntry;

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.listGutter,
            AppSpacing.md,
            AppSpacing.listGutter,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const PlainSectionHeader('学习概览'),
                _HomeStatsCard(stats: homeStats),
                if (resumeEntry != null) ...[
                  const SizedBox(height: AppSpacing.listGroupGap),
                  const PlainSectionHeader('继续上次'),
                  PlainListGroup(
                    children: [
                      PlainListRow(
                        title: resumeEntry.bank.name,
                        subtitle: _resumeSubtitle(resumeEntry.session),
                        value:
                            '${(resumeEntry.session.currentIndex + 1).clamp(1, resumeEntry.session.questionIds.length)}/'
                            '${resumeEntry.session.questionIds.length}',
                        emphasizeValue: true,
                        onTap: () => _open(
                          'shuati-practice-session',
                          params: {
                            'bankId': resumeEntry.session.bankId,
                            'mode': resumeEntry.session.mode.name,
                          },
                          query: {
                            'resume': '1',
                            if (resumeEntry.session.typeFilter != null)
                              'type': resumeEntry.session.typeFilter!.name,
                          },
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: AppSpacing.listGroupGap),
                const PlainSectionHeader('我的题库'),
                if (entries.length > 1) ...[
                  AppSearchField(
                    controller: _searchController,
                    hintText: '搜索题库',
                    onChanged: (_) => setState(() {}),
                    onClear: () {
                      _searchController.clear();
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
            ),
          ),
        ),
        if (filtered.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: AppEmptyView(
              title: '没有匹配的题库',
              icon: Icons.search_off_outlined,
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.listGutter,
              0,
              AppSpacing.listGutter,
              AppSpacing.xl,
            ),
            sliver: SliverList.builder(
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final entry = filtered[index];
                final stats = entry.stats;
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: PlainListGroup(
                    children: [
                      PlainListRow(
                        title: entry.bank.name,
                        subtitle:
                            '${entry.bank.questionCount} 题 · 已练 ${stats.uniqueAnswered}'
                            '${stats.accuracy == null ? '' : ' · 正确率 ${stats.accuracy}%'}',
                        value: '${stats.progress}%',
                        onTap: () => _showBankSheet(entry.bank),
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

  String _resumeSubtitle(PracticeSessionRecord session) {
    final typeLabel = session.typeFilter?.label;
    return typeLabel == null
        ? session.mode.label
        : '${session.mode.label} · $typeLabel';
  }
}

class _HomeStatsCard extends StatelessWidget {
  const _HomeStatsCard({required this.stats});

  final HomeStats stats;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    return PlainListGroup(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _StatMetric(
                      label: '已练题数',
                      value: '${stats.answered}/${stats.totalQuestions}',
                    ),
                  ),
                  Expanded(
                    child: _StatMetric(
                      label: '完成进度',
                      value: '${stats.completionPct}%',
                    ),
                  ),
                  if (stats.accuracy != null)
                    Expanded(
                      child: _StatMetric(
                        label: '总体正确率',
                        value: '${stats.accuracy}%',
                        accent: cs.primary,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text('近 7 天正确率', style: text.meta),
              const SizedBox(height: AppSpacing.sm),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final (i, day) in stats.dailyAccuracy.indexed) ...[
                    if (i > 0) const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: _DailyAccuracyBar(
                        label: day.label,
                        value: day.value,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatMetric extends StatelessWidget {
  const _StatMetric({required this.label, required this.value, this.accent});

  final String label;
  final String value;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final text = context.appText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: accent == null
              ? text.numValue
              : text.numValue.copyWith(color: accent),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(label, style: text.meta),
      ],
    );
  }
}

class _DailyAccuracyBar extends StatelessWidget {
  const _DailyAccuracyBar({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    const trackHeight = 34.0;
    final clamped = value.clamp(0, 100);
    final barHeight = clamped == 0
        ? 0.0
        : math.max(4.0, trackHeight * clamped / 100);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: trackHeight,
          width: double.infinity,
          alignment: Alignment.bottomCenter,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppRadius.tag),
          ),
          child: barHeight > 0
              ? Container(
                  height: barHeight,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: cs.primary,
                    borderRadius: BorderRadius.circular(AppRadius.tag),
                  ),
                )
              : null,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(label, maxLines: 1, overflow: TextOverflow.clip, style: text.tag),
      ],
    );
  }
}

class _BankActionSheet extends StatefulWidget {
  const _BankActionSheet({
    required this.bank,
    required this.questions,
    required this.records,
    required this.wrongCount,
    required this.favoriteCount,
    required this.onStartPractice,
    required this.onOpenWrongBook,
    required this.onRename,
    required this.onExportJson,
    required this.onDelete,
  });

  final QuestionBank bank;
  final List<Question> questions;
  final List<PracticeRecord> records;
  final int wrongCount;
  final int favoriteCount;
  final void Function(PracticeMode mode, Map<String, String> query)
  onStartPractice;
  final VoidCallback onOpenWrongBook;
  final VoidCallback onRename;
  final VoidCallback onExportJson;
  final VoidCallback onDelete;

  @override
  State<_BankActionSheet> createState() => _BankActionSheetState();
}

class _BankActionSheetState extends State<_BankActionSheet> {
  QuestionType? _typeFilter;
  int? _randomCount;
  int? _examCount;

  Future<void> _pickCustomRandomCount(int unanswered) async {
    final raw = await showGlassDialog<String>(
      context: context,
      builder: (_) => _TextPromptDialog(
        title: '自定义随机题数',
        initialValue: '${_randomCount ?? math.min(20, unanswered)}',
        hintText: '1 ~ $unanswered（未做题数）',
        confirmLabel: '确定',
        keyboardType: TextInputType.number,
      ),
    );
    if (raw == null || raw.isEmpty || !mounted) return;
    final parsed = num.tryParse(raw);
    if (parsed == null) return;
    setState(() {
      _randomCount = clampCustomRandomCount(parsed, unanswered);
    });
  }

  void _start(PracticeMode mode) {
    final query = <String, String>{
      if (_typeFilter != null) 'type': _typeFilter!.name,
      if (mode == PracticeMode.exam && _examCount != null)
        'examCount': '$_examCount',
      if (mode == PracticeMode.random && _randomCount != null)
        'randomCount': '$_randomCount',
    };
    widget.onStartPractice(mode, query);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final allSummary = summarizeForModes(
      questions: widget.questions,
      records: widget.records,
    );
    final summary = summarizeForModes(
      questions: widget.questions,
      records: widget.records,
      selectedType: _typeFilter,
    );
    final presentTypes = [
      for (final t in QuestionType.values)
        if ((allSummary.typeCounts[t] ?? 0) > 0) t,
    ];
    final effectiveExamCount =
        _examCount != null && summary.examOptions.contains(_examCount)
        ? _examCount
        : null;

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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PlainSectionHeader(widget.bank.name),
              if (presentTypes.length > 1) ...[
                AppFilterChips<QuestionType?>(
                  padding: EdgeInsets.zero,
                  wrap: true,
                  options: [
                    AppFilterOption(null, '全部 ${widget.questions.length}'),
                    for (final t in presentTypes)
                      AppFilterOption(
                        t,
                        '${t.label} ${allSummary.typeCounts[t]}',
                      ),
                  ],
                  selected: _typeFilter,
                  onSelected: (type) {
                    setState(() {
                      _typeFilter = type;
                      _randomCount = null;
                      _examCount = null;
                    });
                  },
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              PlainListGroup(
                children: [
                  PlainListRow(
                    title: PracticeMode.sequential.label,
                    value: '${summary.totalCount} 题',
                    onTap: () => _start(PracticeMode.sequential),
                  ),
                  PlainListRow(
                    title: PracticeMode.random.label,
                    value: _randomCount == null ? '全库' : '未做 $_randomCount 题',
                    onTap: () => _start(PracticeMode.random),
                  ),
                  PlainListRow(
                    title: '错题练习',
                    value: '${widget.wrongCount} 题',
                    onTap: () => _start(PracticeMode.wrong),
                  ),
                  PlainListRow(
                    title: PracticeMode.favorite.label,
                    value: '${widget.favoriteCount} 题',
                    onTap: () => _start(PracticeMode.favorite),
                  ),
                  PlainListRow(
                    title: PracticeMode.exam.label,
                    value: effectiveExamCount == null
                        ? '全部 ${summary.totalCount} 题'
                        : '$effectiveExamCount 题',
                    onTap: () => _start(PracticeMode.exam),
                  ),
                ],
              ),
              if (summary.randomOptions.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                const PlainSectionHeader('随机抽题数（从未做题中抽取）'),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    _OptionChip(
                      label: '全库随机',
                      selected: _randomCount == null,
                      onTap: () => setState(() => _randomCount = null),
                    ),
                    for (final n in summary.randomOptions)
                      _OptionChip(
                        label: n == summary.unansweredCount
                            ? '全部未做 ($n)'
                            : '$n 题',
                        selected: _randomCount == n,
                        onTap: () => setState(() => _randomCount = n),
                      ),
                    _OptionChip(
                      label:
                          _randomCount != null &&
                              !summary.randomOptions.contains(_randomCount)
                          ? '自定义 ($_randomCount)'
                          : '自定义',
                      selected:
                          _randomCount != null &&
                          !summary.randomOptions.contains(_randomCount),
                      onTap: () =>
                          _pickCustomRandomCount(summary.unansweredCount),
                    ),
                  ],
                ),
              ],
              if (summary.examOptions.length > 1) ...[
                const SizedBox(height: AppSpacing.md),
                const PlainSectionHeader('模拟考试题数'),
                AppFilterChips<int?>(
                  padding: EdgeInsets.zero,
                  wrap: true,
                  options: [
                    for (final n in summary.examOptions)
                      AppFilterOption(
                        n == summary.totalCount ? null : n,
                        n == summary.totalCount ? '全部 ($n)' : '$n 题',
                      ),
                  ],
                  selected: effectiveExamCount,
                  onSelected: (count) => setState(() => _examCount = count),
                ),
              ],
              const SizedBox(height: AppSpacing.listGroupGap),
              const PlainSectionHeader('题库管理'),
              PlainListGroup(
                children: [
                  PlainListRow(
                    title: '错题本',
                    value: '${widget.wrongCount}',
                    onTap: widget.onOpenWrongBook,
                  ),
                  PlainListRow(title: '重命名题库', onTap: widget.onRename),
                  PlainListRow(title: '导出题库 JSON', onTap: widget.onExportJson),
                  PlainListRow(
                    title: '删除题库',
                    titleColor: cs.error,
                    showChevron: false,
                    onTap: widget.onDelete,
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

class _OptionChip extends StatelessWidget {
  const _OptionChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
      selectedColor: cs.secondaryContainer,
      backgroundColor: cs.surfaceContainerHighest,
      labelStyle: context.appText.secondary.copyWith(
        color: selected ? cs.onSecondaryContainer : cs.onSurfaceVariant,
      ),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.chipBorder),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

/// 在弹窗路由完全卸载后才释放 [TextEditingController]，避免退场动画期间报错。
class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.initialValue,
    required this.hintText,
    required this.confirmLabel,
    this.keyboardType,
  });

  final String title;
  final String initialValue;
  final String hintText;
  final String confirmLabel;
  final TextInputType? keyboardType;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: widget.keyboardType,
        decoration: InputDecoration(hintText: widget.hintText),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}
