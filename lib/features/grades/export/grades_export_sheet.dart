import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/auth/zhengfang_auth.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_banner.dart';
import '../../../shared/widgets/app_feedback.dart';
import '../grades_model.dart';
import 'grades_export_serializer.dart';

/// 一次成绩导出的快照：把「打开弹层那一刻」的已加载成绩与所属身份一起冻结。
///
/// [owner] / [revision] 是弹层存活期间的有效性凭据：账号切换 / 登出 / 同账号
/// 重登都会让弹层立即失效，避免导出上一个账号的残留数据。
class GradesExportSnapshot {
  const GradesExportSnapshot({
    required this.owner,
    required this.revision,
    required this.grades,
    required this.scope,
    required this.exportedAt,
    this.lastUpdatedAt,
    this.dataSource,
  });

  final String owner;
  final int revision;
  final List<GradeEntry> grades;
  final GradesExportScope scope;
  final DateTime exportedAt;
  final DateTime? lastUpdatedAt;

  /// 数据来源；页面无法确证时为 `null`，如实显示「未知」。
  final String? dataSource;

  GradesExportDocument toDocument() => GradesExportDocument(
    exportedAt: exportedAt,
    scope: scope,
    records: [for (final g in grades) GradesExportRecord.fromEntry(g)],
    lastUpdatedAt: lastUpdatedAt,
    dataSource: dataSource,
  );
}

/// 保存文件的可注入点，测试用替身替换 file_picker；返回保存路径，
/// 用户取消时返回 `null`。
typedef GradesExportFileSaver = Future<String?> Function(
  String fileName,
  String extension,
  Uint8List bytes,
);

/// 当前生效的文件保存器。
GradesExportFileSaver gradesExportFileSaver = defaultGradesExportFileSaver;

/// 默认实现：file_picker 的「另存为」在移动端会写入字节并返回保存路径。
Future<String?> defaultGradesExportFileSaver(
  String fileName,
  String extension,
  Uint8List bytes,
) {
  return FilePicker.platform.saveFile(
    dialogTitle: '保存成绩导出',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: [extension],
    bytes: bytes,
  );
}

/// 打开成绩导出预览弹层。只读快照，不触发任何网络请求或服务器写入。
Future<void> showGradesExportSheet(
  BuildContext context,
  GradesExportSnapshot snapshot,
) {
  return AppFeedback.sheet<void>(
    context,
    scrollControlled: true,
    builder: (_) => GradesExportSheet(snapshot: snapshot),
  );
}

/// 当前快照是否仍对应当前已验证的教务账号。
bool _snapshotIsCurrent(GradesExportSnapshot snapshot) {
  final auth = ZhengfangAuth.instance;
  return auth.isLoggedIn &&
      auth.verifiedStudentId == snapshot.owner &&
      auth.sessionRevision == snapshot.revision;
}

/// 成绩导出预览 / 操作弹层：Markdown（默认）/ JSON / CSV 预览，复制或保存。
class GradesExportSheet extends StatefulWidget {
  const GradesExportSheet({super.key, required this.snapshot});

  final GradesExportSnapshot snapshot;

  @override
  State<GradesExportSheet> createState() => _GradesExportSheetState();
}

class _GradesExportSheetState extends State<GradesExportSheet> {
  GradesExportFormat _format = GradesExportFormat.markdown;

  @override
  void initState() {
    super.initState();
    ZhengfangAuth.instance.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    ZhengfangAuth.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  bool get _valid => _snapshotIsCurrent(widget.snapshot);

  GradesExportDocument get _document => widget.snapshot.toDocument();

  String get _content => GradesExportSerializer.encode(_format, _document);

  String get _fileName {
    final t = widget.snapshot.exportedAt;
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}';
    return '成绩导出_$stamp.${_format.extension}';
  }

  Future<void> _copy() async {
    if (!_valid) {
      _toastBlocked();
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    final label = _format.label;
    var copied = false;
    try {
      await Clipboard.setData(ClipboardData(text: _content));
      copied = true;
    } on PlatformException {
      copied = false;
    }
    if (messenger == null) return;
    AppFeedback.toastOn(messenger, copied ? '已复制$label' : '复制失败');
  }

  Future<void> _save() async {
    if (!_valid) {
      _toastBlocked();
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final path = await gradesExportFileSaver(
        _fileName,
        _format.extension,
        Uint8List.fromList(utf8.encode(_content)),
      );
      if (messenger == null) return;
      // 用户取消不算保存成功，也不提示。
      if (path == null) return;
      AppFeedback.toastOn(messenger, '已保存到 $path');
    } catch (e) {
      if (messenger == null) return;
      AppFeedback.toastOn(messenger, '保存失败：$e');
    }
  }

  void _toastBlocked() {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    AppFeedback.toastOn(messenger, '当前账号已变化，已停止导出');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final height = MediaQuery.sizeOf(context).height * 0.72;
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.pageMargin,
                0,
                AppSpacing.pageMargin,
                AppSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const AppBanner(
                    message: '仅导出当前已加载成绩（不会重新联网获取）',
                    icon: Icons.inventory_2_outlined,
                  ),
                  if (!_valid) ...[
                    const SizedBox(height: AppSpacing.sm),
                    const AppBanner(
                      message: '当前账号已变化或已登出，导出已停止。请重新查询成绩后再导出。',
                      tone: AppBannerTone.error,
                      icon: Icons.lock_outline_rounded,
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  _buildMetadata(context),
                  if (_valid) ...[
                    const SizedBox(height: AppSpacing.lg),
                    _buildFormatSelector(),
                    const SizedBox(height: AppSpacing.md),
                    _buildPreview(cs),
                  ],
                ],
              ),
            ),
          ),
          _buildActions(context),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '导出成绩',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildMetadata(BuildContext context) {
    final text = context.appText;
    final cs = Theme.of(context).colorScheme;
    final doc = _document;
    final rows = <(String, String)>[
      ('学期范围', widget.snapshot.scope.label),
      ('课程数', '${doc.records.length}'),
      ('学分合计', doc.totalCredits.toStringAsFixed(1)),
      ('最后更新', _formatKnownTime(widget.snapshot.lastUpdatedAt)),
      ('数据来源', widget.snapshot.dataSource ?? '未知'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 72, child: Text(label, style: text.meta)),
                Expanded(
                  child: Text(
                    value,
                    style: text.secondary.copyWith(color: cs.onSurface),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildFormatSelector() {
    return SegmentedButton<GradesExportFormat>(
      key: const Key('grades_export_format'),
      showSelectedIcon: false,
      segments: [
        for (final f in GradesExportFormat.values)
          ButtonSegment(value: f, label: Text(f.label)),
      ],
      selected: {_format},
      onSelectionChanged: (selection) =>
          setState(() => _format = selection.first),
    );
  }

  Widget _buildPreview(ColorScheme cs) {
    return Container(
      height: 180,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: AppRadius.cardBorder,
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: SingleChildScrollView(
        child: SelectableText(
          _content,
          style: context.appText.meta.copyWith(
            fontFamily: 'monospace',
            color: cs.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    return SafeArea(
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
              child: OutlinedButton.icon(
                onPressed: _valid ? _copy : null,
                icon: const Icon(Icons.content_copy_rounded, size: 18),
                label: const Text('复制'),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: FilledButton.icon(
                onPressed: _valid ? _save : null,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('保存到文件'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatKnownTime(DateTime? value) {
    if (value == null) return '未知';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }
}
