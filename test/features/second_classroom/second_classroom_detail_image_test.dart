import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/features/second_classroom/second_classroom_cache_store.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_model.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_page.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_service.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_subscription_service.dart';
import 'package:jxu_campus_hub/shared/widgets/app_status_tag.dart';

/// 回归 issue #86：详情页顶部图片（报名二维码）此前被 16:9 `BoxFit.cover` 裁切、
/// 且整块不可点击。这里用假网络覆盖：完整 1:1 展示 / 加载中 / 加载失败 / 无图 /
/// 点击预览 / 窄屏 + 大字号不溢出。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const imageKey = ValueKey<String>('activity_detail_image:0');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _clearImageCache();
  });

  tearDown(_clearImageCache);

  testWidgets('详情图完整展示：1:1 外框 + contain，不裁切', (tester) async {
    await _withFakeImages(_FakeImageMode.pending, () async {
      await _pumpPage(tester, coverUrl: 'https://dekt.test/qr.png');
      await _openDetailSheet(tester);

      final imageFinder = find.byKey(imageKey);
      expect(imageFinder, findsOneWidget);

      // 图片不再按封面裁切。
      expect(tester.widget<Image>(imageFinder).fit, BoxFit.contain);

      // 外框固定 1:1。
      final aspect = tester.widget<AspectRatio>(
        find
            .ancestor(of: imageFinder, matching: find.byType(AspectRatio))
            .first,
      );
      expect(aspect.aspectRatio, 1);

      // 图片外面留了白边（quiet zone）：外层 Padding 有正的四周内边距。
      final padding = tester.widget<Padding>(
        find.ancestor(of: imageFinder, matching: find.byType(Padding)).first,
      );
      final insets = padding.padding as EdgeInsets;
      expect(insets.left, greaterThan(0));
      expect(insets.top, insets.left);
      expect(insets.bottom, insets.left);
      expect(insets.right, insets.left);

      // 加载中有反馈，不是空白区。
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('招募状态标签移到 1:1 图片区域之外，不遮挡二维码', (tester) async {
    await _withFakeImages(_FakeImageMode.pending, () async {
      await _pumpPage(tester, coverUrl: 'https://dekt.test/qr.png');
      await _openDetailSheet(tester);

      final imageFinder = find.byKey(imageKey);
      expect(imageFinder, findsOneWidget);

      // 状态标签仍保留（元数据不丢）：定位到详情图片组件内部那一个。
      final detailImageColumn = find
          .ancestor(of: imageFinder, matching: find.byType(Column))
          .first;
      final tagFinder = find.descendant(
        of: detailImageColumn,
        matching: find.byType(AppStatusTag),
      );
      expect(tagFinder, findsOneWidget);
      expect(
        tester.widget<AppStatusTag>(tagFinder).tone,
        AppStatusTone.positive,
      );

      final imageRect = tester.getRect(imageFinder);
      final frameRect = tester.getRect(
        find
            .ancestor(of: imageFinder, matching: find.byType(AspectRatio))
            .first,
      );
      final tagRect = tester.getRect(tagFinder);

      // 标签完全在 1:1 外框之上：与图片像素、与图片外框都不重叠。
      expect(tagRect.overlaps(imageRect), isFalse);
      expect(tagRect.overlaps(frameRect), isFalse);
      expect(tagRect.bottom, lessThanOrEqualTo(frameRect.top));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('无二维码数据时给出简短占位文案', (tester) async {
    await _pumpPage(tester, coverUrl: '');
    await _openDetailSheet(tester);

    expect(find.text('暂无活动图片'), findsOneWidget);
    expect(find.byKey(imageKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('加载失败给出简短文案并可重试', (tester) async {
    final client = _FakeImageHttpClient(mode: _FakeImageMode.error);
    await _withClient(client, () async {
      await _pumpPage(tester, coverUrl: 'https://dekt.test/qr.png');
      await _openDetailSheet(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('图片加载失败'), findsOneWidget);
      expect(find.text('重试'), findsWidgets);

      final before = client.getUrlCalls;
      await tester.tap(find.text('重试').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 重试会重新发起请求。
      expect(client.getUrlCalls, greaterThan(before));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('点击二维码打开可缩放的大图预览，可关闭返回', (tester) async {
    await _withFakeImages(_FakeImageMode.pending, () async {
      await _pumpPage(tester, coverUrl: 'https://dekt.test/qr.png');
      await _openDetailSheet(tester);

      expect(find.byType(InteractiveViewer), findsNothing);

      await tester.tap(find.byKey(imageKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('活动图片'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byTooltip('关闭'), findsOneWidget);

      await tester.tap(find.byTooltip('关闭'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byType(InteractiveViewer), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('窄屏 + 系统字体放大时详情弹层不溢出且可滚动', (tester) async {
    tester.view.physicalSize = const Size(640, 1280); // 320 逻辑宽 @dpr 2
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await _withFakeImages(_FakeImageMode.pending, () async {
      await _pumpPage(tester, coverUrl: 'https://dekt.test/qr.png');
      await _openDetailSheet(tester);

      expect(tester.takeException(), isNull);
      expect(find.byKey(imageKey), findsOneWidget);
      // 弹层内容走 ListView，可滚动查看完整信息。
      expect(find.byType(ListView), findsWidgets);

      // 在弹层里向上滚动不应抛异常。
      await tester.drag(find.byType(ListView).last, const Offset(0, -160));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}

/// 假图片网络 + 测试体内复位：painting debug 变量必须在测试体结束前清空，
/// 否则 `TestWidgetsFlutterBinding` 的 invariant 会失败。
Future<void> _withFakeImages(
  _FakeImageMode mode,
  Future<void> Function() body,
) {
  return _withClient(_FakeImageHttpClient(mode: mode), body);
}

Future<void> _withClient(
  _FakeImageHttpClient client,
  Future<void> Function() body,
) async {
  debugNetworkImageHttpClientProvider = () => client;
  try {
    await body();
  } finally {
    debugNetworkImageHttpClientProvider = null;
  }
}

void _clearImageCache() {
  PaintingBinding.instance.imageCache
    ..clear()
    ..clearLiveImages();
}

Future<void> _pumpPage(WidgetTester tester, {required String coverUrl}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SecondClassroomPage(
        service: _FakeSecondClassroomService(coverUrl: coverUrl),
        subscriptionService: _testSubscriptionService(),
        cacheStore: _MemoryCacheStore(),
      ),
    ),
  );
  // 页面首帧：异步缓存 / 列表用假服务同步完成；图片可能是 pending，不能用
  // pumpAndSettle（加载动画会一直转）。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _openDetailSheet(WidgetTester tester) async {
  await tester.tap(find.text('榜样分享活动'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

SecondClassroomSubscriptionService _testSubscriptionService() {
  return SecondClassroomSubscriptionService(
    notifyRecruitingActivity: ({
      required id,
      required title,
      required body,
      required payload,
    }) async {},
  );
}

class _FakeSecondClassroomService extends SecondClassroomService {
  _FakeSecondClassroomService({required this.coverUrl});

  final String coverUrl;

  @override
  Future<SecondClassroomCatalog> fetchCatalog() async {
    return const SecondClassroomCatalog(
      categories: [SecondClassroomFilterOption(value: '1', text: '思想成长')],
      departments: [SecondClassroomFilterOption(value: '51', text: '建筑工程学院')],
      organizationTypes: [
        SecondClassroomFilterOption(value: '2', text: '学生部门'),
      ],
    );
  }

  @override
  Future<SecondClassroomActivityPage> searchActivities(
    SecondClassroomActivityQuery query,
  ) async {
    return SecondClassroomActivityPage(
      items: [_activity],
      pageIndex: query.page,
      pageSize: query.limit,
      totalPages: 1,
      count: 1,
    );
  }

  @override
  Future<SecondClassroomActivityDetail> fetchActivityDetail(int id) async {
    return SecondClassroomActivityDetail(
      activity: _activity,
      signUpMode: '报名无需审核，人满即止',
      limitedCollege: '不限',
      limitedGrade: '不限',
      hasCredit: false,
      isFavorite: false,
      isInRegistrationTime: true,
    );
  }

  @override
  String imageUrl(String imageId) => coverUrl;
}

final _activity = SecondClassroomActivity(
  id: 2485,
  title: '榜样分享活动',
  coverId: 'qr-image-id',
  iconId: '',
  registrationStartAt: DateTime(2026, 6, 8),
  registrationEndAt: DateTime.now().add(const Duration(days: 2)),
  activityStartAt: DateTime.now().add(const Duration(days: 3)),
  activityEndAt: DateTime.now().add(const Duration(days: 3, hours: 2)),
  creditHours: 0,
  location: '兴德楼北楼201',
  summary: '报名成功后加群',
  contactName: '张展健',
  contactPhone: '18536419261',
  categoryName: '思想成长',
  organizerName: '建工学院团委学生会',
  capacity: 90,
  enrolledCount: 31,
  isRegistered: false,
  hasCheckedIn: false,
  hasRetaken: false,
);

/// 内存缓存替身：widget 测试跑在 FakeAsync 区，真实 [JsonCacheStore] 文件 I/O
/// 不会完成，pumpAndSettle 会超时。
class _MemoryCacheStore implements SecondClassroomCacheStore {
  SecondClassroomCatalog? _catalog;
  final _activities = <String, SecondClassroomActivityCacheSnapshot>{};

  String _key(SecondClassroomActivityQuery query) =>
      '${query.categoryId}|${query.status.value}|${query.departmentId}|'
      '${query.sort.value}|${query.organizationType.value}|${query.keyword}';

  @override
  Future<SecondClassroomCatalog?> loadCatalog() async => _catalog;

  @override
  Future<void> saveCatalog(SecondClassroomCatalog catalog) async {
    _catalog = catalog;
  }

  @override
  Future<SecondClassroomActivityCacheSnapshot?> loadActivities(
    SecondClassroomActivityQuery query,
  ) async => _activities[_key(query)];

  @override
  Future<void> saveActivities(
    SecondClassroomActivityQuery query,
    List<SecondClassroomActivity> activities,
  ) async {
    _activities[_key(query)] = SecondClassroomActivityCacheSnapshot(
      activities: activities,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<void> debugClear() async {
    _catalog = null;
    _activities.clear();
  }
}

enum _FakeImageMode { pending, success, error }

/// 受控的假图片网络：不触网，按 [mode] 返回 pending / 合成 PNG / 404。
class _FakeImageHttpClient extends Fake implements HttpClient {
  _FakeImageHttpClient({required this.mode});

  final _FakeImageMode mode;
  int getUrlCalls = 0;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    getUrlCalls++;
    return _FakeImageRequest(mode);
  }
}

class _FakeImageRequest extends Fake implements HttpClientRequest {
  _FakeImageRequest(this.mode);

  final _FakeImageMode mode;

  @override
  final HttpHeaders headers = _FakeImageHeaders();

  @override
  Future<HttpClientResponse> close() async {
    return switch (mode) {
      _FakeImageMode.error => _FakeImageResponse(
        statusCode: HttpStatus.notFound,
        content: const [],
      ),
      _FakeImageMode.pending => _FakeImageResponse(
        statusCode: HttpStatus.ok,
        content: const [],
        pending: true,
      ),
      _FakeImageMode.success => _FakeImageResponse(
        statusCode: HttpStatus.ok,
        content: [_syntheticPng],
      ),
    };
  }
}

class _FakeImageResponse extends Fake implements HttpClientResponse {
  _FakeImageResponse({
    required this.statusCode,
    required this.content,
    this.pending = false,
  });

  @override
  final int statusCode;

  final List<List<int>> content;
  final bool pending;
  bool drained = false;

  @override
  int get contentLength {
    var total = 0;
    for (final chunk in content) {
      total += chunk.length;
    }
    return total;
  }

  @override
  HttpHeaders headers = _FakeImageHeaders();

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (pending) {
      // 永不发送事件也不关闭：模拟还在下载的二维码。
      return _neverEndingStream.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
    }
    return Stream<List<int>>.fromIterable(content).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Future<E> drain<E>([E? futureValue]) async {
    drained = true;
    return futureValue as E;
  }
}

class _FakeImageHeaders extends Fake implements HttpHeaders {
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}
}

final Stream<List<int>> _neverEndingStream =
    StreamController<List<int>>.broadcast().stream;

/// 1×1 透明 PNG（合成、安全、不含任何个人信息）。
final List<int> _syntheticPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE'
  'hQGAhKmMIQAAAABJRU5ErkJggg==',
);
