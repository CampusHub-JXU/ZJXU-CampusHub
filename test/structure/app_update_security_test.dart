import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 应用内一键更新（Issue #42）的**结构性**安全断言。
///
/// 这些断言只读取 manifest / XML / Kotlin / Dart 源码文本，用来锁死关键安全
/// 契约不被回退（签名权限接收器 / 非导出安装页、窄 FileProvider 路径、规范资产 URL 校验、包名 /
/// 签名 / 版本校验、无 Cookie 注入、requestInstall 不再假失败）。
///
/// **它们不是原生运行时行为的证明**：真正的安装安全需要设备端到端验收。
void main() {
  const manifestPath = 'android/app/src/main/AndroidManifest.xml';
  const pathsPath = 'android/app/src/main/res/xml/update_file_paths.xml';
  const updateDir =
      'android/app/src/main/kotlin/edu/zjxu/jxucampushub/platform/update';
  const controllerPath = 'lib/core/update/apk_update_controller.dart';

  String read(String path) {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: 'Missing $path');
    return file.readAsStringSync();
  }

  group('manifest declarations', () {
    test('declares REQUEST_INSTALL_PACKAGES without silent-install APIs', () {
      final manifest = read(manifestPath);
      expect(
        manifest,
        contains('android.permission.REQUEST_INSTALL_PACKAGES'),
        reason: 'Launching the system installer needs this permission.',
      );
      // 绝不静默安装：不出现 PackageInstaller 会话写入 / 无障碍自动点击。
      expect(manifest, isNot(contains('INSTALL_PACKAGES_SILENT')));
    });

    test('FileProvider is non-exported, grant-only, narrow authority', () {
      final manifest = read(manifestPath);
      expect(manifest, contains('androidx.core.content.FileProvider'));
      expect(
        manifest,
        contains(r'android:authorities="${applicationId}.app_update_files"'),
      );
      expect(manifest, contains('android.support.FILE_PROVIDER_PATHS'));
      expect(manifest, contains('@xml/update_file_paths'));

      final providerTag = _tag(
        manifest,
        'provider',
        containing: 'androidx.core.content.FileProvider',
      );
      expect(providerTag, isNotNull, reason: 'FileProvider not declared');
      expect(providerTag, contains('android:exported="false"'));
      expect(providerTag, contains('android:grantUriPermissions="true"'));
    });

    test('download receiver requires signature permission and install activity is private', () {
      final manifest = read(manifestPath);
      expect(manifest, contains('.platform.update.AppUpdateDownloadReceiver'));
      expect(manifest, contains('android.intent.action.DOWNLOAD_COMPLETE'));

      final receiverTag = _tag(
        manifest,
        'receiver',
        containing: '.platform.update.AppUpdateDownloadReceiver',
      );
      expect(receiverTag, isNotNull, reason: 'download receiver not declared');
      expect(receiverTag, contains('android:exported="true"'));
      expect(
        receiverTag,
        contains(
          'android:permission="android.permission.SEND_DOWNLOAD_COMPLETED_INTENTS"',
        ),
      );

      final activityTag = _tag(
        manifest,
        'activity',
        containing: '.platform.update.AppUpdateInstallActivity',
      );
      expect(activityTag, isNotNull, reason: 'install activity not declared');
      expect(activityTag, contains('android:exported="false"'));
    });

    test('FileProvider paths stay inside the app-private updates dir', () {
      final paths = read(pathsPath);
      expect(paths, contains('<external-files-path'));
      // 单数 Download：`Environment.DIRECTORY_DOWNLOADS`（受管 APK 实际所在目录）。
      // 这里曾断言 `Downloads/updates/`，与原生下载目录不一致，等于把 v0.11.1 的
      // 「应用内安装 100% 静默失败」写进了基线；单数/复数漂移由
      // `update_file_provider_paths_test.dart` 继续锁死。
      expect(paths, contains('path="Download/updates/"'));
      // 绝不放行根路径 / 公共目录（注释里也不出现这些字面量）。
      expect(paths, isNot(contains('<root-path')));
      expect(paths, isNot(contains('path="."')));
      expect(paths, isNot(contains('<external-path')));
      expect(paths, isNot(contains('external-public-path')));
    });
  });

  group('native contract', () {
    test(
      'manager is initialized before FlutterActivity creates its engine',
      () {
        final activity = read(
          'android/app/src/main/kotlin/edu/zjxu/jxucampushub/MainActivity.kt',
        );
        final onCreate = activity.substring(
          activity.indexOf('override fun onCreate('),
          activity.indexOf('override fun configureFlutterEngine('),
        );
        final initialized = onCreate.indexOf(
          'appUpdateManager = AppUpdateManager.get(applicationContext)',
        );
        final superCall = onCreate.indexOf(
          'super.onCreate(savedInstanceState)',
        );
        expect(initialized, greaterThanOrEqualTo(0));
        expect(initialized, lessThan(superCall));
      },
    );

    test('channel + method names match the frozen Dart protocol', () {
      final contract = read('$updateDir/AppUpdateContract.kt');
      final controller = read(controllerPath);

      expect(contract, contains('edu.zjxu.jxucampushub/app_update'));
      expect(controller, contains("'edu.zjxu.jxucampushub/app_update'"));

      for (final method in <String>[
        'isSupported',
        'startDownload',
        'queryActiveUpdate',
        'cancelActiveUpdate',
        'requestInstall',
        'openInstallPermissionSettings',
      ]) {
        expect(contract, contains(method), reason: 'missing method $method');
        expect(controller, contains(method), reason: 'Dart missing $method');
      }
    });

    test('only the trusted public distribution repo is accepted', () {
      final contract = read('$updateDir/AppUpdateContract.kt');
      expect(contract, contains('"github.com"'));
      expect(contract, contains('"FHfanshu"'));
      expect(contract, contains('"ZJXU-CampusHub"'));
      expect(contract, contains('"releases"'));
      expect(contract, contains('"download"'));
      expect(contract, contains('"https"'));
      // 拒绝 userinfo / 端口 / query / fragment / 路径穿越。
      expect(contract, contains('userInfo'));
      expect(contract, contains('fragment'));
      expect(contract, contains('query'));
      expect(contract, contains('".."'));
    });

    test(
      'managed download injects no credentials and uses app-private dir',
      () {
        final manager = read('$updateDir/AppUpdateManager.kt');
        // 绝不给下载请求注入 Cookie / 认证头（注释提及不算）。
        expect(manager, isNot(contains('addRequestHeader')));
        expect(manager, isNot(contains('"Cookie"')));
        expect(manager, isNot(contains('"Authorization"')));
        expect(manager, contains('setDestinationInExternalFilesDir'));
        expect(manager, contains('MANAGED_SUBDIR'));
        // 取消 / 清理复用**权威退役**路径（确认归属 → remove → 确认移除 → 删自有文件）。
        expect(manager, contains('retireOwned(record)'));
        expect(manager, contains('dm.remove(targetId)'));
        expect(
          manager,
          contains('startsWith(AppUpdateContract.MANAGED_FILE_PREFIX)'),
        );
      },
    );

    test('install gate verifies package, signature, version, abi, minSdk', () {
      final verifier = read('$updateDir/AppUpdateVerifier.kt');
      expect(verifier, contains('getPackageArchiveInfo'));
      expect(verifier, contains('GET_SIGNING_CERTIFICATES'));
      expect(verifier, contains('GET_SIGNATURES'));
      expect(verifier, contains('archivePackage != context.packageName'));
      expect(verifier, contains('longVersionCode'));
      expect(verifier, contains('SUPPORTED_ABIS'));
      expect(verifier, contains('minSdkVersion'));

      final manager = read('$updateDir/AppUpdateManager.kt');
      expect(manager, contains('FileProvider.getUriForFile'));
      expect(manager, contains('canRequestPackageInstalls'));
      expect(manager, contains('application/vnd.android.package-archive'));
      expect(manager, contains('FLAG_GRANT_READ_URI_PERMISSION'));
    });

    test('receiver uses bounded goAsync and matches tracked download id', () {
      final receiver = read('$updateDir/AppUpdateDownloadReceiver.kt');
      expect(receiver, contains('goAsync'));
      expect(receiver, contains('EXTRA_DOWNLOAD_ID'));
      expect(receiver, contains('onDownloadComplete'));

      final manager = read('$updateDir/AppUpdateManager.kt');
      expect(manager, contains('record.downloadId != downloadId'));
      expect(
        manager,
        contains('trackedRowOwnership(record) != RowOwnership.OWNED'),
      );
      expect(receiver, contains('onDownloadComplete(downloadId) {'));
      expect(receiver, contains('pending.finish()'));
    });

    test('notification targets explicit immutable install activity', () {
      final notifications = read('$updateDir/AppUpdateNotifications.kt');
      expect(notifications, contains('AppUpdateInstallActivity::class.java'));
      expect(notifications, contains('PendingIntent.FLAG_IMMUTABLE'));
      expect(notifications, contains('EXTRA_REQUEST_KEY'));
      // 绝不后台拉起 UI。
      expect(notifications, isNot(contains('startActivity')));
    });
  });

  group('native ownership / single-request invariants', () {
    test('ownership requires exact url AND exact managed destination', () {
      final ownership = read('$updateDir/AppUpdateOwnership.kt');
      expect(ownership, contains('fun matches('));
      expect(ownership, contains('fun classify('));
      expect(ownership, contains('resolveFileSchemeLocalPath'));
      expect(ownership, contains('isManagedFileName'));
      // 只接受 `file://` 且无 authority；content:// / 带 host 一律 fail closed。
      expect(ownership, contains('file://'));
      // 精确相等匹配，绝不做前缀 / basename 之类的宽松匹配。
      expect(ownership, contains('actual == expected'));

      final manager = read('$updateDir/AppUpdateManager.kt');
      expect(manager, contains('COLUMN_LOCAL_URI'));
      expect(manager, contains('scanOwnedDownloads'));
      expect(manager, contains('AppUpdateOwnership.classify'));
      // 扫描上限 / 非权威结论（不重新入队）。
      expect(manager, contains('MAX_SCAN_ROWS'));
      expect(manager, contains('Scan.Incomplete'));
      expect(manager, contains('Scan.Unavailable'));
      expect(manager, contains('Scan.Ambiguous'));
      // 绝不按 URL 单独认领（旧的宽松 findOwnedDownloadId 必须不存在）。
      expect(manager, isNot(contains('findOwnedDownloadId')));
    });

    test('replacing a managed request retires the old owned row first', () {
      final manager = read('$updateDir/AppUpdateManager.kt');
      expect(manager, contains('mutationLock'));
      expect(manager, contains('retireOwned(existing)'));
      expect(manager, contains('trackedRowOwnership'));
      expect(manager, contains('confirmRemoved'));
      // 无法权威退役时绝不丢弃旧记录 / 盲目入队新请求。
      expect(
        manager,
        contains('if (existing != null && !retireOwned(existing))'),
      );
    });

    test('reconcile never re-enqueues when the scan is not authoritative', () {
      final manager = read('$updateDir/AppUpdateManager.kt');
      expect(manager, contains('markReconcileUnresolved'));
      expect(manager, contains('reconcileNotFound'));
      // 只有目标文件也不存在时才允许重新入队。
      expect(manager, contains('if (file.exists())'));
    });
  });

  group('cancel + install-callback generation guards (N1/N2)', () {
    test('cancel reuses authoritative retire and never silently clears', () {
      final manager = read('$updateDir/AppUpdateManager.kt');
      // 取消复用与替换请求相同的权威退役，失败时保留 exact 记录（不 clear / 不谎报）。
      expect(manager, contains('cancelDisposition('));
      expect(manager, contains('retireOwned(record)'));
      expect(manager, contains('CancelDisposition.CLEARED_CANCELED'));
      expect(manager, contains('CancelDisposition.RETAIN_FAILED'));
      // 用户明确取消：失败时消费自动安装意图，但仍保留 id / generation 以便重试。
      expect(manager, contains('userWantsInstall = false'));
      expect(
        manager,
        contains('isStale(current, record.requestKey, record.generation)'),
      );

      // 纯逻辑与可执行用例同源。
      final ownership = read('$updateDir/AppUpdateOwnership.kt');
      expect(ownership, contains('fun cancelDisposition('));
      expect(ownership, contains('fun isStale('));
    });

    test('install callback is (requestKey, generation) guarded end to end', () {
      final manager = read('$updateDir/AppUpdateManager.kt');
      // 回调必须携带被校验记录的代际，而不是拷贝「当前」记录。
      expect(
        manager,
        contains(
          'finishInstallAttempt(activity, record.requestKey, record.generation, outcome, callback)',
        ),
      );
      // 成功 / 失败 / 权限三条回填路径都用同一守卫。
      expect(manager, contains('isStale(verified, requestKey, generation)'));
      expect(manager, contains('isStale(matched, requestKey, generation)'));
      expect(manager, contains('isStale(after, requestKey, generation)'));
      // 用最新匹配记录发起安装，而非旧结果记录。
      expect(manager, contains('launchInstaller(activity, matched!!)'));
    });
  });

  group('dart projection', () {
    test(
      'requestInstall no longer fabricates installerUnavailable failure',
      () {
        final controller = read(controllerPath);
        expect(
          controller,
          isNot(contains('ApkUpdateFailureReason.installerUnavailable')),
          reason:
              'Native is the authority: a false install must refresh and keep '
              'permissionRequired / readyToInstall instead of a fake failure.',
        );
        expect(controller, contains('permissionRequired'));
      },
    );
  });
}

/// 取包含 [containing] 的、名为 [tagName] 的起始标签（`<tag ...>`）。
String? _tag(String source, String tagName, {String? containing}) {
  final regex = RegExp('<$tagName\\b[^>]*>', multiLine: true, dotAll: true);
  for (final match in regex.allMatches(source)) {
    final tag = match.group(0)!;
    if (containing == null || tag.contains(containing)) return tag;
  }
  return null;
}
