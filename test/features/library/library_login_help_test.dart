import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/library/library_login_help.dart';

/// 图书馆登录说明弹层的独立测试（Issue 54）。
///
/// 覆盖：文案完整性、弹层可开可关（按钮 / 返回键）、窄屏 360 + 文字缩放 2 的
/// 明暗两态不溢出、按钮点按目标尺寸（≥48）。全部为纯 UI，不触网、不动会话。
Widget _host({required void Function(BuildContext) onOpen}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () => onOpen(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

/// 窄屏 + 文字缩放 2 的说明内容（直接渲染，无需弹层路由）。
Widget _narrowSheet(Brightness brightness) {
  return MaterialApp(
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    darkTheme: ThemeData(brightness: Brightness.dark),
    home: const MediaQuery(
      data: MediaQueryData(
        size: Size(360, 560),
        textScaler: TextScaler.linear(2),
      ),
      child: Scaffold(body: LibraryLoginHelpSheet()),
    ),
  );
}

void main() {
  testWidgets('说明弹层展示全部文案，点「知道了」关闭', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(500, 1200);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(onOpen: LibraryLoginHelp.show));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text(LibraryLoginHelp.title), findsOneWidget);
    expect(find.text(LibraryLoginHelp.summary), findsOneWidget);
    expect(find.text(LibraryLoginHelp.keyboardHint), findsOneWidget);
    expect(find.text(LibraryLoginHelp.noAutofillHint), findsOneWidget);
    expect(find.text(LibraryLoginHelp.notFailureHint), findsOneWidget);
    expect(find.text(LibraryLoginHelp.webErrorHint), findsOneWidget);
    // 不使用「安全盾」这类口号，也不承诺自动填充。
    expect(find.textContaining('安全盾'), findsNothing);
    expect(find.textContaining('自动填充'), findsNothing);

    expect(
      tester.getSize(find.widgetWithText(FilledButton, '知道了')).height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text(LibraryLoginHelp.summary), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('窄屏 360 · 文字缩放 2 · ${brightness.name} 说明不溢出', (tester) async {
      await tester.pumpWidget(_narrowSheet(brightness));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(LibraryLoginHelpSheet), findsOneWidget);
    });
  }
}
