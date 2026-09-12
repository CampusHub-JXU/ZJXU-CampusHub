import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/micro_life/micro_life_page.dart';
import 'package:jxu_campus_hub/shared/widgets/webview_page.dart';

class _FakeInAppWebViewPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    return _FakePlatformInAppWebViewWidget(params);
  }
}

class _FakePlatformInAppWebViewWidget extends PlatformInAppWebViewWidget {
  _FakePlatformInAppWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) {
    throw UnimplementedError('Controller is not used by this test fake.');
  }

  @override
  void dispose() {}
}

void main() {
  setUpAll(() {
    InAppWebViewPlatform.instance = _FakeInAppWebViewPlatform();
  });

  testWidgets('嘉大微生活以应用内 WebView 打开后勤 H5', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MicroLifePage()));
    await tester.pump();

    final page = tester.widget<WebViewPage>(find.byType(WebViewPage));
    expect(page.title, MicroLifePage.titleText);
    expect(
      page.url,
      'http://jdhq.wap.zjxu.edu.cn/Base/Center/center/account_id/6',
    );
    expect(page.showWebViewBottomBackButton, isTrue);
  });
}
