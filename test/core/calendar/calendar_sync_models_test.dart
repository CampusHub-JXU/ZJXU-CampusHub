import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/calendar/calendar_sync_models.dart';

void main() {
  group('CalendarSyncOpaqueId', () {
    test('generates canonical UUID v4 with RFC 4122 variant', () {
      final pattern = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
        r'[0-9a-f]{12}$',
      );

      for (var index = 0; index < 200; index++) {
        final opaqueId = CalendarSyncOpaqueId.generate();
        expect(opaqueId, matches(pattern));
        expect(CalendarSyncOpaqueId.isValid(opaqueId), isTrue);
      }
    });

    test('generates unique values', () {
      final generated = <String>{
        for (var index = 0; index < 500; index++)
          CalendarSyncOpaqueId.generate(),
      };
      expect(generated, hasLength(500));
    });

    test('honours the injected random source', () {
      final first = CalendarSyncOpaqueId.generate(random: Random(7));
      final second = CalendarSyncOpaqueId.generate(random: Random(7));
      final third = CalendarSyncOpaqueId.generate(random: Random(8));

      expect(first, second);
      expect(first, isNot(third));
    });

    test('accepts the same forms as the native contract', () {
      expect(
        CalendarSyncOpaqueId.isValid('11111111-1111-4111-8111-111111111111'),
        isTrue,
      );
      expect(
        CalendarSyncOpaqueId.isValid('AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'),
        isTrue,
      );
      expect(CalendarSyncOpaqueId.isValid('0123456789abcdef'), isTrue);
      expect(CalendarSyncOpaqueId.isValid('A'.padRight(64, 'A')), isTrue);
    });

    test('rejects non-random / malformed identifiers', () {
      expect(CalendarSyncOpaqueId.isValid(''), isFalse);
      expect(CalendarSyncOpaqueId.isValid('0123456789abcde'), isFalse);
      expect(CalendarSyncOpaqueId.isValid('A'.padRight(65, 'A')), isFalse);
      expect(CalendarSyncOpaqueId.isValid('not-a-uuid'), isFalse);
      expect(
        CalendarSyncOpaqueId.isValid('11111111-1111-4111-8111-11111111111z'),
        isFalse,
      );
      // 学号 / 课程名等业务信息不是合法 opaqueId。
      expect(CalendarSyncOpaqueId.isValid('2023012345'), isFalse);
      expect(CalendarSyncOpaqueId.isValid('高等数学'), isFalse);
    });
  });

  group('CalendarSyncLocalCalendar', () {
    test('parses the fixed protocol shape', () {
      final calendar = CalendarSyncLocalCalendar.tryParse(<String, Object?>{
        'id': 42,
        'displayName': '嘉兴大学课程',
      });

      expect(calendar, isNotNull);
      expect(calendar!.id, 42);
      expect(calendar.displayName, '嘉兴大学课程');
    });

    test('rejects null / malformed payloads', () {
      expect(CalendarSyncLocalCalendar.tryParse(null), isNull);
      expect(CalendarSyncLocalCalendar.tryParse('id'), isNull);
      expect(
        CalendarSyncLocalCalendar.tryParse(<String, Object?>{'id': 42}),
        isNull,
      );
      expect(
        CalendarSyncLocalCalendar.tryParse(<String, Object?>{
          'id': 0,
          'displayName': 'x',
        }),
        isNull,
      );
      expect(
        CalendarSyncLocalCalendar.tryParse(<String, Object?>{
          'id': -1,
          'displayName': 'x',
        }),
        isNull,
      );
      expect(
        CalendarSyncLocalCalendar.tryParse(<String, Object?>{
          'id': '42',
          'displayName': 'x',
        }),
        isNull,
      );
      expect(
        CalendarSyncLocalCalendar.tryParse(<String, Object?>{
          'id': 42,
          'displayName': '   ',
        }),
        isNull,
      );
    });
  });

  group('CalendarSyncWritableCalendar', () {
    test('parses accountName and normalizes blank to null', () {
      final withAccount = CalendarSyncWritableCalendar.tryParse(
        <String, Object?>{
          'id': 7,
          'displayName': '课程表',
          'accountName': 'local@example.com',
        },
      );
      expect(withAccount?.accountName, 'local@example.com');

      final blankAccount = CalendarSyncWritableCalendar.tryParse(
        <String, Object?>{'id': 7, 'displayName': '课程表', 'accountName': ' '},
      );
      expect(blankAccount, isNotNull);
      expect(blankAccount!.accountName, isNull);

      final missingAccount = CalendarSyncWritableCalendar.tryParse(
        <String, Object?>{'id': 7, 'displayName': '课程表'},
      );
      expect(missingAccount?.accountName, isNull);
    });

    test('rejects malformed payloads', () {
      expect(CalendarSyncWritableCalendar.tryParse(null), isNull);
      expect(
        CalendarSyncWritableCalendar.tryParse(<String, Object?>{
          'id': 7,
          'displayName': '',
        }),
        isNull,
      );
      expect(
        CalendarSyncWritableCalendar.tryParse(<String, Object?>{
          'id': 7,
          'displayName': 'x',
          'accountName': 3,
        }),
        isNull,
      );
    });
  });

  group('CalendarSyncOwnedEvent', () {
    test('parses and validates opaqueId', () {
      final event = CalendarSyncOwnedEvent.tryParse(<String, Object?>{
        'opaqueId': '11111111-1111-4111-8111-111111111111',
        'eventId': 99,
      });

      expect(event, isNotNull);
      expect(event!.eventId, 99);
    });

    test('rejects invalid opaqueId or eventId', () {
      expect(
        CalendarSyncOwnedEvent.tryParse(<String, Object?>{
          'opaqueId': '2023012345',
          'eventId': 99,
        }),
        isNull,
      );
      expect(
        CalendarSyncOwnedEvent.tryParse(<String, Object?>{
          'opaqueId': '11111111-1111-4111-8111-111111111111',
          'eventId': 0,
        }),
        isNull,
      );
      expect(
        CalendarSyncOwnedEvent.tryParse(<String, Object?>{
          'opaqueId': '11111111-1111-4111-8111-111111111111',
        }),
        isNull,
      );
    });
  });

  group('CalendarSyncEventDraft', () {
    CalendarSyncEventDraft draft({
      String? opaqueId,
      String title = '高等数学',
      String location = '教学楼 A101',
      int startMillis = 1700000000000,
      int endMillis = 1700003600000,
      int reminderMinutes = 10,
      String timeZone = 'Asia/Shanghai',
    }) => CalendarSyncEventDraft(
      opaqueId: opaqueId ?? CalendarSyncOpaqueId.generate(),
      title: title,
      location: location,
      startMillis: startMillis,
      endMillis: endMillis,
      reminderMinutes: reminderMinutes,
      timeZone: timeZone,
    );

    test('accepts a valid draft and validates cleanly', () {
      expect(draft().validate(), isNull);
    });

    test('rejects every out-of-contract field', () {
      expect(draft(opaqueId: '2023012345').validate(), isNotNull);
      expect(draft(title: '   ').validate(), isNotNull);
      expect(
        draft(title: 'x'.padRight(CalendarSyncProtocol.maxTitleLength + 1, 'x'))
            .validate(),
        isNotNull,
      );
      expect(
        draft(
          location: 'x'.padRight(
            CalendarSyncProtocol.maxLocationLength + 1,
            'x',
          ),
        ).validate(),
        isNotNull,
      );
      expect(draft(startMillis: 0).validate(), isNotNull);
      expect(draft(startMillis: -1).validate(), isNotNull);
      expect(draft(endMillis: 1700000000000).validate(), isNotNull);
      expect(draft(endMillis: 1600000000000).validate(), isNotNull);
      expect(draft(reminderMinutes: -1).validate(), isNotNull);
      expect(
        draft(reminderMinutes: CalendarSyncProtocol.maxReminderMinutes + 1)
            .validate(),
        isNotNull,
      );
      expect(draft(timeZone: '').validate(), isNotNull);
      expect(draft(timeZone: '  ').validate(), isNotNull);
      expect(draft(timeZone: 'Asia / Shanghai').validate(), isNotNull);
      expect(
        draft(
          timeZone: 'x'.padRight(
            CalendarSyncProtocol.maxTimeZoneLength + 1,
            'x',
          ),
        ).validate(),
        isNotNull,
      );
    });

    test('toChannelMap exposes exactly the seven protocol fields', () {
      final event = draft();
      final map = event.toChannelMap();

      expect(map.keys.toSet(), <String>{
        'opaqueId',
        'title',
        'location',
        'startMillis',
        'endMillis',
        'reminderMinutes',
        'timeZone',
      });
      // 身份与业务键绝不进入通道参数。
      expect(map.containsKey('studentId'), isFalse);
      expect(map.containsKey('businessKey'), isFalse);
      expect(map['opaqueId'], event.opaqueId);
      expect(map['title'], '高等数学');
      expect(map['startMillis'], 1700000000000);
      expect(map['reminderMinutes'], 10);
    });
  });

  group('CalendarSyncEventPlan', () {
    test('validates opaqueId and businessKey only locally', () {
      final valid = CalendarSyncEventPlan(
        opaqueId: CalendarSyncOpaqueId.generate(),
        businessKey: '2026-1|高等数学|1-2',
      );
      expect(valid.validate(), isNull);
      expect(valid.toString(), isNot(contains('高等数学')));

      expect(
        CalendarSyncEventPlan(opaqueId: 'bad', businessKey: 'k').validate(),
        isNotNull,
      );
      expect(
        CalendarSyncEventPlan(
          opaqueId: CalendarSyncOpaqueId.generate(),
          businessKey: '  ',
        ).validate(),
        isNotNull,
      );
      expect(
        CalendarSyncEventPlan(
          opaqueId: CalendarSyncOpaqueId.generate(),
          businessKey: 'k'.padRight(
            CalendarSyncProtocol.maxBusinessKeyLength + 1,
            'k',
          ),
        ).validate(),
        isNotNull,
      );
    });
  });

  group('CalendarSyncBatchResult', () {
    const opaqueA = '11111111-1111-4111-8111-111111111111';
    const opaqueB = '22222222-2222-4222-8222-222222222222';

    test('parses counts and eventIds', () {
      final result = CalendarSyncBatchResult.tryParse(<String, Object?>{
        'insertedCount': 1,
        'updatedCount': 1,
        'eventIds': <String, Object?>{opaqueA: 11, opaqueB: 22},
      });

      expect(result, isNotNull);
      expect(result!.insertedCount, 1);
      expect(result.updatedCount, 1);
      expect(result.totalCount, 2);
      expect(result.eventIds[opaqueA], 11);
      expect(result.coversAll(<String>[opaqueA, opaqueB]), isTrue);
      expect(result.coversAll(<String>[opaqueA, opaqueB, 'x']), isFalse);
    });

    test('rejects malformed or inconsistent payloads', () {
      expect(CalendarSyncBatchResult.tryParse(null), isNull);
      expect(CalendarSyncBatchResult.tryParse('ok'), isNull);
      expect(
        CalendarSyncBatchResult.tryParse(<String, Object?>{
          'insertedCount': -1,
          'updatedCount': 0,
          'eventIds': <String, Object?>{},
        }),
        isNull,
      );
      expect(
        CalendarSyncBatchResult.tryParse(<String, Object?>{
          'insertedCount': 2,
          'updatedCount': 0,
          'eventIds': <String, Object?>{opaqueA: 11},
        }),
        isNull,
      );
      expect(
        CalendarSyncBatchResult.tryParse(<String, Object?>{
          'insertedCount': 1,
          'updatedCount': 0,
          'eventIds': <String, Object?>{'not-an-opaque-id': 11},
        }),
        isNull,
      );
      expect(
        CalendarSyncBatchResult.tryParse(<String, Object?>{
          'insertedCount': 1,
          'updatedCount': 0,
          'eventIds': <String, Object?>{opaqueA: 0},
        }),
        isNull,
      );
    });
  });

  group('CalendarSyncDeleteResult', () {
    test('parses deleted / notDeleted classification', () {
      final result = CalendarSyncDeleteResult.tryParse(<String, Object?>{
        'deletedIds': <Object?>[1, 2],
        'notDeletedIds': <Object?>[3],
      });

      expect(result, isNotNull);
      expect(result!.deletedIds, <int>[1, 2]);
      expect(result.notDeletedIds, <int>[3]);
      expect(result.isComplete, isFalse);
    });

    test('empty notDeleted means complete', () {
      final result = CalendarSyncDeleteResult.tryParse(<String, Object?>{
        'deletedIds': <Object?>[1],
        'notDeletedIds': <Object?>[],
      });
      expect(result?.isComplete, isTrue);
    });

    test('rejects malformed payloads', () {
      expect(CalendarSyncDeleteResult.tryParse(null), isNull);
      expect(
        CalendarSyncDeleteResult.tryParse(<String, Object?>{
          'deletedIds': <Object?>[0],
          'notDeletedIds': <Object?>[],
        }),
        isNull,
      );
      expect(
        CalendarSyncDeleteResult.tryParse(<String, Object?>{
          'deletedIds': '1',
          'notDeletedIds': <Object?>[],
        }),
        isNull,
      );
      expect(
        CalendarSyncDeleteResult.tryParse(<String, Object?>{
          'deletedIds': <Object?>['1'],
          'notDeletedIds': <Object?>[],
        }),
        isNull,
      );
    });
  });

  group('CalendarSyncException', () {
    test('maps every native error category', () {
      CalendarSyncException map(String code) =>
          CalendarSyncException.fromPlatformException(
            PlatformException(code: code),
            operation: 'queryOwnedEvents',
          );

      expect(
        map('permission_denied').kind,
        CalendarSyncFailureKind.permissionDenied,
      );
      expect(map('invalid_args').kind, CalendarSyncFailureKind.invalidArgument);
      expect(
        map('provider_unavailable').kind,
        CalendarSyncFailureKind.providerUnavailable,
      );
      expect(
        map('calendar_unavailable').kind,
        CalendarSyncFailureKind.calendarUnavailable,
      );
      expect(
        map('ownership_conflict').kind,
        CalendarSyncFailureKind.ownershipConflict,
      );
      expect(map('batch_failed').kind, CalendarSyncFailureKind.batchFailed);
      expect(map('unsupported').kind, CalendarSyncFailureKind.unsupported);
      expect(
        map('requests_in_flight').kind,
        CalendarSyncFailureKind.requestsInFlight,
      );
    });

    test(
      'keeps code and classifies unknown codes without guessing success',
      () {
        final unknown = CalendarSyncException.fromPlatformException(
          PlatformException(code: 'weird_failure'),
          operation: 'upsertEventBatch',
        );
        expect(unknown.kind, CalendarSyncFailureKind.platformError);
        expect(unknown.code, 'weird_failure');

        final fuzzy = CalendarSyncException.fromPlatformException(
          PlatformException(code: 'PERMISSION_DENIED_BY_OEM'),
          operation: 'createOrGetLocalCalendar',
        );
        expect(fuzzy.kind, CalendarSyncFailureKind.permissionDenied);
      },
    );

    test('missing plugin and ledger kinds carry retry semantics', () {
      final missing = CalendarSyncException.missingPlugin('checkPermissions');
      expect(missing.kind, CalendarSyncFailureKind.missingPlugin);
      expect(missing.isPlatformMissing, isTrue);
      expect(missing.isRetryable, isTrue);

      final corrupted = CalendarSyncException.ledgerCorrupted('损坏');
      expect(corrupted.isRetryable, isFalse);
      expect(CalendarSyncException.invalidArgument('参数错').isRetryable, isFalse);
    });

    test('invalidResponse never leaks raw payload values', () {
      final error = CalendarSyncException.invalidResponse(
        'createOrGetLocalCalendar',
        <String, Object?>{'title': '高等数学', 'studentId': '2023012345'},
      );

      expect(error.kind, CalendarSyncFailureKind.invalidResponse);
      expect(error.message, isNot(contains('高等数学')));
      expect(error.message, isNot(contains('2023012345')));
      expect(error.message, contains('Map'));
    });
  });
}
