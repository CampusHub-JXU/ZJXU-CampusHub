import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../config/app_config.dart';
import '../logging/app_logger.dart';
import '../platform/safe_invoke.dart';
import 'apk_download_route.dart';
import 'update_model.dart';
import 'update_source.dart' show deviceAbiSuffix;

/// 应用内 APK 受管更新的固定通道协议（与原生侧 lockstep）。
///
/// 通道：`edu.zjxu.jxucampushub/app_update`。参数与结果只使用
/// StandardMethodCodec 支持的基本类型（`Map` / `List` / `String` / `int` /
/// `bool`）。
///
/// 设计边界（原生显式状态机，契约见 `docs/in-app-update-state-machine.md`）：
/// - 原生是**唯一权威**：入队、归属对账、换源、校验、安装、「是否已被安装」
///   与清理全部在原生；Dart 只按设置页偏好生成有序候选源、发命令、解码状态，
///   并由 [ApkUpdateController] 在前台轮询时驱动停滞观察器建议换源
///   （[ApkDownloadStallWatcher]）。
/// - Dart 侧**不**负责下载 / 进度合成，也**不**判定受管记录是否过期。
/// - 通道参数**只**含协议字段（版本 / tag / 文件名 / 摘要 / ABI / 请求 key /
///   带校验的候选源 URL），**绝不**传学号、账号、Cookie 或任意本地文件路径 /
///   下载 id。
/// - 候选源 URL 必须是可信形态（规范 GitHub / EdgeOne / R2；调试构建另有
///   本地测试源），否则在调用通道前即拒绝。
abstract final class ApkUpdateProtocol {
  static const String channelName = 'edu.zjxu.jxucampushub/app_update';

  static const String methodIsSupported = 'isSupported';
  static const String methodStartDownload = 'startDownload';
  static const String methodQueryActiveUpdate = 'queryActiveUpdate';
  static const String methodCancelActiveUpdate = 'cancelActiveUpdate';
  static const String methodSwitchSource = 'switchSource';
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
  unavailable,

  /// 归属不明：原生保留任务身份，之后每次查询 / 取消前都重新对账（轮询驱动）。
  reconcileRequired,

  /// 原生已决定退役当前尝试（取消 / 被取代 / 换源），但系统下载移除尚未确认。
  cleanupPending;

  /// 是否属于「有在途 / 可继续」的活动状态（用于幂等去重与保持轮询）。
  bool get isActive => switch (this) {
    enqueued ||
    downloading ||
    paused ||
    verifying ||
    readyToInstall ||
    permissionRequired ||
    installerOpened ||
    reconcileRequired ||
    cleanupPending => true,
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

/// 受管下载的换源模式（wire code 即枚举名）。
///
/// - [auto]：设置页「自动」：原生在明确失败时自动换下一条候选源，Dart 停滞
///   观察器可建议换源；
/// - [manual]：手动选线：原生**不**换源，失败后由用户在设置里改线重试。
enum ApkDownloadMode { auto, manual }

/// 控制器对外投影的受管更新状态（值相等，便于 ValueNotifier 去重）。
///
/// 线路相关字段（[source] … [retired]）全部来自原生权威状态，Dart 不推演。
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
    this.source,
    this.mode,
    this.attempt = 0,
    this.triedSources = const <ApkDownloadSource>[],
    this.canSwitch = false,
    this.switchReason,
    this.fellBackFrom,
    this.switching = false,
    this.exhausted = false,
    this.retired = false,
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

  /// 当前受管请求的稳定 idempotency key（原生持久化的同一 id；不含线路）。
  final String? requestKey;

  /// 当前受管请求的 APK 文件名。
  final String? assetFileName;

  /// 当前尝试的下载线路；未知 / 不在白名单为 null。
  final ApkDownloadSource? source;

  /// 换源模式；未知为 null。
  final ApkDownloadMode? mode;

  /// 当前尝试序号（原生 generation）；停滞观察器据此重置计时。
  final int attempt;

  /// 已尝试过的线路（含当前），按尝试顺序。
  final List<ApkDownloadSource> triedSources;

  /// 原生是否还能响应 `switchSource`（下载中、自动模式、还有未试的线路）。
  final bool canSwitch;

  /// 最近一次换源的原因（白名单）；从未换源为 null。
  final ApkFallbackReason? switchReason;

  /// 最近一次换源离开的线路，或首选线路不可用时的首选线路。
  final ApkDownloadSource? fellBackFrom;

  /// 正在退役旧尝试并换到下一条线路（`cleanupPending` 的换源子类）。
  final bool switching;

  /// 自动模式下所有候选线路都已失败。
  final bool exhausted;

  /// 仅 `cancelActiveUpdate` 返回：原生已确认退役。
  final bool retired;

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
    ApkDownloadSource? source,
    ApkDownloadMode? mode,
    int? attempt,
    List<ApkDownloadSource>? triedSources,
    bool? canSwitch,
    ApkFallbackReason? switchReason,
    ApkDownloadSource? fellBackFrom,
    bool? switching,
    bool? exhausted,
    bool? retired,
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
      source: source ?? this.source,
      mode: mode ?? this.mode,
      attempt: attempt ?? this.attempt,
      triedSources: triedSources ?? this.triedSources,
      canSwitch: canSwitch ?? this.canSwitch,
      switchReason: switchReason ?? this.switchReason,
      fellBackFrom: fellBackFrom ?? this.fellBackFrom,
      switching: switching ?? this.switching,
      exhausted: exhausted ?? this.exhausted,
      retired: retired ?? this.retired,
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
      other.assetFileName == assetFileName &&
      other.source == source &&
      other.mode == mode &&
      other.attempt == attempt &&
      listEquals(other.triedSources, triedSources) &&
      other.canSwitch == canSwitch &&
      other.switchReason == switchReason &&
      other.fellBackFrom == fellBackFrom &&
      other.switching == switching &&
      other.exhausted == exhausted &&
      other.retired == retired;

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
    source,
    mode,
    attempt,
    Object.hashAll(triedSources),
    canSwitch,
    switchReason,
    fellBackFrom,
    switching,
    exhausted,
    retired,
  );

  @override
  String toString() =>
      'ApkUpdateState(phase: ${phase.name}, bytes: $bytesDownloaded/'
      '$totalBytes, reason: ${reason?.name}, version: $version, '
      'source: ${source?.name}, attempt: $attempt)';
}

/// 原生 map → [ApkUpdateState] 的严格解码（白名单字段 + 类型校验）。
///
/// 未知字段忽略；未知 phase / reason 分别 fail-closed 为
/// [ApkUpdatePhase.unavailable] / [ApkUpdateFailureReason.unknown]；非 map、
/// 越界 / 非法数值一律丢弃为 null，绝不合成进度。线路相关字段同样严格：
/// 未知 source / mode / switchReason 为 null，类型不符的布尔为 false、
/// attempt 为 0、triedSources 丢弃未知项；整个解码**绝不抛出**。
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
    'source',
    'mode',
    'attempt',
    'triedSources',
    'canSwitch',
    'switchReason',
    'fellBackFrom',
    'switching',
    'exhausted',
    'retired',
  };

  /// `triedSources` 的上限（候选源最多 3 个，留余量防畸形输入）。
  static const int maxTriedSources = 8;

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
      source: _enumByName(ApkDownloadSource.values, raw['source']),
      mode: _enumByName(ApkDownloadMode.values, raw['mode']),
      attempt: _nonNegativeInt(raw['attempt']) ?? 0,
      triedSources: _sources(raw['triedSources']),
      canSwitch: raw['canSwitch'] == true,
      switchReason: _enumByName(ApkFallbackReason.values, raw['switchReason']),
      fellBackFrom: _enumByName(ApkDownloadSource.values, raw['fellBackFrom']),
      switching: raw['switching'] == true,
      exhausted: raw['exhausted'] == true,
      retired: raw['retired'] == true,
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

  /// 精确（区分大小写、不 trim）匹配枚举名；未知 / 非字符串为 null。
  static T? _enumByName<T extends Enum>(List<T> values, Object? raw) {
    if (raw is! String) return null;
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return null;
  }

  /// 未知项与重复项丢弃，保序；非 list 为空。
  static List<ApkDownloadSource> _sources(Object? raw) {
    if (raw is! List) return const <ApkDownloadSource>[];
    final result = <ApkDownloadSource>[];
    for (final item in raw) {
      final source = _enumByName(ApkDownloadSource.values, item);
      if (source == null || result.contains(source)) continue;
      result.add(source);
      if (result.length >= maxTriedSources) break;
    }
    return List<ApkDownloadSource>.unmodifiable(result);
  }
}

/// 应用内受管下载的线路。
///
/// - [github]：规范 GitHub Release 资产 URL（既有行为；国内常很慢，UI 不再作为
///   可选线路，仅保留给既有受管记录与无线路参数的调用）。
/// - [edgeone]：EdgeOne gh-proxy 对同一 GitHub 资产的代理。
/// - [r2]：Cloudflare R2 自定义域名上的同一份 APK（仅当 Release 带 R2 标记资产）。
/// - [test]：**仅调试构建**的本地端到端测试源（`http://10.0.2.2:<port>/...`），
///   由 `AppConfig.updateTestOrigin` 门控，release / profile 永不出现。
///
/// wire 名即枚举名，与原生白名单 `github|edgeone|r2|test` 一致。
enum ApkDownloadSource { github, edgeone, r2, test }

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
    if (!trimmed.startsWith(ApkUpdateProtocol.trustedMirrorPrefix)) {
      return false;
    }
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
  ///
  /// **不含**调试测试源（[isTestAssetUrl]）：测试源只在 `AppConfig.updateTestOrigin`
  /// 非 null（仅 `kDebugMode`）时由 [testUrlFor] 构造，永远不进入生产白名单。
  static bool isTrustedDownloadUrl(String url) =>
      isCanonicalAssetUrl(url) || isMirrorAssetUrl(url) || isR2AssetUrl(url);

  /// 规范 GitHub 资产 URL 里的 Release tag；不是形态 1 时返回 null。
  static String? canonicalAssetTag(String url) => _githubAssetTag(url.trim());

  static final RegExp _testAssetPattern = RegExp(
    r'^http://10\.0\.2\.2:([1-9]\d{3,4})/([^/?#]+)/([^/?#]+)$',
  );

  /// 调试测试源形态：`http://10.0.2.2:<1024–65535>/<tag>/<apk>`（恰好两段路径，
  /// 无 userinfo / query / fragment / 穿越 / 控制字符）。与原生
  /// `parseCanonicalAssetUrl(allowTestOrigin = true)` 等价。
  ///
  /// 这只是形态校验，**不**代表允许使用：是否启用由 `AppConfig.updateTestOrigin`
  /// （`kDebugMode` 门控）决定。
  static bool isTestAssetUrl(String url) {
    final trimmed = url.trim();
    final match = _testAssetPattern.firstMatch(trimmed);
    if (match == null) return false;
    final port = int.parse(match.group(1)!);
    if (port < 1024 || port > 65535) return false;
    for (final code in trimmed.codeUnits) {
      if (code < 0x20 || code == 0x7f || code == 0x5c) return false;
    }
    final lower = trimmed.toLowerCase();
    if (lower.contains('%2e') ||
        lower.contains('%2f') ||
        lower.contains('%5c')) {
      return false;
    }
    final tag = match.group(2)!;
    final file = match.group(3)!;
    if (_isUnsafeSegment(tag) || _isUnsafeSegment(file)) return false;
    return file.toLowerCase().endsWith('.apk');
  }

  /// 由规范 GitHub 资产 URL 与（已解析的）测试 origin 构造测试源 URL
  /// `<origin>/<tag>/<apk>`；任一不合法返回 null。
  static String? testUrlFor({
    required String origin,
    required String canonicalUrl,
  }) {
    final canonical = canonicalUrl.trim();
    final tag = _githubAssetTag(canonical);
    if (tag == null) return null;
    final fileName = Uri.parse(canonical).pathSegments.last;
    var base = origin.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    final url = '$base/$tag/$fileName';
    return isTestAssetUrl(url) ? url : null;
  }

  /// 由规范 GitHub 资产 URL 派生 [source] 线路的 URL；不可信 / 不可用返回 null
  /// （[ApkDownloadSource.test] 恒为 null，见 [testUrlFor]）。
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
      case ApkDownloadSource.test:
        // 测试源只能经 [testUrlFor] + AppConfig.updateTestOrigin 构造。
        return null;
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

/// 候选源（`source` + 已校验 URL），按尝试顺序排列后随 `startDownload` 下发。
@immutable
class ApkUpdateSourceUrl {
  const ApkUpdateSourceUrl({required this.source, required this.url});

  final ApkDownloadSource source;
  final String url;

  Map<String, Object?> toPlatformMap() => <String, Object?>{
    'source': source.name,
    'url': url,
  };

  @override
  bool operator ==(Object other) =>
      other is ApkUpdateSourceUrl && other.source == source && other.url == url;

  @override
  int get hashCode => Object.hash(source, url);

  @override
  String toString() => 'ApkUpdateSourceUrl(${source.name})';
}

/// 受管下载请求（通道参数白名单由本类构造，调用方无法注入任意字段）。
///
/// 任务身份 = 目标 APK 身份（[requestKey]，**不含线路**）；线路只出现在有序候选
/// [sources] 里，换源不换 key，由原生按 [mode] 决定如何推进。
@immutable
class ApkUpdateRequest {
  const ApkUpdateRequest({
    required this.version,
    required this.releaseTag,
    required this.assetFileName,
    required this.mode,
    required this.sources,
    this.unavailablePreferred,
    this.assetId,
    this.assetSizeBytes,
    this.sha256,
    this.abi,
  });

  final String version;

  /// 候选 URL 共同的 Release tag（原生会逐个 URL 复核）。
  final String releaseTag;
  final String assetFileName;
  final ApkDownloadMode mode;

  /// 有序候选源（1–3 个、线路不重复）；首个即首选线路。
  final List<ApkUpdateSourceUrl> sources;

  /// 用户手动选了某线路但该版本没有它（目前只会是 R2）时，告知原生以便如实
  /// 记录「已从首选线路改用备用线路」。
  final ApkDownloadSource? unavailablePreferred;
  final int? assetId;
  final int? assetSizeBytes;
  final String? sha256;
  final String? abi;

  /// 稳定 idempotency key：`摘要 + assetId/version + ABI + 文件名`，
  /// **不含**任何账号身份，也**不含**线路（换源不换 key）。
  String get requestKey {
    final idPart = assetId?.toString() ?? version;
    return 'v2:$idPart:${abi ?? 'unknown'}:$assetFileName:${sha256 ?? 'nosha'}';
  }

  Map<String, Object?> toPlatformMap() => <String, Object?>{
    'version': version,
    'releaseTag': releaseTag,
    'fileName': assetFileName,
    'requestKey': requestKey,
    'mode': mode.name,
    'sources': <Map<String, Object?>>[
      for (final source in sources) source.toPlatformMap(),
    ],
    if (assetSizeBytes != null) 'sizeBytes': assetSizeBytes,
    if (sha256 != null) 'sha256': sha256,
    if (abi != null) 'abi': abi,
    if (unavailablePreferred != null)
      'unavailablePreferred': unavailablePreferred!.name,
  };

  /// 从 release + 线路偏好 [route] 构造受管请求；规范资产 URL / 文件名 / 版本
  /// 任一不合法、或没有任何可用候选源即返回 null（调用方据此降级为不可用，
  /// 绝不猜测 URL、不调用通道）。
  ///
  /// 候选生成：
  /// - 自动：有 R2 标记为 `[r2, edgeone]`，否则 `[edgeone]`；
  /// - 手动 R2：有标记为 `[r2]`，**没有标记**则 `[edgeone]` 且
  ///   [unavailablePreferred] = r2（不让「更新」点了没反应，同时如实告知）；
  /// - 手动 EdgeOne：`[edgeone]`；
  /// - 调试测试源（[testOrigin]，缺省读 `AppConfig.updateTestOrigin`，release
  ///   恒为 null）启用时候选只有 `[test]`。
  static ApkUpdateRequest? tryCreate(
    AppRelease release, {
    String? abi,
    required ApkDownloadRoute route,
    String? testOrigin,
  }) {
    final canonical = release.canonicalAssetUrl;
    if (canonical == null) return null;
    final tag = ApkUpdateUrlPolicy.canonicalAssetTag(canonical);
    if (tag == null || tag.length > ApkUpdateProtocol.maxVersionLength) {
      return null;
    }
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

    final sources = <ApkUpdateSourceUrl>[];
    ApkDownloadSource? unavailablePreferred;
    final origin = testOrigin ?? AppConfig.updateTestOrigin;
    if (origin != null) {
      final url = ApkUpdateUrlPolicy.testUrlFor(
        origin: origin,
        canonicalUrl: canonical,
      );
      if (url == null) return null;
      sources.add(ApkUpdateSourceUrl(source: ApkDownloadSource.test, url: url));
    } else {
      var candidates = route.candidates(r2Available: release.r2MirrorAvailable);
      if (candidates.isEmpty && route == ApkDownloadRoute.r2) {
        candidates = const <ApkDownloadSource>[ApkDownloadSource.edgeone];
        unavailablePreferred = ApkDownloadSource.r2;
      }
      for (final source in candidates) {
        final url = ApkUpdateUrlPolicy.urlFor(
          source,
          canonicalUrl: canonical,
          r2Available: release.r2MirrorAvailable,
        );
        if (url == null) return null;
        sources.add(ApkUpdateSourceUrl(source: source, url: url));
      }
    }
    if (sources.isEmpty) return null;

    final size = release.assetSizeBytes;
    return ApkUpdateRequest(
      version: version,
      releaseTag: tag,
      assetFileName: fileName,
      mode: route == ApkDownloadRoute.auto
          ? ApkDownloadMode.auto
          : ApkDownloadMode.manual,
      sources: List<ApkUpdateSourceUrl>.unmodifiable(sources),
      unavailablePreferred: unavailablePreferred,
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

  /// 入队一次受管下载（原生持久化任务与候选源），返回原生当前状态。
  Future<ApkUpdateState> startDownload(ApkUpdateRequest request);

  /// 查询原生当前受管状态；无活动请求返回 null。
  Future<ApkUpdateState?> queryActiveUpdate();

  /// 取消当前受管下载并清理其文件，返回原生当前状态（含 `retired`）。
  Future<ApkUpdateState> cancelActiveUpdate();

  /// 建议原生换到下一条候选源（停滞观察器用）；原生不换时照常返回当前状态，
  /// 无任务 / 通道不可用返回 null。
  ///
  /// [attempt] 为判定停滞时看到的尝试代际；原生据此丢弃换源后迟到的建议。
  Future<ApkUpdateState?> switchSource(
    ApkFallbackReason reason, {
    required int attempt,
  });

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
  Future<ApkUpdateState?> switchSource(
    ApkFallbackReason reason, {
    required int attempt,
  }) => safeInvoke<Object, ApkUpdateState?>(
    _channel,
    ApkUpdateProtocol.methodSwitchSource,
    arguments: <String, Object?>{'reason': reason.name, 'attempt': attempt},
    map: (value) =>
        value == null ? null : ApkUpdateStateCodec.fromNative(value),
    // 换源只是建议：通道缺失 / 原生报错都不改变 Dart 侧状态，下一次轮询
    // 会拿到原生真实状态。
    missing: null,
    failed: null,
    label: '建议更新换源',
    level: LogLevel.warn,
    category: LogCategory.general,
  );

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
/// 只投影原生权威状态：不下载、不合成进度、**不判定受管记录是否过期**
/// （版本是否已被安装由原生在每个入口统一处理）；`state` 为 [ValueListenable]
/// 供 UI 监听。
///
/// 轮询与停滞观察归本控制器统一持有（而不是更新弹窗）：用户点「更新」后弹窗
/// 即关闭，下载转入后台，必须由控制器在**应用前台且状态处于活动阶段**时以
/// ~1s 节奏查询原生状态，并驱动 [ApkDownloadStallWatcher] 建议换源；应用退到
/// 后台或状态不再活动时立即停表，不留下空转的 Dart 定时器。回前台（含从
/// 「安装权限设置」返回）查询一次原生真实状态。测试可经构造参数关闭轮询
/// （[enableLifecyclePolling]）或注入前台状态（[foregroundProvider]）。
class ApkUpdateController with WidgetsBindingObserver {
  ApkUpdateController({
    ApkUpdateTransport? transport,
    String? Function()? deviceAbiProvider,
    TargetPlatform Function()? platformProvider,
    bool enableLifecyclePolling = false,
    this.foregroundProvider,
    this.stallWatcherFactory,
    this.pollInterval = const Duration(seconds: 1),
  }) : _transport = transport ?? defaultApkUpdateTransport,
       _deviceAbiProvider = deviceAbiProvider ?? deviceAbiSuffix,
       _platformProvider = platformProvider ?? _defaultPlatform,
       _pollingEnabled = enableLifecyclePolling;

  /// 应用级单例（唯一启用生命周期轮询的默认实例）；测试用构造注入独立实例。
  static final ApkUpdateController instance = ApkUpdateController(
    enableLifecyclePolling: true,
  );

  static TargetPlatform _defaultPlatform() => defaultTargetPlatform;

  final ApkUpdateTransport _transport;
  final String? Function() _deviceAbiProvider;
  final TargetPlatform Function() _platformProvider;

  /// 是否持有前台轮询定时器：默认关闭（测试构造的独立实例不意外起表），
  /// 应用级单例 [instance] 开启，由组合层（`main.dart`）在冷启动时引导一次。
  final bool _pollingEnabled;

  /// 前台状态注入点（测试）；缺省以应用生命周期回调为准，初始视为前台。
  final bool Function()? foregroundProvider;

  /// 停滞观察器工厂注入点（测试）；缺省用默认构造。
  final ApkDownloadStallWatcher Function(ApkUpdateController controller)?
  stallWatcherFactory;

  /// 前台轮询节奏（默认 ~1s）；测试可注入更长间隔。
  final Duration pollInterval;

  /// 停滞观察器：与控制器同生命周期，惰性构造（注入点在工厂里可拿到本实例）。
  late final ApkDownloadStallWatcher _stallWatcher =
      (stallWatcherFactory ??
      (controller) => ApkDownloadStallWatcher(controller: controller))(this);

  final ValueNotifier<ApkUpdateState> state = ValueNotifier<ApkUpdateState>(
    const ApkUpdateState.idle(),
  );

  bool _startInFlight = false;
  int _refreshEpoch = 0;

  Timer? _pollTimer;
  bool _observingLifecycle = false;

  /// 轮询代际：[debugReset] 递增。在途轮询（timer 回调的 `_pollOnce`）跨 await
  /// 后若代际已变，不得再应用查询结果或重建定时器——否则测试 / 复位的收尾
  /// 会漏一个重新创建的后台定时器。
  int _pollGeneration = 0;

  /// 最近一次生命周期回调看到的前台状态；未收到任何回调前视为前台
  /// （应用冷启动即前台），注入 [foregroundProvider] 时以注入值为准。
  bool _foreground = true;

  bool get _isForeground => foregroundProvider?.call() ?? _foreground;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && _pollingEnabled) {
      // 回前台（含从「安装权限设置」返回）：立即查询一次原生真实状态并驱动
      // 停滞观察，不依赖弹窗是否打开。
      unawaited(_pollOnce());
    }
    _syncPolling();
  }

  /// 首次需要轮询时才注册生命周期观察（惰性）：避免纯 Dart 单测在尚未初始化
  /// WidgetsBinding 时构造控制器即崩溃；binding 不可用时轮询保持关闭。
  void _ensureLifecycleObserver() {
    if (_observingLifecycle) return;
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    _observingLifecycle = true;
  }

  /// 轮询只在「轮询启用 + 应用前台 + 状态处于活动阶段」时进行；其余情况一律
  /// 停表。退后台只是停止 Dart 轮询，**不**取消下载——原生 DownloadManager
  /// 继续，回前台再查询即可。
  void _syncPolling() {
    final shouldPoll =
        _pollingEnabled && _isForeground && state.value.phase.isActive;
    if (shouldPoll) {
      _ensureLifecycleObserver();
      _pollTimer ??= Timer.periodic(pollInterval, (_) {
        unawaited(_pollOnce());
      });
      return;
    }
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// 一次轮询：先刷新原生真实状态，再让停滞观察器据此判断是否需要建议换源。
  /// 跨 await 期间控制器被复位（[debugReset]）时整体作废，不再应用结果或
  /// 重建定时器。
  Future<void> _pollOnce() async {
    final generation = _pollGeneration;
    await refreshActiveUpdate();
    if (generation != _pollGeneration) return;
    await _stallWatcher.onPolled();
  }

  /// 组合层冷启动引导：查询一次原生状态（恢复后台已入队的下载投影），此后
  /// 轮询完全由「前台 + 活动阶段」驱动，无需任何 UI 触发。
  Future<void> bootstrap() async {
    if (!_pollingEnabled) return;
    _ensureLifecycleObserver();
    await _pollOnce();
  }

  /// 是否支持应用内受管更新：非 Android 直接 false，不触碰通道。
  Future<bool> isSupported() async {
    if (_platformProvider() != TargetPlatform.android) return false;
    return _transport.isSupported();
  }

  /// 入队一次受管下载。
  ///
  /// 按 [route]（设置页偏好）生成有序候选源并一次性交给原生，之后的换源由原生
  /// 决定（见 [ApkUpdateRequest.tryCreate] 的候选规则）。
  ///
  /// - 规范资产 URL 不可信 / 缺失、或没有任何可用候选源 →
  ///   [ApkUpdatePhase.unavailable]（`untrustedAsset`），**不**调用通道，UI 应
  ///   回退浏览器路径。
  /// - 同一请求已在活动状态或上一次 start 未返回 → 幂等 no-op。
  Future<void> startDownload(
    AppRelease release, {
    required ApkDownloadRoute route,
  }) async {
    if (_startInFlight) return;

    final request = ApkUpdateRequest.tryCreate(
      release,
      abi: _deviceAbiProvider(),
      route: route,
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

  /// 查询原生当前受管状态（冷启动 / 回前台恢复 / 弹窗轮询）并原样应用；无任务
  /// 为 idle。迟到的查询结果被 epoch 作废，绝不覆盖更新的状态；跨 await 期间
  /// 控制器被复位（[debugReset]）时结果整体丢弃，不得再重建轮询定时器。
  Future<void> refreshActiveUpdate() async {
    final epoch = ++_refreshEpoch;
    final generation = _pollGeneration;
    final next = await _transport.queryActiveUpdate();
    if (epoch != _refreshEpoch) return;
    if (generation != _pollGeneration) return;
    // 通道调用本身失败（transport 合成的 failed，不带 requestKey；原生给出的
    // 失败一定带 requestKey）不代表下载失败：活动中的任务保留上一状态，轮询
    // 继续，不让一次通道抖动把弹窗打成「更新失败」并停掉进度与换线观察。
    if (next != null &&
        next.phase == ApkUpdatePhase.failed &&
        next.requestKey == null &&
        state.value.phase.isActive) {
      return;
    }
    _apply(next ?? const ApkUpdateState.idle());
  }

  /// 取消当前受管下载并清理其文件（只影响原生受管的那一条），原样应用原生
  /// 返回值：确认退役为 `canceled`，退役未确认则是 `cleanupPending`（仍为活动
  /// 状态，轮询会驱动原生重试）。
  Future<void> cancelActiveUpdate() async {
    final epoch = ++_refreshEpoch;
    final next = await _transport.cancelActiveUpdate();
    if (epoch != _refreshEpoch) return;
    _apply(next);
  }

  /// 建议原生换到下一条候选源（只由 [ApkDownloadStallWatcher] 调用）。
  ///
  /// `failed` 是原生专属原因（明确失败由原生自己换源），Dart 不会发送。
  /// 原生可以拒绝（没有未试的源 / 不在下载中）：照常返回当前状态，Dart 不重试。
  Future<void> switchSource(ApkFallbackReason reason) async {
    if (reason == ApkFallbackReason.failed) return;
    final epoch = ++_refreshEpoch;
    final next = await _transport.switchSource(
      reason,
      attempt: state.value.attempt,
    );
    if (epoch != _refreshEpoch || next == null) return;
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
        canSwitch: false,
        switching: false,
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
    _syncPolling();
  }

  @visibleForTesting
  void debugReset() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollGeneration++;
    _startInFlight = false;
    // 测试每用例构造新实例：不复位移除的话，旧实例仍注册为生命周期观察者，
    // 后续用例的生命周期事件会把已废弃控制器「复活」重建轮询定时器。
    if (_observingLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
      _observingLifecycle = false;
    }
    state.value = const ApkUpdateState.idle();
    _stallWatcher.reset();
  }
}
