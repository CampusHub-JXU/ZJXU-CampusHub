import 'dart:async';

import 'package:dio/dio.dart';

import 'auth_recovery_state_store.dart';
import 'credential_store.dart';

/// 仅后台组合入口安装：所有嵌套自动登录共享同一申领、取消与提交记录。
class BackgroundAuthContext {
  BackgroundAuthContext({required this.mayContinue});
  final Future<bool> Function() mayContinue;
  final CancelToken cancelToken = CancelToken();
  final Map<String, int> expectedEpochs = {};
  final Map<String, String?> expectedAccounts = {};
  static final Object _key = Object();
  static BackgroundAuthContext? get current =>
      Zone.current[_key] as BackgroundAuthContext?;
  Future<T> run<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_key: this});
  Future<bool> allowed() async {
    if (cancelToken.isCancelled) return false;
    if (!await mayContinue()) {
      cancelToken.cancel('background lease yielded');
      return false;
    }
    return !cancelToken.isCancelled;
  }

  /// 本轮钉住的持久 epoch；未钉住返回 null。
  int? pinnedEpoch(CredentialSessionDomain domain) =>
      expectedEpochs[_wireName(domain)];

  /// 本轮自己的撤销（会话过期判失效）推进了 epoch：钉住值跟进，
  /// 否则同一轮里随后的同账号自动恢复会被误判为「别人改了会话」。
  void advancePinnedEpoch(CredentialSessionDomain domain, int epoch) {
    expectedEpochs[_wireName(domain)] = epoch;
  }

  static String _wireName(CredentialSessionDomain domain) =>
      domain == CredentialSessionDomain.unified
      ? AuthRecoveryDomain.cas.wireName
      : AuthRecoveryDomain.academic.wireName;
}
