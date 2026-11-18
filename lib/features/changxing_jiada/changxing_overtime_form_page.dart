import 'package:material_ui/material_ui.dart';

import 'changxing_form_support.dart';
import 'changxing_jiada_form_validator.dart';
import 'changxing_jiada_service.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../shared/widgets/app_app_bar.dart';

class ChangxingOvertimeFormPage extends StatefulWidget {
  const ChangxingOvertimeFormPage({
    super.key,
    this.applicationId,
    this.service,
  });

  final int? applicationId;

  /// 测试注入点；默认走 [ChangxingJiadaService.instance]。
  final ChangxingJiadaService? service;

  @override
  State<ChangxingOvertimeFormPage> createState() =>
      _ChangxingOvertimeFormPageState();
}

class _ChangxingOvertimeFormPageState extends State<ChangxingOvertimeFormPage> {
  final _reasonController = TextEditingController();

  bool _loading = true;
  bool _submitting = false;

  ChangxingJiadaService get _service =>
      widget.service ?? ChangxingJiadaService.instance;

  bool get _isEdit => (widget.applicationId ?? 0) > 0;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    setState(() => _loading = true);
    if (!_isEdit) {
      setState(() => _loading = false);
      return;
    }

    final loaded = await loadChangxingForm(this, () async {
      final detail = await _service.fetchApplicationDetail(
        widget.applicationId!,
      );
      _reasonController.text = detail.descr;
    });
    if (!loaded) return;
    setState(() => _loading = false);
  }

  Future<void> _submit() async {
    final reasonMessage = ChangxingFormValidator.validateReason(
      _reasonController.text,
      emptyMessage: '超时事由为空',
      tooLongMessage: '超时理由过长，最多200字',
    );
    if (reasonMessage != null) {
      changxingToast(this, reasonMessage);
      return;
    }

    await submitChangxingForm(
      this,
      isEdit: _isEdit,
      setSubmitting: (value) => setState(() => _submitting = value),
      submit: () async {
        await _service.submitOvertime(
          id: widget.applicationId,
          descr: _reasonController.text.trim(),
        );
        return true;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(title: Text(_isEdit ? '编辑超时登记' : '超时登记')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(AppSpacing.pageMargin),
              children: [
                TextField(
                  controller: _reasonController,
                  minLines: 5,
                  maxLines: 7,
                  maxLength: 200,
                  decoration: const InputDecoration(
                    labelText: '超时事由',
                    border: OutlineInputBorder(),
                    hintText: '请输入超时事由',
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: Text(
                    _submitting ? '提交中...' : (_isEdit ? '确认修改' : '提交'),
                  ),
                ),
              ],
            ),
    );
  }
}
