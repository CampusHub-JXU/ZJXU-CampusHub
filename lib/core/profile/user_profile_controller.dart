import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/credential_store.dart';
import '../notice/notice_relevance.dart';

/// 用户身份信息：入学年级（通知相关性排序的依据）。
///
/// 手动设置优先；未手动设置时从已登录的学号自动识别（取开头 20XX，
/// 见 [NoticeRelevance.inferEnrollmentYearFromId]）。学号格式不含年份
/// 前缀的同学在「设置 → 学期 · 我的年级」手动选择即可。
class UserProfileController {
  UserProfileController._();
  static final UserProfileController instance = UserProfileController._();

  static const _keyManualEnrollmentYear = 'profile_enrollment_year';

  /// 手动设置的入学年级；null 表示跟随学号自动识别。
  final ValueNotifier<int?> manualEnrollmentYear = ValueNotifier(null);

  /// 从学号自动识别的入学年级；未登录或无法识别时为 null。
  final ValueNotifier<int?> autoEnrollmentYear = ValueNotifier(null);

  /// 实际生效的入学年级：手动设置优先，否则自动识别结果。
  int? get effectiveEnrollmentYear =>
      manualEnrollmentYear.value ?? autoEnrollmentYear.value;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    manualEnrollmentYear.value = prefs.getInt(_keyManualEnrollmentYear);
  }

  /// 手动设置入学年级；传 null 恢复「跟随学号自动识别」。
  Future<void> setManualEnrollmentYear(int? year) async {
    final prefs = await SharedPreferences.getInstance();
    if (year == null) {
      await prefs.remove(_keyManualEnrollmentYear);
    } else {
      await prefs.setInt(_keyManualEnrollmentYear, year);
    }
    manualEnrollmentYear.value = year;
  }

  /// 从已保存的登录账号重新识别入学年级。启动与登录态变化后调用。
  Future<void> refreshAutoEnrollmentYear() async {
    final unified = await CredentialStore.instance.loadUnifiedAuthSession();
    final zhengfang = unified == null
        ? await CredentialStore.instance.loadZhengfangSession()
        : null;
    final credentials = unified ?? zhengfang;
    final account =
        credentials ?? (await CredentialStore.instance.loadCredentials())?.$1;
    autoEnrollmentYear.value = account == null
        ? null
        : NoticeRelevance.inferEnrollmentYearFromId(account);
  }

  @visibleForTesting
  void debugReset() {
    manualEnrollmentYear.value = null;
    autoEnrollmentYear.value = null;
  }
}
