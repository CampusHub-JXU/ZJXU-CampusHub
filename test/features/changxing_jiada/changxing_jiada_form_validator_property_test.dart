import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_form_validator.dart';

import '../../helpers/property.dart';

void main() {
  // 混入空白与全角字符，确保校验结果只取决于 trim 后的内容。
  const textAlphabet = '张三李四王五请假事由家庭原因为外地隔离无法按时报到 　１２３Ab1、，。';
  final textGen = stringsOf(textAlphabet, 0, 30);

  group('ChangxingFormValidator.isPhone', () {
    test('任意合法前缀的 11 位数字都通过，其余一律拒绝', () {
      final phoneGen = Gen<String>((random) {
        final prefix = '1${random.nextInt(10)}';
        final rest = List.generate(
          9,
          (_) => random.nextInt(10).toString(),
        ).join();
        return prefix + rest;
      });

      forAll('首位为 1、第二位为任意数字的 11 位号码中，仅 1[3-9] 开头合法', phoneGen, (String phone) {
        final secondDigit = int.parse(phone[1]);
        expect(
          ChangxingFormValidator.isPhone(phone),
          secondDigit >= 3,
          reason: 'phone=$phone',
        );
      });
    });

    test('长度不是 11 的数字串一律不合法', () {
      final badLengthGen = Gen<String>((random) {
        final length = [
          ...List.generate(10, (i) => i),
          12,
          15,
        ][random.nextInt(12)];
        return List.generate(
          length,
          (_) => random.nextInt(10).toString(),
        ).join();
      });

      forAll('长度不为 11 的纯数字串不合法', badLengthGen, (String digits) {
        expect(ChangxingFormValidator.isPhone(digits), isFalse);
      });
    });

    test('isPhone 对任意字符串在 trim 前后结果一致', () {
      forAll('trim 不改变判定结果', textGen, (String value) {
        expect(
          ChangxingFormValidator.isPhone(value),
          ChangxingFormValidator.isPhone(value.trim()),
        );
      });
    });
  });

  group('ChangxingFormValidator.validateContactName', () {
    test('结果由 trim 后长度完全决定（0 空 / 1 过短 / >=10 过长 / 其余通过）', () {
      forAll('姓名校验是 trim 后长度的纯函数', textGen, (String value) {
        final length = value.trim().length;
        final expected = length == 0
            ? '紧急联系人为空'
            : length == 1
            ? '紧急联系人姓名过短'
            : length >= 10
            ? '紧急联系人姓名过长'
            : null;
        expect(ChangxingFormValidator.validateContactName(value), expected);
      });
    });
  });

  group('ChangxingFormValidator.validateReason', () {
    test('空串与超长是仅有的失败分支，且随 maxLength 参数缩放', () {
      forAll(
        '0 < trim 长度 <= maxLength 时通过',
        pair(textGen, intsInRange(1, 50)),
        (values) {
          final (value, maxLength) = values;
          final length = value.trim().length;
          final expected = length == 0
              ? '理由为空'
              : length > maxLength
              ? '理由过长'
              : null;
          expect(
            ChangxingFormValidator.validateReason(
              value,
              emptyMessage: '理由为空',
              tooLongMessage: '理由过长',
              maxLength: maxLength,
            ),
            expected,
          );
        },
      );
    });
  });

  group('ChangxingFormValidator.validateNotBackReason', () {
    test('trim 后长度达到 minLength 即通过', () {
      forAll('不小于 minLength 即通过，否则要求补写', pair(textGen, intsInRange(1, 20)), (
        values,
      ) {
        final (value, minLength) = values;
        final expected = value.trim().length < minLength
            ? '请填写无法报到原因，并不少于10个字'
            : null;
        expect(
          ChangxingFormValidator.validateNotBackReason(
            value,
            minLength: minLength,
          ),
          expected,
        );
      });
    });
  });

  group('ChangxingFormValidator.validateDateOrder', () {
    test('校验通过当且仅当结束时间严格晚于开始时间', () {
      final datetimesGen = Gen<(DateTime, DateTime)>((random) {
        final a = dateTimesNear(
          DateTime(2026, 4, 8),
          minOffsetDays: -30,
          maxOffsetDays: 30,
          withTime: true,
        ).next(random);
        final b = dateTimesNear(
          DateTime(2026, 4, 8),
          minOffsetDays: -30,
          maxOffsetDays: 30,
          withTime: true,
        ).next(random);
        return (a, b);
      });

      forAll('结束时间严格晚于开始时间才通过', datetimesGen, (values) {
        final (a, b) = values;
        expect(
          ChangxingFormValidator.validateDateOrder(a, b),
          b.isAfter(a) ? null : '结束时间需大于开始时间',
        );
        expect(
          ChangxingFormValidator.validateDateOrder(b, a),
          a.isAfter(b) ? null : '结束时间需大于开始时间',
        );
        // 同一对时间不可能两个方向同时通过（除非 a == b，此时都不通过）。
        if (a != b) {
          expect(
            ChangxingFormValidator.validateDateOrder(a, b) == null &&
                ChangxingFormValidator.validateDateOrder(b, a) == null,
            isFalse,
          );
        }
      });
    });
  });
}
