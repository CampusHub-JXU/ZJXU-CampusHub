import 'changxing_jiada_exceptions.dart';

/// 提交体里的时间统一为本地墙钟 `yyyy-MM-dd HH:mm:ss` 字符串。
///
/// `DateTime` 不能被 `jsonEncode` 直接序列化（会抛 `JsonUnsupportedObjectError`），
/// 且服务端读到的时间是不带时区的墙钟。格式与服务端返回值（`DateTime.tryParse`
/// 可解析）同构；尚未对真实服务端做设备端到端验证。
String formatSubmitTime(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  final local = value.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-'
      '${two(local.day)} ${two(local.hour)}:${two(local.minute)}:'
      '${two(local.second)}';
}

ChangxingSubmitRequest buildLeaveRequestSubmitRequest({
  int? id,
  required DateTime startTime,
  required DateTime endTime,
  required String descr,
  required int toAreaCode,
  required String toAddr,
  required String emergencyContact,
  required String emergencyPhone,
  required String userPhone,
  required List<String> trafficTools,
  String img = '',
  String annex = '',
}) {
  final payload = <String, dynamic>{
    'startTime': formatSubmitTime(startTime),
    'endTime': formatSubmitTime(endTime),
    'descr': descr,
    'toAreaCode': toAreaCode,
    'toAddr': toAddr,
    'emergencyContact': emergencyContact,
    'emergencyPhone': emergencyPhone,
    'userPhone': userPhone,
    'trafficTool': trafficTools.join(','),
    'img': img,
    'annex': annex,
    'type': 1,
  };
  if (id != null) payload['id'] = id;
  return ChangxingSubmitRequest(
    path: id == null ? '/approvalForm/qingjia/add' : '/approvalForm/edit',
    payload: payload,
  );
}

ChangxingSubmitRequest buildLeaveSchoolSubmitRequest({
  int? id,
  required DateTime startTime,
  required DateTime endTime,
  required String descr,
  required int toAreaCode,
  required String toAddr,
  required String emergencyContact,
  required String emergencyPhone,
  required String userPhone,
  required List<String> trafficTools,
}) {
  final payload = <String, dynamic>{
    'startTime': formatSubmitTime(startTime),
    'endTime': formatSubmitTime(endTime),
    'descr': descr,
    'toAreaCode': toAreaCode,
    'toAddr': toAddr,
    'emergencyContact': emergencyContact,
    'emergencyPhone': emergencyPhone,
    'userPhone': userPhone,
    'trafficTool': trafficTools.join(','),
    'type': 2,
  };
  if (id != null) payload['id'] = id;
  return ChangxingSubmitRequest(
    path: id == null ? '/approvalForm/lixiao/add' : '/approvalForm/edit',
    payload: payload,
  );
}

ChangxingSubmitRequest buildBackSchoolSubmitRequest({
  int? id,
  required String userPhone,
  required DateTime startTime,
  required String trafficTool,
  required String trafficDetail,
  required String nativePlace,
  required int fromAreaCode,
  required String emergencyContact,
  required String emergencyPhone,
  required int backStatus,
  required String notBackReason,
  String img = '',
  String annex = '',
}) {
  final payload = <String, dynamic>{
    'userPhone': userPhone,
    'startTime': formatSubmitTime(startTime),
    'trafficTool': trafficTool,
    'trafficDetail': trafficDetail,
    'nativePlace': nativePlace,
    'fromAreaCode': fromAreaCode,
    'emergencyContact': emergencyContact,
    'emergencyPhone': emergencyPhone,
    'backStatus': backStatus,
    'notBackReason': notBackReason,
    'img': img,
    'annex': annex,
    'type': 3,
  };
  if (id != null) payload['id'] = id;
  return ChangxingSubmitRequest(
    path: id == null ? '/approvalForm/fanxiao/add' : '/approvalForm/edit',
    payload: payload,
  );
}

ChangxingSubmitRequest buildOvertimeSubmitRequest({
  int? id,
  required String descr,
}) {
  final payload = <String, dynamic>{'type': 4, 'descr': descr};
  if (id != null) payload['id'] = id;
  return ChangxingSubmitRequest(
    path: '/approvalForm/overtime/add',
    payload: payload,
  );
}
