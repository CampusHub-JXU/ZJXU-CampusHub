import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../logging/app_logger.dart';
import '../platform/safe_invoke.dart';
import 'update_model.dart';
import 'update_source.dart' show deviceAbiSuffix;

/// 应用内 APK 受管更新的固定通道协议（与原生侧 lockstep）。
///
/// 通道：`edu.zjxu.jxucampushub/app_update`。参数与结果只使用
/// StandardMethodCodec 支持的基本类型（`Map` / `List` / `String` / `int` /
/// `bool`）。
///
/// 设计边界（本阶段为 Dart 契约，原生实现另起阶段）：
/// - Dart 侧**不**负责下载 / 进度 / 定时器：受管下载由系统 DownloadManager
///   在原生进程执行，原生持久化受管请求 id 为唯一权威；本控制器只做参数校验、
///   状态解码与状态投影。
/// - 通道参数**只**含协议字段（版本 / 规范资产 URL / 文件名 / 摘要 / ABI /
///   请求 key），**绝不**传学号、账号、Cookie 或任意本地文件路径 / 下载 id。
/// - 输入 URL 必须是可信仓库的规范资产 URL，否则在调用通道前即拒绝。
abstract final class ApkUpdateProtocol {
  static const String channelName = 'edu.zjxu.jxucampushub/app_update';

  static const String methodIsSupported = 'isSupported';
  static const String methodStartDownload = 'startDownload';
  static const String methodQueryActiveUpdate = 'queryActiveUpdate';
  static const String methodCancelActiveUpdate = 'cancelActiveUpdate';
  static const String methodRequestInstall = 'requestInstall';
  static const String methodOpenInstallPermissionSettings =
      'openInstallPermissionSettings';

  /// 可信公开分发仓库（只信任此仓库的 Release 资产）。
  static const String trustedRepoHost = 'github.com';
  static const String trustedRepoOwner = 'FHfanshu';
  static const String trustedRepoName = 'ZJXU-CampusHub';

  static const int maxVersionLength = 64;
  static const int maxAssetFileNameLength = 256;
  static const int maxRequestKeyLength = 320;
}

/// 受管更新状态机（wire code 即枚举名，稳定）。
enum ApkUpdatePhase {
  idle,
  enqueued,
  downloading,
  paused,
  verifying,
  readyToInstall,
  permissionRequired,
  installerOpened,
  failed,
  canceled,
  unavailable;

  /// 是否属于「有在途 / 可继续」的活动状态（用于幂等去重）。
  bool get isActive => switch (this) {
    enqueued ||
    downloading ||
    paused ||
    verifying ||
    readyToInstall ||
    permissionRequired ||
    installerOpened => true,
    _ => false,
  };

  /// 解析原生 wire code；未知 / 非字符串一律 fail-closed 为 [unavailable]。
  static ApkUpdatePhase fromWire(Object? value) {
    if (value is! String) return ApkUpdatePhase.unavailable;
    for (final phase in values) {
      if (phase.name == value) return phase;
    }
    return ApkUpdatePhase.unavailable;
  }
}

/// 失败 / 不可用原因（安全枚举，**绝不**携带原生异常字符串）。
enum ApkUpdateFailureReason {
  unknown,
  unsupported,
  untrustedAsset,
  network,
  storageInsufficient,
  verificationFailed,
  signatureMismatch,
  packageMismatch,
  versionNotNewer,
  abiUnsupported,
  permissionDenied,
  installerUnavailable,
  nativeError;

  /// 解析原生 wire code；未知 / 非字符串为 [unknown]。
  static ApkUpdateFailureReason fromWire(Object? value) {
    if (value is! String) return ApkUpdateFailureReason.unknown;
    for (final reason in values) {
      if (reason.name == value) return reason;
    }
    return ApkUpdateFailureReason.unknown;
  }
}

/// 控制器对外投影的受管更新状态（值相等，便于 ValueNotifier 去重）。
@immutable
class ApkUpdateState {
  const ApkUpdateState({
    this.phase = ApkUpdatePhase.idle,
    this.bytesDownloaded,
    this.totalBytes,
    this.reason,
    this.version,
    this.requestKey,
    this.assetFileName,
  });

  const ApkUpdateState.idle() : this();

  final ApkUpdatePhase phase;

  /// 已下载字节数；未知时为 null（**不**合成百分比）。
  final int? bytesDownloaded;

  /// 总字节数；未知 / 非法时为 null（**不**合成百分比）。
  final int? totalBytes;

  /// 失败 / 不可用原因；仅 [phase] 为 failed / unavailable 时非 null。
  final ApkUpdateFailureReason? reason;

  /// 展示用版本名（`releaseVersion`，非 versionCode）。
  final String? version;

  /// 当前受管请求的稳定 idempotency key（原生持久化的同一 id）。
  final String? requestKey;

  /// 当前受管请求的 APK 文件名。
  final String? assetFileName;

  ApkUpdateState copyWith({
    ApkUpdatePhase? phase,
    int? bytesDownloaded,
    int? totalBytes,
    ApkUpdateFailureReason? reason,
    bool clearReason = false,
    String? version,
    String? requestKey,
    String? assetFileName,
  }) {
    return ApkUpdateState(
      phase: phase ?? this.phase,
      bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
      totalBytes: totalBytes ?? this.totalBytes,
      reason: clearReason ? null : (reason ?? this.reason),
      version: version ?? this.version,
      requestKey: requestKey ?? this.requestKey,
      assetFileName: assetFileName ?? this.assetFileName,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ApkUpdateState &&
      other.phase == phase &&
      other.bytesDownloaded == bytesDownloaded &&
      other.totalBytes == totalBytes &&
      other.reason == reason &&
      other.version == version &&
      other.requestKey == requestKey &&
      other.assetFileName == assetFileName;

  @override
  int get hashCode => Object.hash(
    phase,
    bytesDownloaded,
    totalBytes,
    reason,
    version,
    requestKey,
    assetFileName,
  );

  @override
  String toString() =>
      'ApkUpdateState(phase: ${phase.name}, bytes: $bytesDownloaded/'
      '$totalBytes, reason: ${reason?.name}, version: $version)';
}

/// 原生 map → [ApkUpdateState] 的严格解码（白名单字段 + 类型校验）。
///
/// 未知字段忽略；未知 phase / reason 分别 fail-closed 为
/// [ApkUpdatePhase.unavailable] / [ApkUpdateFailureReason.unknown]；非 map、
/// 越界 / 非法数值一律丢弃为 null，绝不合成进度。
abstract final class ApkUpdateStateCodec {
  /// 允许出现在原生 map 中的字段（其余忽略）。
  static const Set<String> allowedKeys = <String>{
    'phase',
    'bytesDownloaded',
    'totalBytes',
    'reason',
    'version',
    'requestKey',
    'assetFileName',
  };

  static ApkUpdateState fromNative(Object? raw) {
    if (raw is! Map) {
      return const ApkUpdateState(
        phase: ApkUpdatePhase.unavailable,
        reason: ApkUpdateFailureReason.unknown,
      );
    }

    var bytes = _nonNegativeInt(raw['bytesDownloaded']);
    final total = _positiveInt(raw['totalBytes']);
    // 进度未知 / 异常时有限化：已知总量且已下载越界则收敛到总量，
    // 绝不输出越界百分比。
    if (bytes != null && total != null && bytes > total) {
      bytes = total;
    }

    final phase = ApkUpdatePhase.fromWire(raw['phase']);
    final reason =
        (phase == ApkUpdatePhase.failed || phase == ApkUpdatePhase.unavailable)
        ? ApkUpdateFailureReason.fromWire(raw['reason'])
        : null;

    return ApkUpdateState(
      phase: phase,
      bytesDownloaded: bytes,
      totalBytes: total,
      reason: reason,
      version: _boundedString(
        raw['version'],
        ApkUpdateProtocol.maxVersionLength,
      ),
      requestKey: _boundedString(
        raw['requestKey'],
        ApkUpdateProtocol.maxRequestKeyLength,
      ),
      assetFileName: _boundedString(
        raw['assetFileName'],
        ApkUpdateProtocol.maxAssetFileNameLength,
      ),
    );
  }

  static int? _nonNegativeInt(Object? value) =>
      (value is int && value >= 0) ? value : null;

  static int? _positiveInt(Object? value) =>
      (value is int && value > 0) ? value : null;

  static String? _boundedString(Object? value, int maxLength) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > maxLength) return null;
    return trimmed;
  }
}

/// 可信资产 URL 校验：调用原生前必须通过。
///
/// 只接受 `https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/`
/// 之后接 `tag` / `apk` 两段路径的形态；拒绝 userinfo、fragment、query、非
/// https、非可信主机 / 仓库、编码路径穿越、非 `.apk` 文件名。
abstract final class ApkUpdateUrlPolicy {
  static bool isCanonicalAssetUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return false;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return false;
    if (uri.scheme != 'https') return false;
    if (uri.userInfo.isNotEmpty) return false;
    if (uri.fragment.isNotEmpty) return false;
    if (uri.hasQuery) return false;
    if (uri.hasPort) return false;
    if (uri.host.toLowerCase() != ApkUpdateProtocol.trustedRepoHost) {
      return false;
    }

    // pathSegments 已解码：`%2e%2e` → `..`、`%2f` → `/` 会被下面拒绝。
    final segments = uri.pathSegments;
    if (segments.length != 6) return false;
    if (segments[0] != ApkUpdateProtocol.trustedRepoOwner) return false;
    if (segments[1] != ApkUpdateProtocol.trustedRepoName) return false;
    if (segments[2] != 'releases' || segments[3] != 'download') return false;

    final tag = segments[4];
    final file = segments[5];
    if (_isUnsafeSegment(tag) || _isUnsafeSegment(file)) return false;
    if (!file.toLowerCase().endsWith('.apk')) return false;
    return true;
  }

  static bool _isUnsafeSegment(String segment) {
    if (segment.isEmpty || segment == '.' || segment == '..') return true;
    if (segment.contains('/') || segment.contains(r'\')) return true;
    for (final code in segment.codeUnits) {
      if (code < 0x20 || code == 0x7f) return true;
    }
    return false;
  }
}

/// 受管下载请求（通道参数白名单由本类构造，调用方无法注入任意字段）。
@immutable
class ApkUpdateRequest {
  const ApkUpdateRequest({
    required this.version,
    required this.assetUrl,
    required this.assetFileName,
    this.assetId,
    this.assetSizeBytes,
    this.sha256,
    this.abi,
  });

  final String version;
  final String assetUrl;
  final String assetFileName;
  final int? assetId;
  final int? assetSizeBytes;
  final String? sha256;
  final String? abi;

  /// 稳定 idempotency key：`摘要 + assetId/version + ABI + 文件名`，
  /// **不含**任何账号身份。原生持久化的受管 id 应与此一致。
  String get requestKey {
    final idPart = assetId?.toString() ?? version;
    return 'v1:$idPart:${abi ?? 'unknown'}:$assetFileName:${sha256 ?? 'nosha'}';
  }

  Map<String, Object?> toPlatformMap() => <String, Object?>{
    'version': version,
    'url': assetUrl,
    'fileName': assetFileName,
    'requestKey': requestKey,
    if (assetId != null) 'assetId': assetId,
    if (assetSizeBytes != null) 'sizeBytes': assetSizeBytes,
    if (sha256 != null) 'sha256': sha256,
    if (abi != null) 'abi': abi,
  };

  /// 从 release 构造受管请求；规范资产 URL / 文件名 / 版本任一不合法即返回
  /// null（调用方据此降级为不可用，绝不猜测 URL）。
  static ApkUpdateRequest? tryCreate(AppRelease release, {String? abi}) {
    final url = release.canonicalAssetUrl;
    if (url == null || !ApkUpdateUrlPolicy.isCanonicalAssetUrl(url)) {
      return null;
    }
    final fileName = release.assetFileName ?? _fileNameFromUrl(url);
    if (fileName == null ||
        fileName.isEmpty ||
        fileName.length > ApkUpdateProtocol.maxAssetFileNameLength ||
        !fileName.toLowerCase().endsWith('.apk')) {
      return null;
    }
    final version = release.version.trim();
    if (version.isEmpty ||
        version.length > ApkUpdateProtocol.maxVersionLength) {
      return null;
    }
    final size = release.assetSizeBytes;
    return ApkUpdateRequest(
      version: version,
      assetUrl: url,
      assetFileName: fileName,
      assetId: release.assetId,
      assetSizeBytes: (size != null && size > 0) ? size : null,
      sha256: AppRelease.normalizeSha256(release.assetSha256),
      abi: (abi != null && abi.trim().isNotEmpty) ? abi.trim() : null,
    );
  }

  static String? _fileNameFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.pathSegments.isEmpty) return null;
    final last = uri.pathSegments.last;
    return last.isEmpty ? null : last;
  }
}

/// 受管更新原生通道抽象；测试可注入 fake，不依赖真实 MethodChannel。
abstract interface class ApkUpdateTransport {
  /// 当前平台是否支持应用内受管更新。
  Future<bool> isSupported();

  /// 入队一次受管下载（原生持久化受管 id），返回原生当前状态。
  Future<ApkUpdateState> startDownload(ApkUpdateRequest request);

  /// 查询原生当前受管状态；无活动请求返回 null。
  Future<ApkUpdateState?> queryActiveUpdate();

  /// 取消当前受管下载并清理其文件，返回原生当前状态。
  Future<ApkUpdateState> cancelActiveUpdate();

  /// 调起系统安装确认；返回是否已成功发起（**不代表**用户已安装）。
  Future<bool> requestInstall();

  /// 打开「未知来源安装」授权设置页；返回是否已发起。
  Future<bool> openInstallPermissionSettings();
}

/// 默认门面实例（`MethodChannel` 实现）。
final ApkUpdateTransport defaultApkUpdateTransport =
    MethodChannelApkUpdateTransport();

/// 基于 `MethodChannel` 的实现：缺失通道 / 原生异常降级为 unavailable /
/// failed，绝不向 UI 抛平台异常，也绝不假称成功。
class MethodChannelApkUpdateTransport implements ApkUpdateTransport {
  MethodChannelApkUpdateTransport({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(ApkUpdateProtocol.channelName);

  final MethodChannel _channel;

  static const ApkUpdateState _missing = ApkUpdateState(
    phase: ApkUpdatePhase.unavailable,
    reason: ApkUpdateFailureReason.unsupported,
  );
  static const ApkUpdateState _failed = ApkUpdateState(
    phase: ApkUpdatePhase.failed,
    reason: ApkUpdateFailureReason.nativeError,
  );

  @override
  Future<bool> isSupported() => safeInvoke<bool, bool>(
    _channel,
    ApkUpdateProtocol.methodIsSupported,
    map: (value) => value ?? false,
    missing: false,
    failed: false,
    label: '应用内更新能力探测',
    level: LogLevel.warn,
    category: LogCategory.general,
  );

  @override
  Future<ApkUpdateState> startDownload(ApkUpdateRequest request) =>
      _invokeState(
        ApkUpdateProtocol.methodStartDownload,
        request.toPlatformMap(),
      );

  @override
  Future<ApkUpdateState?> queryActiveUpdate() =>
      safeInvoke<Object, ApkUpdateState?>(
        _channel,
        ApkUpdateProtocol.methodQueryActiveUpdate,
        map: (value) =>
            value == null ? null : ApkUpdateStateCodec.fromNative(value),
        missing: null,
        failed: _failed,
        label: '查询受管更新状态',
        level: LogLevel.warn,
        category: LogCategory.general,
      );

  @override
  Future<ApkUpdateState> cancelActiveUpdate() =>
      _invokeState(ApkUpdateProtocol.methodCancelActiveUpdate);

  @override
  Future<bool> requestInstall() => safeInvoke<bool, bool>(
    _channel,
    ApkUpdateProtocol.methodRequestInstall,
    map: (value) => value ?? false,
    missing: false,
    failed: false,
    label: '调起系统安装',
    level: LogLevel.warn,
    category: LogCategory.general,
  );

  @override
  Future<bool> openInstallPermissionSettings() => safeInvoke<bool, bool>(
    _channel,
    ApkUpdateProtocol.methodOpenInstallPermissionSettings,
    map: (value) => value ?? false,
    missing: false,
    failed: false,
    label: '打开安装权限设置',
    level: LogLevel.warn,
    category: LogCategory.general,
  );

  Future<ApkUpdateState> _invokeState(String method, [Object? arguments]) =>
      safeInvoke<Object, ApkUpdateState>(
        _channel,
        method,
        arguments: arguments,
        map: ApkUpdateStateCodec.fromNative,
        missing: _missing,
        failed: _failed,
        label: '应用内更新（$method）',
        level: LogLevel.warn,
        category: LogCategory.general,
      );
}

/// 应用内受管更新控制器（UI 的唯一 Dart 入口）。
///
/// 只投影原生权威状态：不下载、不计时、不合成进度；`state` 为
/// [ValueListenable] 供 UI 监听。原生推送事件可在后续原生阶段以同一
/// [ApkUpdateStateCodec] 解析的 typed map 补充，本阶段用 [refreshActiveUpdate]
/// 轮询（由 UI 生命周期决定频率，控制器不持有任何后台定时器）。
class ApkUpdateController {
  ApkUpdateController({
    ApkUpdateTransport? transport,
    String? Function()? deviceAbiProvider,
    TargetPlatform Function()? platformProvider,
  }) : _transport = transport ?? defaultApkUpdateTransport,
       _deviceAbiProvider = deviceAbiProvider ?? deviceAbiSuffix,
       _platformProvider = platformProvider ?? _defaultPlatform;

  /// 应用级单例；测试用构造注入独立实例。
  static final ApkUpdateController instance = ApkUpdateController();

  static TargetPlatform _defaultPlatform() => defaultTargetPlatform;

  final ApkUpdateTransport _transport;
  final String? Function() _deviceAbiProvider;
  final TargetPlatform Function() _platformProvider;

  final ValueNotifier<ApkUpdateState> state = ValueNotifier<ApkUpdateState>(
    const ApkUpdateState.idle(),
  );

  bool _startInFlight = false;
  int _refreshEpoch = 0;

  /// 是否支持应用内受管更新：非 Android 直接 false，不触碰通道。
  Future<bool> isSupported() async {
    if (_platformProvider() != TargetPlatform.android) return false;
    return _transport.isSupported();
  }

  /// 入队一次受管下载。
  ///
  /// - 规范资产 URL 不可信 / 缺失 → [ApkUpdatePhase.unavailable]
  ///   （`untrustedAsset`），**不**调用通道，UI 应回退浏览器路径。
  /// - 同一请求已在活动状态或上一次 start 未返回 → 幂等 no-op。
  Future<void> startDownload(AppRelease release) async {
    if (_startInFlight) return;

    final request = ApkUpdateRequest.tryCreate(
      release,
      abi: _deviceAbiProvider(),
    );
    if (request == null) {
      _apply(
        ApkUpdateState(
          phase: ApkUpdatePhase.unavailable,
          reason: ApkUpdateFailureReason.untrustedAsset,
          version: release.version,
        ),
      );
      return;
    }

    final current = state.value;
    if (current.requestKey == request.requestKey && current.phase.isActive) {
      return;
    }

    _startInFlight = true;
    _refreshEpoch++; // 使在途 query 结果失效
    try {
      final next = await _transport.startDownload(request);
      _apply(next);
    } finally {
      _startInFlight = false;
    }
  }

  /// 查询原生当前受管状态（冷启动 / 回前台恢复）。迟到的查询结果被 epoch
  /// 作废，绝不覆盖更新的状态。
  Future<void> refreshActiveUpdate() async {
    final epoch = ++_refreshEpoch;
    final next = await _transport.queryActiveUpdate();
    if (epoch != _refreshEpoch) return;
    _apply(next ?? const ApkUpdateState.idle());
  }

  /// 取消当前受管下载并清理其文件（只影响原生受管的那一条）。
  Future<void> cancelActiveUpdate() async {
    final epoch = ++_refreshEpoch;
    final next = await _transport.cancelActiveUpdate();
    if (epoch != _refreshEpoch) return;
    _apply(next);
  }

  /// 调起系统安装确认。成功仅表示**已发起**（[ApkUpdatePhase.installerOpened]），
  /// 不代表用户已安装。
  Future<bool> requestInstall() async {
    final ok = await _transport.requestInstall();
    final current = state.value;
    if (!ok) {
      _apply(
        current.copyWith(
          phase: ApkUpdatePhase.failed,
          reason: ApkUpdateFailureReason.installerUnavailable,
        ),
      );
      return false;
    }
    _apply(
      current.copyWith(
        phase: ApkUpdatePhase.installerOpened,
        clearReason: true,
      ),
    );
    return true;
  }

  /// 打开「未知来源安装」授权设置页；不改变下载状态。
  Future<bool> openInstallPermissionSettings() =>
      _transport.openInstallPermissionSettings();

  void _apply(ApkUpdateState next) {
    if (state.value == next) return;
    state.value = next;
  }

  @visibleForTesting
  void debugReset() {
    _startInFlight = false;
    _refreshEpoch = 0;
    state.value = const ApkUpdateState.idle();
  }
}
