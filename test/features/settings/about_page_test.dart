import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/logging/app_logger.dart';
import 'package:jxu_campus_hub/features/settings/about_page.dart';

import '../../helpers/pump_app.dart';
import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

  void mockClipboard(WidgetTester tester, {required bool fail}) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData' && fail) {
          throw PlatformException(code: 'clipboard');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  testWidgets('关于页提供复制登录诊断日志入口并复制成功提示', (tester) async {
    mockClipboard(tester, fail: false);
    await pumpPage(tester, const AboutPage());

    expect(find.text('复制登录诊断日志'), findsOneWidget);
    expect(find.text('已脱敏，不含密码与验证码'), findsOneWidget);

    await tester.tap(find.text('复制登录诊断日志'));
    await tester.pumpAndSettle();

    expect(find.text('登录诊断日志已复制'), findsOneWidget);
  });

  testWidgets('剪贴板失败时提示复制失败', (tester) async {
    mockClipboard(tester, fail: true);
    await pumpPage(tester, const AboutPage());

    await tester.tap(find.text('复制登录诊断日志'));
    await tester.pumpAndSettle();

    expect(find.text('复制失败'), findsOneWidget);
  });

  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && !ready(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  void mockPathProvider(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getTemporaryDirectory') {
          return Directory.systemTemp.path;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      ),
    );
  }

  testWidgets('关于页可导出 Markdown 诊断日志并包含认证轨迹', (tester) async {
    mockPathProvider(tester);
    Map<Object?, Object?>? shared;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/share'),
      (call) async {
        if (call.method == 'share') {
          shared = call.arguments as Map<Object?, Object?>;
          return 'dev.fluttercommunity.plus/share/success';
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/share'),
        null,
      ),
    );
    AppLogger.instance.auth(LogLevel.info, 'diagnostic-auth-line');

    await pumpPage(tester, const AboutPage());
    await tester.scrollUntilVisible(find.text('导出诊断日志'), 200);
    expect(find.text('记录完整诊断日志'), findsOneWidget);

    await tester.tap(find.text('导出诊断日志'));
    await waitFor(tester, () => shared != null);

    final paths = (shared?['paths'] as List?)?.cast<String>();
    expect(paths, isNotNull);
    expect(paths, hasLength(1));
    expect(paths!.single, endsWith('.md'));
    final report = File(paths.single).readAsStringSync();
    expect(report, contains('# JXU 完整诊断日志'));
    expect(report, contains('diagnostic-auth-line'));
    expect(report, contains('## 认证轨迹'));
    File(paths.single).deleteSync();
  });

  testWidgets('系统分享不可用时回退复制完整诊断日志', (tester) async {
    mockPathProvider(tester);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/share'),
      (call) async {
        if (call.method == 'share') {
          return 'dev.fluttercommunity.plus/share/unavailable';
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/share'),
        null,
      );
    });
    AppLogger.instance.auth(LogLevel.info, 'fallback-auth-line');

    await pumpPage(tester, const AboutPage());
    await tester.scrollUntilVisible(find.text('导出诊断日志'), 200);
    await tester.tap(find.text('导出诊断日志'));
    await waitFor(tester, () => copied != null);

    expect(find.text('系统分享不可用，已复制到剪贴板'), findsOneWidget);
    expect(copied, contains('fallback-auth-line'));
    expect(copied, contains('# JXU 完整诊断日志'));
  });
}
