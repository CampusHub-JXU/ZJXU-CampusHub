import 'package:jxu_campus_hub/core/auth/credential_store.dart';

/// 测试专用的会话持久化便捷入口（生产代码不使用）。
///
/// 仅走 [CredentialStore] 的公开 envelope API：无条件提交并推进 epoch。
extension CredentialStoreTestExt on CredentialStore {
  Future<void> saveZhengfangSession(String studentId) =>
      _commit(CredentialSessionDomain.academic, studentId);

  Future<void> clearZhengfangSession() =>
      _commit(CredentialSessionDomain.academic, null);

  Future<void> saveUnifiedAuthSession(String account) =>
      _commit(CredentialSessionDomain.unified, account);

  Future<void> clearUnifiedAuthSession() =>
      _commit(CredentialSessionDomain.unified, null);

  Future<void> _commit(CredentialSessionDomain domain, String? account) async {
    final current = await readSessionEnvelope(domain);
    await writeSessionEnvelope(
      domain,
      account == null
          ? CredentialSessionEnvelope(epoch: current.epoch + 1)
          : CredentialSessionEnvelope(
              account: account,
              active: true,
              epoch: current.epoch + 1,
            ),
    );
  }
}
