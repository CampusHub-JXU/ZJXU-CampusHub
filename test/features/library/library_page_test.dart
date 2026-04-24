import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/library/library_page.dart';
import 'package:jxu_campus_hub/shared/widgets/unified_auth_protected_webview_page.dart';

void main() {
  testWidgets('library page uses dedicated unified auth entry', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LibraryPage()));

    final page = tester.widget<UnifiedAuthProtectedWebViewPage>(
      find.byType(UnifiedAuthProtectedWebViewPage),
    );

    expect(page.title, '图书馆');
    expect(
      page.url,
      'https://libapp.zjxu.edu.cn/Info/Thirdparty/ssoFromDingDing',
    );
    expect(
      page.serviceUrl,
      'https://libapp.zjxu.edu.cn/Info/Thirdparty/ssoFromDingDing',
    );
    expect(page.loginDescription, '图书馆仅支持校园网内直连访问，请连接校园网后登录统一认证');
    expect(page.showWebViewBottomBackButton, isTrue);
  });
}
