import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_dropdown.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/external_url_launcher.dart';
import '../../shared/widgets/plain_list.dart';
import 'feedback_service.dart';

/// 应用内「问题反馈与建议」页面。
///
/// 将表单与可选脱敏诊断日志提交至中转 Worker，自动在 GitHub 仓库创建 Issue；
/// 若网络不可用，支持一键复制格式化 Markdown 到剪贴板作为兜底。
class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key, this.service});

  final FeedbackService? service;

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  static const double _contentMaxWidth = 640;

  late final FeedbackService _service;
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _contactController = TextEditingController();

  FeedbackType _type = FeedbackType.bug;
  FeedbackCampus _campus = FeedbackCampus.lianglin;
  bool _includeDiagnostics = false;
  bool _submitting = false;
  FeedbackEnvironment? _environment;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? FeedbackService();
    unawaited(_loadEnvironment());
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _contactController.dispose();
    super.dispose();
  }

  Future<void> _loadEnvironment() async {
    final env = await _service.collectEnvironment();
    if (!mounted) return;
    setState(() => _environment = env);
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

    final env = _environment ?? await _service.collectEnvironment();
    final diagnostics = _includeDiagnostics
        ? await _service.collectDiagnostics(env.appVersion)
        : null;

    return FeedbackSubmission(
      type: _type,
      title: title,
      description: description,
      campus: _campus,
      contact: _contactController.text.trim(),
      diagnostics: diagnostics,
      environment: env,
    );
  }

  Future<void> _submit() async {
    if (_submitting) return;
    FocusScope.of(context).unfocus();
    final submission = await _buildValidatedSubmission();
    if (submission == null || !mounted) return;

    setState(() => _submitting = true);
    FeedbackSubmitResult? result;
    try {
      result = await _service.submit(submission);
    } on FeedbackSubmitException catch (error) {
      if (mounted) {
        AppFeedback.toast(context, error.message);
      }
      return;
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }

    if (!mounted) return;
    _titleController.clear();
    _descriptionController.clear();

    final openIssue = await AppFeedback.confirm(
      context,
      title: '提交成功',
      message: '已创建反馈 #${result.issueNumber}，感谢你的帮助！是否打开页面查看进度？',
      confirmLabel: '查看 Issue',
      cancelLabel: '完成',
    );
    if (openIssue && mounted) {
      await openInExternalBrowser(result.issueUrl, logPrefix: '问题反馈');
    }
    if (mounted) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _copyFallbackText() async {
    final submission = await _buildValidatedSubmission();
    if (submission == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final markdown = _service.buildFallbackMarkdown(submission);
    try {
      await Clipboard.setData(ClipboardData(text: markdown));
      AppFeedback.toastOn(messenger, '已复制反馈内容，可直接粘贴到群聊或邮件');
    } on PlatformException {
      AppFeedback.toastOn(messenger, '复制失败，请重试');
    }
  }

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
                '无需 GitHub 账号，提交后将自动同步至项目 Issue 追踪。请勿填写学号、密码或 Cookie 等个人敏感信息。',
                style: context.appText.secondary,
              ),
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
                onSelectionChanged: _submitting
                    ? null
                    : (selected) {
                        setState(() => _type = selected.first);
                      },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _titleController,
                enabled: !_submitting,
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
                onChanged: _submitting
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() => _campus = value);
                      },
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _descriptionController,
                enabled: !_submitting,
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
                enabled: !_submitting,
                maxLength: 80,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: '联系方式（可选）',
                  hintText: 'QQ 或邮箱，仅用于需要补充信息时联系你',
                  counterText: '',
                ),
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
                    subtitle: '含登录轨迹与近期日志，已自动去除密码和 Cookie',
                    value: _includeDiagnostics,
                    enabled: !_submitting,
                    onChanged: (value) {
                      setState(() => _includeDiagnostics = value);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _submitting ? null : _submit,
                icon: _submitting
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.onPrimary,
                        ),
                      )
                    : const Icon(Icons.send_outlined),
                label: Text(_submitting ? '正在提交...' : '提交反馈'),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _submitting ? null : _copyFallbackText,
                icon: const Icon(Icons.copy_outlined, size: 18),
                label: const Text('复制反馈文本（网络不佳时备用）'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
