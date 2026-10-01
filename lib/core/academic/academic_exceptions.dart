/// 教务业务（成绩 / 考试 / 课表）共用的异常基类与语义。
///
/// 各 feature 保留各自的具体子类型（页面按具体类型 catch），且
/// 「登录过期」仍是该 feature 的「请求异常」子类型（既有调用方 / 测试依赖）。
class AcademicRequestException implements Exception {
  const AcademicRequestException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 教务登录状态过期异常的共用 message。
const academicSessionExpiredMessage = '登录状态已过期，请重新登录';

/// 标记「教务登录状态已过期」的异常（由各 feature 的 AuthExpired 异常实现）。
abstract interface class AcademicSessionExpired {
  /// 自动登录是否因连续身份失败被暂停。为 true 时页面应提示用户手动登录
  /// 一次（登录成功后会由登录控件重新武装自动登录）。
  bool get automaticLoginPaused;
}
