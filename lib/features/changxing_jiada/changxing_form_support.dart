import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/app_feedback.dart';
import 'changxing_area_picker_dialog.dart';
import 'changxing_jiada_model.dart';
import 'changxing_jiada_service.dart';

/// 请假 / 离校 / 返校 / 超时四类表单页共用的小函数。
///
/// 刻意保持为纯函数而不是基类：各页的字段与校验差异很大，只把完全相同的
/// 「区域选择 / 附件上传 / 加载与提交的收尾反馈」抽到这里；页面状态仍由各自
/// 的 `State` 持有（`setState` 仍在页面里）。

/// 表单页内的轻提示；页面已卸载时静默跳过。
void changxingToast(State state, String message) {
  if (!state.mounted) return;
  AppFeedback.toast(state.context, message);
}

/// 把服务端自下而上的区域父链还原成省 / 市 / 区选择；父链为空返回 null。
Future<ChangxingAreaSelection?> buildChangxingAreaSelection(
  ChangxingJiadaService service,
  int areaId,
) async {
  final parents = await service.fetchAreaParents(areaId);
  if (parents.isEmpty) return null;
  final chain = parents.reversed.toList();
  final province = chain.isNotEmpty ? chain[0] : null;
  final city = chain.length > 1 ? chain[1] : null;
  final district = chain.length > 2 ? chain[2] : null;
  return ChangxingAreaSelection(
    id: areaId,
    province: province,
    city: city,
    district: district,
  );
}

/// 弹出区域选择；用户取消或页面已卸载时返回 null。
Future<ChangxingAreaSelection?> pickChangxingArea(
  State state,
  ChangxingJiadaService service, {
  int? initialAreaId,
}) async {
  final selection = await showChangxingAreaPickerDialog(
    context: state.context,
    service: service,
    initialAreaId: initialAreaId,
  );
  if (selection == null || !state.mounted) return null;
  return selection;
}

/// 附件选择并上传的结果：服务端 md5 + 展示用文件名。
typedef ChangxingAttachment = ({String md5, String label});

/// 选择文件并上传。用户取消选择返回 null；上传失败向上抛出，由调用方
/// 决定反馈（统一文案见 [uploadChangxingAttachmentWithFeedback]）。
Future<ChangxingAttachment?> pickAndUploadChangxingAttachment(
  ChangxingJiadaService service,
) async {
  final result = await FilePicker.platform.pickFiles(
    allowMultiple: false,
    type: FileType.custom,
    allowedExtensions: <String>['doc', 'docx', 'xlsx', 'xls', 'txt', 'pdf'],
  );
  final picked = result?.files.single;
  if (picked == null || picked.path == null || picked.path!.isEmpty) {
    return null;
  }
  final upload = await service.uploadAttachment(picked.path!, picked.name);
  return (md5: upload.md5, label: picked.name);
}

/// 附件上传的完整流程：开关 spinner → 选文件上传 → 成功回填并提示 /
/// 失败提示。页面只需提供 [setUploading] 与 [onUploaded] 两个状态回调。
Future<void> uploadChangxingAttachmentWithFeedback(
  State state,
  ChangxingJiadaService service, {
  required void Function(bool uploading) setUploading,
  required void Function(ChangxingAttachment attachment) onUploaded,
}) async {
  setUploading(true);
  try {
    final attachment = await pickAndUploadChangxingAttachment(service);
    if (attachment == null || !state.mounted) return;
    onUploaded(attachment);
    changxingToast(state, '附件上传成功');
  } catch (e) {
    changxingToast(state, '附件上传失败：$e');
  } finally {
    if (state.mounted) setUploading(false);
  }
}

/// 表单初始数据加载：失败时提示「加载表单失败」并退回上一页。
///
/// 返回 true 表示加载成功且页面仍挂载，调用方可继续 `setState`。
Future<bool> loadChangxingForm(
  State state,
  Future<void> Function() load,
) async {
  try {
    await load();
  } catch (e) {
    if (!state.mounted) return false;
    changxingToast(state, '加载表单失败：$e');
    state.context.pop();
    return false;
  }
  return state.mounted;
}

/// 提交收尾：开关「提交中」、成功提示并带 `true` 退出、失败提示。
///
/// [submit] 返回 false 表示已自行提示并中止（例如业务开关未开放），不弹
/// 成功 / 失败文案、不退出页面。
Future<void> submitChangxingForm(
  State state, {
  required bool isEdit,
  required void Function(bool submitting) setSubmitting,
  required Future<bool> Function() submit,
}) async {
  setSubmitting(true);
  try {
    final submitted = await submit();
    if (!submitted) return;
    if (!state.mounted) return;
    changxingToast(state, isEdit ? '修改成功' : '提交成功');
    state.context.pop(true);
  } catch (e) {
    changxingToast(state, isEdit ? '修改失败：$e' : '提交失败：$e');
  } finally {
    if (state.mounted) setSubmitting(false);
  }
}
