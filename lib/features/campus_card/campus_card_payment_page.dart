import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../shared/widgets/unified_auth_protected_webview_page.dart';
import 'campus_card_service.dart';

class CampusCardPaymentPage extends StatelessWidget {
  const CampusCardPaymentPage({super.key});

  static Future<void> _autoClick(
    InAppWebViewController controller,
    String currentUrl,
  ) async {
    if (!currentUrl.contains('/business/ydd/wfw')) return;
    await controller.evaluateJavascript(source: '''
      (function() {
        var attempts = 0;
        var interval = setInterval(function() {
          if (++attempts > 20) { clearInterval(interval); return; }
          var items = document.querySelectorAll('#wfwbd .fk-list');
          if (!items.length) return;
          clearInterval(interval);
          for (var i = 0; i < items.length; i++) {
            var t = items[i].querySelector('.fk-text');
            if (t && t.innerText.trim() === '\u6d88\u8d39\u7801') {
              items[i].click();
              return;
            }
          }
        }, 300);
      })();
    ''');
  }

  @override
  Widget build(BuildContext context) {
    return UnifiedAuthProtectedWebViewPage(
      title: '消费码',
      url: CampusCardService.paymentCodeServiceHallUrl,
      serviceUrl: CampusCardService.serviceHallCasServiceUrl,
      loginDescription: '消费码服务使用统一认证登录，账号为校园一卡通号',
      onLoadStop: _autoClick,
    );
  }
}
