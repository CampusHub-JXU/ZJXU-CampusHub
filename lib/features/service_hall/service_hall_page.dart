import 'package:flutter/material.dart';

import '../../shared/widgets/webview_page.dart';

class ServiceHallPage extends StatelessWidget {
  const ServiceHallPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const WebViewPage(
      title: '服务大厅',
      url:
          'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home',
    );
  }
}
