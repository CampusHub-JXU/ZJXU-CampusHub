import 'package:flutter/foundation.dart' show kDebugMode;

enum AppUpdateMode { disabled, remoteManifest, githubRelease }

abstract final class AppConfig {
  static const xiaofubaoThirdAppId = 'wx8fddf03d92fd6fa9';
  static const xiaofubaoSchoolCode = '10354';
  static const xiaofubaoRechargeBaseUrl =
      'https://webapp.xiaofubao.com/card/card_home.shtml';
  static const updateMode = AppUpdateMode.githubRelease;
  static const updateManifestUrl = '';
  static const updateGithubLatestReleaseApiUrl =
      'https://api.github.com/repos/CampusHub-JXU/ZJXU-CampusHub/releases/latest';
  static const updateGithubLatestReleaseFallbackApiUrls = [
    'https://edgeone.gh-proxy.org/https://api.github.com/repos/CampusHub-JXU/ZJXU-CampusHub/releases/latest',
  ];
  static const updateGithubReleaseMirrorPrefix =
      'https://edgeone.gh-proxy.org/';

  /// Cloudflare R2 自定义下载域名（须与 `ApkUpdateProtocol.trustedR2Host` 及原生
  /// `AppUpdateContract.TRUSTED_R2_HOST` lockstep；一致性由测试断言）。
  ///
  /// 对象路径 `<base>/<tag>/<apk>`。**仅当**该 Release 带有发布流水线在 R2 上传
  /// 并校验成功后才附加的标记资产 [updateR2MirrorMarkerAssetName] 时，应用才会
  /// 使用 R2 线路；域名是否已在 Cloudflare 绑定由维护者负责，应用不探测。
  static const updateR2DownloadBaseUrl = 'https://download.fhfanshu.xyz';
  static const updateR2MirrorMarkerAssetName = 'r2-mirror.json';

  /// 调试端到端专用本地更新源（编译期定义 `JXU_UPDATE_TEST_ORIGIN`，值形如
  /// `http://10.0.2.2:8080`，经 `--dart-define` 传入）。release / profile 构建里编译期 `kDebugMode`
  /// 为 false，[updateTestOrigin] 恒为 null，分支不可达。
  static const String _updateTestOriginDefine = String.fromEnvironment(
    'JXU_UPDATE_TEST_ORIGIN',
  );

  /// 本地测试源的 origin；**仅 `kDebugMode` 且定义值合法时非 null**。
  ///
  /// 这是 Dart 侧唯一的测试源开关（更新检查、候选线路、请求构造都读这里）。
  static String? get updateTestOrigin =>
      resolveUpdateTestOrigin(_updateTestOriginDefine, debugMode: kDebugMode);

  /// [updateTestOrigin] 的纯逻辑：非调试模式、空值、或不是
  /// `http://10.0.2.2:<1024–65535>` 的值一律返回 null（fail closed）；
  /// 末尾 `/` 会被去掉。
  static String? resolveUpdateTestOrigin(
    String raw, {
    required bool debugMode,
  }) {
    if (!debugMode) return null;
    var value = raw.trim();
    if (value.isEmpty) return null;
    if (value.endsWith('/')) value = value.substring(0, value.length - 1);
    final match = RegExp(r'^http://10\.0\.2\.2:([1-9]\d{3,4})$')
        .firstMatch(value);
    if (match == null) return null;
    final port = int.parse(match.group(1)!);
    if (port < 1024 || port > 65535) return null;
    return value;
  }

  static Uri get xiaofubaoRechargeUri => Uri.parse(
    '$xiaofubaoRechargeBaseUrl?platform=WECHAT_H5&schoolCode=$xiaofubaoSchoolCode&thirdAppid=$xiaofubaoThirdAppId',
  );
}
