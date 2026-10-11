import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/credential_store.dart';
import '../auth/unified_auth.dart';
import '../auth/zhengfang_auth.dart';
import '../notice/notice_relevance.dart';

/// 用户身份信息：入学年级（教务处通知相关性排序的依据）。
///
/// 仅从已登录学号自动识别（取开头 20XX，见
/// [NoticeRelevance.inferEnrollmentYearFromId]）。历史版本曾在设置页提供
/// 手动覆盖（持久化 key `profile_enrollment_year`）；新版本不再支持手动
/// 覆盖，[init] 时安全清理该遗留 key，避免升级后它暗中覆盖自动识别。
///
/// 学号无法识别（例如不是 20XX 开头）时为 null；通知相关性保持 fail-open：
/// 所有通知照常可见、只按日期排序，不猜测其他身份证明或学籍。
class UserProfileController {
  UserProfileController._();
  static final UserProfileController instance = UserProfileController._();

  /// 历史手动入学年级覆盖的持久化 key。
  ///
  /// 仅用于升级迁移清理，不再读取；删掉它也不会影响其他偏好。
  static const legacyManualEnrollmentYearKey = 'profile_enrollment_year';

  /// 从学号自动识别的入学年级；未登录或无法识别时为 null。
  final ValueNotifier<int?> autoEnrollmentYear = ValueNotifier(null);

  /// 实际生效的入学年级：仅来自学号自动识别（不再有手动覆盖）。
  int? get effectiveEnrollmentYear => autoEnrollmentYear.value;

  /// 认证变更监听是否已挂载（[init] 幂等 / [debugReset] 释放）。
  bool _listeningToAuth = false;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    // 升级迁移：删除历史手动覆盖偏好。只删这一个 key，不动其他偏好；
    // 删除后 effectiveEnrollmentYear 只受学号自动识别影响。
    if (prefs.containsKey(legacyManualEnrollmentYearKey)) {
      await prefs.remove(legacyManualEnrollmentYearKey);
    }
    if (!_listeningToAuth) {
      _listeningToAuth = true;
      // 登录 / 换号 / 登出后重新识别入学年级：复用既有认证变更通知。
      UnifiedAuthService.instance.addListener(_onAuthIdentityChanged);
      ZhengfangAuth.instance.addListener(_onAuthIdentityChanged);
    }
  }

  void _onAuthIdentityChanged() {
    unawaited(refreshAutoEnrollmentYear());
  }

  /// 从已保存的登录账号重新识别入学年级。启动、登录态变化后调用。
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
    autoEnrollmentYear.value = null;
    if (_listeningToAuth) {
      _listeningToAuth = false;
      UnifiedAuthService.instance.removeListener(_onAuthIdentityChanged);
      ZhengfangAuth.instance.removeListener(_onAuthIdentityChanged);
    }
  }
}
