import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/async/debouncer.dart';
import 'package:jxu_campus_hub/core/async/run_isolated.dart';
import 'package:jxu_campus_hub/core/async/serial_queue.dart';

void main() {
  group('SerialQueue', () {
    test('按提交顺序串行执行，前一个失败不影响后续', () async {
      final queue = SerialQueue();
      final order = <String>[];
      final a = queue.run(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        order.add('a');
      });
      final b = queue.run<void>(() async {
        order.add('b');
        throw StateError('boom');
      });
      final c = queue.run(() async => order.add('c'));
      await a;
      await expectLater(b, throwsStateError);
      await c;
      expect(order, ['a', 'b', 'c']);
    });
  });

  group('Debouncer', () {
    test('只执行最后一次，cancel 可撤销', () async {
      final debouncer = Debouncer(const Duration(milliseconds: 20));
      final calls = <int>[];
      debouncer.run(() => calls.add(1));
      debouncer.run(() => calls.add(2));
      expect(debouncer.isPending, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(calls, [2]);

      debouncer.run(() => calls.add(3));
      debouncer.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(calls, [2]);
    });
  });

  group('runIsolated', () {
    test('吞掉异常并继续', () async {
      var after = false;
      await runIsolated('任务', () async => throw StateError('x'));
      after = true;
      expect(after, isTrue);
    });

    test('成功时执行 action', () async {
      var ran = false;
      await runIsolated('任务', () async => ran = true);
      expect(ran, isTrue);
    });
  });
}
