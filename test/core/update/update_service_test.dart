import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/config/app_config.dart';
import 'package:jxu_campus_hub/core/update/update_model.dart';
import 'package:jxu_campus_hub/core/update/update_source.dart';
import 'package:jxu_campus_hub/core/update/update_service.dart';

import '../../helpers/mock_http_client_adapter.dart';

class _FakeUpdateSource implements UpdateSource {
  const _FakeUpdateSource(this.loader);

  final Future<AppRelease> Function() loader;

  @override
  Future<AppRelease> fetchLatestRelease() => loader();
}

void main() {
  setUp(() {
    UpdateService.instance.debugReset();
  });

  tearDown(() {
    UpdateService.instance.debugReset();
  });

  test('returns release when github version is newer', () async {
    final release = AppRelease(
      version: '0.1.3',
      changelog: '',
      downloadUrl: '',
      releaseUrl: 'https://example.com',
      publishedAt: DateTime(2026),
    );
    UpdateService.instance.debugReleaseProvider = () async => release;
    UpdateService.instance.debugCurrentVersionProvider = () async => '0.1.2';

    final result = await UpdateService.instance.checkForUpdate();

    expect(result, same(release));
  });

  test('returns null when current version is already latest', () async {
    final release = AppRelease(
      version: '0.1.3',
      changelog: '',
      downloadUrl: '',
      releaseUrl: 'https://example.com',
      publishedAt: DateTime(2026),
    );
    UpdateService.instance.debugReleaseProvider = () async => release;
    UpdateService.instance.debugCurrentVersionProvider = () async => '0.1.3';

    final result = await UpdateService.instance.checkForUpdate();

    expect(result, isNull);
  });

  test('throws when release loading fails', () async {
    UpdateService.instance.debugReleaseProvider = () async {
      throw StateError('failed');
    };
    UpdateService.instance.debugCurrentVersionProvider = () async => '0.1.0';

    expect(UpdateService.instance.checkForUpdate(), throwsStateError);
  });

  test('fetches latest release through configured source', () async {
    final release = AppRelease(
      version: '0.1.4',
      changelog: '',
      downloadUrl: 'https://example.com/app.apk',
      releaseUrl: 'https://example.com/release',
      publishedAt: DateTime(2026),
    );
    UpdateService.instance.debugSource = _FakeUpdateSource(() async => release);
    UpdateService.instance.debugIsRemoteUpdateEnabled = true;

    final result = await UpdateService.instance.fetchLatestRelease();

    expect(result, same(release));
  });

  test('reports remote update enabled by default', () {
    expect(UpdateService.instance.isRemoteUpdateEnabled, isTrue);
    expect(AppConfig.updateMode, AppUpdateMode.githubRelease);
    expect(
      AppConfig.updateGithubLatestReleaseApiUrl,
      'https://api.github.com/repos/FHfanshu/ZJXU-CampusHub/releases/latest',
    );
    expect(
      AppConfig.updateGithubLatestReleaseFallbackApiUrls,
      contains(
        'https://edgeone.gh-proxy.org/https://api.github.com/repos/FHfanshu/ZJXU-CampusHub/releases/latest',
      ),
    );
    expect(
      AppConfig.updateGithubReleaseMirrorPrefix,
      'https://edgeone.gh-proxy.org/',
    );
  });

  test(
    'parses github release and mirrors release urls through edgeone',
    () async {
      final dio = Dio();
      final adapter = MockHttpClientAdapter();
      dio.httpClientAdapter = adapter;
      adapter.registerJson(
        'GET',
        '/repos/FHfanshu/ZJXU-CampusHub/releases/latest',
        {
          'tag_name': 'v0.2.5',
          'body': '更新内容',
          'html_url':
              'https://github.com/FHfanshu/ZJXU-CampusHub/releases/tag/v0.2.5',
          'published_at': '2026-05-14T10:00:00Z',
          'assets': [
            {
              'name': 'notes.txt',
              'browser_download_url': 'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/v0.2.5/notes.txt',
            },
            {
              'name': 'JXU-CampusHub-v0.2.5.apk',
              'browser_download_url': 'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/v0.2.5/JXU-CampusHub-v0.2.5.apk',
            },
          ],
        },
      );

      final source = GitHubReleaseUpdateSource(
        dio: dio,
        latestReleaseApiUrl: 'https://api.github.com/repos/FHfanshu/ZJXU-CampusHub/releases/latest',
        releaseMirrorPrefix: 'https://edgeone.gh-proxy.org/',
      );

      final release = await source.fetchLatestRelease();

      expect(release.version, '0.2.5');
      expect(release.changelog, '更新内容');
      expect(
        release.releaseUrl,
        'https://edgeone.gh-proxy.org/https://github.com/FHfanshu/ZJXU-CampusHub/releases/tag/v0.2.5',
      );
      expect(
        release.downloadUrl,
        'https://edgeone.gh-proxy.org/https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/v0.2.5/JXU-CampusHub-v0.2.5.apk',
      );
    },
  );

  test(
    'falls back to secondary github release api when primary fails',
    () async {
      final dio = Dio();
      final adapter = MockHttpClientAdapter();
      dio.httpClientAdapter = adapter;
      adapter.registerJson(
        'GET',
        '/repos/FHfanshu/ZJXU-CampusHub/releases/latest',
        {'message': 'rate limited'},
        statusCode: 403,
      );
      adapter.registerJson(
        'GET',
        '/https://api.github.com/repos/FHfanshu/ZJXU-CampusHub/releases/latest',
        {
          'tag_name': 'v0.2.6',
          'body': 'fallback ok',
          'html_url':
              'https://github.com/FHfanshu/ZJXU-CampusHub/releases/tag/v0.2.6',
          'published_at': '2026-05-14T11:00:00Z',
          'assets': [
            {
              'name': 'JXU-CampusHub-v0.2.6.apk',
              'browser_download_url': 'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/v0.2.6/JXU-CampusHub-v0.2.6.apk',
            },
          ],
        },
      );

      final source = GitHubReleaseUpdateSource(
        dio: dio,
        latestReleaseApiUrl: 'https://api.github.com/repos/FHfanshu/ZJXU-CampusHub/releases/latest',
        latestReleaseFallbackApiUrls: const [
          'https://edgeone.gh-proxy.org/https://api.github.com/repos/FHfanshu/ZJXU-CampusHub/releases/latest',
        ],
        releaseMirrorPrefix: 'https://edgeone.gh-proxy.org/',
      );

      final release = await source.fetchLatestRelease();

      expect(release.version, '0.2.6');
      expect(release.changelog, 'fallback ok');
      expect(adapter.requestLog, [
        'GET /repos/FHfanshu/ZJXU-CampusHub/releases/latest',
        'GET /https://api.github.com/repos/FHfanshu/ZJXU-CampusHub/releases/latest',
      ]);
    },
  );

  test('selects the APK matching the Android runtime ABI', () async {
    final dio = Dio();
    final adapter = MockHttpClientAdapter();
    dio.httpClientAdapter = adapter;
    adapter.registerJson(
      'GET',
      '/repos/FHfanshu/ZJXU-CampusHub/releases/latest',
      {
        'tag_name': 'v0.2.7',
        'html_url':
            'https://github.com/FHfanshu/ZJXU-CampusHub/releases/tag/v0.2.7',
        'published_at': '2026-05-14T12:00:00Z',
        'assets': [
          {
            'name': 'JXU-CampusHub-v0.2.7-arm64-v8a.apk',
            'browser_download_url': 'https://example.com/arm64.apk',
          },
          {
            'name': 'JXU-CampusHub-v0.2.7-armeabi-v7a.apk',
            'browser_download_url': 'https://example.com/arm32.apk',
          },
        ],
      },
    );
    final source = GitHubReleaseUpdateSource(
      dio: dio,
      latestReleaseApiUrl: 'https://api.github.com/repos/FHfanshu/ZJXU-CampusHub/releases/latest',
      releaseMirrorPrefix: '',
      deviceAbiProvider: () => 'armeabi-v7a',
    );

    final release = await source.fetchLatestRelease();

    expect(release.downloadUrl, 'https://example.com/arm32.apk');
  });

  test(
    'throws source unavailable when all github release api candidates fail',
    () async {
      final dio = Dio();
      final adapter = MockHttpClientAdapter();
      dio.httpClientAdapter = adapter;
      adapter.registerJson(
        'GET',
        '/repos/FHfanshu/ZJXU-CampusHub/releases/latest',
        {'message': 'not found'},
        statusCode: 404,
      );

      final source = GitHubReleaseUpdateSource(
        dio: dio,
        latestReleaseApiUrl: 'https://api.github.com/repos/FHfanshu/ZJXU-CampusHub/releases/latest',
        releaseMirrorPrefix: 'https://edgeone.gh-proxy.org/',
      );

      expect(
        source.fetchLatestRelease(),
        throwsA(isA<UpdateSourceUnavailableException>()),
      );
    },
  );

  test('extracts canonical asset metadata without altering mirrored urls', () async {
    final dio = Dio();
    final adapter = MockHttpClientAdapter();
    dio.httpClientAdapter = adapter;
    final hex = 'b' * 64;
    adapter.registerJson(
      'GET',
      '/repos/FHfanshu/ZJXU-CampusHub/releases/latest',
      {
        'tag_name': 'v0.2.8',
        'html_url':
            'https://github.com/FHfanshu/ZJXU-CampusHub/releases/tag/v0.2.8',
        'published_at': '2026-05-14T13:00:00Z',
        'assets': [
          {
            'id': 777,
            'name': 'JXU-CampusHub-v0.2.8-arm64-v8a.apk',
            'size': 123456,
            'digest': 'sha256:$hex',
            'browser_download_url':
                'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/'
                'v0.2.8/JXU-CampusHub-v0.2.8-arm64-v8a.apk',
          },
          {
            'id': 778,
            'name': 'JXU-CampusHub-v0.2.8-armeabi-v7a.apk',
            'browser_download_url':
                'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/'
                'v0.2.8/JXU-CampusHub-v0.2.8-armeabi-v7a.apk',
          },
        ],
      },
    );
    final source = GitHubReleaseUpdateSource(
      dio: dio,
      latestReleaseApiUrl: 'https://api.github.com/repos/FHfanshu/ZJXU-CampusHub/releases/latest',
      releaseMirrorPrefix: 'https://edgeone.gh-proxy.org/',
      deviceAbiProvider: () => 'arm64-v8a',
    );

    final release = await source.fetchLatestRelease();

    // 既有镜像行为不变。
    expect(
      release.downloadUrl,
      'https://edgeone.gh-proxy.org/https://github.com/FHfanshu/'
      'ZJXU-CampusHub/releases/download/v0.2.8/'
      'JXU-CampusHub-v0.2.8-arm64-v8a.apk',
    );
    // 规范官方 URL 不被镜像改写。
    expect(
      release.canonicalAssetUrl,
      'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/'
      'v0.2.8/JXU-CampusHub-v0.2.8-arm64-v8a.apk',
    );
    expect(release.assetId, 777);
    expect(release.assetFileName, 'JXU-CampusHub-v0.2.8-arm64-v8a.apk');
    expect(release.assetSizeBytes, 123456);
    expect(release.assetSha256, hex);
  });

  test('ignores malformed asset digest and size, keeps release parseable', () async {
    final dio = Dio();
    final adapter = MockHttpClientAdapter();
    dio.httpClientAdapter = adapter;
    adapter.registerJson(
      'GET',
      '/repos/FHfanshu/ZJXU-CampusHub/releases/latest',
      {
        'tag_name': 'v0.2.9',
        'html_url':
            'https://github.com/FHfanshu/ZJXU-CampusHub/releases/tag/v0.2.9',
        'published_at': '2026-05-14T14:00:00Z',
        'assets': [
          {
            'id': 779,
            'name': 'JXU-CampusHub-v0.2.9-arm64-v8a.apk',
            'size': 0,
            'digest': 'sha256:nothex',
            'browser_download_url':
                'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/'
                'v0.2.9/JXU-CampusHub-v0.2.9-arm64-v8a.apk',
          },
        ],
      },
    );
    final source = GitHubReleaseUpdateSource(
      dio: dio,
      latestReleaseApiUrl: 'https://api.github.com/repos/FHfanshu/ZJXU-CampusHub/releases/latest',
      releaseMirrorPrefix: '',
      deviceAbiProvider: () => 'arm64-v8a',
    );

    final release = await source.fetchLatestRelease();

    expect(release.assetSha256, isNull);
    expect(release.assetSizeBytes, isNull);
    expect(release.downloadUrl, isNotEmpty);
  });
}
