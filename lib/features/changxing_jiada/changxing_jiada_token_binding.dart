import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/auth/unified_auth.dart';

/// 畅行嘉大业务 token 的持久 envelope：token 与归属账号（统一认证账号）
/// 必须在**同一条 JSON、同一次写入**中原子落盘；任何读取都以 owner 为准。
@immutable
class _StoredToken {
  const _StoredToken({required this.owner, required this.token});

  final String owner;
  final String token;

  /// 解析失败 / 字段缺失一律返回 null（fail closed，不猜测归属）。
  /// owner / token 必须是 JSON 字符串：不做 `toString()` 兜底转换，避免把
  /// 数字、数组、对象等异常字段「拼」成一个看似合法的归属。
  static _StoredToken? tryParse(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final ownerValue = decoded['owner'];
    final tokenValue = decoded['token'];
    if (ownerValue is! String || tokenValue is! String) return null;
    final owner = ownerValue.trim();
    final token = tokenValue.trim();
    if (owner.isEmpty || token.isEmpty) return null;
    return _StoredToken(owner: owner, token: token);
  }

  String encode() => jsonEncode({'owner': owner, 'token': token});
}

/// 畅行嘉大业务 token 的 owner 绑定与持久化（fail closed）：
///
/// * token 只有在 owner 与当前非空统一认证账号一致、且绑定时的
///   `sessionRevision` 未漂移时才可见 / 可发送；
/// * 旧的无 owner token 一律不可用，不做任何自动归因，读取时删除；
/// * CAS 身份未就绪时**不**标记已恢复，身份就绪后可再次读取；
/// * 身份变化 / revision 漂移（即使通知缺失）一律作废旧绑定；
/// * v2 存储的读取 / 写入 / 删除在同一条私有 Future 队列上串行执行，并在
///   临界区内复核身份与恢复标记，保证旧会话 / 旧读盘不会覆盖、删除或污染
///   新会话 / 更新 save 的 envelope 与内存绑定（换号、同账号重登、明确登出
///   均适用）。该串行化只约束本 singleton 在当前 isolate 内的调用顺序，
///   不宣称跨 isolate（如后台引擎）的原子性。
class ChangxingTokenBinding {
  ChangxingTokenBinding() {
    UnifiedAuthService.instance.addListener(_onUnifiedAuthChanged);
  }

  /// 新存储：单条 JSON envelope（owner + token）原子写入。
  static const storageKeyV2 = 'zjxu_changxing_token_owner_v1';

  /// 旧 key：只有 token、没有归属账号。升级后一律按不可用处理，不做任何
  /// 自动归因；读取时顺带删除，避免无主 token 长期驻留。
  static const legacyStorageKey = 'zjxu_changxing_token';

  static const _storage = FlutterSecureStorage();

  String? _token;
  String? _boundOwner;
  int? _boundRevision;
  bool _restored = false;

  /// 最近一次读盘对应的身份戳（owner + revision）：身份漂移后允许重新读盘，
  /// 不依赖通知一定到达（核心层存在 revision 推进但不通知的路径）。
  String? _restoredOwner;
  int? _restoredRevision;

  /// v2 存储操作的串行队列尾：所有读 / 写 / 删依次追加到这里，前一个操作
  /// 完成后才开始下一个（不缓存操作列表，只保留链尾 future）。
  /// 队列自身吞掉异常，避免单次失败卡死后续操作；错误仍回传给对应调用方。
  Future<void> _v2Tail = Future<void>.value();

  void _onUnifiedAuthChanged() => _reset();

  void _reset() {
    _token = null;
    _boundOwner = null;
    _boundRevision = null;
    _restored = false;
    _restoredOwner = null;
    _restoredRevision = null;
  }

  /// 当前明确的统一认证账号；未登录 / 空白账号一律为 null。
  String? get currentOwner {
    final auth = UnifiedAuthService.instance;
    if (!auth.isLoggedIn) return null;
    final account = auth.currentAccount?.trim();
    return (account == null || account.isEmpty) ? null : account;
  }

  /// 当前身份可用的 token：owner 与当前非空 CAS 账号一致，且绑定时记录的
  /// `sessionRevision` 未漂移；任一条不满足一律视为没有 token。
  String? get currentToken {
    final token = _token;
    if (token == null || token.isEmpty) return null;
    final owner = _boundOwner;
    final revision = _boundRevision;
    if (owner == null || revision == null) return null;
    return isCurrent(owner, revision) ? token : null;
  }

  bool get hasToken => currentToken != null;

  /// 捕获的 owner + revision 是否仍是当前身份（每个 await 边界后复核）。
  bool isCurrent(String owner, int revision) {
    final auth = UnifiedAuthService.instance;
    if (!auth.isLoggedIn) return false;
    return currentOwner == owner && auth.sessionRevision == revision;
  }

  /// 内存绑定是否仍指向捕获的 owner + revision（迟到响应 / 500001 守卫）。
  bool isBindingCurrent(String owner, int revision) =>
      _boundOwner == owner && _boundRevision == revision;

  /// 读取落盘 envelope。CAS 身份未就绪时不标记已恢复（页面在身份就绪后会
  /// 再次调用）；无主 / 损坏 envelope 安全舍弃；身份漂移会重新读盘。
  ///
  /// 读盘与提交都在 v2 串行队列内完成，并在临界区内复核 `_restored`：
  /// 排队期间若有更新的 save（同账号同 revision 的 token 刷新）已完成，
  /// 直接沿用其绑定，绝不用旧盘值覆盖新 token。
  Future<void> restore() {
    final owner = currentOwner;
    final revision = UnifiedAuthService.instance.sessionRevision;

    // 已经针对「当前 owner + revision」读过盘：无需重复 I/O。
    if (_restored && _restoredOwner == owner && _restoredRevision == revision) {
      return Future<void>.value();
    }

    return _serializeV2(() async {
      final ownerAtRead = currentOwner;
      final revisionAtRead = UnifiedAuthService.instance.sessionRevision;

      // 排队等待期间可能有更新的 save / restore 提交了同一身份：直接沿用，
      // 不回读旧值、不覆盖更新的内存绑定。
      if (_restored &&
          _restoredOwner == ownerAtRead &&
          _restoredRevision == revisionAtRead) {
        return;
      }

      // legacy 删除是直接的存储调用（不再入队），在临界区内不会造成死锁。
      await _deleteLegacyToken();
      final envelope = _StoredToken.tryParse(
        await _storage.read(key: storageKeyV2),
      );

      // 读盘期间身份变化：本次读取结果作废，不写下任何绑定。
      if (UnifiedAuthService.instance.sessionRevision != revisionAtRead ||
          currentOwner != ownerAtRead) {
        return;
      }

      if (envelope == null) {
        // 无新格式 envelope（含旧 key 升级后首次）：不读取旧 token。
        _markRestored(ownerAtRead, revisionAtRead);
        return;
      }
      if (ownerAtRead == null) {
        // 身份尚未恢复：不做无归属的 token 恢复，等身份就绪后再读。
        return;
      }
      _markRestored(ownerAtRead, revisionAtRead);
      if (ownerAtRead != envelope.owner) {
        // 落盘 token 属于其他账号：不可读取（切回该账号后可正常复用）。
        return;
      }
      _token = envelope.token;
      _boundOwner = envelope.owner;
      _boundRevision = revisionAtRead;
    });
  }

  void _markRestored(String? owner, int revision) {
    _restored = true;
    _restoredOwner = owner;
    _restoredRevision = revision;
  }

  /// 把 v2 存储的读 / 写 / 删操作追加到私有串行队列，返回调用方可见的结果。
  /// 队列中任一操作抛错只回传给该调用方，不阻断后续排队操作。
  Future<T> _serializeV2<T>(Future<T> Function() action) {
    final run = _v2Tail.then((_) => action());
    _v2Tail = run.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return run;
  }

  /// 仅在捕获的 owner + revision 仍是当前身份时写入；身份复核、落盘、内存
  /// 绑定在同一个串行化临界区内完成。排队期间 / 写入期间身份变化一律不建立
  /// 绑定并如实返回 false：旧会话的写入既不会覆盖新会话的 envelope，也不会
  /// 在新会话的内存里生效。
  Future<bool> saveIfCurrent({
    required String token,
    required String owner,
    required int revision,
  }) {
    return _serializeV2(() async {
      // 临界区内复核：排队期间身份可能已变化，旧会话的保存直接放弃。
      if (!isCurrent(owner, revision)) return false;
      await _storage.write(
        key: storageKeyV2,
        value: _StoredToken(owner: owner, token: token).encode(),
      );
      if (!isCurrent(owner, revision)) return false;
      _token = token;
      _boundOwner = owner;
      _boundRevision = revision;
      _markRestored(owner, revision);
      return true;
    });
  }

  /// 明确清理（用户登出）：清内存绑定与落盘 envelope。
  ///
  /// 调用时捕获当前身份，并在串行化临界区内复核：排队 / 删除期间若已有新会话
  /// 接管（换号、同账号重登、期间登录），本次清理一律 no-op，不得删除新会话的
  /// envelope；执行时已登出（无人接管）则照常清理。
  Future<void> clear() async {
    final owner = currentOwner;
    final revision = UnifiedAuthService.instance.sessionRevision;
    await _serializeV2(() async {
      if (!_explicitClearStillValid(owner, revision)) return;
      _clearMemory();
      await _storage.delete(key: storageKeyV2);
    });
    await _deleteLegacyToken();
  }

  /// 只清捕获身份的绑定：旧请求的 500001 不得清掉新会话 token。
  /// 身份 + 内存绑定的复核在串行化临界区内执行：排队期间身份已变化时
  /// no-op，不会删除新会话的 envelope。
  Future<void> clearIfCurrent(String owner, int revision) async {
    await _serializeV2(() async {
      if (!isCurrent(owner, revision)) return;
      if (!isBindingCurrent(owner, revision)) return;
      _clearMemory();
      await _storage.delete(key: storageKeyV2);
    });
    await _deleteLegacyToken();
  }

  /// 调用时的身份 [ownerAtCall] + [revisionAtCall] 在执行时是否仍未被接管。
  /// 执行时已登出且期间无人登录 → 有效；期间有人登录 → 只有仍是同一会话
  /// （owner 与 revision 都一致）才允许清理。
  bool _explicitClearStillValid(String? ownerAtCall, int revisionAtCall) {
    final auth = UnifiedAuthService.instance;
    if (!auth.isLoggedIn) return true;
    if (ownerAtCall == null) return false;
    return currentOwner == ownerAtCall &&
        auth.sessionRevision == revisionAtCall;
  }

  /// 清空内存绑定并标记已恢复（明确清除后不回读；即使删除失败也不复活）。
  void _clearMemory() {
    _token = null;
    _boundOwner = null;
    _boundRevision = null;
    _markRestored(currentOwner, UnifiedAuthService.instance.sessionRevision);
  }

  Future<void> _deleteLegacyToken() async {
    try {
      await _storage.delete(key: legacyStorageKey);
    } catch (_) {
      // 旧 key 不参与任何归属判定，删除失败不影响安全边界。
    }
  }

  /// 测试 / 调试辅助：以真实落盘格式（owner + token 单条 JSON）构造 envelope。
  /// 服务层以 `@visibleForTesting` 同签名转发，测试不直接依赖本类。
  static String encodeEnvelope({
    required String owner,
    required String token,
  }) => _StoredToken(owner: owner, token: token).encode();

  /// 测试 / 调试辅助：当前内存绑定的 owner。
  String? get debugBoundOwner => _boundOwner;

  /// 测试 / 调试辅助：当前内存绑定对应的 `sessionRevision`。
  int? get debugBoundRevision => _boundRevision;

  /// 测试 / 调试辅助：清空内存绑定与读盘标记。
  void debugReset() => _reset();
}
