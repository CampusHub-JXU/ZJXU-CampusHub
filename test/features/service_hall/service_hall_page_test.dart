import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/service_hall/service_hall_page.dart';

void main() {
  test('uses the expected service hall protected webview configuration', () {
    expect(ServiceHallPage.titleText, '服务大厅');
    expect(
      ServiceHallPage.homeUrl,
      'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/portal/home',
    );
    expect(
      ServiceHallPage.authServiceUrl,
      'https://newca.zjxu.edu.cn/casClient/login/ydd',
    );
    expect(ServiceHallPage.authLoginDescription, contains('统一认证'));
  });
}
