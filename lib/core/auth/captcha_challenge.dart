import 'dart:math';
import 'dart:typed_data';

/// 验证码所属的认证域。
enum CaptchaChallengeDomain {
  unifiedAuth('cas'),
  zhengfang('zhengfang');

  const CaptchaChallengeDomain(this.wireName);

  /// 用于日志/状态的稳定短名，不含敏感信息。
  final String wireName;
}

/// 一次验证码事务的**不透明**元数据。
///
/// 只暴露验证码图片与事务标识；`lt` / `execution` / `csrftoken` / 密码等
/// 上下文永远保存在对应 service 的私有快照中，不进入本对象、不写日志、
/// 不持久化。`toString` 刻意只输出非敏感字段。
class CaptchaChallenge {
  CaptchaChallenge({
    required this.id,
    required this.bytes,
    required this.createdAt,
    required this.domain,
    required this.accountRevision,
    this.serviceUrl,
    this.ttl = defaultTtl,
  });

  /// 默认有效期：验证码图片与服务端 session 通常约 2 分钟内有效。
  static const Duration defaultTtl = Duration(minutes: 2);

  /// 不透明事务 id（随机生成，不含服务端字段）。
  final String id;

  /// 验证码图片字节。
  final Uint8List bytes;

  final DateTime createdAt;

  final CaptchaChallengeDomain domain;

  /// 创建时所属服务的身份修订号；身份/epoch 变化后旧 challenge 必须失效。
  final int accountRevision;

  /// 仅 CAS 使用，用于诊断；不包含任何凭据。
  final String? serviceUrl;

  final Duration ttl;

  bool isExpiredAt(DateTime now) => !now.isBefore(createdAt.add(ttl));

  @override
  String toString() =>
      'CaptchaChallenge(domain=${domain.wireName}, id=$id, '
      'bytes=${bytes.length})';
}

/// [CaptchaChallengeStore.consume] 的产物：一次单次提交所需的私有上下文句柄。
class CaptchaChallengeAttempt<TContext> {
  const CaptchaChallengeAttempt({
    required this.challenge,
    required this.context,
    required this.generation,
  });

  final CaptchaChallenge challenge;

  /// 提交时必须使用的私有上下文快照；提交前禁止重新 fetch 上下文。
  final TContext context;

  /// 消费时的 generation，用于在提交过程中检测刷新/失效。
  final int generation;
}

/// 单域验证码事务状态机（内存态，不持久化）。
///
/// 语义：
/// - [arm] 建立新 challenge，同时递增 generation 并替换私有上下文；
/// - [consume] 只允许当前 challenge **单次**提交，成功与否都会清除当前
///   challenge，避免同一验证码被重复使用；id 不匹配 / 过期 / 身份修订
///   不一致都返回 null 并失效当前 challenge；
/// - [isAttemptCurrent] 让提交方在 await 边界检查是否发生刷新/失效/退出，
///   迟到的提交结果必须丢弃；
/// - [invalidate] 由刷新、模式变化、退出、身份变化触发。
///
/// 泛型 [TContext] 是各 service 的私有上下文快照（如 CAS 的 lt/execution，
/// 或教务的 csrftoken + 连接模式）。
class CaptchaChallengeStore<TContext> {
  CaptchaChallengeStore({
    this.defaultTtl = CaptchaChallenge.defaultTtl,
    Random? random,
  }) : _random = random ?? Random.secure();

  final Duration defaultTtl;
  final Random _random;

  int _generation = 0;
  CaptchaChallenge? _challenge;
  TContext? _context;

  int get generation => _generation;
  CaptchaChallenge? get challenge => _challenge;
  bool get hasChallenge => _challenge != null;

  /// 建立新 challenge 并保存对应私有上下文，旧 challenge 立即失效。
  CaptchaChallenge arm({
    required CaptchaChallengeDomain domain,
    required int accountRevision,
    required Uint8List bytes,
    required TContext context,
    String? serviceUrl,
    DateTime? now,
    Duration? ttl,
  }) {
    _generation++;
    final challenge = CaptchaChallenge(
      id: _newId(),
      bytes: bytes,
      createdAt: now ?? DateTime.now(),
      domain: domain,
      accountRevision: accountRevision,
      serviceUrl: serviceUrl,
      ttl: ttl ?? defaultTtl,
    );
    _challenge = challenge;
    _context = context;
    return challenge;
  }

  /// 单次消费当前 challenge。返回 null 表示 id 不匹配 / 已过期 / 身份修订
  /// 不一致，调用方应提示刷新验证码。
  CaptchaChallengeAttempt<TContext>? consume(
    String challengeId, {
    required int accountRevision,
    DateTime? now,
  }) {
    final current = _challenge;
    if (current == null || current.id != challengeId) return null;
    if (current.isExpiredAt(now ?? DateTime.now())) {
      invalidate(challengeId: challengeId);
      return null;
    }
    if (current.accountRevision != accountRevision) {
      invalidate(challengeId: challengeId);
      return null;
    }
    final context = _context as TContext;
    final generation = _generation;
    // 单次提交：消费即清除，后续同 id 一律拒绝。
    _challenge = null;
    _context = null;
    return CaptchaChallengeAttempt<TContext>(
      challenge: current,
      context: context,
      generation: generation,
    );
  }

  /// 消费「当前」challenge（供兼容包装使用）；没有当前 challenge 返回 null。
  /// **不会**重新初始化任何上下文——只引用调用方自己发出的 challenge。
  CaptchaChallengeAttempt<TContext>? consumeCurrent({
    required int accountRevision,
    DateTime? now,
  }) {
    final current = _challenge;
    if (current == null) return null;
    return consume(current.id, accountRevision: accountRevision, now: now);
  }

  /// 提交过程中若发生 [arm]/[invalidate]，generation 前进，旧提交结果作废。
  bool isAttemptCurrent(int attemptGeneration) =>
      attemptGeneration == _generation;

  /// 使 challenge 失效。
  ///
  /// - [challengeId] 为 null：失效当前 challenge（刷新/退出等全局动作）。
  /// - [challengeId] 非 null：只在它仍是当前 challenge 时失效，**不会**误清
  ///   另一个（更新）widget 已建立的新 challenge。返回是否真的失效。
  bool invalidate({String? challengeId}) {
    final current = _challenge;
    if (challengeId != null && (current == null || current.id != challengeId)) {
      return false;
    }
    _generation++;
    _challenge = null;
    _context = null;
    return true;
  }

  String _newId() {
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
