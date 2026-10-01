// 宽松的 JSON 值类型转换（接口字段可能是数字也可能是字符串）。
// 解析失败 / 值为 null 时返回 fallback，不抛异常。

/// 转为 `int`：`int` 原样、`num` 取整、其余按 `toString()` 解析（不 trim）。
int asInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

/// 同 [asInt]，但 `null` 与无法解析都返回 `null`。
int? asNullableInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

/// 转为 `double`：`double` 原样、`num` 转换、其余按 `toString()` 解析（不 trim）。
double asDouble(Object? value, {double fallback = 0}) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}

/// 转为 `String`：`null` 为空串，其余 `toString()`；[trim] 为 true 时去首尾空白。
String asString(Object? value, {bool trim = false}) {
  if (value == null) return '';
  final text = value.toString();
  return trim ? text.trim() : text;
}
