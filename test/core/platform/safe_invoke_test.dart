import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/platform/safe_invoke.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/safe_invoke');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<String> call({bool catchUnknown = true}) => safeInvoke<bool, String>(
    channel,
    'm',
    map: (v) => 'ok:$v',
    missing: 'missing',
    failed: 'failed',
    label: '测试调用',
    catchUnknown: catchUnknown,
  );

  test('成功经 map 转换', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => true);
    expect(await call(), 'ok:true');
  });

  test('通道缺失返回 missing', () async {
    expect(await call(), 'missing');
  });

  test('PlatformException 返回 failed', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'x');
    });
    expect(await call(), 'failed');
  });

  test('map 抛错：catchUnknown 决定降级还是重抛', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => true);
    Future<String> boom(bool catchUnknown) => safeInvoke<bool, String>(
      channel,
      'm',
      map: (_) => throw StateError('map'),
      missing: 'missing',
      failed: 'failed',
      catchUnknown: catchUnknown,
    );
    expect(await boom(true), 'failed');
    await expectLater(boom(false), throwsStateError);
  });
}
