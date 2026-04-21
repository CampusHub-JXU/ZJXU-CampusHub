import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/unified_auth_protected_webview_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  static const _libraryUrl =
      'https://libapp.zjxu.edu.cn/Info/Thirdparty/ssoFromDingDing';

  @override
  Widget build(BuildContext context) {
    return UnifiedAuthProtectedWebViewPage(
      title: '图书馆',
      url: _libraryUrl,
      serviceUrl: _libraryUrl,
      loginDescription: '图书馆仅支持校园网内直连访问，请连接校园网后登录统一认证',
      showWebViewBottomBackButton: true,
      onHomePressed: () => context.goNamed('home'),
    );
  }
}
