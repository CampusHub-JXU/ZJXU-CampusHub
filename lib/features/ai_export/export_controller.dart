import 'package:flutter/foundation.dart';

import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/logging/app_logger.dart';
import 'export_document.dart';
import 'export_model.dart';

// ── 取数契约（由 lib/app 注入，导出功能本身不依赖任何业务 feature） ───────────

/// 一次「获取」的结果。
sealed class ExportFetchOutcome {
  const ExportFetchOutcome();
}

/// 取到了数据（已白名单化）。
final class ExportFetched extends ExportFetchOutcome {
  const ExportFetched(this.data);

  final ExportModuleData data;
}

/// 未登录 / 会话已失效。**导出页不会因此发起登录**，只提示用户去登录。
final class ExportNeedsLogin extends ExportFetchOutcome {
  const ExportNeedsLogin([this.message]);

  final String? message;
}

/// 其它失败（网络 / 响应异常等）；[message] 直接展示给用户。
final class ExportFetchFailed extends ExportFetchOutcome {
  const ExportFetchFailed(this.message);

  final String message;
}

/// 读取本机已有数据（缓存），不联网；没有则返回 `null`。
typedef ExportLocalReader = Future<ExportModuleData?> Function();

/// 经该模块**既有**服务与鉴权守卫联网获取。[force] 为 true 时绕过缓存有效期
/// （用户点「刷新」已过期的数据）。
typedef ExportFetcher = Future<ExportFetchOutcome> Function({
  required bool force,
});

/// 单个模块的取数来源。
class ExportModuleSource {
  const ExportModuleSource({
    required this.module,
    required this.fetch,
    this.readLocal,
  });

  final ExportModule module;
  final ExportFetcher fetch;

  /// 为 `null` 表示该模块没有可证明归属的本地缓存（只能现取，且只存在于本页内存）。
  final ExportLocalReader? readLocal;
}

// ── 身份 ────────────────────────────────────────────────────────────────────

/// 当前两个登录域的已验证身份；未登录为 `null`。
class ExportIdentity {
  const ExportIdentity({this.academic, this.unified});

  final String? academic;
  final String? unified;

  String? forDomain(ExportAuthDomain domain) => switch (domain) {
    ExportAuthDomain.academic => academic,
    ExportAuthDomain.unified => unified,
    // 第二课堂没有应用侧账号：任一登录域变化都视为变化（见 _domainKey）。
    ExportAuthDomain.session => '${academic ?? ''}|${unified ?? ''}',
  };
}

typedef ExportIdentityReader = ExportIdentity Function();

ExportIdentity readCurrentExportIdentity() {
  final z = ZhengfangAuth.instance;
  final u = UnifiedAuthService.instance;
  final studentId = z.verifiedStudentId;
  return ExportIdentity(
    academic: (z.isLoggedIn && studentId != null && studentId.isNotEmpty)
        ? studentId
        : null,
    unified: u.verifiedAccount,
  );
}

Listenable currentExportIdentityChanges() =>
    Listenable.merge([ZhengfangAuth.instance, UnifiedAuthService.instance]);

// ── 槽位 ────────────────────────────────────────────────────────────────────

enum ExportSlotPhase { idle, loading, needsLogin, failed }

class ExportSlot {
  const ExportSlot({
    this.data,
    this.phase = ExportSlotPhase.idle,
    this.message,
  });

  final ExportModuleData? data;
  final ExportSlotPhase phase;
  final String? message;

  ExportSlot copyWith({
    ExportModuleData? data,
    bool clearData = false,
    ExportSlotPhase? phase,
    String? message,
    bool clearMessage = false,
  }) => ExportSlot(
    data: clearData ? null : (data ?? this.data),
    phase: phase ?? this.phase,
    message: clearMessage ? null : (message ?? this.message),
  );
}

/// 页面渲染用的模块行状态。
enum ExportRowKind { loading, ready, missing, needsLogin, failed }

/// 导出页的状态机：每个模块一个槽位（本地读取 / 现取 / 需登录 / 失败），
/// 以及用途预设与模块选择。
///
/// 隐私与归属：
/// * 学业 / 统一认证域的数据绑定当时的已验证账号，账号切换或登出立即清空该域
///   全部数据（先清后读，不会带出上一个账号的内容）；
/// * 在途获取以「域代」校验，身份变化后迟到的结果直接丢弃；
/// * 本控制器永不触发登录：未登录只给「需登录」状态。
class AiExportController extends ChangeNotifier {
  AiExportController({
    required Iterable<ExportModuleSource> sources,
    ExportIdentityReader? identity,
    Listenable? identityChanges,
    DateTime Function()? clock,
    ExportEnvironment Function(DateTime now)? environment,
    ExportPreset initialPreset = ExportPreset.planning,
  }) : _sources = {for (final s in sources) s.module: s},
       _identity = identity ?? readCurrentExportIdentity,
       _identityChanges = identityChanges ?? currentExportIdentityChanges(),
       _clock = clock ?? DateTime.now,
       _environment = environment ?? ExportEnvironment.capture,
       _selected = {...initialPreset.modules} {
    for (final domain in ExportAuthDomain.values) {
      _bound[domain] = _identity().forDomain(domain);
    }
    _selected.removeWhere((m) => !_sources.containsKey(m));
    if (_selected.isEmpty && _sources.isNotEmpty) {
      _selected = {_sources.keys.first};
    }
    _identityChanges.addListener(_onIdentityChanged);
  }

  final Map<ExportModule, ExportModuleSource> _sources;
  final ExportIdentityReader _identity;
  final Listenable _identityChanges;
  final DateTime Function() _clock;
  final ExportEnvironment Function(DateTime now) _environment;

  final Map<ExportModule, ExportSlot> _slots = {};
  final Map<ExportAuthDomain, String?> _bound = {};
  final Map<ExportAuthDomain, int> _generation = {
    for (final d in ExportAuthDomain.values) d: 0,
  };
  Set<ExportModule> _selected;
  bool _disposed = false;
  bool _identityReset = false;

  /// 因账号切换 / 登出而清空过数据（页面据此给一次性提示）。
  bool get identityReset => _identityReset;

  void acknowledgeIdentityReset() {
    if (!_identityReset) return;
    _identityReset = false;
    _notify();
  }

  Set<ExportModule> get selected => Set.unmodifiable(_selected);

  ExportPreset? get preset => ExportPreset.matching(_selected);

  Iterable<ExportModule> get availableModules =>
      ExportModule.values.where(_sources.containsKey);

  ExportSlot slotOf(ExportModule module) =>
      _slots[module] ?? const ExportSlot();

  ExportRowKind rowKindOf(ExportModule module) {
    final slot = slotOf(module);
    if (slot.phase == ExportSlotPhase.loading) return ExportRowKind.loading;
    if (slot.phase == ExportSlotPhase.needsLogin ||
        (slot.data == null && _loggedOut(module))) {
      return ExportRowKind.needsLogin;
    }
    if (slot.phase == ExportSlotPhase.failed) return ExportRowKind.failed;
    return slot.data == null ? ExportRowKind.missing : ExportRowKind.ready;
  }

  bool _loggedOut(ExportModule module) {
    final domain = module.domain;
    if (domain == ExportAuthDomain.session) return false;
    return _identity().forDomain(domain) == null;
  }

  // ── 选择 ─────────────────────────────────────────────────────────────────

  void selectPreset(ExportPreset preset) {
    _selected = {...preset.modules}
      ..removeWhere((m) => !_sources.containsKey(m));
    _notify();
  }

  /// 微调：切换单个模块。至少保留一个。
  void toggleModule(ExportModule module) {
    final next = {..._selected};
    if (!next.remove(module)) {
      next.add(module);
    }
    if (next.isEmpty) return;
    _selected = next;
    _notify();
  }

  // ── 读取本机已有数据 ──────────────────────────────────────────────────────

  /// 逐模块读取本机缓存；单个模块失败不影响其它模块。
  Future<void> initialize() async {
    await Future.wait([for (final module in _sources.keys) _readLocal(module)]);
  }

  Future<void> _readLocal(ExportModule module) async {
    final reader = _sources[module]?.readLocal;
    if (reader == null) return;
    final domain = module.domain;
    final gen = _generation[domain]!;
    try {
      // 读取器自带归属校验（私有缓存按当前已验证账号过滤，未登录读到 null）。
      final data = await reader();
      if (_disposed || gen != _generation[domain]) return;
      if (data != null && data.status.hasData) {
        _slots[module] = slotOf(module).copyWith(data: data);
        _notify();
      }
    } catch (e) {
      AppLogger.instance.warn('ai export local read failed: ${e.runtimeType}');
    }
  }

  // ── 获取 ─────────────────────────────────────────────────────────────────

  /// 经既有服务联网获取。未登录直接进入「需登录」，不发请求、不触发登录。
  Future<void> fetch(ExportModule module) async {
    final source = _sources[module];
    if (source == null) return;
    final current = slotOf(module);
    if (current.phase == ExportSlotPhase.loading) return;
    final domain = module.domain;
    if (_loggedOut(module)) {
      _slots[module] = current.copyWith(
        phase: ExportSlotPhase.needsLogin,
        clearMessage: true,
      );
      _notify();
      return;
    }
    final gen = _generation[domain]!;
    final force = current.data?.status == ExportModuleStatus.stale;
    _slots[module] = current.copyWith(
      phase: ExportSlotPhase.loading,
      clearMessage: true,
    );
    _notify();
    ExportFetchOutcome outcome;
    try {
      outcome = await source.fetch(force: force);
    } catch (e) {
      AppLogger.instance.warn('ai export fetch failed: ${e.runtimeType}');
      outcome = const ExportFetchFailed('获取失败，请稍后重试');
    }
    // 身份在途中变化：旧结果一律丢弃（槽位已被清空并重置）。
    if (_disposed || gen != _generation[domain]) return;
    final slot = slotOf(module);
    _slots[module] = switch (outcome) {
      ExportFetched(:final data) => ExportSlot(data: data),
      ExportNeedsLogin(:final message) => slot.copyWith(
        phase: ExportSlotPhase.needsLogin,
        message: message,
      ),
      ExportFetchFailed(:final message) => slot.copyWith(
        phase: ExportSlotPhase.failed,
        message: message,
      ),
    };
    _notify();
  }

  // ── 身份变化 ──────────────────────────────────────────────────────────────

  void _onIdentityChanged() {
    if (_disposed) return;
    final now = _identity();
    var changed = false;
    for (final domain in ExportAuthDomain.values) {
      final key = now.forDomain(domain);
      if (key == _bound[domain]) continue;
      _bound[domain] = key;
      _generation[domain] = _generation[domain]! + 1;
      changed = true;
      final affected = _sources.keys.where((m) => m.domain == domain).toList();
      final hadData = affected.any((m) => slotOf(m).data != null);
      for (final m in affected) {
        _slots.remove(m);
      }
      if (hadData) _identityReset = true;
      if (key != null) {
        for (final m in affected) {
          // 登录 / 换号后只重读新账号自己的缓存（读取器自带归属校验）。
          _readLocal(m);
        }
      }
    }
    if (changed) _notify();
  }

  // ── 文档 ─────────────────────────────────────────────────────────────────

  /// 以当前选择和槽位数据构建文档；未取到数据的所选模块以「未获取」占位。
  AiExportDocument buildDocument() {
    final now = _clock();
    return AiExportDocument(
      exportedAt: now,
      environment: _environment(now),
      modules: [
        for (final module in ExportModule.values)
          if (_selected.contains(module))
            slotOf(module).data ?? ExportModuleData.missing(module),
      ],
    );
  }

  /// 当前是否存在可导出的数据（至少一个所选模块有数据）。
  bool get hasExportableData => _selected.any((m) => slotOf(m).data != null);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _identityChanges.removeListener(_onIdentityChanged);
    super.dispose();
  }
}
