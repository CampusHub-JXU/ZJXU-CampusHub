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

  test('captcha OCR plugin depends on the ONNX Runtime Android artifact', () {
    final buildGradle = File(buildGradlePath).readAsStringSync();
    expect(
      buildGradle,
      contains('com.microsoft.onnxruntime:onnxruntime-android'),
    );
  });
}
