import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/app/theme.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_models.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_room_picker_sheet.dart';
import 'package:jxu_campus_hub/shared/widgets/app_banner.dart';

DormRoom _room(
  String id,
  String name, {
  String floorId = 'F1',
  String floorName = '默认楼层',
}) => DormRoom(
  areaId: '3',
  buildingId: '114',
  floorId: floorId,
  roomId: id,
  floorName: floorName,
  roomName: name,
);

DormBuilding _building(String id, String name, {String areaId = '3'}) =>
    DormBuilding(
      areaId: areaId,
      areaName: '区$areaId',
      buildingId: id,
      buildingName: name,
    );

void main() {
  group('groupDormRoomsByFloor', () {
    test('keeps API floors in API order when there are several', () {
      final rooms = [
        _room('1', 'A-101', floorId: 'F1', floorName: '1楼'),
        _room('2', 'A-201', floorId: 'F2', floorName: '2楼'),
        _room('3', 'A-102', floorId: 'F1', floorName: '1楼'),
      ];
      final groups = groupDormRoomsByFloor(rooms);
      expect(groups.floors, ['1楼', '2楼']);
      expect(groups.byFloor['1楼']!.map((r) => r.roomId), ['1', '3']);
      expect(groups.byFloor['2楼']!.map((r) => r.roomId), ['2']);
    });

    test('a single default floor is split by the floor parsed from the '
        'room name, numerically sorted, with 默认楼层 first', () {
      final rooms = [
        _room('1', 'HX4-1001'),
        _room('2', 'HX4-201'),
        _room('3', 'HX4-105'),
        _room('4', 'HX4-202'),
      ];
      final groups = groupDormRoomsByFloor(rooms);
      expect(groups.floors, [kDormAllRoomsFloorKey, '1楼', '2楼', '10楼']);
      expect(groups.byFloor[kDormAllRoomsFloorKey], hasLength(4));
      expect(groups.byFloor['2楼']!.map((r) => r.roomName), [
        'HX4-201',
        'HX4-202',
      ]);
      expect(groups.byFloor['10楼']!.map((r) => r.roomName), ['HX4-1001']);
    });

    test('rooms whose names cannot be parsed stay only in 默认楼层', () {
      final rooms = [
        _room('1', 'HX4-105'),
        _room('2', 'HX4-205'),
        _room('3', '值班室'),
      ];
      final groups = groupDormRoomsByFloor(rooms);
      expect(groups.floors, [kDormAllRoomsFloorKey, '1楼', '2楼']);
      expect(groups.byFloor[kDormAllRoomsFloorKey], hasLength(3));
      final parsedIds = [
        for (final f in ['1楼', '2楼'])
          ...groups.byFloor[f]!.map((r) => r.roomId),
      ];
      expect(parsedIds, isNot(contains('3')));
    });

    test('fully unparseable names or a single parsed floor do not split', () {
      final unparseable = groupDormRoomsByFloor([
        _room('1', '值班室'),
        _room('2', '配电间'),
      ]);
      expect(unparseable.floors, ['默认楼层']);
      expect(unparseable.byFloor['默认楼层'], hasLength(2));

      final oneParsed = groupDormRoomsByFloor([
        _room('1', 'HX4-101'),
        _room('2', 'HX4-102'),
      ]);
      expect(oneParsed.floors, ['默认楼层']);
    });

    test(
      'floorOf prefers the parsed floor and falls back to the API floor',
      () {
        final rooms = [
          _room('1', 'HX4-105'),
          _room('2', 'HX4-205'),
          _room('3', '值班室'),
        ];
        final groups = groupDormRoomsByFloor(rooms);
        expect(groups.floorOf(rooms[0]), '1楼');
        expect(groups.floorOf(rooms[1]), '2楼');
        expect(groups.floorOf(rooms[2]), '默认楼层');
      },
    );
  });

  group('showDormRoomPickerSheet', () {
    final areas = [
      DormAreaOption(
        id: '3',
        label: '梁林校区',
        buildings: [_building('114', 'HX4'), _building('115', 'HX5')],
      ),
      DormAreaOption(
        id: '4',
        label: '东校区',
        buildings: [_building('201', 'E1', areaId: '4')],
      ),
    ];

    final multiFloorRooms = [
      _room('1', 'HX4-101'),
      _room('2', 'HX4-102'),
      _room('3', 'HX4-201'),
    ];

    DormRoomPick? result;
    var resultSet = false;

    Future<void> open(
      WidgetTester tester, {
      required Future<List<DormRoom>?> Function(DormBuilding) loadRooms,
      List<DormAreaOption>? areaOptions,
      String? initialAreaId,
      DormBuilding? initialBuilding,
      List<DormRoom> initialRooms = const [],
      String? initialFloor,
      DormRoom? initialRoom,
    }) async {
      result = null;
      resultSet = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    result = await showDormRoomPickerSheet(
                      context,
                      areas: areaOptions ?? areas,
                      loadRooms: loadRooms,
                      initialAreaId: initialAreaId,
                      initialBuilding: initialBuilding,
                      initialRooms: initialRooms,
                      initialFloor: initialFloor,
                      initialRoom: initialRoom,
                    );
                    resultSet = true;
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    /// 点列表行 / chip；面包屑里可能有同名文字，所以限定在 ListTile / ChoiceChip。
    Future<void> tapText(WidgetTester tester, String text) async {
      final target = find.descendant(
        of: find.byWidgetPredicate((w) => w is ListTile || w is ChoiceChip),
        matching: find.text(text),
      );
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    testWidgets('narrows area → building → floor → room and returns the pick', (
      tester,
    ) async {
      var loadCalls = 0;
      await open(
        tester,
        loadRooms: (b) async {
          loadCalls++;
          return multiFloorRooms;
        },
      );
      expect(find.text('选择寝室'), findsOneWidget);
      expect(find.text('梁林校区'), findsOneWidget);
      expect(find.text('东校区'), findsOneWidget);

      await tapText(tester, '梁林校区');
      expect(find.text('HX4'), findsOneWidget);
      expect(find.text('HX5'), findsOneWidget);

      await tapText(tester, 'HX4');
      expect(loadCalls, 1);
      // 多个楼层分组：停在楼层级，面包屑已记录园区与楼幢。
      expect(find.text('默认楼层'), findsOneWidget);
      expect(find.text('1楼'), findsOneWidget);
      expect(find.text('2楼'), findsOneWidget);
      expect(find.byKey(const Key('dorm_crumb_2')), findsOneWidget);

      await tapText(tester, '1楼');
      // 房间级只列出该楼层的房间。
      expect(find.text('HX4-101'), findsOneWidget);
      expect(find.text('HX4-102'), findsOneWidget);
      expect(find.text('HX4-201'), findsNothing);
      expect(resultSet, isFalse);

      await tapText(tester, 'HX4-102');
      expect(resultSet, isTrue);
      expect(result, isNotNull);
      expect(result!.building.buildingId, '114');
      expect(result!.room.roomId, '2');
      expect(result!.floor, '1楼');
      expect(result!.rooms, hasLength(3));
      expect(result!.groups.floors, contains('2楼'));
    });

    testWidgets('closing the sheet cancels with a null result', (tester) async {
      await open(tester, loadRooms: (b) async => multiFloorRooms);
      await tapText(tester, '梁林校区');
      await tester.tap(find.byTooltip('取消'));
      await tester.pumpAndSettle();
      expect(find.text('选择寝室'), findsNothing);
      expect(resultSet, isTrue);
      expect(result, isNull);
    });

    testWidgets('dismissing via the barrier cancels with a null result', (
      tester,
    ) async {
      await open(tester, loadRooms: (b) async => multiFloorRooms);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('选择寝室'), findsNothing);
      expect(resultSet, isTrue);
      expect(result, isNull);
    });

    testWidgets('breadcrumb jumps back; changing the area clears deeper levels '
        'and a same-area pick keeps them', (tester) async {
      var loadCalls = 0;
      await open(
        tester,
        loadRooms: (b) async {
          loadCalls++;
          return multiFloorRooms;
        },
      );
      await tapText(tester, '梁林校区');
      await tapText(tester, 'HX4');
      await tapText(tester, '1楼');
      expect(find.text('HX4-101'), findsOneWidget);

      // 面包屑回到园区级，重新选同一园区：保留楼幢 / 楼层选择，不重拉房间。
      await tester.tap(find.byKey(const Key('dorm_crumb_0')));
      await tester.pumpAndSettle();
      expect(find.text('东校区'), findsOneWidget);
      await tapText(tester, '梁林校区');
      expect(find.byKey(const Key('dorm_crumb_3')), findsOneWidget);
      expect(find.text('HX4'), findsWidgets);
      expect(loadCalls, 1);

      // 回到园区级换成另一个园区：楼幢 / 楼层 / 房间面包屑一并清空。
      await tester.tap(find.byKey(const Key('dorm_crumb_0')));
      await tester.pumpAndSettle();
      await tapText(tester, '东校区');
      expect(find.text('E1'), findsOneWidget);
      expect(find.text('HX4'), findsNothing);
      expect(find.byKey(const Key('dorm_crumb_2')), findsNothing);
      expect(find.byKey(const Key('dorm_crumb_3')), findsNothing);
      expect(find.text('选择楼幢'), findsOneWidget);
      expect(resultSet, isFalse);
    });

    testWidgets('a single floor group is auto-selected and jumps to the room '
        'level', (tester) async {
      final single = [_room('1', 'HX4-111'), _room('2', 'HX4-112')];
      await open(tester, loadRooms: (b) async => single);
      await tapText(tester, '梁林校区');
      await tapText(tester, 'HX4');

      // 无楼层选择步骤：直接列出房间，面包屑里楼层已是默认楼层。
      expect(find.text('HX4-111'), findsOneWidget);
      expect(find.text('HX4-112'), findsOneWidget);
      expect(find.byKey(const Key('dorm_crumb_3')), findsOneWidget);
      expect(find.text('默认楼层'), findsOneWidget);

      await tapText(tester, 'HX4-112');
      expect(result!.room.roomId, '2');
      expect(result!.floor, '默认楼层');
    });

    testWidgets(
      'a single area is preselected so the sheet opens at buildings',
      (tester) async {
        await open(
          tester,
          areaOptions: [areas.first],
          loadRooms: (b) async => multiFloorRooms,
        );
        expect(find.text('HX4'), findsOneWidget);
        expect(find.text('HX5'), findsOneWidget);
        expect(find.text('东校区'), findsNothing);
      },
    );

    testWidgets('opens at the room level when a full selection exists', (
      tester,
    ) async {
      final groups = groupDormRoomsByFloor(multiFloorRooms);
      var loadCalls = 0;
      await open(
        tester,
        initialAreaId: '3',
        initialBuilding: areas.first.buildings.first,
        initialRooms: multiFloorRooms,
        initialFloor: '1楼',
        initialRoom: multiFloorRooms.first,
        loadRooms: (b) async {
          loadCalls++;
          return multiFloorRooms;
        },
      );
      expect(groups.floors, contains('1楼'));
      expect(find.text('HX4-101'), findsWidgets);
      expect(find.text('HX4-102'), findsOneWidget);

      await tapText(tester, 'HX4-102');
      expect(result!.room.roomId, '2');
      expect(loadCalls, 0, reason: '已有房间列表时不应重新拉取');
    });

    testWidgets('loadRooms returning null closes the sheet without a result', (
      tester,
    ) async {
      await open(tester, loadRooms: (b) async => null);
      await tapText(tester, '梁林校区');
      await tester.tap(find.text('HX4'));
      await tester.pumpAndSettle();
      expect(find.text('选择寝室'), findsNothing);
      expect(resultSet, isTrue);
      expect(result, isNull);
    });

    testWidgets('loadRooms failure shows an error banner whose retry reloads', (
      tester,
    ) async {
      var calls = 0;
      await open(
        tester,
        loadRooms: (b) async {
          calls++;
          if (calls == 1) throw '一卡通网关网络异常，请稍后重试';
          return multiFloorRooms;
        },
      );
      await tapText(tester, '梁林校区');
      await tapText(tester, 'HX4');

      expect(calls, 1);
      expect(find.byType(AppBanner), findsOneWidget);
      expect(find.text('一卡通网关网络异常，请稍后重试'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.byType(AppBanner), findsNothing);
      expect(find.text('1楼'), findsOneWidget);
      expect(find.text('2楼'), findsOneWidget);
    });

    testWidgets('a late room result for a building the user already left is '
        'dropped', (tester) async {
      final gates = <String, Completer<List<DormRoom>?>>{};
      await open(
        tester,
        loadRooms: (b) => (gates[b.buildingId] = Completer()).future,
      );
      await tapText(tester, '梁林校区');
      await tester.tap(find.text('HX4'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // 还在加载时回到楼幢级改选 HX5。
      await tester.tap(find.byKey(const Key('dorm_crumb_1')));
      await tester.pump();
      await tester.tap(find.text('HX5'));
      await tester.pump();

      // HX4 的迟到结果到达：不得覆盖 HX5 的加载。
      gates['114']!.complete([_room('9', 'HX4-901')]);
      await tester.pump();
      expect(find.text('HX4-901'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      gates['115']!.complete(multiFloorRooms);
      await tester.pumpAndSettle();
      expect(find.text('1楼'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
