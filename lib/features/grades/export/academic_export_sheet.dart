import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/auth/zhengfang_auth.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/app_banner.dart';
import '../../../shared/widgets/app_feedback.dart';
import 'academic_export_builder.dart';
import 'academic_export_capture.dart';
import 'grades_export_serializer.dart';

/// 保存文件的可注入点，测试用替身替换 file_picker；返回保存路径，
/// 用户取消时返回 `null`。
typedef AcademicExportFileSaver = Future<String?> Function(
  String fileName,
  String extension,
  Uint8List bytes,
);

/// 当前生效的文件保存器。
AcademicExportFileSaver academicExportFileSaver =
    defaultAcademicExportFileSaver;

/// 默认实现：file_picker 的「另存为」在移动端会写入字节并返回保存路径。
Future<String?> defaultAcademicExportFileSaver(
  String fileName,
  String extension,
  Uint8List bytes,
) {
  return FilePicker.platform.saveFile(
    dialogTitle: '保存学业数据导出',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: [extension],
    bytes: bytes,
  );
}

/// 系统分享的结果。**只有「用户选了目标应用」才算 [shared]**；
/// 取消分享不是成功，也不意味着数据被上传。
enum AcademicShareOutcome { shared, dismissed, unavailable }

/// 一次分享的载荷：Markdown 以纯文本分享，JSON / CSV 以内存文件分享。
class AcademicSharePayload {
  const AcademicSharePayload({
    required this.fileName,
    required this.mimeType,
    required this.text,
    required this.asText,
  });

  final String fileName;
  final String mimeType;
  final String text;
  final bool asText;
}

/// 系统分享的可注入点（测试替身）。
typedef AcademicExportSharer = Future<AcademicShareOutcome> Function(
  AcademicSharePayload payload,
);

AcademicExportSharer academicExportSharer = defaultAcademicExportSharer;

/// 默认实现：只调用系统分享菜单（Android Sharesheet），不绑定任何 App。
Future<AcademicShareOutcome> defaultAcademicExportSharer(
  AcademicSharePayload payload,
) async {
  final params = payload.asText
      ? ShareParams(text: payload.text, subject: payload.fileName)
      : ShareParams(
          files: [
            XFile.fromData(
              Uint8List.fromList(utf8.encode(payload.text)),
              mimeType: payload.mimeType,
              name: payload.fileName,
            ),
          ],
          fileNameOverrides: [payload.fileName],
          subject: payload.fileName,
        );
  final result = await SharePlus.instance.share(params);
  return switch (result.status) {
    ShareResultStatus.success => AcademicShareOutcome.shared,
    ShareResultStatus.dismissed => AcademicShareOutcome.dismissed,
    ShareResultStatus.unavailable => AcademicShareOutcome.unavailable,
  };
}

/// 打开学业数据导出弹层。只读快照，不触发任何网络请求或服务器写入。
Future<void> showAcademicExportSheet(
  BuildContext context,
  AcademicExportSnapshot snapshot,
) {
  return AppFeedback.sheet<void>(
    context,
    scrollControlled: true,
    builder: (_) => AcademicExportSheet(snapshot: snapshot),
  );
}

/// 当前快照是否仍对应当前已验证的教务账号。
bool _snapshotIsCurrent(AcademicExportSnapshot snapshot) {
  final auth = ZhengfangAuth.instance;
  return auth.isLoggedIn &&
      auth.verifiedStudentId == snapshot.owner &&
      auth.sessionRevision == snapshot.revision;
}

/// 学业数据导出弹层：按模块勾选，Markdown（默认）/ JSON / CSV 预览，
/// 复制、保存或系统分享。
class AcademicExportSheet extends StatefulWidget {
  const AcademicExportSheet({super.key, required this.snapshot});

  final AcademicExportSnapshot snapshot;

  @override
  State<AcademicExportSheet> createState() => _AcademicExportSheetState();
}

class _AcademicExportSheetState extends State<AcademicExportSheet> {
  GradesExportFormat _format = GradesExportFormat.markdown;
  late Set<ExportModule> _modules;
  late bool _allTerms;

  late AcademicExportDocument _document;
  late String _content;

  AcademicExportInput get _input => widget.snapshot.input;

  @override
  void initState() {
    super.initState();
    ZhengfangAuth.instance.addListener(_onAuthChanged);
    // 默认勾选本机已有数据的模块（全是非敏感学业数据）；一个都没有就留成绩，
    // 让用户看到明确的「未获取」。
    final everything = _input.build(modules: ExportModule.values.toSet());
    final available = {
      for (final m in everything.modules)
        if (m.status.hasData) m.module,
    };
    _modules = available.isEmpty ? {ExportModule.grades} : available;
    _allTerms = !_input.hasTermScope;
    _recompute();
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

  bool get _actionable => _valid && _document.hasAnyData;

  void _recompute() {
    _document = _input.build(modules: _modules, gradesAllTerms: _allTerms);
    _content = AcademicExportBuilder.encode(_format, _document);
  }

  void _selectFormat(GradesExportFormat format) {
    setState(() {
      _format = format;
      // CSV 每次只导出一个模块，避免异构表混在一起。
      if (format == GradesExportFormat.csv && _modules.length > 1) {
        final first = ExportModule.values.firstWhere(_modules.contains);
        _modules = {first};
      }
      _recompute();
    });
  }

  void _selectModules(Set<ExportModule> selection) {
    if (selection.isEmpty) return;
    setState(() {
      _modules = selection;
      _recompute();
    });
  }

  void _selectScope(bool allTerms) {
    setState(() {
      _allTerms = allTerms;
      _recompute();
    });
  }

  String get _fileName => AcademicExportBuilder.fileName(_format, _document);

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
      final path = await academicExportFileSaver(
        _fileName,
        _format.extension,
        Uint8List.fromList(utf8.encode(_content)),
      );
      if (messenger == null) return;
      // 用户取消不算保存成功，也不提示。
      if (path == null) return;
      AppFeedback.toastOn(messenger, '已保存到 $path');
    } catch (e) {
      // 只记录异常类型（不含路径 / 内容），提示给用户的是可理解的文案。
      AppLogger.instance.warn('academic export save failed: ${e.runtimeType}');
      if (messenger == null) return;
      AppFeedback.toastOn(messenger, '保存失败，请重试或改用复制');
    }
  }

  Future<void> _share() async {
    if (!_valid) {
      _toastBlocked();
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    final asText = _format == GradesExportFormat.markdown;
    final mime = switch (_format) {
      GradesExportFormat.markdown => 'text/markdown',
      GradesExportFormat.json => 'application/json',
      GradesExportFormat.csv => 'text/csv',
    };
    try {
      final outcome = await academicExportSharer(
        AcademicSharePayload(
          fileName: _fileName,
          mimeType: mime,
          text: _content,
          asText: asText,
        ),
      );
      if (messenger == null) return;
      switch (outcome) {
        case AcademicShareOutcome.shared:
          AppFeedback.toastOn(messenger, '已交给所选应用，其后续处理受对方平台政策约束');
        case AcademicShareOutcome.unavailable:
          AppFeedback.toastOn(messenger, '已打开系统分享菜单');
        case AcademicShareOutcome.dismissed:
          // 取消分享：没有任何数据交出，不提示成功。
          break;
      }
    } catch (e) {
      AppLogger.instance.warn('academic export share failed: ${e.runtimeType}');
      if (messenger == null) return;
      AppFeedback.toastOn(messenger, '无法打开系统分享，请改用复制或保存');
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
    final height = MediaQuery.sizeOf(context).height * 0.78;
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
                    message:
                        '仅导出本机已加载的数据，不会联网获取；默认不含学号、姓名等身份信息。'
                        '分享到外部 AI 后，数据将受目标平台的数据处理政策约束。',
                    icon: Icons.inventory_2_outlined,
                  ),
                  if (!_valid) ...[
                    const SizedBox(height: AppSpacing.sm),
                    const AppBanner(
                      message: '当前账号已变化或已登出，导出已停止。请重新查询后再导出。',
                      tone: AppBannerTone.error,
                      icon: Icons.lock_outline_rounded,
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  _buildModuleSelector(),
                  if (_modules.contains(ExportModule.grades) &&
                      _input.hasTermScope) ...[
                    const SizedBox(height: AppSpacing.md),
                    _buildScopeSelector(),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  _buildMetadata(context),
                  if (_valid) ...[
                    const SizedBox(height: AppSpacing.lg),
                    _buildFormatSelector(),
                    if (_format == GradesExportFormat.csv) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        'CSV 每次导出一个模块，仅含数据表（状态与来源见 Markdown / JSON）。',
                        style: context.appText.meta,
                      ),
                    ],
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
          Expanded(child: Text('导出学业数据', style: context.appText.rowTitle)),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildModuleSelector() {
    final multi = _format != GradesExportFormat.csv;
    return SegmentedButton<ExportModule>(
      key: const Key('academic_export_modules'),
      showSelectedIcon: false,
      multiSelectionEnabled: multi,
      emptySelectionAllowed: false,
      segments: [
        for (final m in ExportModule.values)
          ButtonSegment(value: m, label: Text(m.label)),
      ],
      selected: _modules,
      onSelectionChanged: _selectModules,
    );
  }

  Widget _buildScopeSelector() {
    final label = _input.termScope!.label;
    return SegmentedButton<bool>(
      key: const Key('academic_export_scope'),
      showSelectedIcon: false,
      segments: [
        ButtonSegment(value: false, label: Text('成绩：$label')),
        const ButtonSegment(value: true, label: Text('成绩：全部学期')),
      ],
      selected: {_allTerms},
      onSelectionChanged: (s) => _selectScope(s.first),
    );
  }

  Widget _buildMetadata(BuildContext context) {
    final text = context.appText;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final m in _document.modules)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 72,
                  child: Text(m.module.label, style: text.meta),
                ),
                Expanded(
                  child: Text(
                    _moduleSummary(m),
                    style: text.secondary.copyWith(
                      color: m.status.hasData ? cs.onSurface : cs.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static const String _sep = '\u00B7';

  static String _moduleSummary(ExportModuleData m) {
    if (!m.status.hasData) return '${m.status.label}（本机暂无数据，将标注缺失）';
    final source = m.dataSource ?? '未知';
    final updated = GradesExportSerializer.formatDateTime(m.lastUpdatedAt);
    return '${m.status.label} $_sep ${m.itemCount ?? 0} 条 $_sep '
        '${m.scopeLabel} $_sep 更新 $updated $_sep 来源 $source';
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
      onSelectionChanged: (selection) => _selectFormat(selection.first),
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
    final enabled = _actionable;
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
                onPressed: enabled ? _copy : null,
                icon: const Icon(Icons.content_copy_rounded, size: 18),
                label: const Text('复制'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: enabled ? _save : null,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('保存'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: FilledButton.icon(
                onPressed: enabled ? _share : null,
                icon: const Icon(Icons.ios_share_rounded, size: 18),
                label: const Text('分享'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
