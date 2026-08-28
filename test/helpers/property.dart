/// 极简属性测试（Property-based Testing）工具。
///
/// 依赖免费、结果可复现：使用固定 `seed` 的 `Random`，失败时打印
/// 反例与 seed，把 seed 写回测试即可稳定复现。
///
/// 特性取舍：不做反例收缩（shrinking），失败信息直接给出原始反例；
/// 对纯函数解析器/校验器而言，反例通常足够小，收缩收益有限。
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

typedef PropertyCheck<T> = FutureOr<void> Function(T value);

/// 随机值生成器：给定 [Random] 产出一个候选输入。
class Gen<T> {
  const Gen(this._generate);

  final T Function(Random random) _generate;

  T next(Random random) => _generate(random);
}

/// `[min, max]` 闭区间内的均匀随机整数。
Gen<int> intsInRange(int min, int max) =>
    Gen((random) => min + random.nextInt(max - min + 1));

Gen<bool> booleans() => Gen((random) => random.nextBool());

/// 从非空候选集中随机选取。
Gen<T> oneOf<T>(List<T> values) {
  assert(values.isNotEmpty);
  return Gen((random) => values[random.nextInt(values.length)]);
}

/// 以 [anchor] 为基准，偏移 `[minOffsetDays, maxOffsetDays]` 天的随机日期。
/// [withTime] 为 true 时附带随机的时分秒，用于校验归一化逻辑。
Gen<DateTime> dateTimesNear(
  DateTime anchor, {
  int minOffsetDays = 0,
  int maxOffsetDays = 0,
  bool withTime = false,
}) {
  return Gen((random) {
    final offsetDays =
        minOffsetDays + random.nextInt(maxOffsetDays - minOffsetDays + 1);
    var value = DateTime(
      anchor.year,
      anchor.month,
      anchor.day,
    ).add(Duration(days: offsetDays));
    if (withTime) {
      value = value.add(
        Duration(
          hours: random.nextInt(24),
          minutes: random.nextInt(60),
          seconds: random.nextInt(60),
        ),
      );
    }
    return value;
  });
}

/// 从 [alphabet] 中随机取样，长度在 `[minLength, maxLength]` 闭区间内。
Gen<String> stringsOf(String alphabet, int minLength, int maxLength) {
  assert(alphabet.isNotEmpty);
  return Gen((random) {
    final length = minLength + random.nextInt(maxLength - minLength + 1);
    return List.generate(
      length,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  });
}

Gen<(A, B)> pair<A, B>(Gen<A> first, Gen<B> second) =>
    Gen((random) => (first.next(random), second.next(random)));

Gen<List<T>> listOf<T>(Gen<T> element, int minLength, int maxLength) {
  return Gen((random) {
    final length = minLength + random.nextInt(maxLength - minLength + 1);
    return List.generate(length, (_) => element.next(random));
  });
}

/// 对 [iterations] 个随机输入反复执行 [check]。
///
/// 任一输入失败即抛出测试失败，并附带：反例值、迭代序号、seed，
/// 便于把该输入固化为一个普通的 `expect` 样例。
Future<void> forAll<T>(
  String description,
  Gen<T> gen,
  PropertyCheck<T> check, {
  int iterations = 200,
  int seed = 20260828,
}) async {
  final random = Random(seed);
  for (var i = 0; i < iterations; i++) {
    final value = gen.next(random);
    Object? failure;
    StackTrace? stackTrace;
    try {
      await check(value);
    } catch (error, trace) {
      failure = error;
      stackTrace = trace;
    }
    if (failure != null) {
      fail(
        '属性不成立: $description\n'
        '反例（第 ${i + 1}/$iterations 次）: $value\n'
        '复现 seed: $seed\n'
        '$failure\n'
        '$stackTrace',
      );
    }
  }
}
