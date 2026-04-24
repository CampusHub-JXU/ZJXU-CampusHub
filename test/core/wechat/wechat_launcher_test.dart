import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/config/app_config.dart';

void main() {
  test('xiaofubao recharge uri keeps required wechat parameters', () {
    final uri = AppConfig.xiaofubaoRechargeUri;

    expect(uri.toString(), startsWith(AppConfig.xiaofubaoRechargeBaseUrl));
    expect(uri.queryParameters['platform'], 'WECHAT_H5');
    expect(uri.queryParameters['schoolCode'], AppConfig.xiaofubaoSchoolCode);
    expect(uri.queryParameters['thirdAppid'], AppConfig.xiaofubaoThirdAppId);
  });
}
