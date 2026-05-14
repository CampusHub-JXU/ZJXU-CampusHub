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
  static const updateChannel = 'internal';

  static Uri get xiaofubaoRechargeUri => Uri.parse(
    '$xiaofubaoRechargeBaseUrl?platform=WECHAT_H5&schoolCode=$xiaofubaoSchoolCode&thirdAppid=$xiaofubaoThirdAppId',
  );
}
