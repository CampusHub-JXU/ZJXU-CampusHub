import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/campus_card/campus_card_service.dart';

void main() {
  test('exposes stable campus card payment service hall urls', () {
    expect(
      CampusCardService.paymentCodeServiceHallUrl,
      'https://mobilehall.zjxu.edu.cn/mportal/start/index.html#/business/ydd/wfw/id=ED8D7B51A2422411E0532602010A9D8D',
    );
    expect(
      CampusCardService.serviceHallCasServiceUrl,
      'https://newca.zjxu.edu.cn/casClient/login/ydd?services=business%2Fydd%2Fwfw',
    );
  });
}
