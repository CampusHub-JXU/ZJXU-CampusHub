import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/captcha/captcha_recognizer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(
    MethodChannelCaptchaRecognizer.channelName,
  );

  final calls = <MethodCall>[];

  void setHandler(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) {
          calls.add(call);
          return handler(call);
        });
  }

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  });

  Uint8List image([int length = 64]) =>
      Uint8List(length)..fillRange(0, length, 1);

  MethodChannelCaptchaRecognizer buildRecognizer({Duration? timeout}) =>
      MethodChannelCaptchaRecognizer(
        channel: methodChannel,
        timeout: timeout ?? const Duration(seconds: 5),
      );

  test('returns candidate and preserves original case', () async {
    setHandler(
      (_) async => [
        {'text': 'aB12', 'confidence': null},
      ],
    );

    final result = await buildRecognizer().recognize(
      image(),
      expectedLength: 4,
    );

    expect(result, isNotNull);
    expect(result!.text, 'aB12');
    expect(result.confidence, isNull);
    // 答案不得出现在可打印表示里。
    expect(result.toString(), isNot(contains('aB12')));
  });

  test('strips leading, trailing and inner whitespace', () async {
    setHandler(
      (_) async => [
        {'text': ' A B 1 2\n'},
      ],
    );

    final result = await buildRecognizer().recognize(
      image(),
      expectedLength: 4,
    );

    expect(result?.text, 'AB12');
  });

  test('accepts six-character answers', () async {
    setHandler(
      (_) async => [
        {'text': 'Ab12Cd', 'confidence': null},
      ],
    );

    final result = await buildRecognizer().recognize(
      image(),
      expectedLength: 6,
    );

    expect(result?.text, 'Ab12Cd');
  });

  test('carries a non-null confidence through when provided', () async {
    setHandler(
      (_) async => [
        {'text': 'AB12', 'confidence': 0.92},
      ],
    );

    final result = await buildRecognizer().recognize(
      image(),
      expectedLength: 4,
    );

    expect(result?.confidence, 0.92);
  });

  test('rejects candidates whose length does not match', () async {
    setHandler(
      (_) async => [
        {'text': 'AB12X'},
      ],
    );

    final result = await buildRecognizer().recognize(
      image(),
      expectedLength: 4,
    );

    expect(result, isNull);

    setHandler(
      (_) async => [
        {'text': 'AB1'},
      ],
    );
    expect(
      await buildRecognizer().recognize(image(), expectedLength: 4),
      isNull,
    );
  });

  test(
    'rejects non-whitelisted characters without fabricating an answer',
    () async {
      setHandler(
        (_) async => [
          {'text': 'AB1!'},
        ],
      );

      expect(
        await buildRecognizer().recognize(image(), expectedLength: 4),
        isNull,
      );

      setHandler(
        (_) async => [
          {'text': 'A B-12'},
        ],
      );
      expect(
        await buildRecognizer().recognize(image(), expectedLength: 4),
        isNull,
      );
    },
  );

  test('returns null when candidates disagree (ambiguous)', () async {
    setHandler(
      (_) async => [
        {'text': 'AB12', 'confidence': 0.99},
        {'text': 'CD34', 'confidence': 0.98},
      ],
    );

    final result = await buildRecognizer().recognize(
      image(),
      expectedLength: 4,
    );

    expect(result, isNull);
  });

  test('treats case-insensitive duplicates as one answer', () async {
    setHandler(
      (_) async => [
        {'text': 'ab12'},
        {'text': 'AB12'},
      ],
    );

    final result = await buildRecognizer().recognize(
      image(),
      expectedLength: 4,
    );

    expect(result?.text, 'ab12');
  });

  test(
    'skips invalid candidates instead of treating them as ambiguity',
    () async {
      setHandler(
        (_) async => [
          {'text': 'AB1!'},
          {'text': 'AB12'},
        ],
      );

      final result = await buildRecognizer().recognize(
        image(),
        expectedLength: 4,
      );

      expect(result?.text, 'AB12');
    },
  );

  test('rejects explicitly low-confidence candidates', () async {
    setHandler(
      (_) async => [
        {'text': 'AB12', 'confidence': 0.2},
      ],
    );

    expect(
      await buildRecognizer().recognize(image(), expectedLength: 4),
      isNull,
    );
  });

  test('returns null for empty or malformed native results', () async {
    setHandler((_) async => <Object?>[]);
    expect(
      await buildRecognizer().recognize(image(), expectedLength: 4),
      isNull,
    );

    setHandler((_) async => null);
    expect(
      await buildRecognizer().recognize(image(), expectedLength: 4),
      isNull,
    );

    setHandler((_) async => 'AB12');
    expect(
      await buildRecognizer().recognize(image(), expectedLength: 4),
      isNull,
    );

    setHandler(
      (_) async => [
        42,
        <String, Object?>{'text': 12},
      ],
    );
    expect(
      await buildRecognizer().recognize(image(), expectedLength: 4),
      isNull,
    );
  });

  test('passes bytes and expectedLength to the native channel', () async {
    setHandler(
      (_) async => [
        {'text': 'AB12', 'confidence': null},
      ],
    );

    final bytes = image(128);
    await buildRecognizer().recognize(bytes, expectedLength: 4);

    expect(calls, hasLength(1));
    expect(calls.single.method, MethodChannelCaptchaRecognizer.methodRecognize);
    final arguments = calls.single.arguments as Map<Object?, Object?>;
    expect(arguments['bytes'], bytes);
    expect(arguments['expectedLength'], 4);
  });

  test('rejects empty input without touching the native channel', () async {
    final result = await buildRecognizer().recognize(
      Uint8List(0),
      expectedLength: 4,
    );

    expect(result, isNull);
    expect(calls, isEmpty);
  });

  test(
    'rejects unsupported lengths without touching the native channel',
    () async {
      expect(
        await buildRecognizer().recognize(image(), expectedLength: 5),
        isNull,
      );
      expect(
        await buildRecognizer().recognize(image(), expectedLength: 0),
        isNull,
      );
      expect(calls, isEmpty);
    },
  );

  test('rejects oversized input without touching the native channel', () async {
    final oversized = image(MethodChannelCaptchaRecognizer.maxInputBytes + 1);

    expect(
      await buildRecognizer().recognize(oversized, expectedLength: 4),
      isNull,
    );
    expect(calls, isEmpty);
  });

  test('returns null when the native channel is unavailable', () async {
    expect(
      await buildRecognizer().recognize(image(), expectedLength: 4),
      isNull,
    );
  });

  test('returns null when the native side throws PlatformException', () async {
    setHandler((_) async => throw PlatformException(code: 'boom'));

    expect(
      await buildRecognizer().recognize(image(), expectedLength: 4),
      isNull,
    );
  });

  test('returns null on timeout and ignores the late native result', () async {
    final completer = Completer<Object?>();
    setHandler((_) => completer.future);

    final result = await buildRecognizer(
      timeout: const Duration(milliseconds: 30),
    ).recognize(image(), expectedLength: 4);

    expect(result, isNull);

    // 迟到的结果不得再抛出，也不得改变已返回的 null。
    completer.complete([
      {'text': 'AB12', 'confidence': null},
    ]);
    await Future<void>.delayed(Duration.zero);
  });
}
