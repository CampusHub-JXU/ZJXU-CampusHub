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
        'switchSource',
        'requestInstall',
        'openInstallPermissionSettings',
      ]) {
        expect(contract, contains(method), reason: 'missing method $method');
        expect(controller, contains(method), reason: 'Dart missing $method');
      }
    });

    test('only the three trusted URL shapes are accepted', () {
      final contract = read('$updateDir/AppUpdateContract.kt');
      // 形态 1：GitHub 规范 Release 资产。
      expect(contract, contains('"github.com"'));
      expect(contract, contains('"CampusHub-JXU"'));
      expect(contract, contains('"ZJXU-CampusHub"'));
      expect(contract, contains('"releases"'));
      expect(contract, contains('"download"'));
      expect(contract, contains('"https"'));
      // 形态 2：EdgeOne gh-proxy 精确前缀；形态 3：R2 自有域名。
      expect(
        contract,
        contains(
          'const val TRUSTED_MIRROR_PREFIX = "https://edgeone.gh-proxy.org/"',
        ),
      );
      expect(
        contract,
        contains('const val TRUSTED_R2_HOST = "download.fhfanshu.xyz"'),
      );
      // 镜像前缀按原样（区分大小写）匹配，不 lowercase / ignoreCase。
      expect(contract, contains('value.startsWith(TRUSTED_MIRROR_PREFIX)'));
      expect(contract, isNot(contains('startsWith(TRUSTED_MIRROR_PREFIX, ')));
      expect(contract, isNot(contains('ignoreCase')));
      // R2 恰好两段路径。
      expect(contract, contains('segments.size != 2'));
      // 拒绝 userinfo / 端口 / query / fragment / 路径穿越。
      expect(contract, contains('userInfo'));
      expect(contract, contains('fragment'));
      expect(contract, contains('query'));
      expect(contract, contains('".."'));
    });

    test(
      'hosts are compared exactly: no wildcard / suffix / substring match',
      () {
        final contract = read('$updateDir/AppUpdateContract.kt');
        // 剥离注释后只检查可执行代码。
        final code = contract
            .split('\n')
            .where((line) {
              final t = line.trimLeft();
              return !t.startsWith('*') &&
                  !t.startsWith('/*') &&
                  !t.startsWith('//');
            })
            .join('\n');
        expect(code, isNot(contains('*.')));
        expect(code, isNot(contains('host.endsWith')));
        expect(code, isNot(contains('host?.endsWith')));
        expect(code, isNot(contains('host.contains')));
        expect(code, isNot(contains('host?.contains')));
        expect(code, isNot(contains('Regex(')));
        expect(code, isNot(contains('.toRegex')));
        // 主机经 `when (uri.host?.lowercase())` 与常量整串相等比较。
        expect(code, contains('when (uri.host?.lowercase())'));
        expect(code, contains('TRUSTED_HOST ->'));
        expect(code, contains('TRUSTED_R2_HOST ->'));
        expect(code, contains('uri.host?.lowercase() != TRUSTED_HOST'));
      },
    );

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
      final machine = read('$updateDir/AppUpdateMachine.kt');
      expect(manager, contains('mutationLock'));
      expect(manager, contains('trackedRowOwnership'));
      expect(manager, contains('confirmRemoved'));
      // 不同 requestKey 的 Start 先把旧任务转入 CLEANUP_PENDING 并退役；
      // 只有退役确认、旧任务已清空后才执行挂起的新 Start。
      expect(machine, contains('return cleanup(CleanupIntent.CANCEL, event)'));
      expect(
        manager,
        contains(
          'if (confirmed && effect.restart != null && store.read() == null)',
        ),
      );
    });

    test('reconcile never re-enqueues when the scan is not authoritative', () {
      final machine = read('$updateDir/AppUpdateMachine.kt');
      final manager = read('$updateDir/AppUpdateManager.kt');
      // 只有完整扫描无匹配且自有目标文件也不存在时才重新入队；其余一律保留身份。
      expect(
        machine,
        contains('AppUpdateOwnership.Scan.NotFound -> if (!event.fileExists)'),
      );
      expect(
        machine,
        contains('else -> out(task.copy(stage = Stage.RECONCILE_REQUIRED))'),
      );
      expect(manager, contains('managedFile(t).exists() || !canReenqueue(t)'));
      // 旧实现把对账失败写成可重试失败并丢掉 pending 标记（会遗留孤儿下载）。
      expect(manager, isNot(contains('markReconcileUnresolved')));
    });

    test('a failed DM query is never persisted as a download failure', () {
      final manager = read('$updateDir/AppUpdateManager.kt');
      final machine = read('$updateDir/AppUpdateMachine.kt');
      // 查询不可用与「行不存在」分开；Unavailable 只投影，不改任务。
      expect(manager, contains('if (c == null) return DmObs.Unavailable'));
      expect(manager, contains('if (!c.moveToFirst()) return DmObs.Absent'));
      expect(machine, contains('else -> out(dm = dm)'));
    });

    test('superseded-by-installed is decided natively at every entry', () {
      final manager = read('$updateDir/AppUpdateManager.kt');
      final machine = read('$updateDir/AppUpdateMachine.kt');
      expect(
        manager,
        contains('Event.Installed(versionCode(info), info.versionName)'),
      );
      expect(machine, contains('cleanup(CleanupIntent.SUPERSEDED)'));
      // Dart 不再按 semver 删除原生任务。
      final controller = read(controllerPath);
      expect(controller, isNot(contains('_isSuperseded')));
    });

    test('debug test origin is gated only by FLAG_DEBUGGABLE', () {
      final manager = read('$updateDir/AppUpdateManager.kt');
      final contract = read('$updateDir/AppUpdateContract.kt');
      expect(
        manager,
        contains(
          'private val allowTestOrigin = (appContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0',
        ),
      );
      expect(
        RegExp(r'allowTestOrigin\s*=').allMatches(manager).length,
        1,
        reason: 'allowTestOrigin 只能在一处由 FLAG_DEBUGGABLE 计算',
      );
      expect(
        contract,
        contains(
          'fun parseCanonicalAssetUrl(raw: String?, allowTestOrigin: Boolean = false)',
        ),
      );
      expect('10.0.2.2'.allMatches(contract).length, 1);
      expect(contract, contains('if (allowTestOrigin) {'));
      // debug 网络安全配置只在 debug 源集；main 不允许 10.0.2.2 明文。
      final mainNsc = read(
        'android/app/src/main/res/xml/network_security_config.xml',
      );
      expect(mainNsc, isNot(contains('10.0.2.2')));
      final debugNsc = read(
        'android/app/src/debug/res/xml/network_security_config.xml',
      );
      expect(debugNsc, contains('10.0.2.2'));
    });
  });

  group('cancel + install-callback generation guards (N1/N2)', () {
    test('cancel reuses authoritative retire and never silently clears', () {
      final manager = read('$updateDir/AppUpdateManager.kt');
      final machine = read('$updateDir/AppUpdateMachine.kt');
      // 取消进入 CLEANUP_PENDING 并退役；同时消费自动安装意图。
      expect(machine, contains('return cleanup(CleanupIntent.CANCEL)'));
      expect(machine, contains('failureReason = null, wantsInstall = false)'));
      // 未确认退役：保留完整身份并如实返回 retired=false（不 clear / 不谎报 canceled）。
      expect(
        machine,
        contains('else if (!event.confirmed) out(retired = false)'),
      );
      expect(manager, contains('val confirmed = retireOwned(record)'));
      expect(manager, contains('retired = view.task == null'));
      final ownership = read('$updateDir/AppUpdateOwnership.kt');
      expect(ownership, contains('fun isStale('));
    });

    test('install callback is (requestKey, generation) guarded end to end', () {
      final manager = read('$updateDir/AppUpdateManager.kt');
      final machine = read('$updateDir/AppUpdateMachine.kt');
      // 所有迟到结果（入队 / 校验 / 安装 / 退役）先核对 generation。
      expect(
        machine,
        contains('if (gen != null && gen != task?.generation) return out()'),
      );
      // 校验回填与拉起安装器都用同一 (requestKey, generation) 守卫，并用最新记录发起。
      expect(
        manager,
        contains('!isStale(current, record.requestKey, record.generation)'),
      );
      expect(
        manager,
        contains(
          'if (isStale(current, record.requestKey, record.generation) || current?.stage != Stage.READY || !current.wantsInstall)',
        ),
      );
      expect(manager, contains('launchInstaller(target, current)'));
    });
  });

  group('dart debug test-origin gate', () {
    const configPath = 'lib/core/config/app_config.dart';

    test('the compile-time define is read in exactly one place', () {
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final normalized = entity.path.replaceAll('\\', '/');
        if (normalized.endsWith(configPath)) continue;
        if (entity.readAsStringSync().contains('JXU_UPDATE_TEST_ORIGIN')) {
          offenders.add(normalized);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: '测试源开关只能由 AppConfig.updateTestOrigin 统一把关',
      );
    });

    test('AppConfig only yields an origin when kDebugMode is true', () {
      final config = read(configPath);
      expect(config, contains("'JXU_UPDATE_TEST_ORIGIN'"));
      // 门控 getter 把编译期 kDebugMode 传给纯逻辑；纯逻辑先判断它。
      expect(
        config,
        contains(
          'resolveUpdateTestOrigin(_updateTestOriginDefine, debugMode: kDebugMode)',
        ),
      );
      expect(config, contains('if (!debugMode) return null;'));
      // 只接受 http://10.0.2.2:<端口>，不是任意主机。
      expect(config, contains(r'10\.0\.2\.2'));
    });

    test(
      'update check and request building consume the gate, not the define',
      () {
        final service = read('lib/core/update/update_service.dart');
        final controller = read(controllerPath);
        expect(service, contains('AppConfig.updateTestOrigin'));
        expect(controller, contains('AppConfig.updateTestOrigin'));
      },
    );

    test(
      'the debug-only test url shape is not in the production allow-list',
      () {
        final controller = read(controllerPath);
        final trusted = RegExp(
          r'static bool isTrustedDownloadUrl\(String url\) =>([^;]*);',
        ).firstMatch(controller);
        expect(trusted, isNotNull, reason: 'isTrustedDownloadUrl 形态变了，请同步本断言');
        expect(trusted!.group(1), isNot(contains('isTestAssetUrl')));
        expect(trusted.group(1), isNot(contains('ApkDownloadSource.test')));
      },
    );

    test('switchSource is part of the Dart protocol', () {
      final controller = read(controllerPath);
      expect(controller, contains("methodSwitchSource = 'switchSource'"));
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
