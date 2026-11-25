import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/maintenance_window.dart';

void main() {
  group('isInMaintenanceWindow', () {
    DateTime at(int hour, int minute, {int day = 15}) =>
        DateTime(2026, 11, day, hour, minute);

    test('23:29 在窗口外', () {
      expect(isInMaintenanceWindow(at(23, 29)), isFalse);
    });

    test('23:30 整进入窗口', () {
      expect(isInMaintenanceWindow(at(23, 30)), isTrue);
    });

    test('23:59 在窗口内', () {
      expect(isInMaintenanceWindow(at(23, 59)), isTrue);
    });

    test('0:00 跨零点仍在窗口内', () {
      expect(isInMaintenanceWindow(at(0, 0, day: 16)), isTrue);
    });

    test('3:30 凌晨在窗口内', () {
      expect(isInMaintenanceWindow(at(3, 30, day: 16)), isTrue);
    });

    test('5:59 在窗口内', () {
      expect(isInMaintenanceWindow(at(5, 59, day: 16)), isTrue);
    });

    test('6:00 整离开窗口', () {
      expect(isInMaintenanceWindow(at(6, 0, day: 16)), isFalse);
    });

    test('白天 12:00 在窗口外', () {
      expect(isInMaintenanceWindow(at(12, 0)), isFalse);
    });

    test('傍晚 18:00 在窗口外', () {
      expect(isInMaintenanceWindow(at(18, 0)), isFalse);
    });
  });

  group('appendMaintenanceHint', () {
    const base = '网络异常，请稍后重试';

    test('维护时段内追加提示后缀', () {
      final result = appendMaintenanceHint(
        base,
        now: DateTime(2026, 11, 15, 23, 45),
      );
      expect(result, '$base$maintenanceHint');
    });

    test('凌晨时段同样追加提示', () {
      final result = appendMaintenanceHint(
        base,
        now: DateTime(2026, 11, 16, 2, 0),
      );
      expect(result, contains(maintenanceHint));
    });

    test('白天文案完全不变', () {
      final result = appendMaintenanceHint(
        base,
        now: DateTime(2026, 11, 15, 10, 0),
      );
      expect(result, base);
    });

    test('窗口边界 6:00 整不追加', () {
      final result = appendMaintenanceHint(
        base,
        now: DateTime(2026, 11, 16, 6, 0),
      );
      expect(result, base);
    });

    test('已含提示的文案不重复追加', () {
      final once = appendMaintenanceHint(
        base,
        now: DateTime(2026, 11, 15, 23, 45),
      );
      final twice = appendMaintenanceHint(
        once,
        now: DateTime(2026, 11, 15, 23, 50),
      );
      expect(twice, once);
    });
  });
}
