import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/webview_page.dart';

/// 嘉大微生活（PRD 0.7.0 §26）。
///
/// 0.7 首版先用内部 H5 WebView 承接；后续按使用价值与接口逆向情况再考虑原生。
class MicroLifePage extends StatelessWidget {
  const MicroLifePage({super.key});

  static const titleText = '嘉大微生活';
  static const homeUrl =
      'http://jdhq.wap.zjxu.edu.cn/Base/Center/center/account_id/6';

  @override
  Widget build(BuildContext context) {
    return WebViewPage(
      title: titleText,
      url: homeUrl,
      showWebViewBottomBackButton: true,
      onHomePressed: () => context.goNamed('home'),
    );
  }
}
