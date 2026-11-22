/// 原生导入页：选文件（JSON/CSV/xlsx/docx/TXT/MD）→ [ShuatiImportService] → 类型化报告与快捷开练。
library;

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_app_bar.dart';
import '../../../shared/widgets/plain_list.dart';
import '../domain/shuati_models.dart';
import '../import/import_models.dart';
import '../import/import_service.dart';
import 'shuati_services.dart';

class ShuatiNativeImportPage extends StatefulWidget {
  const ShuatiNativeImportPage({super.key});

  @override
  State<ShuatiNativeImportPage> createState() => _ShuatiNativeImportPageState();
}

class _ShuatiNativeImportPageState extends State<ShuatiNativeImportPage> {
  final _nameController = TextEditingController();
  bool _busy = false;
  ShuatiImportReport? _report;
  String? _failure;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickAndImport() async {
    setState(() {
      _busy = true;
      _report = null;
      _failure = null;
    });
    try {
      final io = ShuatiServices.instance.io;
      final file = await io.pickFile(
        extensions: const ['json', 'csv', 'xlsx', 'docx', 'txt', 'md'],
      );
      if (file == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final store = await ShuatiServices.instance.store();
      final name = _nameController.text.trim();
      final report = await ShuatiImportService(store).importFile(
        bytes: file.bytes,
        fileName: file.name,
        bankName: name.isEmpty ? null : name,
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

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final importedBank = report?.bank;
    return Scaffold(
      appBar: AppAppBar(title: const Text('导入题库')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.listGutter,
          AppSpacing.md,
          AppSpacing.listGutter,
          AppSpacing.xl,
        ),
        children: [
          TextField(
            controller: _nameController,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: '题库名称（可选）',
              hintText: '留空则使用文件名',
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton.icon(
            onPressed: _busy ? null : _pickAndImport,
            icon: const Icon(Icons.file_open_outlined),
            label: Text(_busy ? '正在导入…' : '选择文件'),
          ),
          if (_busy) ...[
            const SizedBox(height: AppSpacing.md),
            const LinearProgressIndicator(),
          ],
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
            if (importedBank != null && importedBank.questionCount > 0) ...[
              const SizedBox(height: AppSpacing.lg),
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
            ],
          ],
        ],
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
