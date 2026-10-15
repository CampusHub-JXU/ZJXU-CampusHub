import 'package:flutter/foundation.dart';
import 'package:jxu_campus_hub/core/update/apk_update_controller.dart';
import 'package:jxu_campus_hub/core/update/update_model.dart';

/// 受管更新通道（`edu.zjxu.jxucampushub/app_update`）的测试替身：不触真实
/// MethodChannel，记录调用次数并返回可编排的状态。
class FakeApkUpdateTransport implements ApkUpdateTransport {
  FakeApkUpdateTransport({
    this.supported = true,
    ApkUpdateState? active,
    ApkUpdateState? startResult,
  }) : _active = active ?? const ApkUpdateState.idle(),
       _startResult = startResult ?? const ApkUpdateState.idle();

  /// `isSupported` 的返回值。
  bool supported;

  /// `requestInstall` / `openInstallPermissionSettings` 的返回值。
  bool installResult = true;
  bool permissionSettingsResult = true;

  ApkUpdateState _active;
  ApkUpdateState _startResult;

  int startCalls = 0;
  int queryCalls = 0;
  int cancelCalls = 0;
  int installCalls = 0;
  int permissionSettingsCalls = 0;

  ApkUpdateRequest? lastRequest;
  String? lastExpectedReleaseTag;

  /// `requestInstall` 期间的副作用钩子：用来模拟「原生返回 false 的同时把受管
  /// 状态推进为 permissionRequired / failed」这类真实并发顺序。
  void Function()? onInstall;

  /// 主动推进原生「当前受管状态」（模拟下载在后台推进）。
  set active(ApkUpdateState value) => _active = value;

  /// 下一次 `startDownload` 返回的状态。
  set startResult(ApkUpdateState value) => _startResult = value;

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<ApkUpdateState> startDownload(ApkUpdateRequest request) async {
    startCalls++;
    lastRequest = request;
    _active = _startResult;
    return _startResult;
  }

  @override
  Future<ApkUpdateState?> queryActiveUpdate() async {
    queryCalls++;
    return _active;
  }

  @override
  Future<ApkUpdateState> cancelActiveUpdate() async {
    cancelCalls++;
    _active = const ApkUpdateState(phase: ApkUpdatePhase.canceled);
    return _active;
  }

  @override
  Future<bool> requestInstall({String? expectedReleaseTag}) async {
    installCalls++;
    lastExpectedReleaseTag = expectedReleaseTag;
    onInstall?.call();
    return installResult;
  }

  @override
  Future<bool> openInstallPermissionSettings() async {
    permissionSettingsCalls++;
    return permissionSettingsResult;
  }
}

/// 用注入的替身构造控制器：固定为 Android + arm64-v8a，避免测试依赖宿主
/// 平台探测。
/// [installedVersion] 默认取一个低于所有测试 Release 的版本，避免受管更新被
/// 视为「已安装、过期」而自动取消。
ApkUpdateController fakeApkUpdateController(
  FakeApkUpdateTransport transport, {
  String? installedVersion = '0.0.1',
}) {
  return ApkUpdateController(
    transport: transport,
    deviceAbiProvider: () => 'arm64-v8a',
    platformProvider: () => TargetPlatform.android,
    installedVersionProvider: () async => installedVersion,
  );
}

/// 公开分发仓库的规范资产 URL 样例。
const String kTestCanonicalAssetUrl =
    'https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/'
    'v0.3.0/JXU-CampusHub-v0.3.0-arm64-v8a.apk';

/// 构造一条 release；[canonicalAssetUrl] 传 null 表示版本未提供可信安装包
/// 资产（应降级为外部浏览器路径）。
AppRelease managedTestRelease({
  String version = '0.3.0',
  String changelog = '· 修复若干问题',
  String downloadUrl = 'https://example.com/app.apk',
  String? canonicalAssetUrl = kTestCanonicalAssetUrl,
}) {
  return AppRelease(
    version: version,
    changelog: changelog,
    downloadUrl: downloadUrl,
    releaseUrl: 'https://example.com/release',
    publishedAt: DateTime(2026, 4, 11, 9, 30),
    canonicalAssetUrl: canonicalAssetUrl,
    assetId: 42,
    assetFileName: 'JXU-CampusHub-v0.3.0-arm64-v8a.apk',
    assetSizeBytes: 45 * 1024 * 1024,
    assetSha256: 'a' * 64,
  );
}
