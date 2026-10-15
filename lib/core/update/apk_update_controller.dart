import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

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

  /// EdgeOne gh-proxy 镜像前缀：`<前缀><规范 GitHub 资产 URL>`（精确、区分大小写）。
  static const String trustedMirrorPrefix = 'https://edgeone.gh-proxy.org/';

  /// Cloudflare R2 自定义下载域名：`https://<host>/<tag>/<apk>`。
  static const String trustedR2Host = 'download.fhfanshu.xyz';

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
    this.releaseTag,
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

  /// 当前受管资产 URL 对应的 Release tag。
  final String? releaseTag;

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
    String? releaseTag,
    String? requestKey,
    String? assetFileName,
  }) {
    return ApkUpdateState(
      phase: phase ?? this.phase,
      bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
      totalBytes: totalBytes ?? this.totalBytes,
      reason: clearReason ? null : (reason ?? this.reason),
      version: version ?? this.version,
      releaseTag: releaseTag ?? this.releaseTag,
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
      other.releaseTag == releaseTag &&
      other.requestKey == requestKey &&
      other.assetFileName == assetFileName;

  @override
  int get hashCode => Object.hash(
    phase,
    bytesDownloaded,
    totalBytes,
    reason,
    version,
    releaseTag,
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
    'releaseTag',
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
      releaseTag: _boundedString(
        raw['releaseTag'],
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

/// 应用内受管下载的线路。
///
/// - [github]：规范 GitHub Release 资产 URL（既有行为；国内常很慢，UI 不再作为
///   可选线路，仅保留给既有受管记录与无线路参数的调用）。
/// - [edgeone]：EdgeOne gh-proxy 对同一 GitHub 资产的代理。
/// - [r2]：Cloudflare R2 自定义域名上的同一份 APK（仅当 Release 带 R2 标记资产）。
enum ApkDownloadSource { github, edgeone, r2 }

/// 可信下载 URL 校验：调用原生前必须通过（与原生
/// `AppUpdateContract.parseCanonicalAssetUrl` 等价）。
///
/// 接受三种固定形态（其余一律拒绝）：
/// 1. GitHub 规范资产：`https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/<tag>/<apk>`
///    （[isCanonicalAssetUrl]，Release 元数据只提供这一种）；
/// 2. EdgeOne 镜像：`https://edgeone.gh-proxy.org/` + 形态 1（[isMirrorAssetUrl]）；
/// 3. R2：`https://download.fhfanshu.xyz/<tag>/<apk>`，恰好两段路径
///    （[isR2AssetUrl]）。
///
/// 拒绝 userinfo、fragment、query、非 https、非可信主机 / 仓库、编码路径穿越、
/// 非 `.apk` 文件名。
///
/// 校验先对**原始字符串**做 fail-closed 检查，再做 `Uri` 解析后的结构校验
/// （纵深防御）：`Uri` 会把 `\` 归一为 `/`、解析 dot-segments、把显式默认端口
/// 视为 `hasPort=false`，这些规范化会掩盖恶意输入，而原生侧不做等价归一
/// （`android.net.Uri` + `isSafeApkFileName` / `isSafePathSegment` 拒绝字面
/// `\`、`..` 与非默认端口），因此 Dart 必须先行拒绝，保持两侧一致。
abstract final class ApkUpdateUrlPolicy {
  /// GitHub 规范资产 URL（形态 1）。
  static bool isCanonicalAssetUrl(String url) =>
      _githubAssetTag(url.trim()) != null;

  /// EdgeOne 镜像资产 URL（形态 2）：精确前缀 + 形态 1，整串无 query / fragment。
  static bool isMirrorAssetUrl(String url) {
    final trimmed = url.trim();
    if (!trimmed.startsWith(ApkUpdateProtocol.trustedMirrorPrefix))
      return false;
    final inner = trimmed.substring(
      ApkUpdateProtocol.trustedMirrorPrefix.length,
    );
    // 与原生一致：内层必须是小写字面 `https://github.com/` 开头（原生比镜像外的
    // GitHub 规范 URL 更严，不接受大写主机写法）。
    if (!inner.startsWith('https://github.com/')) return false;
    return _githubAssetTag(inner) != null;
  }

  /// R2 资产 URL（形态 3）。
  static bool isR2AssetUrl(String url) {
    final trimmed = url.trim();
    final uri = _structurallySafeUri(trimmed);
    if (uri == null) return false;
    if (uri.host.toLowerCase() != ApkUpdateProtocol.trustedR2Host) return false;
    final segments = uri.pathSegments;
    if (segments.length != 2) return false;
    if (_isUnsafeSegment(segments[0]) || _isUnsafeSegment(segments[1])) {
      return false;
    }
    return segments[1].toLowerCase().endsWith('.apk');
  }

  /// 三种形态之一（原生入队前的同一白名单）。
  static bool isTrustedDownloadUrl(String url) =>
      isCanonicalAssetUrl(url) || isMirrorAssetUrl(url) || isR2AssetUrl(url);

  /// 由规范 GitHub 资产 URL 派生 [source] 线路的 URL；不可信 / 不可用返回 null。
  ///
  /// R2 额外要求 [r2Available]（Release 带 R2 标记资产），否则不构造 URL。
  static String? urlFor(
    ApkDownloadSource source, {
    required String canonicalUrl,
    required bool r2Available,
  }) {
    final canonical = canonicalUrl.trim();
    final tag = _githubAssetTag(canonical);
    if (tag == null) return null;
    switch (source) {
      case ApkDownloadSource.github:
        return canonical;
      case ApkDownloadSource.edgeone:
        final url = '${ApkUpdateProtocol.trustedMirrorPrefix}$canonical';
        return isMirrorAssetUrl(url) ? url : null;
      case ApkDownloadSource.r2:
        if (!r2Available) return null;
        final fileName = Uri.parse(canonical).pathSegments.last;
        final url = 'https://${ApkUpdateProtocol.trustedR2Host}/$tag/$fileName';
        return isR2AssetUrl(url) ? url : null;
    }
  }

  /// 通过原始字符串检查与 `Uri` 结构校验（scheme / userinfo / fragment / query /
  /// port），返回 Uri；host 与路径形态由调用方继续校验。
  static Uri? _structurallySafeUri(String trimmed) {
    if (trimmed.isEmpty) return null;

    // 1) 原始字符串检查（绝不依赖 Uri 规范化）。
    final lower = trimmed.toLowerCase();
    if (!lower.startsWith('https://')) return null;
    for (final code in trimmed.codeUnits) {
      // 控制字符 / DEL：绝不接受（原生同样拒绝）。
      if (code < 0x20 || code == 0x7f) return null;
      // 字面反斜杠：Uri 会归一为路径分隔符，原生拒绝 `\`。
      if (code == 0x5c) return null;
    }
    // 编码的 `.` / `/` / `\`（`%2e` / `%2f` / `%5c`，大小写不敏感）：
    // 拒绝任何「解码后才暴露」的路径穿越 / 分隔符向量。
    if (lower.contains('%2e') ||
        lower.contains('%2f') ||
        lower.contains('%5c')) {
      return null;
    }
    // authority 段（`https://` 之后到首个 `/`、`?`、`#`）：拒绝 userinfo `@`
    // 与字面端口 `:`（含显式 `:443`——Uri 会把它视为 hasPort=false）。
    final authority = _rawAuthority(trimmed);
    if (authority == null) return null;
    if (authority.contains('@') || authority.contains(':')) return null;

    // 2) Uri 解析后的结构校验（纵深防御）。
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    if (uri.scheme != 'https') return null;
    if (uri.userInfo.isNotEmpty) return null;
    if (uri.fragment.isNotEmpty) return null;
    if (uri.hasQuery) return null;
    if (uri.hasPort) return null;
    return uri;
  }

  /// 形态 1 校验；通过返回 tag，否则 null。
  static String? _githubAssetTag(String trimmed) {
    final uri = _structurallySafeUri(trimmed);
    if (uri == null) return null;
    if (uri.host.toLowerCase() != ApkUpdateProtocol.trustedRepoHost) {
      return null;
    }

    // pathSegments 已解码：`%2e%2e` → `..`、`%2f` → `/` 会被下面拒绝。
    final segments = uri.pathSegments;
    if (segments.length != 6) return null;
    if (segments[0] != ApkUpdateProtocol.trustedRepoOwner) return null;
    if (segments[1] != ApkUpdateProtocol.trustedRepoName) return null;
    if (segments[2] != 'releases' || segments[3] != 'download') return null;

    final tag = segments[4];
    final file = segments[5];
    if (_isUnsafeSegment(tag) || _isUnsafeSegment(file)) return null;
    if (!file.toLowerCase().endsWith('.apk')) return null;
    return tag;
  }

  /// 取 `https://` 之后的 authority 原文（到首个 `/`、`?`、`#` 为止）；
  /// 无 authority 返回 null。调用前已确认前缀为 `https://`。
  static String? _rawAuthority(String url) {
    final start = url.indexOf('://') + 3;
    if (start < 3 || start >= url.length) return null;
    var end = url.length;
    for (var i = start; i < url.length; i++) {
      final c = url[i];
      if (c == '/' || c == '?' || c == '#') {
        end = i;
        break;
      }
    }
    if (end <= start) return null;
    return url.substring(start, end);
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
    this.source = ApkDownloadSource.github,
  });

  final String version;
  final String assetUrl;
  final String assetFileName;
  final int? assetId;
  final int? assetSizeBytes;
  final String? sha256;
  final String? abi;

  /// 下载线路（只影响 [assetUrl] 与 [requestKey]，不影响校验契约）。
  final ApkDownloadSource source;

  /// 稳定 idempotency key：`摘要 + assetId/version + ABI + 文件名`，
  /// **不含**任何账号身份。原生持久化的受管 id 应与此一致。
  ///
  /// 非默认线路追加 `:<线路>` 后缀，使「换线重试」被原生视为新请求并走既有的
  /// 权威退役路径；默认 [ApkDownloadSource.github] 的 key 与既有记录一致。
  String get requestKey {
    final idPart = assetId?.toString() ?? version;
    final base =
        'v1:$idPart:${abi ?? 'unknown'}:$assetFileName:${sha256 ?? 'nosha'}';
    return source == ApkDownloadSource.github ? base : '$base:${source.name}';
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

  /// 从 release 构造受管请求；规范资产 URL / 文件名 / 版本任一不合法、或所选
  /// [source] 线路不可用（例如 R2 标记缺失）即返回 null（调用方据此降级为
  /// 不可用，绝不猜测 URL）。
  static ApkUpdateRequest? tryCreate(
    AppRelease release, {
    String? abi,
    ApkDownloadSource source = ApkDownloadSource.github,
  }) {
    final canonical = release.canonicalAssetUrl;
    if (canonical == null ||
        !ApkUpdateUrlPolicy.isCanonicalAssetUrl(canonical)) {
      return null;
    }
    final url = ApkUpdateUrlPolicy.urlFor(
      source,
      canonicalUrl: canonical,
      r2Available: release.r2MirrorAvailable,
    );
    if (url == null) return null;
    final fileName = release.assetFileName ?? _fileNameFromUrl(canonical);
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
      source: source,
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
  Future<bool> requestInstall({String? expectedReleaseTag});

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
  Future<bool> requestInstall({String? expectedReleaseTag}) =>
      safeInvoke<bool, bool>(
        _channel,
        ApkUpdateProtocol.methodRequestInstall,
        arguments: expectedReleaseTag == null
            ? null
            : <String, Object?>{'expectedReleaseTag': expectedReleaseTag},
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
    Future<String?> Function()? installedVersionProvider,
  }) : _transport = transport ?? defaultApkUpdateTransport,
       _deviceAbiProvider = deviceAbiProvider ?? deviceAbiSuffix,
       _platformProvider = platformProvider ?? _defaultPlatform,
       _installedVersionProvider =
           installedVersionProvider ?? _defaultInstalledVersion;

  /// 应用级单例；测试用构造注入独立实例。
  static final ApkUpdateController instance = ApkUpdateController();

  static TargetPlatform _defaultPlatform() => defaultTargetPlatform;

  static Future<String?> _defaultInstalledVersion() async {
    try {
      return (await PackageInfo.fromPlatform().timeout(
        const Duration(seconds: 3),
      )).version;
    } catch (_) {
      return null;
    }
  }

  final ApkUpdateTransport _transport;
  final String? Function() _deviceAbiProvider;
  final TargetPlatform Function() _platformProvider;
  final Future<String?> Function() _installedVersionProvider;

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
  ///
  /// [source] 选择下载线路（默认 [ApkDownloadSource.github] 保持既有行为）；
  /// 所选线路不可用同样降级为 `untrustedAsset`。
  Future<void> startDownload(
    AppRelease release, {
    ApkDownloadSource source = ApkDownloadSource.github,
  }) async {
    if (_startInFlight) return;

    final request = ApkUpdateRequest.tryCreate(
      release,
      abi: _deviceAbiProvider(),
      source: source,
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
  ///
  /// 已不新于当前安装版本的受管更新（例如用户已经从文件管理器装上了同一个
  /// 包，或经其它渠道升级）会被视为过期：取消原生请求并删除其文件，回到
  /// idle，让「检查更新」重新查询线上版本，而不是一直提示安装当前版本。
  /// 版本无法读取时保守保留原状态。
  Future<void> refreshActiveUpdate() async {
    final epoch = ++_refreshEpoch;
    final next = await _transport.queryActiveUpdate();
    if (epoch != _refreshEpoch) return;
    if (next != null && await _isSuperseded(next)) {
      if (epoch != _refreshEpoch) return;
      final cleared = await _transport.cancelActiveUpdate();
      if (epoch != _refreshEpoch) return;
      _apply(cleared.phase.isActive ? cleared : const ApkUpdateState.idle());
      return;
    }
    if (epoch != _refreshEpoch) return;
    _apply(next ?? const ApkUpdateState.idle());
  }

  Future<bool> _isSuperseded(ApkUpdateState managed) async {
    if (!managed.phase.isActive) return false;
    final managedVersion = managed.version?.trim();
    if (managedVersion == null || managedVersion.isEmpty) return false;
    final installed = await _installedVersionProvider();
    if (installed == null || installed.trim().isEmpty) return false;
    return !AppRelease.isVersionNewer(managedVersion, installed);
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
  ///
  /// 原生未发起安装器（例如缺「未知来源」权限）时返回 false，并以**原生权威状态**
  /// 为准刷新（保留 `permissionRequired` / `readyToInstall`），绝不覆盖成 failed；
  /// UI 可据此引导用户打开权限设置页并在回前台后重试安装。
  Future<bool> requestInstall({String? expectedReleaseTag}) async {
    final ok = await _transport.requestInstall(
      expectedReleaseTag: expectedReleaseTag,
    );
    if (!ok) {
      final epoch = ++_refreshEpoch;
      final next = await _transport.queryActiveUpdate();
      if (epoch == _refreshEpoch && next != null) {
        _apply(next);
      }
      return false;
    }
    _apply(
      state.value.copyWith(
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
