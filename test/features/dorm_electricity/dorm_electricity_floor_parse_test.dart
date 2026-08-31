import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';

void main() {
  group('DormElectricityService.parseFloorLabel', () {
    test('三位数字：首位为楼层、末两位为序号', () {
      expect(DormElectricityService.parseFloorLabel('HX4-105'), '1楼');
      expect(DormElectricityService.parseFloorLabel('HX4-111'), '1楼');
      expect(DormElectricityService.parseFloorLabel('HX4-305'), '3楼');
    });

    test('四位数字：前两位为楼层（10 楼以上）', () {
      expect(DormElectricityService.parseFloorLabel('HX4-1005'), '10楼');
      expect(DormElectricityService.parseFloorLabel('HX4-1111'), '11楼');
    });

    test('容忍尾缀「号」与首尾空白', () {
      expect(DormElectricityService.parseFloorLabel('HX4-105号'), '1楼');
      expect(DormElectricityService.parseFloorLabel(' HX4-206 '), '2楼');
    });

    test('解析不出时返回 null', () {
      expect(DormElectricityService.parseFloorLabel('默认楼层'), isNull);
      expect(DormElectricityService.parseFloorLabel('走廊灯-01'), isNull);
      expect(DormElectricityService.parseFloorLabel(''), isNull);
      expect(DormElectricityService.parseFloorLabel('HX4-'), isNull);
    });
  });
}
