import 'package:flutter/material.dart';

import '../../core/auth/unified_auth.dart';
import '../../shared/widgets/unified_auth_protected_webview_page.dart';
import 'campus_card_service.dart';

class CampusCardPaymentPage extends StatelessWidget {
  const CampusCardPaymentPage({super.key});

  @override
  Widget build(BuildContext context) {
    return UnifiedAuthProtectedWebViewPage(
      title: '消费码',
      url: CampusCardService.paymentCodeServiceHallUrl,
      serviceUrl: UnifiedAuthService.defaultServiceUrl,
      loginDescription: '统一认证登录后可直接进入消费码服务',
    );
  }
}
