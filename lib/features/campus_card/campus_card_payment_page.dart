import 'package:flutter/material.dart';

import '../../shared/widgets/unified_auth_protected_webview_page.dart';
import 'campus_card_service.dart';

class CampusCardPaymentPage extends StatelessWidget {
  const CampusCardPaymentPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const UnifiedAuthProtectedWebViewPage(
      title: '消费码',
      url: CampusCardService.paymentCodeServiceHallUrl,
      serviceUrl: CampusCardService.serviceHallCasServiceUrl,
      loginDescription: '消费码服务使用统一认证登录，账号为校园一卡通号',
    );
  }
}
