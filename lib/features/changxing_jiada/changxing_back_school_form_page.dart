import 'package:material_ui/material_ui.dart';

import 'changxing_form_support.dart';
import 'changxing_jiada_form_validator.dart';
import 'changxing_jiada_model.dart';
import 'changxing_jiada_service.dart';
import 'changxing_jiada_widgets.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_dropdown.dart';
import '../../shared/widgets/plain_list.dart';

class ChangxingBackSchoolFormPage extends StatefulWidget {
  const ChangxingBackSchoolFormPage({
    super.key,
    this.applicationId,
    this.service,
  });

  final int? applicationId;

  /// 测试注入点；默认走 [ChangxingJiadaService.instance]。
  final ChangxingJiadaService? service;

  @override
  State<ChangxingBackSchoolFormPage> createState() =>
      _ChangxingBackSchoolFormPageState();
}

class _ChangxingBackSchoolFormPageState
    extends State<ChangxingBackSchoolFormPage> {
  final _userPhoneController = TextEditingController();
  final _nativePlaceController = TextEditingController();
  final _emergencyContactController = TextEditingController();
  final _emergencyPhoneController = TextEditingController();
  final _trafficDetailController = TextEditingController();
  final _notBackReasonController = TextEditingController();

  final List<String> _trafficOptions = <String>['飞机', '火车', '客车', '自驾'];

  bool _loading = true;
  bool _submitting = false;
  bool _uploadingAttachment = false;

  int? _backStatus;
  bool _promiseChecked = false;
  DateTime? _reportDate;
  String? _trafficTool;

  ChangxingAreaSelection? _areaSelection;

  String _imageMd5 = '';
  String _attachmentMd5 = '';
  String _attachmentLabel = '';

  ChangxingJiadaService get _service =>
      widget.service ?? ChangxingJiadaService.instance;

  bool get _isEdit => (widget.applicationId ?? 0) > 0;

  bool get _isNormalBack => _backStatus == 0;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  @override
  void dispose() {
    _userPhoneController.dispose();
    _nativePlaceController.dispose();
    _emergencyContactController.dispose();
    _emergencyPhoneController.dispose();
    _trafficDetailController.dispose();
    _notBackReasonController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    setState(() => _loading = true);
    final loaded = await loadChangxingForm(this, () async {
      if (_isEdit) {
        final detail = await _service.fetchApplicationDetail(
          widget.applicationId!,
        );
        _userPhoneController.text = detail.userPhone;
        _nativePlaceController.text = detail.nativePlace;
        _emergencyContactController.text = detail.emergencyContact;
        _emergencyPhoneController.text = detail.emergencyPhone;
        _reportDate = detail.startTime;
        _backStatus = detail.backStatus;
        _notBackReasonController.text = detail.notBackReason;
        _imageMd5 = detail.img;
        _attachmentMd5 = detail.annex;
        _attachmentLabel = _attachmentMd5.isEmpty
            ? ''
            : '已上传附件（${_attachmentMd5.substring(0, 8)}...）';

        if (detail.fromAreaCode > 0) {
          _areaSelection = await buildChangxingAreaSelection(
            _service,
            detail.fromAreaCode,
          );
        }

        if (_trafficOptions.contains(detail.trafficTool)) {
          _trafficTool = detail.trafficTool;
          _trafficDetailController.text = detail.trafficDetail;
        } else {
          _trafficTool = null;
          _trafficDetailController.text = detail.trafficDetail.isNotEmpty
              ? detail.trafficDetail
              : detail.trafficTool;
        }

        _promiseChecked = _backStatus == 0;
      } else {
        final profile = await _service.fetchUserProfile();
        _userPhoneController.text = profile.phone;
        _emergencyContactController.text = profile.emergencyContact;
        _emergencyPhoneController.text = profile.emergencyPhone;
      }
    });
    if (!loaded) return;
    setState(() => _loading = false);
  }

  Future<void> _pickArea() async {
    final selection = await pickChangxingArea(
      this,
      _service,
      initialAreaId: _areaSelection?.id,
    );
    if (selection == null) return;
    setState(() => _areaSelection = selection);
  }

  Future<void> _pickReportDate() async {
    final initial = _reportDate ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime(2100, 12, 31),
    );
    if (date == null || !mounted) return;
    setState(() => _reportDate = date);
  }

  Future<void> _pickAttachment() => uploadChangxingAttachmentWithFeedback(
    this,
    _service,
    setUploading: (value) => setState(() => _uploadingAttachment = value),
    onUploaded: (attachment) => setState(() {
      _attachmentMd5 = attachment.md5;
      _attachmentLabel = attachment.label;
    }),
  );

  Future<void> _submit() async {
    if (_backStatus == null) {
      changxingToast(this, '请选择报到状态');
      return;
    }

    if (!ChangxingFormValidator.isPhone(_userPhoneController.text)) {
      changxingToast(this, '请输入正确的手机号');
      return;
    }

    final contactMessage = ChangxingFormValidator.validateContactName(
      _emergencyContactController.text,
    );
    if (contactMessage != null) {
      changxingToast(this, contactMessage);
      return;
    }

    if (!ChangxingFormValidator.isPhone(_emergencyPhoneController.text)) {
      changxingToast(this, '请输入正确的紧急联系人手机号');
      return;
    }

    if (ChangxingFormValidator.isBlank(_nativePlaceController.text)) {
      changxingToast(this, '请填写籍贯');
      return;
    }

    if (_areaSelection == null) {
      changxingToast(this, '请选择生源所在地');
      return;
    }

    if (_isNormalBack) {
      if (_reportDate == null) {
        changxingToast(this, '请选择报到日期');
        return;
      }

      if ((_trafficTool ?? '').isEmpty) {
        changxingToast(this, '请选择交通方式');
        return;
      }

      if (ChangxingFormValidator.isBlank(_trafficDetailController.text)) {
        changxingToast(this, '请填写交通信息详情');
        return;
      }

      if (!_promiseChecked) {
        changxingToast(this, '如正常报到，请勾选承诺');
        return;
      }
    } else {
      final notBackReasonMessage = ChangxingFormValidator.validateNotBackReason(
        _notBackReasonController.text,
      );
      if (notBackReasonMessage != null) {
        changxingToast(this, notBackReasonMessage);
        return;
      }
    }

    await submitChangxingForm(
      this,
      isEdit: _isEdit,
      setSubmitting: (value) => setState(() => _submitting = value),
      submit: () async {
        final enabled = await _service.fetchFanxiaoEnableFlag();
        if (!enabled) {
          changxingToast(this, '报到登记暂未开放，请联系管理员');
          return false;
        }

        await _service.submitBackSchool(
          id: widget.applicationId,
          userPhone: _userPhoneController.text.trim(),
          startTime: _reportDate ?? DateTime.now(),
          trafficTool: _trafficTool ?? '',
          trafficDetail: _trafficDetailController.text.trim(),
          nativePlace: _nativePlaceController.text.trim(),
          fromAreaCode: _areaSelection!.id,
          emergencyContact: _emergencyContactController.text.trim(),
          emergencyPhone: _emergencyPhoneController.text.trim(),
          backStatus: _backStatus!,
          notBackReason: _isNormalBack
              ? ''
              : _notBackReasonController.text.trim(),
          img: _imageMd5,
          annex: _attachmentMd5,
        );

        return true;
      },
    );
  }

  String _fmtDate(DateTime? value) {
    if (value == null) return '请选择';
    String two(int n) => n.toString().padLeft(2, '0');
    final local = value.toLocal();
    return '${local.year}/${two(local.month)}/${two(local.day)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(title: Text(_isEdit ? '编辑返校登记' : '返校登记')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(AppSpacing.pageMargin),
              children: [
                const PlainSectionHeader('报到'),
                TextField(
                  controller: _userPhoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: '手机号',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppSpacing.listGroupGap),
                const PlainSectionHeader('报到状态'),
                SegmentedButton<int>(
                  segments: const <ButtonSegment<int>>[
                    ButtonSegment<int>(value: 0, label: Text('正常报到')),
                    ButtonSegment<int>(value: 1, label: Text('暂缓报到')),
                    ButtonSegment<int>(value: 2, label: Text('不报到')),
                  ],
                  emptySelectionAllowed: true,
                  selected: _backStatus == null
                      ? const <int>{}
                      : <int>{_backStatus!},
                  onSelectionChanged: (selection) {
                    final value = selection.isEmpty ? null : selection.first;
                    setState(() {
                      _backStatus = value;
                      _promiseChecked = value == 0;
                    });
                  },
                ),
                if (_isNormalBack)
                  CheckboxListTile(
                    value: _promiseChecked,
                    onChanged: (value) {
                      setState(() => _promiseChecked = value ?? false);
                    },
                    contentPadding: EdgeInsets.zero,
                    title: const Text('承诺：本人已熟悉开学报到要求'),
                  ),
                if (!_isNormalBack) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _notBackReasonController,
                    minLines: 3,
                    maxLines: 5,
                    maxLength: 1000,
                    decoration: const InputDecoration(
                      labelText: '无法正常报到原因',
                      border: OutlineInputBorder(),
                      helperText: '不少于10个字',
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.listGroupGap),
                const PlainSectionHeader('籍贯与生源地'),
                TextField(
                  controller: _nativePlaceController,
                  decoration: const InputDecoration(
                    labelText: '籍贯',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                PlainListGroup(
                  children: [
                    changxingAreaRow(
                      title: '生源所在地',
                      selection: _areaSelection,
                      onTap: _pickArea,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.listGroupGap),
                const PlainSectionHeader('紧急联系人'),
                TextField(
                  controller: _emergencyContactController,
                  decoration: const InputDecoration(
                    labelText: '紧急联系人',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _emergencyPhoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: '联系人电话',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_isNormalBack) ...[
                  const SizedBox(height: AppSpacing.listGroupGap),
                  const PlainSectionHeader('行程'),
                  PlainListGroup(
                    children: [
                      PlainListRow(
                        title: '报到日期',
                        value: _fmtDate(_reportDate),
                        onTap: _pickReportDate,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  AppDropdown<String>(
                    label: '交通方式',
                    value: _trafficTool,
                    items: _trafficOptions
                        .map(
                          (it) => AppDropdownItem<String>(value: it, label: it),
                        )
                        .toList(),
                    onChanged: (value) {
                      setState(() => _trafficTool = value);
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _trafficDetailController,
                    minLines: 2,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '交通信息详情',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.listGroupGap),
                PlainListGroup(
                  children: [
                    changxingAttachmentRow(
                      label: _attachmentLabel,
                      uploading: _uploadingAttachment,
                      onTap: _pickAttachment,
                    ),
                  ],
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
