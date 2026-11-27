import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_dropdown.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/external_url_launcher.dart';
import '../../shared/widgets/plain_list.dart';
import 'feedback_service.dart';
import 'feedback_store.dart';

/// 应用内「问题反馈与建议」页面。
///
/// 将表单与可选脱敏诊断日志提交至中转 Worker，自动在 GitHub 仓库创建 Issue；
/// 若网络不可用，支持一键复制格式化 Markdown 到剪贴板作为兜底。
class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key, this.service, this.store});

  final FeedbackService? service;
  final FeedbackStore? store;

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  static const double _contentMaxWidth = 640;

  late final FeedbackService _service;
  late final FeedbackStore _store;
  Timer? _saveTimer;
  bool _draftReady = false;
  bool _draftFailed = false;
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _contactController = TextEditingController();

  FeedbackType _type = FeedbackType.bug;
  FeedbackCampus _campus = FeedbackCampus.lianglin;
  bool _includeDiagnostics = false;
  bool _submitting = false;
  bool _posting = false;
  FeedbackEnvironment? _environment;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? FeedbackService();
    _store = widget.store ?? FeedbackStore.instance;
    unawaited(_restoreDraft());
    for (final controller in [
      _titleController,
      _descriptionController,
      _contactController,
    ]) {
      controller.addListener(_scheduleSave);
    }
    unawaited(_loadEnvironment());
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    final draft = _draftJson;
    if (draft != null && !_draftSubmitted) {
      unawaited(_store.setPreference('draft', draft).catchError((_) {}));
    }
    _titleController.dispose();
    _descriptionController.dispose();
    _contactController.dispose();
    super.dispose();
  }

  String? _draftJson;
  bool _draftSubmitted = false;

  Future<void> _restoreDraft() async {
    try {
      final raw = await _store.preference('draft');
      if (!mounted) return;
      if (raw != null) {
        final draft = Map<String, dynamic>.from(jsonDecode(raw));
        _titleController.text = draft['title'] as String? ?? '';
        _descriptionController.text = draft['description'] as String? ?? '';
        _contactController.text = draft['contact'] as String? ?? '';
        _type = FeedbackType.values.firstWhere(
          (v) => v.apiValue == draft['type'],
          orElse: () => FeedbackType.bug,
        );
        _campus = FeedbackCampus.values.firstWhere(
          (v) => v.name == draft['campus'],
          orElse: () => FeedbackCampus.unspecified,
        );
        // A restored draft must preview a fresh report before attaching logs.
        _includeDiagnostics = false;
      }
      setState(() => _draftReady = true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _draftReady = true;
          _draftFailed = true;
        });
      }
    }
  }

  void _scheduleSave() {
    if (!_draftReady || _submitting || _draftSubmitted) return;
    _saveTimer?.cancel();
    // Capture before disposal; do not read TextEditingControllers from a delayed callback.
    final raw = jsonEncode({
      'title': _titleController.text,
      'description': _descriptionController.text,
      'contact': _contactController.text,
      'type': _type.apiValue,
      'campus': _campus.name,
    });
    _draftJson = raw;
    _saveTimer = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(
        _store.setPreference('draft', raw).catchError((_) {
          if (mounted) setState(() => _draftFailed = true);
        }),
      ),
    );
  }

  Future<void> _loadEnvironment() async {
    try {
      final env = await _service.collectEnvironment();
      if (!mounted) return;
      setState(() => _environment = env);
    } catch (_) {
      /* Submission retries environment collection. */
    }
  }

  Future<FeedbackSubmission?> _buildValidatedSubmission() async {
    final title = _titleController.text.trim();
    final description = _descriptionController.text.trim();
    if (title.length < 2) {
      AppFeedback.toast(context, '请填写至少 2 个字的标题');
      return null;
    }
    if (description.length < 5) {
      AppFeedback.toast(context, '请填写至少 5 个字的详细说明');
      return null;
    }

    final contact = _contactController.text.trim();
    final type = _type;
    final campus = _campus;
    final diagnostics = _includeDiagnostics ? _approvedDiagnostics : null;
    final env = _environment ?? await _service.collectEnvironment();

    return FeedbackSubmission(
      type: type,
      title: title,
      description: description,
      campus: campus,
      contact: contact,
      diagnostics: diagnostics,
      environment: env,
    );
  }

  Future<void> _submit() async {
    if (_submitting) return;
    FocusScope.of(context).unfocus();
    setState(() => _submitting = true);
    FeedbackSubmission? submission;
    try {
      _saveTimer?.cancel();
      if (_draftJson != null) {
        try {
          await _store.setPreference('draft', _draftJson);
        } catch (_) {
          if (mounted) setState(() => _draftFailed = true);
        }
      }
      submission = await _buildValidatedSubmission();
    } catch (_) {
      if (mounted) AppFeedback.toast(context, '无法生成环境报告，请重试');
    }
    if (submission == null || !mounted) {
      if (mounted) setState(() => _submitting = false);
      return;
    }
    final confirmed = await AppFeedback.confirm(
      context,
      title: '确认公开提交',
      message:
          '正文${submission.contact.isEmpty ? '' : '、联系方式'}${submission.diagnostics == null ? '' : '、已预览的诊断日志'}将发布到公开 GitHub Issue，任何人可见。请确认已移除个人敏感信息。',
      confirmLabel: '确认公开并提交',
    );
    if (!confirmed || !mounted) {
      if (mounted) setState(() => _submitting = false);
      return;
    }
    FeedbackSubmitResult? result;
    setState(() => _posting = true);
    try {
      result = await _service.submit(submission);
      _draftSubmitted = true;
      _saveTimer?.cancel();
      try {
        await _store.recordSubmission(submission.title, result);
      } catch (_) {
        if (mounted) {
          AppFeedback.toast(
            context,
            'Issue 已创建，但本机记录保存失败，请记下链接：${result.issueUrl}',
          );
        }
      }
    } on FeedbackSubmitException catch (error) {
      if (mounted) {
        AppFeedback.toast(context, error.message);
      }
      return;
    } catch (_) {
      if (mounted) AppFeedback.toast(context, '无法确认提交结果，请先查看 GitHub，避免重复提交');
      return;
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
          _posting = false;
        });
      }
    }

    if (!mounted) return;
    _titleController.clear();
    _descriptionController.clear();

    final created = result;
    final openIssue = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('提交成功'),
        content: SelectableText(
          '已创建反馈 #${created.issueNumber}，感谢你的帮助！\n${created.issueUrl}',
        ),
        actions: [
          TextButton(
            onPressed: () async {
              try {
                await Clipboard.setData(ClipboardData(text: created.issueUrl));
                if (dialogContext.mounted) {
                  AppFeedback.toast(dialogContext, '已复制 Issue 链接');
                }
              } on PlatformException {
                if (dialogContext.mounted) {
                  AppFeedback.toast(dialogContext, '复制失败，请重试');
                }
              }
            },
            child: const Text('复制链接'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('完成'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('查看 Issue'),
          ),
        ],
      ),
    );
    if (openIssue == true && mounted) {
      await openInExternalBrowser(result.issueUrl, logPrefix: '问题反馈');
    }
    if (mounted) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _copyFallbackText() async {
    try {
      final submission = await _buildValidatedSubmission();
      if (submission == null || !mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      final markdown = _service.buildFallbackMarkdown(submission);
      await Clipboard.setData(ClipboardData(text: markdown));
      AppFeedback.toastOn(messenger, '已复制反馈内容，可直接粘贴到群聊或邮件');
    } catch (_) {
      if (mounted) AppFeedback.toast(context, '复制失败，请重试');
    }
  }

  Future<void> _toggleDiagnostics(bool value) async {
    if (!value) {
      setState(() => _includeDiagnostics = false);
      _scheduleSave();
      return;
    }
    setState(() => _submitting = true);
    try {
      final env = _environment ?? await _service.collectEnvironment();
      final report = await _service.collectDiagnostics(env.appVersion);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('诊断报告预览'),
          content: SizedBox(
            width: 560,
            height: 400,
            child: SingleChildScrollView(child: SelectableText(report)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('不附带'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认附带并公开'),
            ),
          ],
        ),
      );
      if (mounted && confirmed == true) {
        setState(() {
          _includeDiagnostics = true;
          _approvedDiagnostics = report;
        });
      }
    } catch (error) {
      if (mounted) AppFeedback.toast(context, '无法生成报告：$error');
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
        _scheduleSave();
      }
    }
  }

  String? _approvedDiagnostics;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final envSummary = _environment?.summary ?? '正在读取设备与版本信息...';

    return Scaffold(
      appBar: const AppAppBar(title: Text('问题反馈与建议')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              kPlainListGutter,
              12,
              kPlainListGutter,
              32,
            ),
            children: [
              Text(
                '无需 GitHub 账号。反馈正文和自愿提供的联系方式将公开显示在 GitHub，任何人可见。请勿填写学号、密码或 Cookie 等敏感信息。',
                style: context.appText.secondary,
              ),
              if (_draftFailed) const Text('本机草稿存储不可用，请复制文本备份；仍可提交反馈。'),
              const SizedBox(height: 16),
              SegmentedButton<FeedbackType>(
                segments: FeedbackType.values
                    .map(
                      (item) => ButtonSegment<FeedbackType>(
                        value: item,
                        label: Text(item.label),
                        icon: Icon(
                          item == FeedbackType.bug
                              ? Icons.bug_report_outlined
                              : Icons.lightbulb_outline,
                        ),
                      ),
                    )
                    .toList(),
                selected: {_type},
                onSelectionChanged: _submitting || !_draftReady
                    ? null
                    : (selected) {
                        setState(() => _type = selected.first);
                        _scheduleSave();
                      },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _titleController,
                enabled: !_submitting && _draftReady,
                maxLength: 100,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: _type == FeedbackType.bug ? '问题标题' : '建议标题',
                  hintText: _type == FeedbackType.bug
                      ? '例如：实验课表无法导入'
                      : '例如：希望支持自定义首页卡片顺序',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 14),
              AppDropdown<FeedbackCampus>(
                label: '所在校区 / 网络环境',
                expanded: true,
                value: _campus,
                items: FeedbackCampus.values
                    .map(
                      (campus) =>
                          AppDropdownItem(value: campus, label: campus.label),
                    )
                    .toList(),
                onChanged: _submitting || !_draftReady
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() => _campus = value);
                        _scheduleSave();
                      },
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _descriptionController,
                enabled: !_submitting && _draftReady,
                minLines: 5,
                maxLines: 10,
                maxLength: 4000,
                decoration: InputDecoration(
                  labelText: _type == FeedbackType.bug ? '问题描述与复现步骤' : '功能描述',
                  hintText: _type == FeedbackType.bug
                      ? '请简述触发路径、预期结果和实际现象'
                      : '简述使用场景和期望效果',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _contactController,
                enabled: !_submitting && _draftReady,
                maxLength: 80,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: '联系方式（可选）',
                  hintText: 'QQ 或邮箱（将公开，任何人可见）',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '提交后可在 GitHub 查看进度；补充截图或评论需要登录 GitHub。',
                style: context.appText.secondary,
              ),
              const SizedBox(height: kPlainListGroupGap),
              const PlainSectionHeader('附加环境信息'),
              PlainListGroup(
                children: [
                  PlainListRow(
                    title: '自动附带版本与系统',
                    subtitle: envSummary,
                    showChevron: false,
                  ),
                  PlainSwitchRow(
                    title: '附带脱敏诊断日志',
                    subtitle: '默认关闭；预览后选择公开。自动脱敏仍需你检查',
                    value: _includeDiagnostics,
                    enabled: !_submitting && _draftReady,
                    onChanged: _toggleDiagnostics,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _submitting || !_draftReady ? null : _submit,
                icon: _posting
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.onPrimary,
                        ),
                      )
                    : const Icon(Icons.send_outlined),
                label: Text(
                  _posting
                      ? '正在提交...'
                      : _submitting
                      ? '请稍候...'
                      : '提交反馈',
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _submitting ? null : _copyFallbackText,
                icon: const Icon(Icons.copy_outlined, size: 18),
                label: const Text('复制反馈文本（网络不佳时备用）'),
              ),
              TextButton.icon(
                onPressed: _submitting
                    ? null
                    : () => openInExternalBrowser(
                        FeedbackService.githubIssuesUrl,
                        logPrefix: '问题反馈',
                      ),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('查看 GitHub 反馈列表'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
