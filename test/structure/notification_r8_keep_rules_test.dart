import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// R8 tripwire for `flutter_local_notifications` (Gson `TypeToken`).
///
/// The plugin persists scheduled notifications with Gson and
/// `new TypeToken<ArrayList<NotificationDetails>>() {}`. In the `v0.8.2`
/// release build R8 stripped the generic signature, so every
/// `cancel()` / `schedule` call failed with "TypeToken must be created with a
/// type argument". The plugin ships no consumer rules, so the app must keep
/// them in `android/app/proguard-rules.pro` (picked up automatically by the
/// Flutter Gradle plugin for release builds).
void main() {
  const rulesPath = 'android/app/proguard-rules.pro';

  late List<String> rules;

  setUpAll(() {
    final file = File(rulesPath);
    expect(
      file.existsSync(),
      isTrue,
      reason:
          'Missing $rulesPath. Without it R8 strips Gson TypeToken generics '
          'and notification scheduling crashes on release builds.',
    );
    rules = file
        .readAsLinesSync()
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toList();
  });

  test('keeps generic signatures (-keepattributes Signature)', () {
    final keepsSignature = rules.any(
      (rule) =>
          rule.startsWith('-keepattributes') &&
          RegExp(r'(^|[\s,])Signature($|[\s,])').hasMatch(rule),
    );
    expect(
      keepsSignature,
      isTrue,
      reason:
          'Gson reads TypeToken type arguments from the Signature '
          'attribute; R8 must not strip it.',
    );
  });

  test('keeps Gson TypeToken and its subclasses', () {
    expect(
      rules.any(
        (rule) =>
            rule.startsWith('-keep') &&
            rule.endsWith('class com.google.gson.reflect.TypeToken'),
      ),
      isTrue,
      reason: 'Missing the keep rule for com.google.gson.reflect.TypeToken.',
    );
    expect(
      rules.any(
        (rule) =>
            rule.startsWith('-keep') &&
            rule.endsWith('class * extends com.google.gson.reflect.TypeToken'),
      ),
      isTrue,
      reason: 'Missing the keep rule for anonymous TypeToken subclasses.',
    );
  });
}
