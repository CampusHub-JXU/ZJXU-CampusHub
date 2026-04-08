import 'package:flutter/material.dart';

import '../../shared/widgets/zhengfang_protected_webview_page.dart';

class AcademicServicePage extends StatelessWidget {
  const AcademicServicePage({super.key});

  static const serviceUrl =
      'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html?jsdm=xs';

  @override
  Widget build(BuildContext context) {
    return const ZhengfangProtectedWebViewPage(
      title: '教务系统',
      url: serviceUrl,
      loginDescription: '账号为学号',
    );
  }
}
