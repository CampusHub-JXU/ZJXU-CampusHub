import 'package:flutter/material.dart';

import '../../shared/widgets/webview_page.dart';
import 'campus_card_service.dart';

class CampusCardPaymentPage extends StatelessWidget {
  const CampusCardPaymentPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const WebViewPage(
      title: '消费码',
      url: CampusCardService.paymentCodeEntryUrl,
    );
  }
}
