import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/actions/pending_action_inbox.dart';

void main() {
  testWidgets('就绪前挂起，就绪后投递最新一条且只投递一次', (tester) async {
    final ready = ValueNotifier<bool>(false);
    final delivered = <String>[];
    final inbox = PendingActionInbox(deliver: delivered.add)
      ..navigationReady = ready
      ..ensureListening();

    inbox.queue('a');
    inbox.queue('b');
    await tester.pump();
    expect(delivered, isEmpty);

    ready.value = true;
    await tester.pump();
    expect(delivered, ['b']);

    ready.value = false;
    ready.value = true;
    await tester.pump();
    expect(delivered, ['b']);
    inbox.reset();
  });

  testWidgets('canDeliver 为 false 时保留挂起动作', (tester) async {
    final ready = ValueNotifier<bool>(true);
    var allowed = false;
    final delivered = <String>[];
    final inbox = PendingActionInbox(
      deliver: delivered.add,
      canDeliver: () => allowed,
    )..navigationReady = ready;

    inbox.queue('a');
    await tester.pump();
    expect(delivered, isEmpty);

    allowed = true;
    inbox.flush();
    await tester.pump();
    expect(delivered, ['a']);
  });
}
