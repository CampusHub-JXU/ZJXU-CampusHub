import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// R8 tripwire for the bundled ONNX Runtime captcha OCR plugin.
///
/// `v0.8.0` shipped release APKs in which R8 removed
/// `ai.onnxruntime.TensorInfo`. ONNX Runtime's JNI layer resolves that class by
/// literal name (`FindClass("ai/onnxruntime/TensorInfo")`), so `GetMethodID`
/// received a null class and ART aborted the process (SIGABRT, `Aborted`) on
/// every captcha OCR call — 18 tombstones from the plugin's OCR worker thread.
///
/// The Flutter Gradle plugin enables R8 for release builds by default
/// (`isMinifyEnabled = true`), and the ONNX Runtime AAR only ships telemetry
/// keep rules, so the consumer must keep the ORT Java API itself. These rules
/// must stay wired up; the release workflow additionally verifies the built
/// release dex still contains the class.
void main() {
  const rulesPath = 'packages/campus_captcha_ocr/android/consumer-rules.pro';
  const buildGradlePath = 'packages/campus_captcha_ocr/android/build.gradle';

  test('captcha OCR plugin keeps the ONNX Runtime Java API under R8', () {
    final rulesFile = File(rulesPath);
    expect(
      rulesFile.existsSync(),
      isTrue,
      reason:
          'Missing $rulesPath. R8 would strip ai.onnxruntime.TensorInfo again '
          'and captcha OCR would abort the process on release builds.',
    );

    final rules = rulesFile.readAsStringSync();
    expect(rules, contains('-keep'));
    expect(
      rules,
      contains('ai.onnxruntime.**'),
      reason:
          'The keep rule must cover the whole ai.onnxruntime package; ONNX '
          'Runtime resolves several of its classes by literal name from JNI.',
    );

    final buildGradle = File(buildGradlePath);
    expect(
      buildGradle.existsSync(),
      isTrue,
      reason: 'Missing $buildGradlePath.',
    );
    expect(
      buildGradle.readAsStringSync(),
      contains('consumerProguardFiles "consumer-rules.pro"'),
      reason:
          'The keep rules only apply when the plugin ships them as consumer '
          'rules; otherwise every release build loses them again.',
    );
  });

  test('captcha OCR plugin depends on the self-built minimal ONNX Runtime AAR', () {
    // tools/ocr_slim/: the official full onnxruntime-android AAR was replaced by
    // a minimal build (only the captcha model's operators). It must replace the
    // full artifact, never stack with it, and its Java API is still the upstream
    // ai.onnxruntime package, so the keep rule above keeps covering it.
    const aarPath =
        'packages/campus_captcha_ocr/android/libs/onnxruntime-android-minimal-1.30.0.aar';
    final buildGradle = File(buildGradlePath).readAsStringSync();
    expect(
      buildGradle,
      contains(
        'implementation files("libs/onnxruntime-android-minimal-1.30.0.aar")',
      ),
    );
    expect(
      buildGradle,
      isNot(contains('com.microsoft.onnxruntime:onnxruntime-android')),
      reason: 'Full and minimal ONNX Runtime must not both be packaged.',
    );
    expect(File(aarPath).existsSync(), isTrue, reason: 'Missing $aarPath.');
    expect(
      File(rulesPath).readAsStringSync(),
      contains('-keep class ai.onnxruntime.** { *; }'),
    );
  });

  test('captcha OCR ships the ORT-format model the minimal runtime can load', () {
    const assets =
        'packages/campus_captcha_ocr/android/src/main/assets/captcha_ocr';
    const engine =
        'packages/campus_captcha_ocr/android/src/main/kotlin/edu/zjxu/campus_captcha_ocr/DdddocrEngine.kt';
    final source = File(engine).readAsStringSync();
    expect(source, contains('"captcha_ocr/common_old_alnum.ort"'));
    expect(source, contains('"captcha_ocr/charset_alnum.txt"'));
    expect(source, contains('EXPECTED_CHARSET_SIZE = 63'));
    expect(File('$assets/common_old_alnum.ort').existsSync(), isTrue);
    // A minimal ORT build cannot load .onnx; shipping it again would only add
    // ~6.5MB of dead weight.
    expect(File('$assets/common_old.onnx').existsSync(), isFalse);

    final charset = File('$assets/charset_alnum.txt').readAsStringSync();
    expect(charset.length, 62, reason: 'blank (implicit) + 62 classes = 63');
    expect(RegExp(r'^[A-Za-z0-9]{62}$').hasMatch(charset), isTrue);
    expect(charset.split('').toSet().length, 62);

    // ORT format: FlatBuffers file identifier "ORTM" at byte offset 4.
    final model = File('$assets/common_old_alnum.ort').readAsBytesSync();
    expect(String.fromCharCodes(model.sublist(4, 8)), 'ORTM');
  });
}
