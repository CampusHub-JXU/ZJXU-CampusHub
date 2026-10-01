import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/auth/unified_auth.dart';
import '../../core/cache/cache_policy.dart';
import '../../core/cache/cached_resource.dart';
import '../../core/logging/app_logger.dart';
import '../../core/system_surface/campus_data_change_bus.dart';
import 'dorm_electricity_models.dart';
import 'dorm_electricity_private_writes.dart';
import '../../core/epay100/epay100_gateway.dart';

// DTO / 异常拆分到 dorm_electricity_models.dart；重新导出，保持
// `import .../dorm_electricity_service.dart` 的历史调用方不变。
export 'dorm_electricity_models.dart';

/// 宿舍电费服务：数据源为 epay100 新版电控（老 jdhq.wap 系统已于 2026-08
/// 下线）。RPC 经 [Epay100Gateway] 在隐藏 WebView 页面上下文发出，
/// 会话不可用时抛 [EpaySessionUnavailableException]，由本层转译为
/// [_lastError] 并回退缓存。
///
/// **单账号归属（fail closed）**：房间配置 / 余额缓存 / 预警设置都绑定
/// 统一认证账号 owner（[roomOwnerKey] 标记）。未登录、owner 标记缺失
/// （历史遗留无主数据）或 owner 与当前已验证账号不一致时：不展示、不查询、
/// 不回退缓存、不发送预警，磁盘数据保留但被忽略，直到用户显式重新选择
/// 房间（[saveRoomConfig] 才会重写 owner 标记）。换账号显式保存会重置旧
/// 账号的缓存与预警 opt-in，不做任何隐藏迁移。
///
/// **同一 isolate 串行**：所有私有 prefs 写入都排在同一条 FIFO 队列上
/// （[DormPrivateWrites]，zone 安全），写入前后复核捕获的 owner +
/// sessionRevision（必要时含 owner 标记），失败即放弃并回滚。因此 A 的迟到
/// 写入不会与 B 的显式保存交错留下混合状态；后台 isolate 的读取仍是
/// best-effort 复核，不宣称跨 isolate 原子性。
class DormElectricityService {
  DormElectricityService._() {
    UnifiedAuthService.instance.addListener(_onAuthChanged);
  }

  static final DormElectricityService instance = DormElectricityService._();

  // 房间 / 缓存 / 预警的 SharedPreferences 键：后台 isolate
  // （dorm_electricity_background.dart）读取同一批键，故作为公开常量，避免两处
  // 字面量漂移。
  static const keyAreaId = 'dorm_epay_area_id';
  static const keyBuildingId = 'dorm_epay_building_id';
  static const keyFloorId = 'dorm_epay_floor_id';
  static const keyRoomId = 'dorm_epay_room_id';

  /// 房间配置 / 余额缓存 / 预警设置的 owner 标记（统一认证账号）。
  ///
  /// 后台 isolate 也要读取同一标记，故作为公开常量避免两处字面量漂移。
  static const roomOwnerKey = 'dorm_room_owner';

  // 老系统（jdhq.wap）遗留键，迁移时清除。
  static const _legacyKeys = [
    'dorm_community_id',
    'dorm_building_id',
    'dorm_floor_id',
    'dorm_room_id',
  ];
  static const keyElectricity = 'dorm_cached_electricity';
  static const keyElectricityUpdatedAt = 'dorm_cached_electricity_updated_at';
  static const keyAlertEnabled = 'dorm_alert_enabled';
  static const keyAlertThreshold = 'dorm_alert_threshold';
  static const keyAlertLastNotifiedDate = 'dorm_alert_last_notified_date';
  static const refreshWindow = Duration(minutes: 30);
  static const _catalogCacheBucket = 'dorm_electricity_catalog';

  /// 电控适配器（麦狐统一前置 API）。网关会话里也可动态读取，
  /// 这里作为缺省值兜底。
  static const defaultAdapterId = '6279260700100006';

  /// 电费充值页（epay100 电控）。必须在微信内打开才会展示微信支付。
  static String get rechargeUrl => HeadlessEpay100Gateway.rechargeUrl;

  /// 从房间名解析楼层标签：`HX4-105` → `1楼`，`HX4-1005` → `10楼`。
  ///
  /// 约定 `-` 后数字串的末两位为房间序号、其余为楼层号；解析不出
  ///（无数字段 / 序号不足两位）返回 null，该房间不参与楼层筛选分组。
  static String? parseFloorLabel(String roomName) {
    final match = RegExp(r'-(\d{3,})号?$').firstMatch(roomName.trim());
    final digits = match?.group(1);
    if (digits == null || digits.length < 3) return null;
    final floor = int.tryParse(digits.substring(0, digits.length - 2));
    final seq = int.tryParse(digits.substring(digits.length - 2));
    if (floor == null || seq == null) return null;
    return '$floor楼';
  }

  @visibleForTesting
  Epay100Gateway gateway = Epay100Gateway.instance;

  SharedPreferences? _prefs;
  bool _cacheRestored = false;
  Future<double?>? _fetchElectricityFuture;
  String? _fetchElectricityOwner;
  int? _fetchElectricityRevision;
  final Map<String, CachedResource<String>> _catalogResources =
      <String, CachedResource<String>>{};

  double? _cachedElectricity;
  DateTime? _lastUpdated;

  /// 内存缓存当前归属的统一认证账号；null 表示不可展示（未登录 / 未采纳）。
  String? _cachedOwner;

  /// 内存缓存代际：每次清空 / 采纳 / 网络结果写入都会推进；异步 restoreCache
  /// 在读到更晚的代际时放弃回写，避免旧磁盘值覆盖刚取回的新值。
  int _cacheGeneration = 0;

  /// 最近一次观察到的已验证 owner，用于识别身份变化（同 owner 的 revision
  /// 变化不清内存缓存，由 inflight 归属校验处理）。
  String? _lastAuthOwner;

  /// 当前已验证的统一认证 owner；未登录 / 空白账号一律 null（fail closed）。
  static String? _verifiedOwnerOf(UnifiedAuthService auth) {
    if (!auth.isLoggedIn) return null;
    final account = auth.currentAccount?.trim();
    return (account == null || account.isEmpty) ? null : account;
  }

  String? get _currentOwner => _verifiedOwnerOf(UnifiedAuthService.instance);

  /// 捕获的 owner + sessionRevision 是否仍是当前身份（每个 await 边界复核）。
  bool _isCurrentIdentity(String owner, int revision) {
    final auth = UnifiedAuthService.instance;
    return _verifiedOwnerOf(auth) == owner && auth.sessionRevision == revision;
  }

  /// 同一 isolate 内私有 prefs 变更的串行队列与受守卫写入（zone 安全，
  /// 设计与 zone 契约见 [DormPrivateWrites]）。
  final DormPrivateWrites _privateWrites = DormPrivateWrites();

  /// 测试注入：委托 [DormPrivateWrites.debugWriteHook]（钩子契约见该类）。
  @visibleForTesting
  set debugPrivateWriteHook(
    Future<void> Function(
      String operation,
      String key,
      Future<void> Function() write,
    )?
    value,
  ) => _privateWrites.debugWriteHook = value;

  /// 把一次私有变更排到串行队列尾部（见 [DormPrivateWrites.serialize]）。
  Future<void> _serializedPrivateMutation(Future<void> Function() action) =>
      _privateWrites.serialize(action);

  /// 串行队列内的一次受守卫私有写入（见 [DormPrivateWrites.guarded]）。
  Future<bool> _guardedPrivateWrite({
    required String operation,
    required String key,
    required bool Function() verify,
    required Future<void> Function() write,
    Future<void> Function()? rollback,
  }) => _privateWrites.guarded(
    operation: operation,
    key: key,
    verify: verify,
    write: write,
    rollback: rollback,
  );

  /// 统一认证身份变化：内存缓存只允许同 owner 展示；身份变化先清空，
  /// 出现已验证 owner 时再按 owner 标记恢复持久缓存（冷启动暖缓存路径）。
  void _onAuthChanged() {
    final owner = _currentOwner;
    if (owner == _lastAuthOwner) return;
    _lastAuthOwner = owner;
    _clearMemoryCache();
    _cacheRestored = false;
    _lastError = null;
    _requiresAuthentication = false;
    if (owner != null) {
      unawaited(restoreCache());
    }
  }

  void _clearMemoryCache() {
    _cachedElectricity = null;
    _lastUpdated = null;
    _cachedOwner = null;
    _cacheGeneration++;
  }

  /// 只在内存缓存归属与当前已验证统一认证账号一致时可见。
  double? get cachedElectricity {
    final owner = _cachedOwner;
    if (owner == null || owner != _currentOwner) return null;
    return _cachedElectricity;
  }

  /// 与 [cachedElectricity] 同归属校验；未登录 / 换号后视为「未刷新」。
  DateTime? get lastUpdated {
    final owner = _cachedOwner;
    if (owner == null || owner != _currentOwner) return null;
    return _lastUpdated;
  }

  bool get hasFreshCache {
    final updatedAt = lastUpdated;
    if (cachedElectricity == null || updatedAt == null) return false;
    return DateTime.now().difference(updatedAt) <= refreshWindow;
  }

  String? _lastError;
  String? get lastError => _lastError;
  bool _requiresAuthentication = false;
  bool get requiresAuthentication => _requiresAuthentication;

  @visibleForTesting
  void debugSetGateway(Epay100Gateway value) => gateway = value;

  /// 测试注入：restoreCache 在采纳磁盘值之前调用（验证旧代际不回写）。
  @visibleForTesting
  Future<void> Function()? debugBeforeCacheAdopt;

  /// 测试注入：loadRoomConfig 在最后一个 await 之后、复核身份并暴露配置
  /// 之前的边界（验证身份在等待内变化时不返回旧快照）。
  @visibleForTesting
  Future<void> Function()? debugBeforeRoomConfigExpose;

  Future<void> invalidateGatewaySession() => gateway.invalidate();

  Future<void> restoreCache({bool force = false}) async {
    if (_cacheRestored && !force) return;
    final owner = _currentOwner;
    if (owner == null) {
      // 未登录：不读、不采纳、不展示；身份就绪后（auth 监听或下次调用）
      // 再按 owner 标记恢复。
      _clearMemoryCache();
      return;
    }
    final revision = UnifiedAuthService.instance.sessionRevision;
    final generation = _cacheGeneration;
    final prefs = await _ensurePrefs();
    // 老系统 id 空间与 epay100 不兼容，一次性清除遗留配置（只删不采纳）。
    // 清理同样排在私有变更队列上：绝不与 B 的显式保存交错、删掉新身份刚写入
    // 的缓存；身份已变化或磁盘归属他人时整体跳过（留给该 owner 自己清理）。
    await _serializedPrivateMutation(() async {
      if (!_isCurrentIdentity(owner, revision)) return;
      final marker = prefs.getString(roomOwnerKey);
      if (marker != null && marker != owner) return;
      var removedLegacyConfig = false;
      for (final key in _legacyKeys) {
        if (prefs.containsKey(key)) {
          await prefs.remove(key);
          removedLegacyConfig = true;
        }
      }
      if (removedLegacyConfig) {
        await prefs.remove(keyElectricity);
        await prefs.remove(keyElectricityUpdatedAt);
        await prefs.remove(keyAlertLastNotifiedDate);
      }
    });
    if (!_isCurrentIdentity(owner, revision)) return;
    if (generation != _cacheGeneration) return;
    // 测试注入：可在采纳磁盘值之前推进内存缓存代际，验证旧值不回写。
    await debugBeforeCacheAdopt?.call();
    if (generation != _cacheGeneration) return;
    // 注入点同样是 await 边界：同账号重登只推进 revision（无监听、不推进
    // 内存缓存代际），必须在采纳前复核身份，绝不把旧 epoch 的磁盘快照当成
    // 新 epoch 的缓存值。
    if (!_isCurrentIdentity(owner, revision)) return;
    if (prefs.getString(roomOwnerKey) != owner) {
      // 无 owner 标记（历史遗留无主数据）或归属他人：fail closed，磁盘
      // 数据保留但绝不展示/采纳，直到用户显式重新选择房间。
      _clearMemoryCache();
      _cacheRestored = true;
      return;
    }
    _cachedElectricity = prefs.getDouble(keyElectricity);
    final updatedAtMillis = prefs.getInt(keyElectricityUpdatedAt);
    _lastUpdated = updatedAtMillis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(updatedAtMillis);
    _cachedOwner = owner;
    _cacheGeneration++;
    _cacheRestored = true;
  }

  Future<bool> hasRoomConfig() async {
    final config = await loadRoomConfig();
    return config != null;
  }

  /// 返回 owner 归属仍一致的 prefs 快照；未登录 / 归属不一致返回 null
  /// （fail closed：调用方不得读写任何 owner 作用域的数据）。
  Future<SharedPreferences?> _ownedPrefs(String owner) async {
    final revision = UnifiedAuthService.instance.sessionRevision;
    final prefs = await _ensurePrefs();
    if (!_isCurrentIdentity(owner, revision)) return null;
    if (prefs.getString(roomOwnerKey) != owner) return null;
    return prefs;
  }

  /// 只在当前已验证统一认证账号与 owner 标记一致时返回配置；无标记或
  /// 归属他人一律 null（fail closed）。
  Future<DormRoomConfig?> loadRoomConfig() async {
    final owner = _currentOwner;
    if (owner == null) return null;
    final revision = UnifiedAuthService.instance.sessionRevision;
    final prefs = await _ownedPrefs(owner);
    if (prefs == null) return null;
    // 最后一个 await 边界：_ownedPrefs 内部的复核只覆盖它自己的等待，
    // 同账号重登只推进 revision（无监听），这里必须用入口捕获的 revision
    // 再复核一次，绝不把旧 epoch 的配置快照暴露给新 epoch。
    await debugBeforeRoomConfigExpose?.call();
    if (!_isCurrentIdentity(owner, revision)) return null;
    final areaId = prefs.getString(keyAreaId);
    final buildingId = prefs.getString(keyBuildingId);
    final floorId = prefs.getString(keyFloorId);
    final roomId = prefs.getString(keyRoomId);
    if (areaId == null ||
        buildingId == null ||
        floorId == null ||
        roomId == null) {
      return null;
    }
    return DormRoomConfig(
      areaId: areaId,
      buildingId: buildingId,
      floorId: floorId,
      roomId: roomId,
    );
  }

  /// 显式保存寝室配置：只允许当前已验证统一认证账号写入。
  ///
  /// 整个写入排在私有变更队列上（见 [_privateMutationQueue]）：owner 标记
  /// **先失效、最后落**，中途每次写入前后都复核身份，身份变化时回滚本次写入
  /// 并抛错，不会留下被采纳的半写入配置；换 owner 时重置旧账号的余额缓存、
  /// 预警 opt-in 与当日通知状态（新账号必须自己重新开启预警），不做任何
  /// 隐藏迁移。
  Future<void> saveRoomConfig(DormRoomConfig config) async {
    final owner = _currentOwner;
    if (owner == null) {
      throw const DormServiceException('请先登录一卡通后再保存寝室');
    }
    final revision = UnifiedAuthService.instance.sessionRevision;
    await _serializedPrivateMutation(() async {
      final prefs = await _ensurePrefs();
      bool identityIntact() => _isCurrentIdentity(owner, revision);

      // 每次写入都复核身份；身份在写入后变化时回滚本次写入并抛错。
      Future<void> write(String key, Future<void> Function() op) async {
        final applied = await _guardedPrivateWrite(
          operation: 'saveRoomConfig',
          key: key,
          verify: identityIntact,
          write: op,
          rollback: () => prefs.remove(key),
        );
        if (!applied) {
          throw const DormServiceException('登录状态已变化，请重新登录后再保存');
        }
      }

      if (!identityIntact()) {
        throw const DormServiceException('登录状态已变化，请重新登录后再保存');
      }
      final previousOwner = prefs.getString(roomOwnerKey);
      // 先失效 owner 标记：半写入配置绝不被采纳。
      await write(roomOwnerKey, () => prefs.remove(roomOwnerKey));
      // 余额必须和房间配置绑定；保存后强制下一次查询新房间，绝不能回退到
      // 上一个寝室的缓存值。
      await write(keyElectricity, () => prefs.remove(keyElectricity));
      await write(
        keyElectricityUpdatedAt,
        () => prefs.remove(keyElectricityUpdatedAt),
      );
      await write(
        keyAlertLastNotifiedDate,
        () => prefs.remove(keyAlertLastNotifiedDate),
      );
      if (previousOwner != owner) {
        await write(
          keyAlertEnabled,
          () => prefs.setBool(keyAlertEnabled, false),
        );
        await write(keyAlertThreshold, () => prefs.remove(keyAlertThreshold));
      }
      await write(keyAreaId, () => prefs.setString(keyAreaId, config.areaId));
      await write(
        keyBuildingId,
        () => prefs.setString(keyBuildingId, config.buildingId),
      );
      await write(
        keyFloorId,
        () => prefs.setString(keyFloorId, config.floorId),
      );
      await write(keyRoomId, () => prefs.setString(keyRoomId, config.roomId));
      // owner 标记最后落：只有全部键写入成功后才可被采纳；身份在落盘后
      // 变化时立即撤回标记（回滚），绝不让新身份采纳旧身份的半写入配置。
      await write(roomOwnerKey, () => prefs.setString(roomOwnerKey, owner));
      _clearMemoryCache();
      _cacheRestored = false;
      _lastError = null;
      _requiresAuthentication = false;
    });
  }

  /// 显式清除寝室配置 / 余额缓存 / 预警设置与 owner 标记。
  ///
  /// 与其他私有变更同队列串行：绝不在 B 的显式保存中间穿插删除，留下半清除
  /// 状态。清除资格**在队列内按执行时的身份与磁盘标记复核**（不在调用时
  /// 一次性判定）：已登录时要求捕获的 owner + revision 仍有效、磁盘标记为
  /// 空或属己；未登录（调用时 owner 为 null）时只允许清除真正无主的遗留数据，
  /// 排队期间 B 若已登录或已保存（owner 标记出现），整体跳过——A 登出后迟到
  /// 的清除绝不删掉 B 的新状态，也不清 B 正在展示的内存视图。
  Future<void> clearRoomConfig() async {
    final owner = _currentOwner;
    final revision = UnifiedAuthService.instance.sessionRevision;
    var cleared = false;
    await _serializedPrivateMutation(() async {
      final prefs = await _ensurePrefs();
      if (owner == null) {
        // 无 owner 归属：只清无主（无标记）数据；身份或标记任一显示已有
        // 归属就整体跳过，绝不把 B 的保存当遗留数据删掉。
        if (_currentOwner != null) return;
        if (prefs.getString(roomOwnerKey) != null) return;
      } else {
        if (!_isCurrentIdentity(owner, revision)) return;
        final marker = prefs.getString(roomOwnerKey);
        if (marker != null && marker != owner) return;
      }
      for (final key in [
        keyAreaId,
        keyBuildingId,
        keyFloorId,
        keyRoomId,
        roomOwnerKey,
        keyElectricity,
        keyElectricityUpdatedAt,
        keyAlertEnabled,
        keyAlertThreshold,
        keyAlertLastNotifiedDate,
      ]) {
        await prefs.remove(key);
      }
      cleared = true;
    });
    if (!cleared || _currentOwner != owner) return;
    _clearMemoryCache();
    _cacheRestored = false;
    _lastError = null;
    _requiresAuthentication = false;
  }

  // ── 低电量预警 ──

  /// 预警设置同样按 owner 归属：未登录 / 无 owner 标记 / 归属他人一律
  /// 按「未开启」处理，绝不把 A 的 opt-in 透给 B。
  Future<bool> getAlertEnabled() async {
    final owner = _currentOwner;
    if (owner == null) return false;
    final revision = UnifiedAuthService.instance.sessionRevision;
    final prefs = await _ownedPrefs(owner);
    if (prefs == null || !_isCurrentIdentity(owner, revision)) return false;
    return prefs.getBool(keyAlertEnabled) ?? false;
  }

  /// 无 owner 归属时静默失败（不写、不迁移），避免把设置写到别的账号上。
  ///
  /// 写入排在私有变更队列上：即使与 B 的显式保存并发，也只在 owner 标记
  /// 仍属于捕获身份时写入，写入后身份变化则回滚（绝不把 A 的 opt-in 留给 B）。
  Future<void> setAlertEnabled(bool value) async {
    final owner = _currentOwner;
    if (owner == null) return;
    final revision = UnifiedAuthService.instance.sessionRevision;
    await _serializedPrivateMutation(() async {
      final prefs = await _ensurePrefs();
      bool stillOwned() =>
          _isCurrentIdentity(owner, revision) &&
          prefs.getString(roomOwnerKey) == owner;
      final previous = prefs.getBool(keyAlertEnabled);
      await _guardedPrivateWrite(
        operation: 'setAlertEnabled',
        key: keyAlertEnabled,
        verify: stillOwned,
        write: () => prefs.setBool(keyAlertEnabled, value),
        rollback: previous == null
            ? () => prefs.remove(keyAlertEnabled)
            : () => prefs.setBool(keyAlertEnabled, previous),
      );
    });
  }

  static const double defaultAlertThreshold = 20;

  Future<double> getAlertThreshold() async {
    final owner = _currentOwner;
    if (owner == null) return defaultAlertThreshold;
    final revision = UnifiedAuthService.instance.sessionRevision;
    final prefs = await _ownedPrefs(owner);
    if (prefs == null || !_isCurrentIdentity(owner, revision)) {
      return defaultAlertThreshold;
    }
    return prefs.getDouble(keyAlertThreshold) ?? defaultAlertThreshold;
  }

  Future<void> setAlertThreshold(double value) async {
    final owner = _currentOwner;
    if (owner == null) return;
    final revision = UnifiedAuthService.instance.sessionRevision;
    await _serializedPrivateMutation(() async {
      final prefs = await _ensurePrefs();
      bool stillOwned() =>
          _isCurrentIdentity(owner, revision) &&
          prefs.getString(roomOwnerKey) == owner;
      final previous = prefs.getDouble(keyAlertThreshold);
      await _guardedPrivateWrite(
        operation: 'setAlertThreshold',
        key: keyAlertThreshold,
        verify: stillOwned,
        write: () => prefs.setDouble(keyAlertThreshold, value),
        rollback: previous == null
            ? () => prefs.remove(keyAlertThreshold)
            : () => prefs.setDouble(keyAlertThreshold, previous),
      );
    });
  }

  /// 本地日期 `yyyy-MM-dd`；预警「当日已通知」标记与后台任务共用。
  static String todayString() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  /// 低电量检查：owner + sessionRevision 在发起时捕获，每个 await 边界复核；
  /// 身份变化后旧检查既不回调 onAlert，也不写当日通知状态。
  ///
  /// 当日通知状态的「读取 → 判定 → 回调 → 落盘」整体排在同一条私有变更
  /// 队列上：两个并发的同身份检查绝不各自读到空标记、各自回调（重复通知）
  /// 后互相覆盖，后到者只看到「今天已通知」。
  Future<void> checkAndAlert({
    required void Function({required double value, required double threshold})
    onAlert,
  }) async {
    final owner = _currentOwner;
    if (owner == null) return;
    final revision = UnifiedAuthService.instance.sessionRevision;
    bool identityIntact() => _isCurrentIdentity(owner, revision);

    final enabled = await getAlertEnabled();
    if (!identityIntact() || !enabled) return;

    final hasConfig = await hasRoomConfig();
    if (!identityIntact() || !hasConfig) return;

    final electricity = await fetchElectricity();
    if (!identityIntact() || electricity == null) return;

    final threshold = await getAlertThreshold();
    if (!identityIntact()) return;

    final prefs = await _ensurePrefs();
    bool stillOwned() =>
        identityIntact() && prefs.getString(roomOwnerKey) == owner;
    if (!stillOwned()) return;

    final today = todayString();
    await _serializedPrivateMutation(() async {
      if (!stillOwned()) return;
      final lastNotified = prefs.getString(keyAlertLastNotifiedDate);
      if (electricity >= threshold) {
        // 电量已回到阈值之上：撤掉当日标记，下次跌回阈值内仍可提醒。
        if (lastNotified == null) return;
        await _guardedPrivateWrite(
          operation: 'checkAndAlert',
          key: keyAlertLastNotifiedDate,
          verify: stillOwned,
          write: () => prefs.remove(keyAlertLastNotifiedDate),
          rollback: () =>
              prefs.setString(keyAlertLastNotifiedDate, lastNotified),
        );
        return;
      }
      if (lastNotified == today) return;
      onAlert(value: electricity, threshold: threshold);
      if (!stillOwned()) return;
      await _guardedPrivateWrite(
        operation: 'checkAndAlert',
        key: keyAlertLastNotifiedDate,
        verify: stillOwned,
        write: () => prefs.setString(keyAlertLastNotifiedDate, today),
        rollback: lastNotified == null
            ? () => prefs.remove(keyAlertLastNotifiedDate)
            : () => prefs.setString(keyAlertLastNotifiedDate, lastNotified),
      );
    });
  }

  // ── RPC：四级目录 + 余额 ─────────────────────────────────────────────────

  /// 园区（校区）列表。
  Future<List<DormArea>> fetchAreas() async {
    final body = await _callCatalog('app.electric.getAreaList', {
      'adapter_id': defaultAdapterId,
    });
    final data = _decodeDataMap(body, '园区');
    final list = (data['area_list'] as List<dynamic>? ?? const []);
    return list
        .whereType<Map<String, dynamic>>()
        .map(
          (a) => DormArea(
            id: a['id'].toString(),
            name: a['value'] as String? ?? a['name'] as String? ?? '',
          ),
        )
        .toList();
  }

  /// 指定园区下的楼幢列表。
  Future<List<DormBuilding>> fetchBuildings(DormArea area) async {
    final body = await _callCatalog('app.electric.getBuildingList', {
      'adapter_id': defaultAdapterId,
      'L1_area_id': area.id,
    });
    final data = _decodeDataMap(body, '楼幢');
    final list = (data['building_list'] as List<dynamic>? ?? const []);
    return list.whereType<Map<String, dynamic>>().map((b) {
      return DormBuilding(
        areaId: area.id,
        areaName: area.name,
        buildingId: b['id'].toString(),
        buildingName: b['name'] as String? ?? '',
      );
    }).toList();
  }

  /// 指定楼幢下的全部房间（逐楼层展开；多数楼幢只有「默认楼层」）。
  Future<List<DormRoom>> fetchRooms({
    required String areaId,
    required String buildingId,
  }) async {
    final floorsBody = await _callCatalog('app.electric.getFloorList', {
      'adapter_id': defaultAdapterId,
      'L1_area_id': areaId,
      'L2_building_id': buildingId,
    });
    final floorsData = _decodeDataMap(floorsBody, '楼层');
    final floors = (floorsData['floor_list'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(
          (f) => DormFloor(
            areaId: areaId,
            buildingId: buildingId,
            floorId: f['id'].toString(),
            floorName: f['name'] as String? ?? '',
          ),
        )
        .toList();

    final rooms = <DormRoom>[];
    for (final floor in floors) {
      final roomsBody = await _callCatalog('app.electric.getRoomList', {
        'adapter_id': defaultAdapterId,
        'L1_area_id': areaId,
        'L2_building_id': buildingId,
        'L3_floor_id': floor.floorId,
      });
      final roomsData = _decodeDataMap(roomsBody, '房间');
      final list = (roomsData['room_list'] as List<dynamic>? ?? const []);
      rooms.addAll(
        list.whereType<Map<String, dynamic>>().map(
          (r) => DormRoom(
            areaId: areaId,
            buildingId: buildingId,
            floorId: floor.floorId,
            roomId: r['id'].toString(),
            floorName: floor.floorName,
            roomName: r['name'] as String? ?? '',
          ),
        ),
      );
    }
    return rooms;
  }

  /// 查询剩余电量（度）。失败时回退**同 owner** 缓存并设置 [_lastError]。
  ///
  /// 未登录：不查询、不回退缓存。in-flight 去重按 owner + sessionRevision
  /// 绑定：A 在途请求绝不会被 B 复用，也不会把 A 的结果写进 B 的内存缓存 /
  /// 磁盘缓存或通知总线。
  Future<double?> fetchElectricity({bool forceRefresh = false}) async {
    final owner = _currentOwner;
    if (owner == null) {
      // 未登录：不展示、不查询、不回退缓存。
      _clearMemoryCache();
      _lastError = null;
      _requiresAuthentication = true;
      return null;
    }
    final revision = UnifiedAuthService.instance.sessionRevision;

    if (!forceRefresh) {
      // 先按 owner 采纳持久缓存再判断新鲜度：冷启动身份恢复与 fetch 存在
      // 竞态时，也绝不因为内存未预热而多发一次网络请求。
      await restoreCache();
      if (!_isCurrentIdentity(owner, revision)) return null;
      if (hasFreshCache) {
        _lastError = null;
        _requiresAuthentication = false;
        return _cachedElectricity;
      }
    }

    final existing = _fetchElectricityFuture;
    if (existing != null &&
        _fetchElectricityOwner == owner &&
        _fetchElectricityRevision == revision) {
      return existing;
    }

    final future = _fetchElectricityInner(owner: owner, revision: revision);
    _fetchElectricityFuture = future;
    _fetchElectricityOwner = owner;
    _fetchElectricityRevision = revision;
    try {
      return await future;
    } finally {
      if (identical(_fetchElectricityFuture, future)) {
        _fetchElectricityFuture = null;
        _fetchElectricityOwner = null;
        _fetchElectricityRevision = null;
      }
    }
  }

  Future<double?> _fetchElectricityInner({
    required String owner,
    required int revision,
  }) async {
    try {
      await restoreCache();
      if (!_isCurrentIdentity(owner, revision)) return null;

      final config = await loadRoomConfig();
      if (!_isCurrentIdentity(owner, revision)) return null;
      if (config == null) {
        _lastError = null;
        _requiresAuthentication = false;
        return null;
      }

      final body = await _call('app.electric.getRoomBalance', {
        'adapter_id': defaultAdapterId,
        'L1_area_id': config.areaId,
        'L2_building_id': config.buildingId,
        'L3_floor_id': config.floorId,
        'L4_room_id': config.roomId,
      });
      if (!_isCurrentIdentity(owner, revision)) return null;
      final data = _decodeDataMap(body, '余额');
      final list = (data['balance_list'] as List<dynamic>? ?? const []);
      String? balanceText;
      for (final b in list.whereType<Map<String, dynamic>>()) {
        if (b['id'].toString() == config.roomId) {
          balanceText = b['balance']?.toString();
          break;
        }
      }
      final value = balanceText == null ? null : double.tryParse(balanceText);
      if (value == null) {
        if (!_isCurrentIdentity(owner, revision)) return null;
        _lastError = '数据解析失败';
        return cachedElectricity;
      }
      if (!_isCurrentIdentity(owner, revision)) return null;
      _cachedElectricity = value;
      _lastUpdated = DateTime.now();
      _cachedOwner = owner;
      _cacheGeneration++;
      await _persistCache(owner: owner, revision: revision);
      if (!_isCurrentIdentity(owner, revision)) return null;
      CampusDataChangeBus.instance.notifyChanged();
      _lastError = null;
      _requiresAuthentication = false;
      AppLogger.instance.network(LogLevel.info, '电费解析成功: $value 度');
      return value;
    } on EpaySessionUnavailableException catch (e) {
      if (!_isCurrentIdentity(owner, revision)) return null;
      AppLogger.instance.network(LogLevel.warn, '电费会话不可用: ${e.message}');
      _lastError = e.message;
      _requiresAuthentication = true;
      return cachedElectricity;
    } on EpayGatewayException catch (e) {
      if (!_isCurrentIdentity(owner, revision)) return null;
      AppLogger.instance.network(LogLevel.warn, '电费网关请求失败: ${e.message}');
      _lastError = e.message;
      _requiresAuthentication = false;
      return cachedElectricity;
    } on DormServiceException catch (e) {
      if (!_isCurrentIdentity(owner, revision)) return null;
      _lastError = e.message;
      _requiresAuthentication = false;
      return cachedElectricity;
    } catch (e) {
      if (!_isCurrentIdentity(owner, revision)) return null;
      AppLogger.instance.network(LogLevel.error, '电费查询异常: $e');
      _lastError = '未知错误';
      _requiresAuthentication = false;
      return cachedElectricity;
    }
  }

  String formatElectricity(double? value) {
    if (value == null) return '--';
    if (value == value.truncateToDouble()) {
      return value.toInt().toString();
    }
    return value.toStringAsFixed(2);
  }

  // ── 内部 ────────────────────────────────────────────────────────────────

  Future<String> _call(String method, Map<String, String> data) {
    return gateway.call(method, data);
  }

  /// 目录 RPC 超时/网关抖动时自动重试一次。超时路径会作废会话，下一次
  /// 调用会重建会话，多数情况下第二次即成功；绑定缺失需用户处理，不重试。
  static const _catalogRetryAttempts = 2;
  static const _catalogRetryDelay = Duration(milliseconds: 600);

  Future<String> _callCatalogWithRetry(
    String method,
    Map<String, String> data,
  ) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await _call(method, data);
      } catch (error) {
        if (attempt >= _catalogRetryAttempts ||
            !_isRetryableCatalogError(error)) {
          rethrow;
        }
        await Future<void>.delayed(_catalogRetryDelay);
      }
    }
  }

  bool _isRetryableCatalogError(Object error) =>
      error is EpayGatewayException && error is! EpayBindingRequiredException;

  /// 目录 RPC 走通用读穿缓存。余额等动态数据仍使用 [_call]，避免把实时值
  /// 按目录 TTL 缓存。key 包含排序后的全部参数，同一方法不同园区/楼幢不会
  /// 串数据。
  Future<String> _callCatalog(String method, Map<String, String> data) async {
    final sortedEntries = data.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final cacheKey = jsonEncode(<String, Object?>{
      'method': method,
      'params': <String, String>{
        for (final entry in sortedEntries) entry.key: entry.value,
      },
    });
    final requestData = Map<String, String>.unmodifiable(data);
    final resource = _catalogResources.putIfAbsent(
      cacheKey,
      () => CachedResource<String>(
        bucket: _catalogCacheBucket,
        key: cacheKey,
        policy: CachePolicy.catalog,
        decode: (payload) => payload is String ? payload : null,
        encode: (value) => value,
        fetch: () => _callCatalogWithRetry(method, requestData),
      ),
    );
    final result = await resource.get();
    final value = result.value;
    if (value != null) return value;
    final error = result.error;
    if (error != null) throw error;
    throw const DormServiceException('电费目录数据不可用');
  }

  /// 解析 RPC 响应信封 `{"code":"200","msg":"SUC0000","data":{...}}`。
  Map<String, dynamic> _decodeDataMap(String body, String label) {
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw DormServiceException('电费$label数据无法识别');
    }
    if (json is! Map<String, dynamic>) {
      throw DormServiceException('电费$label数据格式异常');
    }
    if (json['code']?.toString() != '200') {
      final message = json['msg']?.toString();
      throw DormServiceException(
        message == null || message.isEmpty ? '电费$label请求失败' : message,
      );
    }
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw DormServiceException('电费$label数据为空');
    }
    return data;
  }

  Future<SharedPreferences> _ensurePrefs() async {
    final prefs = _prefs;
    if (prefs != null) return prefs;
    final created = await SharedPreferences.getInstance();
    _prefs = created;
    return created;
  }

  Future<void> _persistCache({
    required String owner,
    required int revision,
  }) async {
    // 多键写入排在同一串行队列上：绝不与 B 的显式保存交错，留下
    // 「B 的 owner 标记 + A 的余额 / 时间戳」的混合状态。
    await _serializedPrivateMutation(() async {
      final prefs = await _ensurePrefs();
      bool stillOwned() =>
          _isCurrentIdentity(owner, revision) &&
          _cachedOwner == owner &&
          prefs.getString(roomOwnerKey) == owner;
      final value = _cachedElectricity;
      final updatedAt = _lastUpdated;
      if (value == null || updatedAt == null) return;
      final wroteValue = await _guardedPrivateWrite(
        operation: 'persistCache',
        key: keyElectricity,
        verify: stillOwned,
        write: () => prefs.setDouble(keyElectricity, value),
        rollback: () => prefs.remove(keyElectricity),
      );
      if (!wroteValue) return;
      final wroteTimestamp = await _guardedPrivateWrite(
        operation: 'persistCache',
        key: keyElectricityUpdatedAt,
        verify: stillOwned,
        write: () => prefs.setInt(
          keyElectricityUpdatedAt,
          updatedAt.millisecondsSinceEpoch,
        ),
        rollback: () => prefs.remove(keyElectricityUpdatedAt),
      );
      if (wroteTimestamp) return;
      // 时间戳被放弃 / 回滚：值也必须撤掉，绝不留下半对缓存（归属仍属捕获
      // owner 或已无主时才删，绝不误删新身份刚写入的数据）。
      final marker = prefs.getString(roomOwnerKey);
      if (marker == null || marker == owner) {
        await prefs.remove(keyElectricity);
      }
    });
  }

  @visibleForTesting
  void debugSetCachedElectricity(double? value, {DateTime? updatedAt}) {
    _cachedElectricity = value;
    _lastUpdated = updatedAt;
    _cachedOwner = _currentOwner;
    _cacheGeneration++;
    _cacheRestored = true;
  }

  @visibleForTesting
  void debugReset() {
    gateway = Epay100Gateway.instance;
    _prefs = null;
    _cacheRestored = false;
    _cachedElectricity = null;
    _lastUpdated = null;
    _cachedOwner = null;
    _cacheGeneration = 0;
    _lastAuthOwner = null;
    _lastError = null;
    _requiresAuthentication = false;
    _fetchElectricityFuture = null;
    _fetchElectricityOwner = null;
    _fetchElectricityRevision = null;
    _catalogResources.clear();
    debugBeforeCacheAdopt = null;
    debugBeforeRoomConfigExpose = null;
    _privateWrites.debugReset();
  }
}
