enum AppUpdateMode { disabled, remoteManifest, githubRelease }

abstract final class AppConfig {
  static const xiaofubaoThirdAppId = 'wx8fddf03d92fd6fa9';
  static const xiaofubaoSchoolCode = '10354';
  static const xiaofubaoRechargeBaseUrl =
      'https://webapp.xiaofubao.com/card/card_home.shtml';
  static const updateMode = AppUpdateMode.githubRelease;
  static const updateManifestUrl = '';
  static const updateGithubLatestReleaseApiUrl =
      'https://api.github.com/repos/FHfanshu/ZJXU-CampusHub/releases/latest';
  static const updateGithubLatestReleaseFallbackApiUrls = [
    'https://edgeone.gh-proxy.org/https://api.github.com/repos/FHfanshu/ZJXU-CampusHub/releases/latest',
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

  static Uri get xiaofubaoRechargeUri => Uri.parse(
    '$xiaofubaoRechargeBaseUrl?platform=WECHAT_H5&schoolCode=$xiaofubaoSchoolCode&thirdAppid=$xiaofubaoThirdAppId',
  );
}
