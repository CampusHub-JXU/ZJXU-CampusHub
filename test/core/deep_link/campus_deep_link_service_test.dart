import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/actions/campus_action_ids.dart';
import 'package:jxu_campus_hub/core/deep_link/campus_deep_link_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('edu.zjxu.jxucampushub/deeplink');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late ValueNotifier<bool> ready;

  setUp(() {
    ready = ValueNotifier<bool>(true);
    CampusDeepLinkService.instance.debugReset();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    CampusDeepLinkService.instance.debugReset();
  });

  void mockInitial(String? raw) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'consumeInitialDeepLink') return raw;
      return null;
    });
  }

  testWidgets('初始深链解析为 action id 并在就绪后分发', (tester) async {
    mockInitial('jxucampushub://action/${CampusActionIds.campusCardPayment}');
    final dispatched = <String>[];

    await CampusDeepLinkService.instance.initialize(
      navigationReady: ready,
      dispatch: (id) async => dispatched.add(id),
    );
    await tester.pump();

    expect(dispatched, [CampusActionIds.campusCardPayment]);
  });

  testWidgets('导航未就绪时挂起，就绪后补发一次', (tester) async {
    mockInitial('jxucampushub://action/${CampusActionIds.campusCardPayment}');
    ready.value = false;
    final dispatched = <String>[];

    await CampusDeepLinkService.instance.initialize(
      navigationReady: ready,
      dispatch: (id) async => dispatched.add(id),
    );
    await tester.pump();
    expect(dispatched, isEmpty);

    ready.value = true;
    await tester.pump();
    expect(dispatched, [CampusActionIds.campusCardPayment]);

    // 已消费，不会重复补发。
    ready.value = false;
    ready.value = true;
    await tester.pump();
    expect(dispatched, hasLength(1));
  });

  testWidgets('未注册 / 非本 scheme 的深链一律丢弃', (tester) async {
    mockInitial('jxucampushub://action/definitely-not-registered');
    final dispatched = <String>[];

    await CampusDeepLinkService.instance.initialize(
      navigationReady: ready,
      dispatch: (id) async => dispatched.add(id),
    );
    await tester.pump();

    expect(dispatched, isEmpty);
  });

  testWidgets('运行期原生 onDeepLinkAction 回调同样分发', (tester) async {
    mockInitial(null);
    final dispatched = <String>[];
    await CampusDeepLinkService.instance.initialize(
      navigationReady: ready,
      dispatch: (id) async => dispatched.add(id),
    );

    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
        const MethodCall(
          'onDeepLinkAction',
          'jxucampushub://action/${CampusActionIds.shuatiOpen}',
        ),
      ),
      (_) {},
    );
    await tester.pump();

    expect(dispatched, [CampusActionIds.shuatiOpen]);
  });

  testWidgets('通道缺失 / 原生报错不抛出且不分发', (tester) async {
    final dispatched = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException();
    });
    await CampusDeepLinkService.instance.initialize(
      navigationReady: ready,
      dispatch: (id) async => dispatched.add(id),
    );
    await tester.pump();
    expect(dispatched, isEmpty);

    CampusDeepLinkService.instance.debugReset();
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'boom', message: 'native failure');
    });
    await CampusDeepLinkService.instance.initialize(
      navigationReady: ready,
      dispatch: (id) async => dispatched.add(id),
    );
    await tester.pump();
    expect(dispatched, isEmpty);
  });
}
