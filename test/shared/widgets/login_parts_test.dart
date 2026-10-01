import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/shared/widgets/login_parts.dart';

Uint8List _tinyPng() => Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  group('RememberAccountTile', () {
    testWidgets('reflects value and reports toggles from row and checkbox', (
      tester,
    ) async {
      final changes = <bool>[];
      var value = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => RememberAccountTile(
                value: value,
                onChanged: (next) {
                  changes.add(next);
                  setState(() => value = next);
                },
              ),
            ),
          ),
        ),
      );

      expect(find.text('记住账号并自动登录'), findsOneWidget);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);

      await tester.tap(find.text('记住账号并自动登录'));
      await tester.pump();
      expect(changes, [false]);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);

      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(changes, [false, true]);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    });
  });

  group('CaptchaRow', () {
    Widget host({
      Uint8List? bytes,
      bool loading = false,
      bool captchaLoading = false,
      bool hasError = false,
      VoidCallback? onRefresh,
      VoidCallback? onSubmitted,
      TextEditingController? controller,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: CaptchaRow(
            controller: controller ?? TextEditingController(),
            focusNode: FocusNode(),
            hintText: '测试验证码',
            bytes: bytes,
            loading: loading,
            captchaLoading: captchaLoading,
            hasError: hasError,
            onRefresh: onRefresh ?? () {},
            onSubmitted: onSubmitted ?? () {},
          ),
        ),
      );
    }

    testWidgets('tapping the image refreshes; submit key calls onSubmitted', (
      tester,
    ) async {
      var refreshes = 0;
      var submits = 0;
      await tester.pumpWidget(
        host(
          bytes: _tinyPng(),
          onRefresh: () => refreshes++,
          onSubmitted: () => submits++,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('测试验证码'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);

      await tester.tap(find.byType(Image));
      expect(refreshes, 1);

      await tester.showKeyboard(find.byType(TextField));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      expect(submits, 1);
    });

    testWidgets('shows spinner while loading and ignores taps', (tester) async {
      var refreshes = 0;
      await tester.pumpWidget(
        host(captchaLoading: true, onRefresh: () => refreshes++),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsNothing);
      await tester.tap(find.byType(CircularProgressIndicator));
      expect(refreshes, 0);
    });

    testWidgets('shows retry icon when no image and an error is present', (
      tester,
    ) async {
      var refreshes = 0;
      await tester.pumpWidget(
        host(hasError: true, onRefresh: () => refreshes++),
      );
      await tester.pump();

      expect(find.byIcon(Icons.refresh), findsOneWidget);
      await tester.tap(find.byIcon(Icons.refresh));
      expect(refreshes, 1);
    });

    testWidgets('error icon is suppressed while captcha is loading', (
      tester,
    ) async {
      await tester.pumpWidget(host(hasError: true, captchaLoading: true));
      await tester.pump();

      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('submitting login disables refresh even with an image', (
      tester,
    ) async {
      var refreshes = 0;
      await tester.pumpWidget(
        host(bytes: _tinyPng(), loading: true, onRefresh: () => refreshes++),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Image));
      expect(refreshes, 0);
    });

    testWidgets('semantics tap action mirrors the enabled state', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var refreshes = 0;

      await tester.pumpWidget(
        host(bytes: _tinyPng(), onRefresh: () => refreshes++),
      );
      await tester.pumpAndSettle();

      final node = find.semantics.byLabel('刷新验证码');
      expect(
        node.evaluate().single.getSemanticsData().hasAction(
          SemanticsAction.tap,
        ),
        isTrue,
      );
      tester.semantics.tap(node);
      expect(refreshes, 1);

      await tester.pumpWidget(
        host(bytes: _tinyPng(), loading: true, onRefresh: () => refreshes++),
      );
      await tester.pumpAndSettle();
      expect(
        find.semantics
            .byLabel('刷新验证码')
            .evaluate()
            .single
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isFalse,
      );
      handle.dispose();
    });
  });
}
