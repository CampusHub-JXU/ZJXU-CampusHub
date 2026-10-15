import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// FileProvider tripwire for the in-app APK update flow.
///
/// `v0.11.1` and every earlier release shipped `update_file_paths.xml` with
/// `<external-files-path path="Downloads/updates/" />`, while the managed APK is
/// written to `getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)/updates/`.
/// `Environment.DIRECTORY_DOWNLOADS` is `Download` (singular), so the whitelist
/// root did not contain the APK: `FileProvider.getUriForFile` threw
/// `IllegalArgumentException: Failed to find configured root that contains
/// /storage/emulated/0/Android/data/`<pkg>`/files/Download/updates/...`, the catch
/// in `AppUpdateManager.launchInstaller` swallowed it, and tapping 「安装更新」
/// returned `false` forever — the system installer never opened, on every device.
///
/// The whitelist must therefore stay exactly `Download/<MANAGED_SUBDIR>/`, and the
/// native side must keep deriving that directory from
/// `Environment.DIRECTORY_DOWNLOADS` (never a hand-written literal), so the two
/// sides cannot drift apart again.
void main() {
  const xmlPath = 'android/app/src/main/res/xml/update_file_paths.xml';
  const manifestPath = 'android/app/src/main/AndroidManifest.xml';
  const contractPath =
      'android/app/src/main/kotlin/edu/zjxu/jxucampushub/platform/update/AppUpdateContract.kt';
  const managerPath =
      'android/app/src/main/kotlin/edu/zjxu/jxucampushub/platform/update/AppUpdateManager.kt';

  /// `android.os.Environment.DIRECTORY_DOWNLOADS` — singular, not the public
  /// `Downloads` collection, and not the provider's own directory name.
  const downloadDirectory = 'Download';

  String managedSubdir() {
    final match = RegExp(r'const val MANAGED_SUBDIR = "([^"]+)"')
        .firstMatch(File(contractPath).readAsStringSync());
    expect(
      match,
      isNotNull,
      reason: 'MANAGED_SUBDIR must stay a string const in $contractPath.',
    );
    final subdir = match!.group(1)!;
    expect(subdir, isNotEmpty);
    return subdir;
  }

  test('FileProvider whitelist covers the managed APK directory', () {
    final xmlFile = File(xmlPath);
    expect(xmlFile.existsSync(), isTrue, reason: 'Missing $xmlPath.');
    final xml = xmlFile.readAsStringSync();

    final declaredRoots = RegExp(r'<external-files-path\b[^>]*\bpath="([^"]*)"')
        .allMatches(xml)
        .map((match) => match.group(1)!)
        .toList();

    expect(
      declaredRoots,
      equals(<String>['$downloadDirectory/${managedSubdir()}/']),
      reason:
          'The whitelist must expose exactly getExternalFilesDir('
          'Environment.DIRECTORY_DOWNLOADS)/${managedSubdir()}. FileProvider '
          'matches roots by path prefix, so a root that does not contain the '
          'managed APK makes getUriForFile throw and the installer never opens '
          '(the shipped bug: "Downloads/updates/" vs '
          '".../files/Download/updates/").',
    );

    for (final tag in const <String>[
      'files-path',
      'cache-path',
      'external-path',
      'root-path',
    ]) {
      expect(
        xml,
        isNot(contains('<$tag')),
        reason:
            'Never widen the update FileProvider beyond the managed '
            'subdirectory (found <$tag).',
      );
    }
  });

  test(
    'native code derives that directory from Environment, not a literal',
    () {
      final manager = File(managerPath).readAsStringSync();

      expect(
        manager,
        contains('getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)'),
        reason: 'managedDir() must resolve the very directory the whitelist declares.',
      );
      expect(manager, contains('setDestinationInExternalFilesDir('));
      expect(
        manager,
        isNot(contains('"$downloadDirectory/')),
        reason:
            'A hand-written path literal would drift from '
            'Environment.DIRECTORY_DOWNLOADS again.',
      );
    },
  );

  test(
    'manifest wires that whitelist to the update FileProvider authority',
    () {
      final manifest = File(manifestPath).readAsStringSync();
      expect(manifest, contains('android:resource="@xml/update_file_paths"'));
      expect(
        manifest,
        contains(r'android:authorities="${applicationId}.app_update_files"'),
      );
      expect(
        File(contractPath).readAsStringSync(),
        contains('const val FILE_PROVIDER_SUFFIX = ".app_update_files"'),
      );
    },
  );
}
