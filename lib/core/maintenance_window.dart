/// 学校系统夜间维护时段提示工具。
///
/// 学校教务/CAS/一卡通/网关等系统每天 23:30 后例行维护休眠，次日 6:00 恢复。
/// 维护时段内请求失败属正常现象，错误文案统一通过 [appendMaintenanceHint]
/// 追加中性提示；白天文案完全不变。时段常量集中在本文件，调整只改这里。
library;

/// 维护开始：当天 23:30（本地时间）。
const int maintenanceStartHour = 23;
const int maintenanceStartMinute = 30;

/// 维护结束：次日 6:00（本地时间，不含）。
const int maintenanceEndHour = 6;
const int maintenanceEndMinute = 0;

/// 追加到错误文案后的维护提示后缀。
const String maintenanceHint = '（学校系统夜间维护 23:30–6:00，可明早再试）';

/// 判断 [now]（本地时间）是否处于维护时段 23:30 – 次日 6:00。
///
/// 边界：23:30 整与 0:00–5:59 在窗口内；6:00 整与 23:29 在窗口外。
bool isInMaintenanceWindow(DateTime now) {
  final minutes = now.hour * 60 + now.minute;
  const start = maintenanceStartHour * 60 + maintenanceStartMinute;
  const end = maintenanceEndHour * 60 + maintenanceEndMinute;
  // 跨零点窗口：[start, 24:00) ∪ [0:00, end)
  return minutes >= start || minutes < end;
}

/// 若当前处于维护时段，在 [message] 末尾追加 [maintenanceHint]；
/// 否则原样返回。已含提示的文案不重复追加。
///
/// [now] 可注入便于测试，缺省取本地当前时间。
String appendMaintenanceHint(String message, {DateTime? now}) {
  final time = now ?? DateTime.now();
  if (!isInMaintenanceWindow(time)) return message;
  if (message.contains(maintenanceHint)) return message;
  return '$message$maintenanceHint';
}
