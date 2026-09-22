import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/credential_store.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('saves loads and clears zhengfang credentials', () async {
    final store = CredentialStore.instance;

    await store.saveCredentials('20250001', 'secret');
    expect(await store.loadCredentials(), ('20250001', 'secret'));

    await store.clearCredentials();
    expect(await store.loadCredentials(), isNull);
  });

  test('persists independent auth sessions', () async {
    final store = CredentialStore.instance;

    await store.saveZhengfangSession('20250001');
    await store.saveUnifiedAuthSession('u20250001');

    expect(await store.loadZhengfangSession(), '20250001');
    expect(await store.loadUnifiedAuthSession(), 'u20250001');

    await store.clearZhengfangSession();
    expect(await store.loadZhengfangSession(), isNull);
    expect(await store.loadUnifiedAuthSession(), 'u20250001');
  });

  test('session envelope is a single key with monotonic epoch', () async {
    final store = CredentialStore.instance;

    final initial = await store.readSessionEnvelope(
      CredentialSessionDomain.unified,
    );
    expect(initial.active, isFalse);
    expect(initial.epoch, 0);

    await store.saveUnifiedAuthSession('A');
    final afterSave = await store.readSessionEnvelope(
      CredentialSessionDomain.unified,
    );
    expect(afterSave.active, isTrue);
    expect(afterSave.account, 'A');
    expect(afterSave.epoch, 1);

    await store.clearUnifiedAuthSession();
    final afterClear = await store.readSessionEnvelope(
      CredentialSessionDomain.unified,
    );
    expect(afterClear.active, isFalse);
    expect(afterClear.account, isNull);
    expect(afterClear.epoch, 2);
  });

  test('legacy multi-key session migrates once into the envelope', () async {
    FlutterSecureStorage.setMockInitialValues({
      'zjxu_ua_account': 'legacy-user',
      'zjxu_ua_session_active': '1',
    });
    final store = CredentialStore.instance;

    expect(await store.loadUnifiedAuthSession(), 'legacy-user');
    // 迁移后旧 key 被删除，且已落新 envelope。
    final storage = const FlutterSecureStorage();
    expect(await storage.read(key: 'zjxu_ua_account'), isNull);
    expect(await storage.read(key: 'zjxu_ua_session_active'), isNull);
    final envelope = await store.readSessionEnvelope(
      CredentialSessionDomain.unified,
    );
    expect(envelope.account, 'legacy-user');
    expect(envelope.active, isTrue);
  });

  test('corrupt envelope fails closed instead of resurrecting', () async {
    FlutterSecureStorage.setMockInitialValues({
      'zjxu_ua_session_v2': '{not-json',
    });
    final store = CredentialStore.instance;
    final envelope = await store.readSessionEnvelope(
      CredentialSessionDomain.unified,
    );
    expect(envelope.active, isFalse);
    expect(envelope.account, isNull);
    expect(await store.loadUnifiedAuthSession(), isNull);
  });

  test('persisted envelope never contains password material', () async {
    final store = CredentialStore.instance;
    await store.saveUnifiedAuthSession('A');
    final raw = await const FlutterSecureStorage().read(
      key: 'zjxu_ua_session_v2',
    );
    expect(raw, isNotNull);
    expect(raw!.contains('password'), isFalse);
    expect(raw.contains('secret'), isFalse);
  });
}
