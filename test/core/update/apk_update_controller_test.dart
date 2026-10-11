import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/logging/app_logger.dart';
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
  int installCalls = 0;
  int permissionCalls = 0;
  ApkUpdateRequest? lastRequest;

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
  Future<bool> requestInstall() async {
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

AppRelease _release({
  String version = '0.2.7',
  String? canonicalAssetUrl = _goodUrl,
  String? assetFileName = 'JXU-CampusHub-v0.2.7-arm64-v8a.apk',
  int? assetId = 12345,
  int? assetSizeBytes = 52428800,
  String? assetSha256 =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
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
  });

  group('ApkUpdateRequest', () {
    test('builds a whitelisted platform map and stable request key', () {
      final request = ApkUpdateRequest.tryCreate(_release(), abi: 'arm64-v8a')!;

      expect(request.assetUrl, _goodUrl);
      expect(request.assetFileName, 'JXU-CampusHub-v0.2.7-arm64-v8a.apk');
      expect(request.sha256, hasLength(64));

      final map = request.toPlatformMap();
      expect(map.keys, containsAll(<String>['version', 'url', 'fileName']));
      expect(map.keys, isNot(contains('account')));
      expect(map['requestKey'], request.requestKey);

      // 稳定：同输入重复构造 key 相同；不含账号身份。
      final again = ApkUpdateRequest.tryCreate(_release(), abi: 'arm64-v8a')!;
      expect(again.requestKey, request.requestKey);
      expect(request.requestKey, isNot(contains('account')));
    });

    test('returns null when canonical asset url is missing or untrusted', () {
      expect(
        ApkUpdateRequest.tryCreate(_release(canonicalAssetUrl: null)),
        isNull,
      );
      expect(
        ApkUpdateRequest.tryCreate(
          _release(
            canonicalAssetUrl:
                'https://evil.example.com/FHfanshu/ZJXU-CampusHub/'
                'releases/download/v0.2.7/a.apk',
          ),
        ),
        isNull,
      );
    });

    test('derives file name from url when metadata omitted', () {
      final request = ApkUpdateRequest.tryCreate(
        _release(assetFileName: null),
      )!;
      expect(request.assetFileName, 'JXU-CampusHub-v0.2.7-arm64-v8a.apk');
    });
  });

  group('ApkUpdateStateCodec', () {
    test('decodes full map and ignores unknown keys', () {
      final state = ApkUpdateStateCodec.fromNative(<String, Object?>{
        'phase': 'downloading',
        'bytesDownloaded': 42,
        'totalBytes': 100,
        'version': '0.2.7',
        'requestKey': 'v1:12345:arm64-v8a:a.apk:nosha',
        'assetFileName': 'a.apk',
        'unexpected': 'ignored',
      });
      expect(state.phase, ApkUpdatePhase.downloading);
      expect(state.bytesDownloaded, 42);
      expect(state.totalBytes, 100);
      expect(state.reason, isNull);
      expect(state.version, '0.2.7');
    });

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
      await controller.startDownload(_release());
      expect(transport.startCalls, 1);
      expect(controller.state.value.phase, ApkUpdatePhase.downloading);
      expect(controller.state.value.bytesDownloaded, 10);
      expect(transport.lastRequest!.assetUrl, _goodUrl);
    });

    test('untrusted asset url degrades without touching the channel', () async {
      await controller.startDownload(_release(canonicalAssetUrl: null));
      expect(transport.startCalls, 0);
      expect(controller.state.value.phase, ApkUpdatePhase.unavailable);
      expect(
        controller.state.value.reason,
        ApkUpdateFailureReason.untrustedAsset,
      );
    });

    test('duplicate active request is idempotent', () async {
      final key = ApkUpdateRequest.tryCreate(
        _release(),
        abi: 'arm64-v8a',
      )!.requestKey;
      transport.startResult = ApkUpdateState(
        phase: ApkUpdatePhase.downloading,
        requestKey: key,
      );

      await controller.startDownload(_release());
      await controller.startDownload(_release());
      expect(transport.startCalls, 1);
    });

    test('concurrent start while in flight is bounded', () async {
      transport.startGate = Completer<void>();
      final first = controller.startDownload(_release());
      await controller.startDownload(_release()); // ignored
      expect(transport.startCalls, 1);
      transport.startGate!.complete();
      await first;
    });

    test('refresh projects idle when native has no active request', () async {
      await controller.refreshActiveUpdate();
      expect(controller.state.value.phase, ApkUpdatePhase.idle);
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

    test('cancel projects canceled', () async {
      await controller.cancelActiveUpdate();
      expect(transport.cancelCalls, 1);
      expect(controller.state.value.phase, ApkUpdatePhase.canceled);
    });

    test('requestInstall success marks installerOpened', () async {
      await controller.startDownload(_release());
      expect(await controller.requestInstall(), isTrue);
      expect(controller.state.value.phase, ApkUpdatePhase.installerOpened);
    });

    test(
      'requestInstall failure keeps native permissionRequired state',
      () async {
        await controller.startDownload(_release());
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
        await controller.startDownload(_release());
        transport.installOk = false;
        transport.queryResult = null;

        expect(await controller.requestInstall(), isFalse);
        expect(controller.state.value.phase, ApkUpdatePhase.downloading);
      },
    );

    test(
      'openInstallPermissionSettings delegates without phase change',
      () async {
        await controller.startDownload(_release());
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

  group('MethodChannelApkUpdateTransport', () {
    const channel = MethodChannel(ApkUpdateProtocol.channelName);
    late MethodChannelApkUpdateTransport transport;

    setUp(() {
      transport = MethodChannelApkUpdateTransport(channel: channel);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('missing plugin degrades to unavailable / false / null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      expect(await transport.isSupported(), isFalse);
      expect(
        (await transport.startDownload(
          ApkUpdateRequest.tryCreate(_release(), abi: 'arm64-v8a')!,
        )).phase,
        ApkUpdatePhase.unavailable,
      );
      expect(await transport.queryActiveUpdate(), isNull);
      expect(await transport.requestInstall(), isFalse);
      expect(await transport.openInstallPermissionSettings(), isFalse);
    });

    test('platform exception degrades to failed / false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'boom');
          });

      expect(await transport.isSupported(), isFalse);
      final state = await transport.startDownload(
        ApkUpdateRequest.tryCreate(_release(), abi: 'arm64-v8a')!,
      );
      expect(state.phase, ApkUpdatePhase.failed);
      expect(state.reason, ApkUpdateFailureReason.nativeError);
      expect(await transport.requestInstall(), isFalse);
    });

    test('decodes native state map and forwards whitelisted args', () async {
      MethodCall? seen;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            seen = call;
            if (call.method == ApkUpdateProtocol.methodStartDownload) {
              return <String, Object?>{
                'phase': 'downloading',
                'bytesDownloaded': 7,
                'totalBytes': 70,
              };
            }
            if (call.method == ApkUpdateProtocol.methodIsSupported) return true;
            return null;
          });

      final request = ApkUpdateRequest.tryCreate(_release(), abi: 'arm64-v8a')!;
      final state = await transport.startDownload(request);

      expect(state.phase, ApkUpdatePhase.downloading);
      expect(state.bytesDownloaded, 7);
      expect(seen!.method, ApkUpdateProtocol.methodStartDownload);
      final args = seen!.arguments as Map<Object?, Object?>;
      expect(args['url'], _goodUrl);
      expect(args.keys, isNot(contains('account')));
      expect(await transport.isSupported(), isTrue);
    });
  });
}
