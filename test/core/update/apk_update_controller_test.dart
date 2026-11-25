import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/config/app_config.dart';
import 'package:jxu_campus_hub/core/logging/app_logger.dart';
import 'package:jxu_campus_hub/core/update/apk_download_route.dart';
import 'package:jxu_campus_hub/core/update/apk_update_controller.dart';
import 'package:jxu_campus_hub/core/update/update_model.dart';

/// 可控的假 transport：不触达真实 MethodChannel / 原生。
class _FakeApkUpdateTransport implements ApkUpdateTransport {
  bool supported = true;
  ApkUpdateState startResult = const ApkUpdateState(
    phase: ApkUpdatePhase.downloading,
    bytesDownloaded: 10,
    totalBytes: 100,
  );
  ApkUpdateState cancelResult = const ApkUpdateState(
    phase: ApkUpdatePhase.canceled,
  );
  ApkUpdateState? queryResult;
  bool installOk = true;
  bool permissionOk = true;

  Future<ApkUpdateState?> Function()? queryHandler;
  Completer<void>? startGate;

  int supportedCalls = 0;
  int startCalls = 0;
  int queryCalls = 0;
  int cancelCalls = 0;
  int switchCalls = 0;
  int installCalls = 0;
  int permissionCalls = 0;
  ApkUpdateRequest? lastRequest;
  ApkFallbackReason? lastSwitchReason;
  ApkUpdateState? switchResult;

  @override
  Future<bool> isSupported() async {
    supportedCalls++;
    return supported;
  }

  @override
  Future<ApkUpdateState> startDownload(ApkUpdateRequest request) async {
    startCalls++;
    lastRequest = request;
    final gate = startGate;
    if (gate != null) await gate.future;
    return startResult;
  }

  @override
  Future<ApkUpdateState?> queryActiveUpdate() async {
    queryCalls++;
    final handler = queryHandler;
    if (handler != null) return handler();
    return queryResult;
  }

  @override
  Future<ApkUpdateState> cancelActiveUpdate() async {
    cancelCalls++;
    return cancelResult;
  }

  @override
  Future<ApkUpdateState?> switchSource(
    ApkFallbackReason reason, {
    required int attempt,
  }) async {
    switchCalls++;
    lastSwitchReason = reason;
    return switchResult;
  }

  @override
  Future<bool> requestInstall({String? expectedReleaseTag}) async {
    installCalls++;
    return installOk;
  }

  @override
  Future<bool> openInstallPermissionSettings() async {
    permissionCalls++;
    return permissionOk;
  }
}

const String _goodUrl =
    'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/'
    'v0.2.7/JXU-CampusHub-v0.2.7-arm64-v8a.apk';
const String _r2Url =
    'https://download.fhfanshu.xyz/v0.2.7/JXU-CampusHub-v0.2.7-arm64-v8a.apk';

AppRelease _release({
  String version = '0.2.7',
  String? canonicalAssetUrl = _goodUrl,
  String? assetFileName = 'JXU-CampusHub-v0.2.7-arm64-v8a.apk',
  int? assetId = 12345,
  int? assetSizeBytes = 52428800,
  String? assetSha256 =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  bool r2 = false,
}) {
  return AppRelease(
    version: version,
    changelog: '',
    downloadUrl:
        'https://edgeone.gh-proxy.org/https://github.com/FHfanshu/'
        'ZJXU-CampusHub/releases/download/v0.2.7/JXU-CampusHub-v0.2.7-arm64-v8a.apk',
    releaseUrl:
        'https://github.com/FHfanshu/ZJXU-CampusHub/releases/tag/v0.2.7',
    publishedAt: DateTime(2026, 5, 14),
    canonicalAssetUrl: canonicalAssetUrl,
    assetId: assetId,
    assetFileName: assetFileName,
    assetSizeBytes: assetSizeBytes,
    assetSha256: assetSha256,
    r2MirrorAvailable: r2,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppLogger.instance.debugReset();
  });

  group('ApkUpdateUrlPolicy', () {
    test('accepts canonical trusted repo asset url', () {
      expect(ApkUpdateUrlPolicy.isCanonicalAssetUrl(_goodUrl), isTrue);
    });

    test('rejects non-https, userinfo, fragment, query and ports', () {
      expect(
        ApkUpdateUrlPolicy.isCanonicalAssetUrl(
          _goodUrl.replaceFirst('https://', 'http://'),
        ),
        isFalse,
      );
      expect(
        ApkUpdateUrlPolicy.isCanonicalAssetUrl(
          _goodUrl.replaceFirst('github.com', 'user@github.com'),
        ),
        isFalse,
      );
      expect(ApkUpdateUrlPolicy.isCanonicalAssetUrl('$_goodUrl#frag'), isFalse);
      expect(ApkUpdateUrlPolicy.isCanonicalAssetUrl('$_goodUrl?x=1'), isFalse);
      expect(
        ApkUpdateUrlPolicy.isCanonicalAssetUrl(
          _goodUrl.replaceFirst('github.com', 'github.com:8443'),
        ),
        isFalse,
      );
    });

    test('rejects untrusted host and different repo', () {
      expect(
        ApkUpdateUrlPolicy.isCanonicalAssetUrl(
          _goodUrl.replaceFirst('github.com', 'evil.example.com'),
        ),
        isFalse,
      );
      expect(
        ApkUpdateUrlPolicy.isCanonicalAssetUrl(
          _goodUrl.replaceFirst('FHfanshu', 'SomeoneElse'),
        ),
        isFalse,
      );
      expect(
        ApkUpdateUrlPolicy.isCanonicalAssetUrl(
          _goodUrl.replaceFirst('ZJXU-CampusHub', 'OtherRepo'),
        ),
        isFalse,
      );
    });

    test('rejects encoded path traversal and non-apk files', () {
      expect(
        ApkUpdateUrlPolicy.isCanonicalAssetUrl(
          'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/'
          'v0.2.7/%2e%2e/%2e%2e/evil.apk',
        ),
        isFalse,
      );
      expect(
        ApkUpdateUrlPolicy.isCanonicalAssetUrl(
          _goodUrl.replaceFirst('.apk', '.txt'),
        ),
        isFalse,
      );
      expect(
        ApkUpdateUrlPolicy.isCanonicalAssetUrl(
          'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/'
          'v0.2.7/extra/deep/file.apk',
        ),
        isFalse,
      );
    });

    test(
      'rejects literal default port, backslash and control chars (raw parity)',
      () {
        // 显式默认端口 `:443`：Dart 曾因 hasPort=false 放行，原生拒绝。
        expect(
          ApkUpdateUrlPolicy.isCanonicalAssetUrl(
            _goodUrl.replaceFirst('github.com', 'github.com:443'),
          ),
          isFalse,
        );
        // 字面反斜杠：Uri 会归一为 `/`，原生拒绝。
        expect(
          ApkUpdateUrlPolicy.isCanonicalAssetUrl(
            _goodUrl.replaceFirst(
              'JXU-CampusHub-v0.2.7-arm64-v8a.apk',
              r'a\..\b.apk',
            ),
          ),
          isFalse,
        );
        // 控制字符 / NUL：绝不接受。
        expect(
          ApkUpdateUrlPolicy.isCanonicalAssetUrl('$_goodUrl\u0001'),
          isFalse,
        );
        expect(
          ApkUpdateUrlPolicy.isCanonicalAssetUrl(
            'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/'
            'v0.2.7/a\u0000.apk',
          ),
          isFalse,
        );
      },
    );

    test('accepts encoded space but rejects encoded traversal / slash', () {
      // 编码空格 `%20`：合法资产名（原生解码后安全），不得误杀。
      expect(
        ApkUpdateUrlPolicy.isCanonicalAssetUrl(
          'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/'
          'v0.2.7/JXU%20Campus%20Hub.apk',
        ),
        isTrue,
      );
      // 编码的 `.` / `/` / `\`：解码后才暴露的穿越 / 分隔符向量，拒绝。
      expect(
        ApkUpdateUrlPolicy.isCanonicalAssetUrl(
          'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/'
          'v0.2.7/a%2e%2e.apk',
        ),
        isFalse,
      );
      expect(
        ApkUpdateUrlPolicy.isCanonicalAssetUrl(
          'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/'
          'v0.2.7/a%2Fb.apk',
        ),
        isFalse,
      );
      expect(
        ApkUpdateUrlPolicy.isCanonicalAssetUrl(
          'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/'
          'v0.2.7/a%5cb.apk',
        ),
        isFalse,
      );
    });

    test('normal canonical urls with dots and dashes still accepted', () {
      expect(ApkUpdateUrlPolicy.isCanonicalAssetUrl(_goodUrl), isTrue);
      expect(
        ApkUpdateUrlPolicy.isCanonicalAssetUrl(
          'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/'
          'v1.2.3/JXU-CampusHub-v1.2.3-arm64-v8a.apk',
        ),
        isTrue,
      );
    });
  });

  group('ApkUpdateRequest', () {
    test('builds a whitelisted platform map and stable request key', () {
      final request = ApkUpdateRequest.tryCreate(
        _release(),
        abi: 'arm64-v8a',
        route: ApkDownloadRoute.auto,
      )!;

      expect(request.releaseTag, 'v0.2.7');
      expect(request.assetFileName, 'JXU-CampusHub-v0.2.7-arm64-v8a.apk');
      expect(request.sha256, hasLength(64));
      expect(request.sources.single.source, ApkDownloadSource.edgeone);

      final map = request.toPlatformMap();
      expect(map.keys.toSet(), <String>{
        'version',
        'releaseTag',
        'fileName',
        'requestKey',
        'mode',
        'sources',
        'sizeBytes',
        'sha256',
        'abi',
      }, reason: '协议字段白名单；无 url / assetId / 账号类字段');
      expect(map['requestKey'], request.requestKey);
      expect(map['mode'], 'auto');
      expect(map['sources'], <Map<String, Object?>>[
        <String, Object?>{
          'source': 'edgeone',
          'url': 'https://edgeone.gh-proxy.org/$_goodUrl',
        },
      ]);

      // 稳定：同输入重复构造 key 相同；不含账号身份。
      final again = ApkUpdateRequest.tryCreate(
        _release(),
        abi: 'arm64-v8a',
        route: ApkDownloadRoute.auto,
      )!;
      expect(again.requestKey, request.requestKey);
      expect(request.requestKey, isNot(contains('account')));
    });

    test('requestKey is v2 and has no source suffix', () {
      final release = _release();
      final keys = <String>{
        for (final route in ApkDownloadRoute.values)
          ApkUpdateRequest.tryCreate(
            release,
            abi: 'arm64-v8a',
            route: route,
          )!.requestKey,
      };
      expect(keys, hasLength(1), reason: '换线 / 换偏好不换任务身份');
      expect(
        keys.single,
        'v2:12345:arm64-v8a:JXU-CampusHub-v0.2.7-arm64-v8a.apk:${'a' * 64}',
      );
      for (final source in ApkDownloadSource.values) {
        expect(keys.single, isNot(endsWith(':${source.name}')));
      }
    });

    test('returns null when canonical asset url is missing or untrusted', () {
      expect(
        ApkUpdateRequest.tryCreate(
          _release(canonicalAssetUrl: null),
          route: ApkDownloadRoute.auto,
        ),
        isNull,
      );
      expect(
        ApkUpdateRequest.tryCreate(
          _release(
            canonicalAssetUrl:
                'https://evil.example.com/FHfanshu/ZJXU-CampusHub/'
                'releases/download/v0.2.7/a.apk',
          ),
          route: ApkDownloadRoute.auto,
        ),
        isNull,
      );
    });

    test('derives file name from url when metadata omitted', () {
      final request = ApkUpdateRequest.tryCreate(
        _release(assetFileName: null),
        route: ApkDownloadRoute.auto,
      )!;
      expect(request.assetFileName, 'JXU-CampusHub-v0.2.7-arm64-v8a.apk');
    });

    group('candidate generation', () {
      List<ApkDownloadSource> sourcesOf(ApkUpdateRequest r) => [
        for (final s in r.sources) s.source,
      ];

      test('auto with R2 marker: r2 then edgeone, mode auto', () {
        final r = ApkUpdateRequest.tryCreate(
          _release(r2: true),
          route: ApkDownloadRoute.auto,
        )!;
        expect(sourcesOf(r), [ApkDownloadSource.r2, ApkDownloadSource.edgeone]);
        expect(r.sources.first.url, _r2Url);
        expect(r.mode, ApkDownloadMode.auto);
        expect(r.unavailablePreferred, isNull);
      });

      test('auto without R2 marker: edgeone only, still mode auto', () {
        final r = ApkUpdateRequest.tryCreate(
          _release(),
          route: ApkDownloadRoute.auto,
        )!;
        expect(sourcesOf(r), [ApkDownloadSource.edgeone]);
        expect(r.mode, ApkDownloadMode.auto);
        expect(r.unavailablePreferred, isNull);
      });

      test('manual r2 with marker: r2 only, mode manual', () {
        final r = ApkUpdateRequest.tryCreate(
          _release(r2: true),
          route: ApkDownloadRoute.r2,
        )!;
        expect(sourcesOf(r), [ApkDownloadSource.r2]);
        expect(r.mode, ApkDownloadMode.manual);
        expect(r.unavailablePreferred, isNull);
      });

      test('manual r2 unavailable: edgeone + unavailablePreferred r2', () {
        final r = ApkUpdateRequest.tryCreate(
          _release(),
          route: ApkDownloadRoute.r2,
        )!;
        expect(sourcesOf(r), [ApkDownloadSource.edgeone]);
        expect(r.mode, ApkDownloadMode.manual);
        expect(r.unavailablePreferred, ApkDownloadSource.r2);
        expect(r.toPlatformMap()['unavailablePreferred'], 'r2');
      });

      test('manual edgeone: edgeone only even when R2 exists', () {
        final r = ApkUpdateRequest.tryCreate(
          _release(r2: true),
          route: ApkDownloadRoute.edgeone,
        )!;
        expect(sourcesOf(r), [ApkDownloadSource.edgeone]);
        expect(r.mode, ApkDownloadMode.manual);
        expect(r.unavailablePreferred, isNull);
        expect(r.toPlatformMap().containsKey('unavailablePreferred'), isFalse);
      });

      test('debug test origin: candidates are exactly [test]', () {
        final r = ApkUpdateRequest.tryCreate(
          _release(r2: true),
          route: ApkDownloadRoute.auto,
          testOrigin: 'http://10.0.2.2:8080',
        )!;
        expect(sourcesOf(r), [ApkDownloadSource.test]);
        expect(
          r.sources.single.url,
          'http://10.0.2.2:8080/v0.2.7/JXU-CampusHub-v0.2.7-arm64-v8a.apk',
        );
      });

      test('invalid test origin yields no request instead of a bad url', () {
        for (final origin in <String>[
          'http://evil.example.com:8080',
          'http://10.0.2.2:80',
          'https://10.0.2.2:8080',
          'http://10.0.2.2:8080/x',
        ]) {
          expect(
            ApkUpdateRequest.tryCreate(
              _release(),
              route: ApkDownloadRoute.auto,
              testOrigin: origin,
            ),
            isNull,
            reason: origin,
          );
        }
      });
    });
  });

  group('test origin gate', () {
    test('requires kDebugMode and a well-formed 10.0.2.2 origin', () {
      String? resolve(String raw, {bool debug = true}) =>
          AppConfig.resolveUpdateTestOrigin(raw, debugMode: debug);
      expect(resolve('http://10.0.2.2:8080'), 'http://10.0.2.2:8080');
      expect(resolve('http://10.0.2.2:8080/'), 'http://10.0.2.2:8080');
      // release / profile（kDebugMode == false）恒为 null。
      expect(resolve('http://10.0.2.2:8080', debug: false), isNull);
      for (final bad in <String>[
        '',
        'http://10.0.2.2',
        'http://10.0.2.2:80',
        'http://10.0.2.2:99999',
        'http://10.0.2.2:08080',
        'http://10.0.2.3:8080',
        'https://10.0.2.2:8080',
        'http://user@10.0.2.2:8080',
        'http://10.0.2.2:8080/path',
        'http://localhost:8080',
      ]) {
        expect(resolve(bad), isNull, reason: bad);
      }
    });

    test('is inert in tests (no define passed)', () {
      expect(AppConfig.updateTestOrigin, isNull);
    });

    test('test urls are never part of the production allow-list', () {
      const url = 'http://10.0.2.2:8080/v0.2.7/a.apk';
      expect(ApkUpdateUrlPolicy.isTestAssetUrl(url), isTrue);
      expect(ApkUpdateUrlPolicy.isTrustedDownloadUrl(url), isFalse);
      expect(
        ApkUpdateUrlPolicy.urlFor(
          ApkDownloadSource.test,
          canonicalUrl: _goodUrl,
          r2Available: true,
        ),
        isNull,
      );
    });

    test('isTestAssetUrl shape checks', () {
      const good = 'http://10.0.2.2:8080/v0.2.7/a.apk';
      expect(ApkUpdateUrlPolicy.isTestAssetUrl(good), isTrue);
      for (final bad in <String>[
        'http://10.0.2.2:8080/a.apk',
        'http://10.0.2.2:8080/v/x/a.apk',
        'http://10.0.2.2:8080/v0.2.7/a.zip',
        'http://10.0.2.2:80/v0.2.7/a.apk',
        'http://10.0.2.2:8080/../a.apk',
        'http://10.0.2.2:8080/v0.2.7/a.apk?x=1',
        'http://10.0.2.2:8080/v0.2.7/a.apk#f',
        'http://10.0.2.2:8080/%2e%2e/a.apk',
        r'http://10.0.2.2:8080/v\2/a.apk',
        'http://10.0.2.2/v0.2.7/a.apk',
        // userinfo 注入；拆开拼接，避免密钥扫描把字面量误判为 Basic Auth。
        ['http://10.0.2.2:8080', '@evil.com/v0.2.7/a.apk'].join(),
        'http://10.0.2.20:8080/v0.2.7/a.apk',
      ]) {
        expect(ApkUpdateUrlPolicy.isTestAssetUrl(bad), isFalse, reason: bad);
      }
    });
  });

  group('ApkUpdateStateCodec', () {
    test('decodes full map and ignores unknown keys', () {
      final state = ApkUpdateStateCodec.fromNative(<String, Object?>{
        'phase': 'downloading',
        'bytesDownloaded': 42,
        'totalBytes': 100,
        'version': '0.2.7',
        'releaseTag': 'v0.2.7',
        'requestKey': 'v2:12345:arm64-v8a:a.apk:nosha',
        'assetFileName': 'a.apk',
        'unexpected': 'ignored',
      });
      expect(state.phase, ApkUpdatePhase.downloading);
      expect(state.bytesDownloaded, 42);
      expect(state.totalBytes, 100);
      expect(state.reason, isNull);
      expect(state.version, '0.2.7');
      expect(state.releaseTag, 'v0.2.7');
      // 线路字段缺省：安全默认值。
      expect(state.source, isNull);
      expect(state.mode, isNull);
      expect(state.attempt, 0);
      expect(state.triedSources, isEmpty);
      expect(state.canSwitch, isFalse);
      expect(state.switchReason, isNull);
      expect(state.fellBackFrom, isNull);
      expect(state.switching, isFalse);
      expect(state.exhausted, isFalse);
      expect(state.retired, isFalse);
    });

    test('decodes every new source / attempt field', () {
      final state = ApkUpdateStateCodec.fromNative(<String, Object?>{
        'phase': 'downloading',
        'source': 'edgeone',
        'mode': 'auto',
        'attempt': 3,
        'triedSources': <Object?>['r2', 'edgeone'],
        'canSwitch': true,
        'switchReason': 'stalled',
        'fellBackFrom': 'r2',
        'switching': false,
        'exhausted': false,
      });
      expect(state.source, ApkDownloadSource.edgeone);
      expect(state.mode, ApkDownloadMode.auto);
      expect(state.attempt, 3);
      expect(state.triedSources, [
        ApkDownloadSource.r2,
        ApkDownloadSource.edgeone,
      ]);
      expect(state.canSwitch, isTrue);
      expect(state.switchReason, ApkFallbackReason.stalled);
      expect(state.fellBackFrom, ApkDownloadSource.r2);
    });

    test('every whitelisted source / switchReason / mode round-trips', () {
      for (final source in ApkDownloadSource.values) {
        final state = ApkUpdateStateCodec.fromNative(<String, Object?>{
          'phase': 'enqueued',
          'source': source.name,
          'fellBackFrom': source.name,
          'triedSources': <Object?>[source.name],
        });
        expect(state.source, source);
        expect(state.fellBackFrom, source);
        expect(state.triedSources, [source]);
      }
      for (final reason in ApkFallbackReason.values) {
        expect(
          ApkUpdateStateCodec.fromNative(<String, Object?>{
            'phase': 'cleanupPending',
            'switchReason': reason.name,
          }).switchReason,
          reason,
        );
      }
      for (final mode in ApkDownloadMode.values) {
        expect(
          ApkUpdateStateCodec.fromNative(<String, Object?>{
            'phase': 'enqueued',
            'mode': mode.name,
          }).mode,
          mode,
        );
      }
    });

    test('decodes cleanupPending / switching / exhausted / retired flags', () {
      final switching = ApkUpdateStateCodec.fromNative(<String, Object?>{
        'phase': 'cleanupPending',
        'switching': true,
        'source': 'r2',
        'switchReason': 'connectTimeout',
      });
      expect(switching.phase, ApkUpdatePhase.cleanupPending);
      expect(switching.switching, isTrue);

      final exhausted = ApkUpdateStateCodec.fromNative(<String, Object?>{
        'phase': 'failed',
        'reason': 'network',
        'exhausted': true,
      });
      expect(exhausted.exhausted, isTrue);

      final canceled = ApkUpdateStateCodec.fromNative(<String, Object?>{
        'phase': 'canceled',
        'retired': true,
      });
      expect(canceled.retired, isTrue);

      expect(
        ApkUpdateStateCodec.fromNative(<String, Object?>{
          'phase': 'reconcileRequired',
        }).phase,
        ApkUpdatePhase.reconcileRequired,
      );
    });

    test('hostile values fail closed and never throw', () {
      final hostile = ApkUpdateStateCodec.fromNative(<String, Object?>{
        'phase': 'downloading',
        'source': 'GITHUB',
        'mode': 'AUTO',
        'attempt': -4,
        'triedSources': 'r2',
        'canSwitch': 'true',
        'switchReason': 'bogus',
        'fellBackFrom': 7,
        'switching': 1,
        'exhausted': 'yes',
        'retired': <Object?>[],
      });
      expect(hostile.phase, ApkUpdatePhase.downloading);
      expect(hostile.source, isNull);
      expect(hostile.mode, isNull);
      expect(hostile.attempt, 0);
      expect(hostile.triedSources, isEmpty);
      expect(hostile.canSwitch, isFalse);
      expect(hostile.switchReason, isNull);
      expect(hostile.fellBackFrom, isNull);
      expect(hostile.switching, isFalse);
      expect(hostile.exhausted, isFalse);
      expect(hostile.retired, isFalse);

      // 类型错位 / 不在白名单 / 带空白的字符串都不被宽容接受。
      final padded = ApkUpdateStateCodec.fromNative(<String, Object?>{
        'phase': 'downloading',
        'source': ' r2 ',
        'attempt': 1.5,
        'switchReason': 'failed ',
      });
      expect(padded.source, isNull);
      expect(padded.attempt, 0);
      expect(padded.switchReason, isNull);
    });

    test(
      'triedSources drops unknown / duplicate / non-string and is capped',
      () {
        final state = ApkUpdateStateCodec.fromNative(<String, Object?>{
          'phase': 'downloading',
          'triedSources': <Object?>[
            'r2',
            'bogus',
            null,
            3,
            'r2',
            'edgeone',
            <Object?>['github'],
          ],
        });
        expect(state.triedSources, [
          ApkDownloadSource.r2,
          ApkDownloadSource.edgeone,
        ]);
        expect(
          () => state.triedSources.add(ApkDownloadSource.github),
          throwsUnsupportedError,
          reason: '解码结果不可变',
        );
      },
    );

    test('malformed / unknown phase fail closed to unavailable', () {
      expect(
        ApkUpdateStateCodec.fromNative('not-a-map').phase,
        ApkUpdatePhase.unavailable,
      );
      expect(
        ApkUpdateStateCodec.fromNative(<String, Object?>{'phase': 'bogus'})
            .phase,
        ApkUpdatePhase.unavailable,
      );
      expect(
        ApkUpdateStateCodec.fromNative(<String, Object?>{}).phase,
        ApkUpdatePhase.unavailable,
      );
    });

    test('unknown reason maps to unknown; reason only on failure phases', () {
      final failed = ApkUpdateStateCodec.fromNative(<String, Object?>{
        'phase': 'failed',
        'reason': 'bogus',
      });
      expect(failed.reason, ApkUpdateFailureReason.unknown);

      final downloading = ApkUpdateStateCodec.fromNative(<String, Object?>{
        'phase': 'downloading',
        'reason': 'network',
      });
      expect(downloading.reason, isNull);
    });

    test('drops invalid byte counts and clamps overflow', () {
      final invalid = ApkUpdateStateCodec.fromNative(<String, Object?>{
        'phase': 'downloading',
        'bytesDownloaded': -1,
        'totalBytes': 0,
      });
      expect(invalid.bytesDownloaded, isNull);
      expect(invalid.totalBytes, isNull);

      final clamped = ApkUpdateStateCodec.fromNative(<String, Object?>{
        'phase': 'downloading',
        'bytesDownloaded': 500,
        'totalBytes': 100,
      });
      expect(clamped.bytesDownloaded, 100);
      expect(clamped.totalBytes, 100);
    });

    test('state equality covers the new fields', () {
      const a = ApkUpdateState(
        phase: ApkUpdatePhase.downloading,
        triedSources: [ApkDownloadSource.r2],
        attempt: 1,
      );
      const same = ApkUpdateState(
        phase: ApkUpdatePhase.downloading,
        triedSources: [ApkDownloadSource.r2],
        attempt: 1,
      );
      expect(a, same);
      expect(a.hashCode, same.hashCode);
      expect(a, isNot(a.copyWith(attempt: 2)));
      expect(a, isNot(a.copyWith(canSwitch: true)));
      expect(
        a,
        isNot(a.copyWith(triedSources: const [ApkDownloadSource.edgeone])),
      );
    });
  });

  group('ApkUpdatePhase.isActive', () {
    test('reconcileRequired and cleanupPending are active', () {
      expect(ApkUpdatePhase.reconcileRequired.isActive, isTrue);
      expect(ApkUpdatePhase.cleanupPending.isActive, isTrue);
    });

    test('exactly the in-flight phases are active', () {
      const active = <ApkUpdatePhase>{
        ApkUpdatePhase.enqueued,
        ApkUpdatePhase.downloading,
        ApkUpdatePhase.paused,
        ApkUpdatePhase.verifying,
        ApkUpdatePhase.readyToInstall,
        ApkUpdatePhase.permissionRequired,
        ApkUpdatePhase.installerOpened,
        ApkUpdatePhase.reconcileRequired,
        ApkUpdatePhase.cleanupPending,
      };
      for (final phase in ApkUpdatePhase.values) {
        expect(phase.isActive, active.contains(phase), reason: phase.name);
      }
    });

    test('new phases decode from their wire names', () {
      expect(
        ApkUpdatePhase.fromWire('reconcileRequired'),
        ApkUpdatePhase.reconcileRequired,
      );
      expect(
        ApkUpdatePhase.fromWire('cleanupPending'),
        ApkUpdatePhase.cleanupPending,
      );
    });
  });

  group('ApkUpdateController', () {
    late _FakeApkUpdateTransport transport;
    late ApkUpdateController controller;

    setUp(() {
      transport = _FakeApkUpdateTransport();
      controller = ApkUpdateController(
        transport: transport,
        deviceAbiProvider: () => 'arm64-v8a',
        platformProvider: () => TargetPlatform.android,
      );
    });

    test('startDownload projects native state', () async {
      await controller.startDownload(_release(), route: ApkDownloadRoute.auto);
      expect(transport.startCalls, 1);
      expect(controller.state.value.phase, ApkUpdatePhase.downloading);
      expect(controller.state.value.bytesDownloaded, 10);
      expect(
        transport.lastRequest!.sources.single.url,
        'https://edgeone.gh-proxy.org/$_goodUrl',
      );
    });

    test('startDownload sends the ordered candidates from the route', () async {
      await controller.startDownload(
        _release(r2: true),
        route: ApkDownloadRoute.auto,
      );
      expect(
        [for (final s in transport.lastRequest!.sources) s.source],
        [ApkDownloadSource.r2, ApkDownloadSource.edgeone],
      );
      expect(transport.lastRequest!.mode, ApkDownloadMode.auto);
    });

    test('untrusted asset url degrades without touching the channel', () async {
      await controller.startDownload(
        _release(canonicalAssetUrl: null),
        route: ApkDownloadRoute.auto,
      );
      expect(transport.startCalls, 0);
      expect(controller.state.value.phase, ApkUpdatePhase.unavailable);
      expect(
        controller.state.value.reason,
        ApkUpdateFailureReason.untrustedAsset,
      );
    });

    test(
      'empty candidate list degrades without touching the channel',
      () async {
        // 构造「没有任何可用候选」：规范资产 URL 不是可信形态。
        await controller.startDownload(
          _release(
            canonicalAssetUrl:
                'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/'
                'v0.2.7/extra/a.apk',
          ),
          route: ApkDownloadRoute.edgeone,
        );
        expect(transport.startCalls, 0);
        expect(controller.state.value.phase, ApkUpdatePhase.unavailable);
        expect(
          controller.state.value.reason,
          ApkUpdateFailureReason.untrustedAsset,
        );
      },
    );

    test('duplicate active request is idempotent', () async {
      final key = ApkUpdateRequest.tryCreate(
        _release(),
        abi: 'arm64-v8a',
        route: ApkDownloadRoute.auto,
      )!.requestKey;
      transport.startResult = ApkUpdateState(
        phase: ApkUpdatePhase.downloading,
        requestKey: key,
      );

      await controller.startDownload(_release(), route: ApkDownloadRoute.auto);
      await controller.startDownload(_release(), route: ApkDownloadRoute.auto);
      expect(transport.startCalls, 1);
    });

    test('concurrent start while in flight is bounded', () async {
      transport.startGate = Completer<void>();
      final first = controller.startDownload(
        _release(),
        route: ApkDownloadRoute.auto,
      );
      await controller.startDownload(
        _release(),
        route: ApkDownloadRoute.auto,
      ); // ignored
      expect(transport.startCalls, 1);
      transport.startGate!.complete();
      await first;
    });

    test('refresh projects idle when native has no active request', () async {
      await controller.refreshActiveUpdate();
      expect(controller.state.value.phase, ApkUpdatePhase.idle);
    });

    test('a channel-level query failure keeps an active download, a native failure does not', () async {
      transport.queryResult = const ApkUpdateState(
        phase: ApkUpdatePhase.downloading,
        requestKey: 'k',
        releaseTag: 'v1.2.3',
        bytesDownloaded: 10,
      );
      await controller.refreshActiveUpdate();
      // transport 合成的失败（无 requestKey）= 通道抖动，不是下载失败。
      transport.queryResult = const ApkUpdateState(
        phase: ApkUpdatePhase.failed,
        reason: ApkUpdateFailureReason.nativeError,
      );
      await controller.refreshActiveUpdate();
      expect(controller.state.value.phase, ApkUpdatePhase.downloading);
      // 原生给出的失败带 requestKey，照常应用。
      transport.queryResult = const ApkUpdateState(
        phase: ApkUpdatePhase.failed,
        reason: ApkUpdateFailureReason.network,
        requestKey: 'k',
        releaseTag: 'v1.2.3',
      );
      await controller.refreshActiveUpdate();
      expect(controller.state.value.phase, ApkUpdatePhase.failed);
    });

    group('native is the only authority on record validity', () {
      // 回归：旧版 `_isSuperseded` 会在 Dart 里比较已安装版本并 cancel 原生请求。
      // 现在版本是否已被安装只由原生判定，控制器只查询并原样应用。
      for (final phase in <ApkUpdatePhase>[
        ApkUpdatePhase.readyToInstall,
        ApkUpdatePhase.failed,
        ApkUpdatePhase.reconcileRequired,
        ApkUpdatePhase.cleanupPending,
      ]) {
        test('refresh applies ${phase.name} as-is and never cancels', () async {
          transport.queryResult = ApkUpdateState(
            phase: phase,
            reason: phase == ApkUpdatePhase.failed
                ? ApkUpdateFailureReason.versionNotNewer
                : null,
            // 一个肯定不新于任何已安装版本的旧版本号。
            version: '0.0.1',
            releaseTag: 'v0.0.1',
          );
          await controller.refreshActiveUpdate();
          expect(transport.cancelCalls, 0);
          expect(controller.state.value.phase, phase);
          expect(controller.state.value.version, '0.0.1');
        });
      }
    });

    test('late query result is discarded by epoch', () async {
      final gate = Completer<void>();
      transport.queryHandler = () async {
        await gate.future;
        return const ApkUpdateState(phase: ApkUpdatePhase.downloading);
      };
      final late = controller.refreshActiveUpdate();

      transport.queryHandler = () async =>
          const ApkUpdateState(phase: ApkUpdatePhase.readyToInstall);
      await controller.refreshActiveUpdate();
      expect(controller.state.value.phase, ApkUpdatePhase.readyToInstall);

      gate.complete();
      await late;
      expect(controller.state.value.phase, ApkUpdatePhase.readyToInstall);
    });

    test('cancel projects native canceled result', () async {
      transport.cancelResult = const ApkUpdateState(
        phase: ApkUpdatePhase.canceled,
        retired: true,
      );
      await controller.cancelActiveUpdate();
      expect(transport.cancelCalls, 1);
      expect(controller.state.value.phase, ApkUpdatePhase.canceled);
      expect(controller.state.value.retired, isTrue);
    });

    test(
      'cancel with unconfirmed retire stays active (cleanupPending)',
      () async {
        transport.cancelResult = const ApkUpdateState(
          phase: ApkUpdatePhase.cleanupPending,
          retired: false,
          releaseTag: 'v0.2.7',
        );
        await controller.cancelActiveUpdate();
        expect(controller.state.value.phase, ApkUpdatePhase.cleanupPending);
        expect(controller.state.value.phase.isActive, isTrue);
        expect(controller.state.value.retired, isFalse);
      },
    );

    group('switchSource', () {
      test('forwards the reason and applies the native result', () async {
        transport.switchResult = const ApkUpdateState(
          phase: ApkUpdatePhase.cleanupPending,
          switching: true,
          attempt: 1,
        );
        await controller.switchSource(ApkFallbackReason.stalled);
        expect(transport.switchCalls, 1);
        expect(transport.lastSwitchReason, ApkFallbackReason.stalled);
        expect(controller.state.value.phase, ApkUpdatePhase.cleanupPending);
        expect(controller.state.value.switching, isTrue);
      });

      test('null native result leaves the state untouched', () async {
        transport.queryResult = const ApkUpdateState(
          phase: ApkUpdatePhase.downloading,
          attempt: 1,
        );
        await controller.refreshActiveUpdate();
        transport.switchResult = null;
        await controller.switchSource(ApkFallbackReason.slow);
        expect(controller.state.value.phase, ApkUpdatePhase.downloading);
        expect(controller.state.value.attempt, 1);
      });

      test('the native-only failed reason is never sent', () async {
        await controller.switchSource(ApkFallbackReason.failed);
        expect(transport.switchCalls, 0);
      });
    });

    test('requestInstall success marks installerOpened', () async {
      await controller.startDownload(_release(), route: ApkDownloadRoute.auto);
      expect(await controller.requestInstall(), isTrue);
      expect(controller.state.value.phase, ApkUpdatePhase.installerOpened);
    });

    test(
      'requestInstall failure keeps native permissionRequired state',
      () async {
        await controller.startDownload(
          _release(),
          route: ApkDownloadRoute.auto,
        );
        transport.installOk = false;
        transport.queryResult = const ApkUpdateState(
          phase: ApkUpdatePhase.permissionRequired,
          reason: ApkUpdateFailureReason.permissionDenied,
        );

        expect(await controller.requestInstall(), isFalse);
        expect(transport.queryCalls, 1);
        expect(controller.state.value.phase, ApkUpdatePhase.permissionRequired);
        expect(
          controller.state.value.reason,
          ApkUpdateFailureReason.permissionDenied,
        );
      },
    );

    test(
      'requestInstall failure with no native record keeps prior state',
      () async {
        await controller.startDownload(
          _release(),
          route: ApkDownloadRoute.auto,
        );
        transport.installOk = false;
        transport.queryResult = null;

        expect(await controller.requestInstall(), isFalse);
        expect(controller.state.value.phase, ApkUpdatePhase.downloading);
      },
    );

    test(
      'openInstallPermissionSettings delegates without phase change',
      () async {
        await controller.startDownload(
          _release(),
          route: ApkDownloadRoute.auto,
        );
        final before = controller.state.value.phase;
        expect(await controller.openInstallPermissionSettings(), isTrue);
        expect(transport.permissionCalls, 1);
        expect(controller.state.value.phase, before);
      },
    );

    test(
      'isSupported is false off Android without touching the channel',
      () async {
        final nonAndroid = ApkUpdateController(
          transport: transport,
          deviceAbiProvider: () => 'arm64-v8a',
          platformProvider: () => TargetPlatform.windows,
        );
        expect(await nonAndroid.isSupported(), isFalse);
        expect(transport.supportedCalls, 0);
      },
    );

    test('isSupported delegates on Android', () async {
      expect(await controller.isSupported(), isTrue);
      expect(transport.supportedCalls, 1);
    });
  });

  group('ApkUpdateController foreground polling', () {
    late _FakeApkUpdateTransport transport;
    late bool foreground;

    ApkUpdateController pollingController() {
      return ApkUpdateController(
        transport: transport,
        deviceAbiProvider: () => 'arm64-v8a',
        platformProvider: () => TargetPlatform.android,
        enableLifecyclePolling: true,
        foregroundProvider: () => foreground,
      );
    }

    ApkUpdateState downloading() => const ApkUpdateState(
      phase: ApkUpdatePhase.downloading,
      bytesDownloaded: 10,
      totalBytes: 100,
      requestKey: 'k',
      releaseTag: 'v0.2.7',
    );

    setUp(() {
      transport = _FakeApkUpdateTransport();
      foreground = true;
    });

    /// 模拟原生已有活动下载并完成一次控制器查询：状态应用后轮询启动。
    void adoptDownloading(
      ApkUpdateController controller,
      FakeAsync async,
    ) {
      transport.queryResult = downloading();
      unawaited(controller.refreshActiveUpdate());
      async.flushMicrotasks();
      expect(controller.state.value.phase, ApkUpdatePhase.downloading);
    }

    test('前台且活动阶段时按 ~1s 轮询原生状态并驱动停滞观察', () async {
      fakeAsync((async) {
        final controller = pollingController();
        adoptDownloading(controller, async);

        final before = transport.queryCalls;
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(
          transport.queryCalls,
          greaterThan(before),
          reason: '活动阶段前台应每秒查询一次原生状态',
        );
        final afterFirst = transport.queryCalls;
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(transport.queryCalls, greaterThan(afterFirst + 1));

        controller.debugReset();
        async.flushMicrotasks();
      });
    });

    test('非活动阶段或后台立即停表，不再查询', () async {
      fakeAsync((async) {
        final controller = pollingController();
        // 非活动阶段（idle）：根本不起表。
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();
        expect(transport.queryCalls, 0);

        // 活动阶段起表后退到后台：立即停止查询。
        adoptDownloading(controller, async);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        final inForeground = transport.queryCalls;
        expect(inForeground, greaterThan(0));

        foreground = false;
        controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();
        expect(transport.queryCalls, inForeground, reason: '退到后台应立即停表，不空转');

        // 回前台立即查询一次，且轮询恢复。
        foreground = true;
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        async.flushMicrotasks();
        expect(
          transport.queryCalls,
          greaterThan(inForeground),
          reason: '回前台应立即查询一次原生状态',
        );
        final afterResume = transport.queryCalls;
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(transport.queryCalls, greaterThan(afterResume));

        controller.debugReset();
        async.flushMicrotasks();
      });
    });

    test('状态转入终态即停表；debugReset 不遗留定时器', () async {
      fakeAsync((async) {
        final controller = pollingController();
        adoptDownloading(controller, async);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        final activeCalls = transport.queryCalls;
        expect(activeCalls, greaterThan(0));

        // 终态（已取消）：下一次应用状态即停表。
        transport.queryResult = const ApkUpdateState(
          phase: ApkUpdatePhase.canceled,
          retired: true,
          requestKey: 'k',
        );
        unawaited(controller.refreshActiveUpdate());
        async.flushMicrotasks();
        expect(controller.state.value.phase, ApkUpdatePhase.canceled);
        final atTerminal = transport.queryCalls;
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();
        expect(transport.queryCalls, atTerminal, reason: '终态不应继续轮询');

        controller.debugReset();
        async.flushMicrotasks();
      });
    });

    test('未启用轮询的实例（默认）永不创建定时器', () async {
      fakeAsync((async) {
        final controller = ApkUpdateController(
          transport: transport,
          deviceAbiProvider: () => 'arm64-v8a',
          platformProvider: () => TargetPlatform.android,
        );
        transport.queryResult = downloading();
        controller.state.value = downloading();
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(transport.queryCalls, 0, reason: '测试构造的独立实例默认不做生命周期轮询');
        controller.debugReset();
      });
    });
  });

  group('MethodChannelApkUpdateTransport', () {
    const channel = MethodChannel(ApkUpdateProtocol.channelName);
    late MethodChannelApkUpdateTransport transport;

    ApkUpdateRequest request() => ApkUpdateRequest.tryCreate(
      _release(r2: true),
      abi: 'arm64-v8a',
      route: ApkDownloadRoute.auto,
    )!;

    setUp(() {
      transport = MethodChannelApkUpdateTransport(channel: channel);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('installation forwards the displayed release tag to native', () async {
      MethodCall? seen;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            seen = call;
            return true;
          });
      expect(
        await transport.requestInstall(expectedReleaseTag: 'v0.2.7'),
        isTrue,
      );
      expect(seen!.method, ApkUpdateProtocol.methodRequestInstall);
      expect(seen!.arguments, <String, Object?>{
        'expectedReleaseTag': 'v0.2.7',
      });
    });

    test('missing plugin degrades to unavailable / false / null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      expect(await transport.isSupported(), isFalse);
      expect(
        (await transport.startDownload(request())).phase,
        ApkUpdatePhase.unavailable,
      );
      expect(await transport.queryActiveUpdate(), isNull);
      expect(
        await transport.switchSource(ApkFallbackReason.slow, attempt: 1),
        isNull,
      );
      expect(await transport.requestInstall(), isFalse);
      expect(await transport.openInstallPermissionSettings(), isFalse);
    });

    test('platform exception degrades to failed / false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'boom');
          });

      expect(await transport.isSupported(), isFalse);
      final state = await transport.startDownload(request());
      expect(state.phase, ApkUpdatePhase.failed);
      expect(state.reason, ApkUpdateFailureReason.nativeError);
      expect(
        await transport.switchSource(ApkFallbackReason.slow, attempt: 1),
        isNull,
      );
      expect(await transport.requestInstall(), isFalse);
    });

    test('decodes native state map and forwards the v2 start args', () async {
      MethodCall? seen;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            seen = call;
            if (call.method == ApkUpdateProtocol.methodStartDownload) {
              return <String, Object?>{
                'phase': 'downloading',
                'bytesDownloaded': 7,
                'totalBytes': 70,
                'source': 'r2',
                'attempt': 1,
                'canSwitch': true,
              };
            }
            if (call.method == ApkUpdateProtocol.methodIsSupported) return true;
            return null;
          });

      final state = await transport.startDownload(request());

      expect(state.phase, ApkUpdatePhase.downloading);
      expect(state.bytesDownloaded, 7);
      expect(state.source, ApkDownloadSource.r2);
      expect(state.canSwitch, isTrue);
      expect(seen!.method, ApkUpdateProtocol.methodStartDownload);
      final args = seen!.arguments as Map<Object?, Object?>;
      expect(args.keys, isNot(contains('account')));
      expect(args.keys, isNot(contains('url')));
      expect(args['mode'], 'auto');
      expect(args['releaseTag'], 'v0.2.7');
      expect(args['requestKey'], request().requestKey);
      expect(args['sources'], <Map<String, Object?>>[
        <String, Object?>{'source': 'r2', 'url': _r2Url},
        <String, Object?>{
          'source': 'edgeone',
          'url': 'https://edgeone.gh-proxy.org/$_goodUrl',
        },
      ]);
      expect(await transport.isSupported(), isTrue);
    });

    test('switchSource sends only the whitelisted reason', () async {
      MethodCall? seen;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            seen = call;
            return <String, Object?>{
              'phase': 'cleanupPending',
              'switching': true,
            };
          });
      final state = await transport.switchSource(
        ApkFallbackReason.connectTimeout,
        attempt: 3,
      );
      expect(seen!.method, ApkUpdateProtocol.methodSwitchSource);
      expect(seen!.arguments, <String, Object?>{
        'reason': 'connectTimeout',
        'attempt': 3,
      });
      expect(state!.phase, ApkUpdatePhase.cleanupPending);
      expect(state.switching, isTrue);
    });

    test('switchSource returns null when native has no task', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
      expect(
        await transport.switchSource(ApkFallbackReason.paused, attempt: 1),
        isNull,
      );
    });
  });
}
