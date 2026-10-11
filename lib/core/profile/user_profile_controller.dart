import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/credential_store.dart';
import '../auth/unified_auth.dart';
import '../auth/zhengfang_auth.dart';
import '../notice/notice_relevance.dart';

/// 用户身份信息：入学年级（教务处通知相关性排序的依据）。
///
/// 仅从当前**已验证身份**自动识别（取学号 / 账号开头 20XX，见
/// [NoticeRelevance.inferEnrollmentYearFromId]）。历史版本曾在设置页提供
/// 手动覆盖（持久化 key `profile_enrollment_year`）；新版本不再支持手动
/// 覆盖，[init] 时安全清理该遗留 key，避免升级后它暗中覆盖自动识别。
///
/// 身份来源分两条，绝不混用：
/// - 认证变更（登录 / 换号 / 登出）：**只用内存权威身份**
///   [UnifiedAuthService.verifiedAccount] / [ZhengfangAuth.verifiedStudentId]，
///   不读保存的用户名 / 旧持久 envelope（登出按设计不删除保存的凭据，
///   读存储会把旧年级读回来）。
/// - 冷启动（首帧前尚无内存身份）：[refreshAutoEnrollmentYear] 从**激活的**
///   持久 session envelope 恢复一次；读取期间若有认证变更则以修订号作废，
///   绝不覆盖更新的内存身份 / 登出。
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

  /// 从已登录身份自动识别的入学年级；未登录或无法识别时为 null。
  final ValueNotifier<int?> autoEnrollmentYear = ValueNotifier(null);

  /// 实际生效的入学年级：仅来自身份自动识别（不再有手动覆盖）。
  int? get effectiveEnrollmentYear => autoEnrollmentYear.value;

  /// 认证变更监听是否已挂载（[init] 幂等 / [debugReset] 释放）。
  bool _listeningToAuth = false;

  /// 身份修订号：每次认证变更通知自增。冷启动的持久读取以它为界，
  /// 读取期间发生变更即丢弃结果（与 `UnifiedAuthService.restoreSession`
  /// 丢弃迟到恢复同构）。
  int _identityRevision = 0;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    // 升级迁移：删除历史手动覆盖偏好。只删这一个 key，不动其他偏好；
    // 删除后 effectiveEnrollmentYear 只受身份自动识别影响。
    if (prefs.containsKey(legacyManualEnrollmentYearKey)) {
      await prefs.remove(legacyManualEnrollmentYearKey);
    }
    if (!_listeningToAuth) {
      _listeningToAuth = true;
      // 登录 / 换号 / 登出后重新识别：复用既有认证变更通知。
      UnifiedAuthService.instance.addListener(_onAuthIdentityChanged);
      ZhengfangAuth.instance.addListener(_onAuthIdentityChanged);
    }
  }

  /// 认证变更：身份变化后立即按内存权威身份重算年级。
  ///
  /// 真实登录 / 登出都会在 `notifyListeners` 之前同步更新内存会话
  /// （`_applySessionIdentity` / `markLoggedOut`），因此这里同步读内存即可，
  /// 既不需要也不允许在 await 之后再读盘。
  void _onAuthIdentityChanged() {
    _identityRevision++;
    _applyVerifiedIdentity();
  }

  /// 是否存在内存中的已验证身份（统一认证优先，其次正方）。
  bool _hasVerifiedIdentity() =>
      UnifiedAuthService.instance.verifiedAccount != null ||
      ZhengfangAuth.instance.verifiedStudentId != null;

  /// 按内存权威身份重算年级：统一认证账号优先，其次正方学生号；都没有
  /// （登出 / 未登录）时为 null。不读存储、不猜测。
  void _applyVerifiedIdentity() {
    final account =
        UnifiedAuthService.instance.verifiedAccount ??
        ZhengfangAuth.instance.verifiedStudentId;
    autoEnrollmentYear.value = account == null
        ? null
        : NoticeRelevance.inferEnrollmentYearFromId(account);
  }

  /// 冷启动恢复入学年级。
  ///
  /// 首帧前内存尚无权威身份时，从**激活的**持久 session envelope 恢复一次
  /// （`active` 才计；不读保存的用户名 / 密码）。若读取期间发生认证变更
  /// （修订漂移）或已出现内存身份，则丢弃本次持久结果，绝不覆盖更新的
  /// 内存身份 / 登出。已有内存身份时直接以内存为准，不读盘。
  Future<void> refreshAutoEnrollmentYear() async {
    if (_hasVerifiedIdentity()) {
      _applyVerifiedIdentity();
      return;
    }
    final revisionAtRead = _identityRevision;
    final unified = await CredentialStore.instance.loadUnifiedAuthSession();
    final zhengfang = unified == null
        ? await CredentialStore.instance.loadZhengfangSession()
        : null;
    if (revisionAtRead != _identityRevision || _hasVerifiedIdentity()) {
      return;
    }
    final account = unified ?? zhengfang;
    autoEnrollmentYear.value = account == null
        ? null
        : NoticeRelevance.inferEnrollmentYearFromId(account);
  }

  @visibleForTesting
  void debugReset() {
    autoEnrollmentYear.value = null;
    _identityRevision = 0;
    if (_listeningToAuth) {
      _listeningToAuth = false;
      UnifiedAuthService.instance.removeListener(_onAuthIdentityChanged);
      ZhengfangAuth.instance.removeListener(_onAuthIdentityChanged);
    }
  }
}
