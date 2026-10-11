import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/calendar/calendar_sync_channel.dart';
import 'package:jxu_campus_hub/core/calendar/calendar_sync_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(CalendarSyncProtocol.channelName);
  const opaqueA = '11111111-1111-4111-8111-111111111111';
  const opaqueB = '22222222-2222-4222-8222-222222222222';

  final calls = <MethodCall>[];

  void setHandler(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) {
          calls.add(call);
          return handler(call);
        });
  }

  void removeHandler() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  }

  CalendarSyncChannel buildChannel() =>
      MethodChannelCalendarSyncChannel(channel: methodChannel);

  MethodChannelCalendarSyncChannel buildDiscoveryChannel() =>
      MethodChannelCalendarSyncChannel(channel: methodChannel);

  CalendarSyncEventDraft draft({
    String opaqueId = opaqueA,
    String title = '高等数学',
  }) => CalendarSyncEventDraft(
    opaqueId: opaqueId,
    title: title,
    location: '教学楼 A101',
    startMillis: 1700000000000,
    endMillis: 1700003600000,
    reminderMinutes: 10,
    timeZone: 'Asia/Shanghai',
  );

  setUp(() {
    calls.clear();
    removeHandler();
  });

  tearDown(removeHandler);

  test('channel and method names match the fixed protocol', () {
    expect(
      CalendarSyncProtocol.channelName,
      'edu.zjxu.jxucampushub/calendar_sync',
    );
    expect(CalendarSyncProtocol.methodCheckPermissions, 'checkPermissions');
    expect(CalendarSyncProtocol.methodRequestPermissions, 'requestPermissions');
    expect(
      CalendarSyncProtocol.methodCreateOrGetLocalCalendar,
      'createOrGetLocalCalendar',
    );
    expect(
      CalendarSyncProtocol.methodListWritableCalendars,
      'listWritableCalendars',
    );
    expect(CalendarSyncProtocol.methodQueryOwnedEvents, 'queryOwnedEvents');
    expect(CalendarSyncProtocol.methodUpsertEventBatch, 'upsertEventBatch');
    expect(
      CalendarSyncProtocol.methodDeleteOwnedEventsByIds,
      'deleteOwnedEventsByIds',
    );
    expect(
      CalendarSyncProtocol.methodListOwnedEventCalendars,
      'listOwnedEventCalendars',
    );
  });

  group('checkPermissions / requestPermissions', () {
    test('returns true only when native returns literal true', () async {
      setHandler((_) async => true);
      expect(await buildChannel().checkPermissions(), isTrue);

      setHandler((_) async => false);
      expect(await buildChannel().checkPermissions(), isFalse);

      setHandler((_) async => 'true');
      expect(await buildChannel().checkPermissions(), isFalse);
      expect(calls.last.method, 'checkPermissions');
      expect(calls.last.arguments, isNull);
    });

    test('maps platform missing / platform errors to false', () async {
      // 无 handler：MissingPluginException。
      expect(await buildChannel().checkPermissions(), isFalse);

      setHandler(
        (_) async => throw PlatformException(code: 'requests_in_flight'),
      );
      expect(await buildChannel().requestPermissions(), isFalse);

      setHandler((_) async => true);
      expect(await buildChannel().requestPermissions(), isTrue);
      expect(calls.last.method, 'requestPermissions');
    });
  });

  group('createOrGetLocalCalendar', () {
    test('parses the local calendar', () async {
      setHandler(
        (_) async => <String, Object?>{'id': 12, 'displayName': '嘉兴大学课程'},
      );

      final calendar = await buildChannel().createOrGetLocalCalendar();

      expect(calendar.id, 12);
      expect(calendar.displayName, '嘉兴大学课程');
      expect(calls.single.method, 'createOrGetLocalCalendar');
    });

    test('rejects malformed results as typed invalidResponse', () async {
      for (final raw in <Object?>[
        null,
        'x',
        <String, Object?>{'id': 0, 'displayName': 'x'},
        <String, Object?>{'id': 12, 'displayName': '   '},
        <String, Object?>{'id': '12', 'displayName': 'x'},
      ]) {
        setHandler((_) async => raw);
        await expectLater(
          buildChannel().createOrGetLocalCalendar(),
          throwsA(
            isA<CalendarSyncException>().having(
              (error) => error.kind,
              'kind',
              CalendarSyncFailureKind.invalidResponse,
            ),
          ),
        );
      }
    });

    test('maps platform exceptions without swallowing', () async {
      setHandler(
        (_) async => throw PlatformException(code: 'calendar_unavailable'),
      );
      await expectLater(
        buildChannel().createOrGetLocalCalendar(),
        throwsA(
          isA<CalendarSyncException>()
              .having(
                (error) => error.kind,
                'kind',
                CalendarSyncFailureKind.calendarUnavailable,
              )
              .having((error) => error.code, 'code', 'calendar_unavailable'),
        ),
      );

      removeHandler();
      await expectLater(
        buildChannel().createOrGetLocalCalendar(),
        throwsA(
          isA<CalendarSyncException>().having(
            (error) => error.kind,
            'kind',
            CalendarSyncFailureKind.missingPlugin,
          ),
        ),
      );
    });
  });

  group('listWritableCalendars', () {
    test('parses writable calendars including null accountName', () async {
      setHandler(
        (_) async => <Object?>[
          <String, Object?>{
            'id': 1,
            'displayName': '课程表',
            'accountName': 'local@example.com',
          },
          <String, Object?>{
            'id': 2,
            'displayName': '我的日历',
            'accountName': null,
          },
        ],
      );

      final calendars = await buildChannel().listWritableCalendars();

      expect(calendars, hasLength(2));
      expect(calendars.first.accountName, 'local@example.com');
      expect(calendars.last.accountName, isNull);
    });

    test('accepts an empty list', () async {
      setHandler((_) async => <Object?>[]);
      expect(await buildChannel().listWritableCalendars(), isEmpty);
    });

    test('rejects malformed lists', () async {
      for (final raw in <Object?>[
        null,
        'calendars',
        <Object?>[42],
        <Object?>[
          <String, Object?>{'id': 1, 'displayName': 'a'},
          <String, Object?>{'id': 1, 'displayName': 'b'},
        ],
      ]) {
        setHandler((_) async => raw);
        await expectLater(
          buildChannel().listWritableCalendars(),
          throwsA(
            isA<CalendarSyncException>().having(
              (error) => error.kind,
              'kind',
              CalendarSyncFailureKind.invalidResponse,
            ),
          ),
        );
      }
    });
  });

  group('queryOwnedEvents', () {
    test('passes calendarId and optional opaqueIds filter', () async {
      setHandler(
        (_) async => <Object?>[
          <String, Object?>{'opaqueId': opaqueA, 'eventId': 31},
        ],
      );

      final events = await buildChannel().queryOwnedEvents(
        calendarId: 5,
        opaqueIds: <String>[opaqueA],
      );

      expect(events.single.eventId, 31);
      final arguments = calls.single.arguments as Map<Object?, Object?>;
      expect(arguments['calendarId'], 5);
      expect(arguments['opaqueIds'], <Object?>[opaqueA]);
    });

    test('omits the filter key when querying all owned events', () async {
      setHandler((_) async => <Object?>[]);

      await buildChannel().queryOwnedEvents(calendarId: 5);

      final arguments = calls.single.arguments as Map<Object?, Object?>;
      expect(arguments.containsKey('opaqueIds'), isFalse);
    });

    test('rejects unrequested / duplicate / malformed results', () async {
      setHandler(
        (_) async => <Object?>[
          <String, Object?>{'opaqueId': opaqueB, 'eventId': 31},
        ],
      );
      await expectLater(
        buildChannel().queryOwnedEvents(
          calendarId: 5,
          opaqueIds: <String>[opaqueA],
        ),
        throwsA(
          isA<CalendarSyncException>().having(
            (error) => error.kind,
            'kind',
            CalendarSyncFailureKind.invalidResponse,
          ),
        ),
      );

      setHandler(
        (_) async => <Object?>[
          <String, Object?>{'opaqueId': opaqueA, 'eventId': 31},
          <String, Object?>{'opaqueId': opaqueA, 'eventId': 32},
        ],
      );
      await expectLater(
        buildChannel().queryOwnedEvents(calendarId: 5),
        throwsA(
          isA<CalendarSyncException>().having(
            (error) => error.kind,
            'kind',
            CalendarSyncFailureKind.invalidResponse,
          ),
        ),
      );

      setHandler(
        (_) async => <Object?>[
          <String, Object?>{'opaqueId': '2023012345', 'eventId': 31},
        ],
      );
      await expectLater(
        buildChannel().queryOwnedEvents(calendarId: 5),
        throwsA(
          isA<CalendarSyncException>().having(
            (error) => error.kind,
            'kind',
            CalendarSyncFailureKind.invalidResponse,
          ),
        ),
      );
    });

    test(
      'rejects invalid local arguments without touching the channel',
      () async {
        setHandler((_) async => <Object?>[]);

        await expectLater(
          buildChannel().queryOwnedEvents(calendarId: 0),
          throwsA(
            isA<CalendarSyncException>().having(
              (error) => error.kind,
              'kind',
              CalendarSyncFailureKind.invalidArgument,
            ),
          ),
        );
        await expectLater(
          buildChannel().queryOwnedEvents(
            calendarId: 5,
            opaqueIds: <String>['not-an-opaque-id'],
          ),
          throwsA(
            isA<CalendarSyncException>().having(
              (error) => error.kind,
              'kind',
              CalendarSyncFailureKind.invalidArgument,
            ),
          ),
        );
        await expectLater(
          buildChannel().queryOwnedEvents(
            calendarId: 5,
            opaqueIds: <String>[opaqueA, opaqueA],
          ),
          throwsA(
            isA<CalendarSyncException>().having(
              (error) => error.kind,
              'kind',
              CalendarSyncFailureKind.invalidArgument,
            ),
          ),
        );
        await expectLater(
          buildChannel().queryOwnedEvents(
            calendarId: 5,
            opaqueIds: List<String>.filled(
              CalendarSyncProtocol.maxQueryOpaqueIds + 1,
              opaqueA,
            ),
          ),
          throwsA(
            isA<CalendarSyncException>().having(
              (error) => error.kind,
              'kind',
              CalendarSyncFailureKind.invalidArgument,
            ),
          ),
        );

        expect(calls, isEmpty);
      },
    );

    test('maps permission denial to a typed failure', () async {
      setHandler(
        (_) async => throw PlatformException(code: 'permission_denied'),
      );

      await expectLater(
        buildChannel().queryOwnedEvents(calendarId: 5),
        throwsA(
          isA<CalendarSyncException>()
              .having(
                (error) => error.kind,
                'kind',
                CalendarSyncFailureKind.permissionDenied,
              )
              .having(
                (error) => error.isPermissionDenied,
                'isPermissionDenied',
                isTrue,
              ),
        ),
      );
    });
  });

  group('upsertEventBatch', () {
    test('sends exactly the protocol fields and parses the result', () async {
      setHandler(
        (_) async => <String, Object?>{
          'insertedCount': 2,
          'updatedCount': 0,
          'eventIds': <String, Object?>{opaqueA: 41, opaqueB: 42},
        },
      );

      final result = await buildChannel().upsertEventBatch(
        calendarId: 5,
        events: <CalendarSyncEventDraft>[
          draft(),
          draft(opaqueId: opaqueB, title: '大学物理'),
        ],
      );

      expect(result.insertedCount, 2);
      expect(result.eventIds[opaqueB], 42);

      final arguments = calls.single.arguments as Map<Object?, Object?>;
      expect(arguments['calendarId'], 5);
      final events = arguments['events']! as List<Object?>;
      expect(events, hasLength(2));
      for (final rawEvent in events) {
        final event = rawEvent! as Map<Object?, Object?>;
        expect(event.keys.toSet(), <Object?>{
          'opaqueId',
          'title',
          'location',
          'startMillis',
          'endMillis',
          'reminderMinutes',
          'timeZone',
        });
        expect(event.containsKey('studentId'), isFalse);
        expect(event.containsKey('businessKey'), isFalse);
      }
      expect(calls.single.method, 'upsertEventBatch');
    });

    test(
      'rejects invalid local batches without touching the channel',
      () async {
        setHandler(
          (_) async => <String, Object?>{
            'insertedCount': 1,
            'updatedCount': 0,
            'eventIds': <String, Object?>{opaqueA: 41},
          },
        );

        Future<void> expectInvalidArgument(Future<Object?> future) =>
            expectLater(
              future,
              throwsA(
                isA<CalendarSyncException>().having(
                  (error) => error.kind,
                  'kind',
                  CalendarSyncFailureKind.invalidArgument,
                ),
              ),
            );

        await expectInvalidArgument(
          buildChannel().upsertEventBatch(calendarId: 5, events: const []),
        );
        await expectInvalidArgument(
          buildChannel().upsertEventBatch(
            calendarId: 0,
            events: <CalendarSyncEventDraft>[draft()],
          ),
        );
        await expectInvalidArgument(
          buildChannel().upsertEventBatch(
            calendarId: 5,
            events: <CalendarSyncEventDraft>[
              draft(),
              draft(opaqueId: opaqueA, title: '重复'),
            ],
          ),
        );
        await expectInvalidArgument(
          buildChannel().upsertEventBatch(
            calendarId: 5,
            events: <CalendarSyncEventDraft>[draft(title: '   ')],
          ),
        );
        await expectInvalidArgument(
          buildChannel().upsertEventBatch(
            calendarId: 5,
            events: <CalendarSyncEventDraft>[
              for (
                var index = 0;
                index <= CalendarSyncProtocol.maxBatchEvents;
                index++
              )
                draft(opaqueId: CalendarSyncOpaqueId.generate()),
            ],
          ),
        );

        expect(calls, isEmpty);
      },
    );

    test('rejects incomplete or bogus native results', () async {
      Future<void> expectInvalidResponse(Object? raw) async {
        setHandler((_) async => raw);
        await expectLater(
          buildChannel().upsertEventBatch(
            calendarId: 5,
            events: <CalendarSyncEventDraft>[
              draft(),
              draft(opaqueId: opaqueB),
            ],
          ),
          throwsA(
            isA<CalendarSyncException>().having(
              (error) => error.kind,
              'kind',
              CalendarSyncFailureKind.invalidResponse,
            ),
          ),
        );
      }

      // eventIds 未覆盖整批：账本会留下无法确认的 pending，必须拒绝。
      await expectInvalidResponse(<String, Object?>{
        'insertedCount': 1,
        'updatedCount': 0,
        'eventIds': <String, Object?>{opaqueA: 41},
      });
      // 返回了未请求的 opaqueId。
      await expectInvalidResponse(<String, Object?>{
        'insertedCount': 1,
        'updatedCount': 0,
        'eventIds': <String, Object?>{
          opaqueA: 41,
          '33333333-3333-4333-8333-333333333333': 42,
        },
      });
      // 计数与映射不一致。
      await expectInvalidResponse(<String, Object?>{
        'insertedCount': 3,
        'updatedCount': 0,
        'eventIds': <String, Object?>{opaqueA: 41, opaqueB: 42},
      });
      await expectInvalidResponse(null);
    });

    test('maps platform batch failure without faking success', () async {
      setHandler((_) async => throw PlatformException(code: 'batch_failed'));

      await expectLater(
        buildChannel().upsertEventBatch(
          calendarId: 5,
          events: <CalendarSyncEventDraft>[draft()],
        ),
        throwsA(
          isA<CalendarSyncException>()
              .having(
                (error) => error.kind,
                'kind',
                CalendarSyncFailureKind.batchFailed,
              )
              .having((error) => error.code, 'code', 'batch_failed'),
        ),
      );
    });
  });

  group('deleteOwnedEventsByIds', () {
    test('sends opaqueId + eventId and returns full classification', () async {
      setHandler(
        (_) async => <String, Object?>{
          'deletedIds': <Object?>[41],
          'notDeletedIds': <Object?>[42],
        },
      );

      final result = await buildChannel().deleteOwnedEventsByIds(
        calendarId: 5,
        events: const <CalendarSyncOwnedEvent>[
          CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 41),
          CalendarSyncOwnedEvent(opaqueId: opaqueB, eventId: 42),
        ],
      );

      expect(result.deletedIds, <int>[41]);
      expect(result.notDeletedIds, <int>[42]);
      expect(result.isComplete, isFalse);

      final arguments = calls.single.arguments as Map<Object?, Object?>;
      final events = arguments['events']! as List<Object?>;
      expect((events.first! as Map<Object?, Object?>).keys.toSet(), <Object?>{
        'opaqueId',
        'eventId',
      });
    });

    test(
      'rejects invalid local batches without touching the channel',
      () async {
        setHandler(
          (_) async => <String, Object?>{
            'deletedIds': <Object?>[],
            'notDeletedIds': <Object?>[41],
          },
        );

        Future<void> expectInvalidArgument(Future<Object?> future) =>
            expectLater(
              future,
              throwsA(
                isA<CalendarSyncException>().having(
                  (error) => error.kind,
                  'kind',
                  CalendarSyncFailureKind.invalidArgument,
                ),
              ),
            );

        await expectInvalidArgument(
          buildChannel().deleteOwnedEventsByIds(
            calendarId: 5,
            events: const [],
          ),
        );
        await expectInvalidArgument(
          buildChannel().deleteOwnedEventsByIds(
            calendarId: 5,
            events: const <CalendarSyncOwnedEvent>[
              CalendarSyncOwnedEvent(opaqueId: 'bad', eventId: 41),
            ],
          ),
        );
        await expectInvalidArgument(
          buildChannel().deleteOwnedEventsByIds(
            calendarId: 5,
            events: const <CalendarSyncOwnedEvent>[
              CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 0),
            ],
          ),
        );
        await expectInvalidArgument(
          buildChannel().deleteOwnedEventsByIds(
            calendarId: 5,
            events: const <CalendarSyncOwnedEvent>[
              CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 41),
              CalendarSyncOwnedEvent(opaqueId: opaqueB, eventId: 41),
            ],
          ),
        );
        await expectInvalidArgument(
          buildChannel().deleteOwnedEventsByIds(
            calendarId: 5,
            events: const <CalendarSyncOwnedEvent>[
              CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 41),
              CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 42),
            ],
          ),
        );

        expect(calls, isEmpty);
      },
    );

    test('rejects results that do not classify every requested id', () async {
      Future<void> expectInvalidResponse(Object? raw) async {
        setHandler((_) async => raw);
        await expectLater(
          buildChannel().deleteOwnedEventsByIds(
            calendarId: 5,
            events: const <CalendarSyncOwnedEvent>[
              CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 41),
              CalendarSyncOwnedEvent(opaqueId: opaqueB, eventId: 42),
            ],
          ),
          throwsA(
            isA<CalendarSyncException>().having(
              (error) => error.kind,
              'kind',
              CalendarSyncFailureKind.invalidResponse,
            ),
          ),
        );
      }

      // 少分类一个 id。
      await expectInvalidResponse(<String, Object?>{
        'deletedIds': <Object?>[41],
        'notDeletedIds': <Object?>[],
      });
      // 同时出现在两个列表。
      await expectInvalidResponse(<String, Object?>{
        'deletedIds': <Object?>[41],
        'notDeletedIds': <Object?>[41, 42],
      });
      // 未请求的 id。
      await expectInvalidResponse(<String, Object?>{
        'deletedIds': <Object?>[41, 42, 99],
        'notDeletedIds': <Object?>[],
      });
      // 重复项。
      await expectInvalidResponse(<String, Object?>{
        'deletedIds': <Object?>[41, 41],
        'notDeletedIds': <Object?>[42],
      });
      await expectInvalidResponse(null);
    });

    test('maps permission denial to a typed failure', () async {
      setHandler(
        (_) async => throw PlatformException(code: 'permission_denied'),
      );

      await expectLater(
        buildChannel().deleteOwnedEventsByIds(
          calendarId: 5,
          events: const <CalendarSyncOwnedEvent>[
            CalendarSyncOwnedEvent(opaqueId: opaqueA, eventId: 41),
          ],
        ),
        throwsA(
          isA<CalendarSyncException>().having(
            (error) => error.kind,
            'kind',
            CalendarSyncFailureKind.permissionDenied,
          ),
        ),
      );
    });
  });

  group('listOwnedEventCalendars (read-only discovery)', () {
    test('sends an empty payload and parses a complete scan', () async {
      setHandler(
        (_) async => <String, Object?>{
          'calendars': <Object?>[
            <String, Object?>{
              'calendarId': 5,
              'displayName': '嘉兴大学课程',
              'writable': true,
            },
            <String, Object?>{
              'calendarId': 7,
              'displayName': '只读日历',
              'writable': false,
            },
          ],
          'complete': true,
          'reason': null,
        },
      );

      final discovery = await buildDiscoveryChannel().listOwnedEventCalendars();

      expect(discovery.complete, isTrue);
      expect(discovery.reason, isNull);
      expect(discovery.calendars, hasLength(2));
      expect(discovery.calendars.first.calendarId, 5);
      expect(discovery.calendars.last.writable, isFalse);
      expect(discovery.hasUnknownMetadata, isFalse);

      final call = calls.single;
      expect(call.method, 'listOwnedEventCalendars');
      final arguments = call.arguments as Map<Object?, Object?>;
      // 只读、无输入：绝不夹带 opaqueIds / 路径 / owner 包名。
      expect(arguments, isEmpty);
    });

    test('downgrades malformed rows to an incomplete scan', () async {
      setHandler(
        (_) async => <String, Object?>{
          'calendars': <Object?>[
            <String, Object?>{'calendarId': 5, 'writable': true},
            <String, Object?>{'calendarId': 0},
            'not-a-map',
            <String, Object?>{'calendarId': 5, 'writable': false},
          ],
          'complete': true,
          'reason': null,
        },
      );

      final discovery = await buildDiscoveryChannel().listOwnedEventCalendars();

      // 保留唯一合法行，但绝不把残缺结果当「完整 / 空即干净」。
      expect(discovery.complete, isFalse);
      expect(discovery.reason, CalendarOwnedDiscoveryReason.unavailable);
      expect(discovery.calendars.single.calendarId, 5);
    });

    test('keeps the native incomplete reason', () async {
      setHandler(
        (_) async => <String, Object?>{
          'calendars': <Object?>[
            <String, Object?>{'calendarId': 9, 'writable': null},
          ],
          'complete': false,
          'reason': 'calendarUnavailable',
        },
      );

      final discovery = await buildDiscoveryChannel().listOwnedEventCalendars();

      expect(discovery.complete, isFalse);
      expect(
        discovery.reason,
        CalendarOwnedDiscoveryReason.calendarUnavailable,
      );
      expect(discovery.hasUnknownMetadata, isTrue);
    });

    test('degrades platform failures to typed conservative results', () async {
      // 无 handler → MissingPluginException。
      final missing = await buildDiscoveryChannel().listOwnedEventCalendars();
      expect(missing.complete, isFalse);
      expect(missing.reason, CalendarOwnedDiscoveryReason.unavailable);
      expect(missing.calendars, isEmpty);

      setHandler(
        (_) async => throw PlatformException(code: 'permission_denied'),
      );
      final denied = await buildDiscoveryChannel().listOwnedEventCalendars();
      expect(denied.complete, isFalse);
      expect(denied.reason, CalendarOwnedDiscoveryReason.permissionDenied);

      setHandler(
        (_) async => throw PlatformException(code: 'provider_unavailable'),
      );
      final unavailable = await buildDiscoveryChannel()
          .listOwnedEventCalendars();
      expect(unavailable.complete, isFalse);
      expect(unavailable.reason, CalendarOwnedDiscoveryReason.unavailable);
    });

    test('rejects malformed top-level payloads as unavailable', () async {
      for (final raw in <Object?>[
        null,
        'x',
        <String, Object?>{'complete': true, 'reason': null},
        <String, Object?>{'calendars': <Object?>[], 'complete': 'true'},
        <String, Object?>{
          'calendars': <Object?>[],
          'complete': true,
          'reason': 'bogus',
        },
      ]) {
        setHandler((_) async => raw);
        final discovery = await buildDiscoveryChannel()
            .listOwnedEventCalendars();
        expect(discovery.complete, isFalse);
        expect(discovery.reason, CalendarOwnedDiscoveryReason.unavailable);
      }
    });
  });
}
