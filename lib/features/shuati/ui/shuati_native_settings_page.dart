/// 原生刷题设置页：备份导出 / 合并与覆盖恢复 / 旧版过渡入口 / 清空数据。没有 AI 设置。
library;

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../shared/widgets/app_app_bar.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../../../shared/widgets/plain_list.dart';
import '../backup/backup_exporter.dart';
import '../backup/backup_importer.dart';
import '../backup/backup_models.dart';
import '../migration/shuati_legacy_migration_service.dart';
import 'shuati_services.dart';

class ShuatiNativeSettingsPage extends StatefulWidget {
  const ShuatiNativeSettingsPage({super.key});

  @override
  State<ShuatiNativeSettingsPage> createState() =>
      _ShuatiNativeSettingsPageState();
}

class _ShuatiNativeSettingsPageState extends State<ShuatiNativeSettingsPage> {
  bool _busy = false;
  ShuatiBackupImportReport? _report;
  String? _reportTitle;

  String get _stamp {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Future<void> _guard(Future<void> Function() action, String failure) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (messenger != null) AppFeedback.toastOn(messenger, failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export({required bool share}) => _guard(() async {
    final store = await ShuatiServices.instance.store();
    final bytes = await ShuatiBackupExporter(store).exportZip();
    final io = ShuatiServices.instance.io;
    final name = '刷题助手备份_$_stamp.zip';
    if (share) {
      await io.shareFile(name, bytes);
      return;
    }
    final path = await io.saveFile(name, bytes);
    if (path != null && mounted) {
      AppFeedback.toast(context, '备份已保存');
    }
  }, '导出失败');

  Future<void> _restore(BackupImportMode mode) async {
    if (mode == BackupImportMode.replaceAll) {
      final confirmed = await AppFeedback.confirm(
        context,
        title: '覆盖全部数据？',
        message: '将清空当前全部题库、做题记录、收藏和错题，并以所选备份内容替换。',
        confirmLabel: '选择备份并覆盖',
        destructive: true,
      );
      if (!confirmed || !mounted) return;
    }
    await _guard(() async {
      final io = ShuatiServices.instance.io;
      final file = await io.pickFile(extensions: const ['zip', 'json']);
      if (file == null || !mounted) return;
      final store = await ShuatiServices.instance.store();
      final report = await ShuatiBackupImporter(store)
          .importBytes(file.bytes, mode: mode);
      if (mounted) {
        setState(() {
          _report = report;
          _reportTitle = null;
        });
      }
    }, '恢复失败：文件不是有效的刷题助手备份');
  }

  /// 从旧版 WebView 自动迁移：只读旧数据、幂等合并，绝不删除本地或旧数据。
  Future<void> _migrateLegacy() async {
    final confirmed = await AppFeedback.confirm(
      context,
      title: '从旧版迁移数据？',
      message:
          '自动读取旧版刷题助手的题库、做题记录、收藏、错题与练习进度，'
          '合并到当前版本（不覆盖已有内容，可重复执行）。旧版数据不会被删除。',
      confirmLabel: '开始迁移',
    );
    if (!confirmed || !mounted) return;
    await _guard(() async {
      final store = await ShuatiServices.instance.store();
      final migration = ShuatiServices.instance.createLegacyMigration(store);
      if (migration == null) {
        if (mounted) AppFeedback.toast(context, '当前环境不支持自动迁移');
        return;
      }
      final outcome = await migration.migrateNow();
      if (!mounted) return;
      switch (outcome.status) {
        case ShuatiLegacyMigrationStatus.migrated:
          setState(() {
            _report = outcome.report;
            _reportTitle = '迁移结果';
          });
          final report = outcome.report!;
          if (report.banks.added + report.questions.added > 0) {
            AppFeedback.toast(
              context,
              '已迁移 ${report.banks.added} 个题库、'
              '${report.questions.added} 道题目',
            );
          } else {
            AppFeedback.toast(context, '迁移完成：没有新增内容（可能已迁移过）');
          }
        case ShuatiLegacyMigrationStatus.noLegacyData:
          AppFeedback.toast(context, '未检测到旧版数据');
        case ShuatiLegacyMigrationStatus.skipped:
          AppFeedback.toast(context, '本次未执行迁移');
        case ShuatiLegacyMigrationStatus.failed:
          AppFeedback.toast(context, outcome.error ?? '迁移失败，请重试');
      }
    }, '迁移失败，请重试');
  }

  Future<void> _clear() async {
    final first = await AppFeedback.confirm(
      context,
      title: '清空所有数据？',
      message: '将删除全部题库、做题记录、收藏和错题。',
      confirmLabel: '继续',
      destructive: true,
    );
    if (!first || !mounted) return;
    final second = await AppFeedback.confirm(
      context,
      title: '再次确认',
      message: '此操作无法撤销，确定清空？',
      confirmLabel: '清空',
      destructive: true,
    );
    if (!second || !mounted) return;
    await _guard(() async {
      final store = await ShuatiServices.instance.store();
      await store.banks.clearAll();
      if (mounted) AppFeedback.toast(context, '所有数据已清空');
    }, '清空失败');
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Scaffold(
      appBar: AppAppBar(title: const Text('刷题设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.listGutter,
          AppSpacing.md,
          AppSpacing.listGutter,
          AppSpacing.xl,
        ),
        children: [
          if (_busy) const LinearProgressIndicator(),
          const PlainSectionHeader('备份'),
          PlainListGroup(
            children: [
              PlainListRow(
                title: '导出备份到文件',
                onTap: _busy ? null : () => _export(share: false),
              ),
              PlainListRow(
                title: '分享备份',
                onTap: _busy ? null : () => _export(share: true),
              ),
              PlainListRow(
                title: '恢复备份（合并）',
                onTap: _busy ? null : () => _restore(BackupImportMode.merge),
              ),
              PlainListRow(
                title: '恢复备份（覆盖全部）',
                titleColor: Theme.of(context).colorScheme.error,
                onTap: _busy
                    ? null
                    : () => _restore(BackupImportMode.replaceAll),
              ),
            ],
          ),
          if (report != null) ...[
            const SizedBox(height: AppSpacing.listGroupGap),
            ShuatiBackupReportView(report: report, title: _reportTitle),
          ],
          const SizedBox(height: AppSpacing.listGroupGap),
          const PlainSectionHeader('旧版迁移'),
          PlainListGroup(
            children: [
              PlainListRow(
                title: '从旧版自动迁移',
                subtitle: '读取旧版题库、记录与进度并合并到当前版本，不删除旧数据',
                onTap: _busy ? null : _migrateLegacy,
              ),
              PlainListRow(
                title: '打开旧版刷题助手（手动导出）',
                subtitle: '自动迁移失败时，可在旧页面设置中导出 ZIP 后回到此处恢复',
                onTap: _busy ? null : () => context.pushNamed('shuati-legacy'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.listGroupGap),
          const PlainSectionHeader('数据'),
          PlainListGroup(
            children: [
              PlainListRow(
                title: '清空所有数据',
                titleColor: Theme.of(context).colorScheme.error,
                showChevron: false,
                onTap: _busy ? null : _clear,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 备份导入报告：各集合新增 / 重复 / 丢弃计数。
class ShuatiBackupReportView extends StatelessWidget {
  const ShuatiBackupReportView({super.key, required this.report, this.title});

  final ShuatiBackupImportReport report;

  /// 标题前缀（默认「恢复结果」；迁移场景传「迁移结果」）。
  final String? title;

  static String _line(BackupCollectionCounts c) {
    final dropped = c.orphan + c.invalid;
    return '新增 ${c.added} · 重复 ${c.duplicate}'
        '${c.merged > 0 ? ' · 合并 ${c.merged}' : ''}'
        '${dropped > 0 ? ' · 丢弃 $dropped' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PlainSectionHeader('${title ?? '恢复结果'}（V${report.version}）'),
        PlainListGroup(
          children: [
            PlainListRow(title: '题库', value: _line(report.banks)),
            PlainListRow(title: '题目', value: _line(report.questions)),
            PlainListRow(title: '做题记录', value: _line(report.records)),
            PlainListRow(title: '收藏', value: _line(report.favorites)),
            PlainListRow(title: '错题', value: _line(report.wrongQuestions)),
            if (report.droppedAiSettings > 0)
              PlainListRow(
                title: 'AI 设置（不导入）',
                value: '${report.droppedAiSettings}',
              ),
          ],
        ),
      ],
    );
  }
}
