import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/config/app_config.dart';
import 'package:jxu_campus_hub/core/update/apk_download_route.dart';
import 'package:jxu_campus_hub/core/update/apk_update_controller.dart';
import 'package:jxu_campus_hub/core/update/update_model.dart';
import 'package:jxu_campus_hub/core/update/update_source.dart';

import '../../helpers/mock_http_client_adapter.dart';

const String _tag = 'v0.11.4';
const String _name = 'JXU-CampusHub-v0.11.4-arm64-v8a.apk';
const String _github =
    'https://github.com/CampusHub-JXU/ZJXU-CampusHub/releases/download/$_tag/$_name';
const String _edgeone = 'https://edgeone.gh-proxy.org/$_github';
const String _r2 = 'https://download.fhfanshu.xyz/$_tag/$_name';

AppRelease _release({bool r2 = true}) => AppRelease(
  version: '0.11.4',
  changelog: '',
  downloadUrl: '',
  releaseUrl:
      'https://github.com/CampusHub-JXU/ZJXU-CampusHub/releases/tag/$_tag',
  publishedAt: DateTime(2026, 10, 16),
  canonicalAssetUrl: _github,
  assetId: 9,
  assetFileName: _name,
  assetSizeBytes: 1000,
  assetSha256: 'c' * 64,
  r2MirrorAvailable: r2,
);

void main() {
  group('ApkUpdateUrlPolicy 三种可信形态', () {
    test('接受 GitHub / EdgeOne / R2', () {
      expect(ApkUpdateUrlPolicy.isCanonicalAssetUrl(_github), isTrue);
      expect(ApkUpdateUrlPolicy.isMirrorAssetUrl(_edgeone), isTrue);
      expect(ApkUpdateUrlPolicy.isR2AssetUrl(_r2), isTrue);
      for (final url in [_github, _edgeone, _r2]) {
        expect(
          ApkUpdateUrlPolicy.isTrustedDownloadUrl(url),
          isTrue,
          reason: url,
        );
      }
    });

    test('形态之间互不混淆', () {
      expect(ApkUpdateUrlPolicy.isCanonicalAssetUrl(_edgeone), isFalse);
      expect(ApkUpdateUrlPolicy.isCanonicalAssetUrl(_r2), isFalse);
      expect(ApkUpdateUrlPolicy.isMirrorAssetUrl(_github), isFalse);
      expect(ApkUpdateUrlPolicy.isR2AssetUrl(_github), isFalse);
      expect(ApkUpdateUrlPolicy.isR2AssetUrl(_edgeone), isFalse);
    });

    test('拒绝形态外的 URL', () {
      const rejects = <String>[
        // 镜像：前缀大小写 / 双前缀 / 非 GitHub 内层 / query。
        'HTTPS://edgeone.gh-proxy.org/$_github',
        'https://EDGEONE.gh-proxy.org/$_github',
        'https://edgeone.gh-proxy.org/https://edgeone.gh-proxy.org/$_github',
        'https://edgeone.gh-proxy.org/https://evil.example.com/a/b.apk',
        'https://edgeone.gh-proxy.org/$_github?x=1',
        'https://edgeone.gh-proxy.org/https://GITHUB.com/CampusHub-JXU/ZJXU-CampusHub/'
            'releases/download/$_tag/$_name',
        'https://edgeone.gh-proxy.org/',
        'http://edgeone.gh-proxy.org/$_github',
        'https://edgeone.gh-proxy.org.evil.com/$_github',
        // R2：额外段 / 缺 apk / 其它子域 / 端口 / userinfo / query / 穿越。
        'https://download.fhfanshu.xyz/$_tag/extra/$_name',
        'https://download.fhfanshu.xyz/$_name',
        'https://download.fhfanshu.xyz/$_tag/file.zip',
        'https://r2.fhfanshu.xyz/$_tag/$_name',
        'https://download.fhfanshu.xyz.evil.com/$_tag/$_name',
        'https://download.fhfanshu.xyz:443/$_tag/$_name',
        'https://user@download.fhfanshu.xyz/$_tag/$_name',
        'https://download.fhfanshu.xyz/$_tag/$_name?x=1',
        'https://download.fhfanshu.xyz/$_tag/$_name#frag',
        'https://download.fhfanshu.xyz/%2e%2e/$_name',
        r'https://download.fhfanshu.xyz/v0\..4/a.apk',
        'http://download.fhfanshu.xyz/$_tag/$_name',
      ];
      for (final url in rejects) {
        expect(
          ApkUpdateUrlPolicy.isTrustedDownloadUrl(url),
          isFalse,
          reason: url,
        );
      }
    });
  });

  group('线路 URL 派生与请求', () {
    test('urlFor 从规范 URL 派生三线路', () {
      String? url(ApkDownloadSource s, {bool r2 = true}) =>
          ApkUpdateUrlPolicy.urlFor(s, canonicalUrl: _github, r2Available: r2);
      expect(url(ApkDownloadSource.github), _github);
      expect(url(ApkDownloadSource.edgeone), _edgeone);
      expect(url(ApkDownloadSource.r2), _r2);
      expect(url(ApkDownloadSource.r2, r2: false), isNull);
      expect(
        ApkUpdateUrlPolicy.urlFor(
          ApkDownloadSource.edgeone,
          canonicalUrl: 'https://evil.example.com/a/b/c/d/e/f.apk',
          r2Available: true,
        ),
        isNull,
      );
    });

    test('同一任务的候选源共享文件名 / 大小 / SHA-256 / tag，requestKey 不含线路', () {
      final auto = ApkUpdateRequest.tryCreate(
        _release(),
        abi: 'arm64-v8a',
        route: ApkDownloadRoute.auto,
      )!;
      final edge = ApkUpdateRequest.tryCreate(
        _release(),
        abi: 'arm64-v8a',
        route: ApkDownloadRoute.edgeone,
      )!;
      final r2 = ApkUpdateRequest.tryCreate(
        _release(),
        abi: 'arm64-v8a',
        route: ApkDownloadRoute.r2,
      )!;
      expect([for (final s in auto.sources) s.url], [_r2, _edgeone]);
      expect(edge.sources.single.url, _edgeone);
      expect(r2.sources.single.url, _r2);
      for (final r in [auto, edge, r2]) {
        expect(r.assetFileName, _name);
        expect(r.releaseTag, _tag);
        expect(r.assetSizeBytes, 1000);
        expect(r.sha256, 'c' * 64);
        expect(r.toPlatformMap()['fileName'], _name);
        // 每个候选 URL 都通过可信白名单（原生入队前会逐个复核同一白名单）。
        for (final candidate in r.sources) {
          expect(
            ApkUpdateUrlPolicy.isTrustedDownloadUrl(candidate.url),
            isTrue,
            reason: candidate.url,
          );
        }
      }
      expect(auto.requestKey, endsWith(':${'c' * 64}'));
      expect(auto.requestKey, startsWith('v2:'));
      expect(edge.requestKey, auto.requestKey);
      expect(r2.requestKey, auto.requestKey);
    });

    test('无 R2 标记时 R2 请求不可构造（绝不猜测对象）', () {
      // 自动 / 手动 EdgeOne 都不会带上 R2 候选；手动 R2 退到 EdgeOne 并如实标注。
      for (final route in ApkDownloadRoute.values) {
        final r = ApkUpdateRequest.tryCreate(
          _release(r2: false),
          route: route,
        )!;
        expect(
          r.sources.map((c) => c.source),
          isNot(contains(ApkDownloadSource.r2)),
          reason: route.name,
        );
      }
    });
  });

  group('配置与原生契约 lockstep', () {
    test('AppConfig 的 R2 基址 / 镜像前缀 == 协议常量', () {
      expect(
        AppConfig.updateR2DownloadBaseUrl,
        'https://${ApkUpdateProtocol.trustedR2Host}',
      );
      expect(
        AppConfig.updateGithubReleaseMirrorPrefix,
        ApkUpdateProtocol.trustedMirrorPrefix,
      );
    });
  });

  group('R2 镜像标记资产', () {
    Future<AppRelease> fetch(List<Map<String, Object?>> assets) async {
      final dio = Dio();
      final adapter = MockHttpClientAdapter();
      dio.httpClientAdapter = adapter;
      adapter.registerJson(
        'GET',
        '/repos/CampusHub-JXU/ZJXU-CampusHub/releases/latest',
        {
          'tag_name': _tag,
          'html_url':
              'https://github.com/CampusHub-JXU/ZJXU-CampusHub/releases/tag/$_tag',
          'published_at': '2026-10-16T00:00:00Z',
          'assets': assets,
        },
      );
      return GitHubReleaseUpdateSource(
        dio: dio,
        latestReleaseApiUrl: 'https://api.github.com/repos/CampusHub-JXU/ZJXU-CampusHub/releases/latest',
        releaseMirrorPrefix: 'https://edgeone.gh-proxy.org/',
        deviceAbiProvider: () => 'arm64-v8a',
      ).fetchLatestRelease();
    }

    final apk = <String, Object?>{
      'id': 1,
      'name': _name,
      'browser_download_url': _github,
    };

    test('存在 r2-mirror.json 时才视为 R2 可用', () async {
      final with_ = await fetch([
        apk,
        {'id': 2, 'name': 'r2-mirror.json', 'browser_download_url': 'x'},
      ]);
      expect(with_.r2MirrorAvailable, isTrue);
      final without = await fetch([apk]);
      expect(without.r2MirrorAvailable, isFalse);
    });

    test('标记资产不会被当成 APK 资产选中', () async {
      final release = await fetch([
        {'id': 2, 'name': 'r2-mirror.json', 'browser_download_url': 'x'},
        apk,
      ]);
      expect(release.assetFileName, _name);
      expect(release.canonicalAssetUrl, _github);
    });
  });
}
