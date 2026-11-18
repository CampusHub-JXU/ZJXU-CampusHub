import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_banner.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/app_filter_chips.dart';
import 'dorm_electricity_service.dart';

/// 房间按楼层分组的结果：[floors] 为展示顺序，[byFloor] 为楼层 → 房间。
class DormFloorGroups {
  const DormFloorGroups(this.floors, this.byFloor);

  static const empty = DormFloorGroups(<String>[], <String, List<DormRoom>>{});

  final List<String> floors;
  final Map<String, List<DormRoom>> byFloor;

  /// 房间所属楼层分组：优先房间名解析出的楼层，找不到再回退 API 楼层名。
  String? floorOf(DormRoom room) {
    final label =
        DormElectricityService.parseFloorLabel(room.roomName) ?? room.floorName;
    if (byFloor.containsKey(label)) return label;
    if (byFloor.containsKey(room.floorName)) return room.floorName;
    return null;
  }
}

/// 「默认楼层」：API 只回一个楼层时保留的全量分组。
const String kDormAllRoomsFloorKey = '默认楼层';

/// 按楼层分组房间。API 只回一个「默认楼层」时，几百个房间号只能从头滚：
/// 按房间名解析楼层（HX4-105 → 1楼）追加筛选分组，解析不出的房间只留在
/// 默认楼层。
DormFloorGroups groupDormRoomsByFloor(List<DormRoom> rooms) {
  final byApiFloor = <String, List<DormRoom>>{};
  for (final r in rooms) {
    byApiFloor.putIfAbsent(r.floorName, () => []).add(r);
  }
  if (byApiFloor.length <= 1) {
    final parsed = <String, List<DormRoom>>{};
    for (final r in rooms) {
      final label = DormElectricityService.parseFloorLabel(r.roomName);
      if (label == null) continue;
      parsed.putIfAbsent(label, () => []).add(r);
    }
    if (parsed.length > 1) {
      final keys = parsed.keys.toList()..sort(_compareFloorLabel);
      return DormFloorGroups(
        [kDormAllRoomsFloorKey, ...keys],
        {kDormAllRoomsFloorKey: List.of(rooms), ...parsed},
      );
    }
  }
  return DormFloorGroups(byApiFloor.keys.toList(), byApiFloor);
}

int _compareFloorLabel(String a, String b) {
  final na = int.tryParse(a.replaceAll(RegExp(r'\D'), '')) ?? 0;
  final nb = int.tryParse(b.replaceAll(RegExp(r'\D'), '')) ?? 0;
  return na.compareTo(nb);
}

/// 一个园区及其楼幢。
class DormAreaOption {
  const DormAreaOption({
    required this.id,
    required this.label,
    required this.buildings,
  });

  final String id;
  final String label;
  final List<DormBuilding> buildings;
}

/// 弹层选定结果：已拉好的房间与分组一并带回，页面无需再拉一次。
class DormRoomPick {
  const DormRoomPick({
    required this.building,
    required this.rooms,
    required this.groups,
    required this.floor,
    required this.room,
  });

  final DormBuilding building;
  final List<DormRoom> rooms;
  final DormFloorGroups groups;
  final String floor;
  final DormRoom room;
}

/// 逐级收窄选寝室：园区 → 楼幢 → 楼层 → 房间，在底部弹层里完成。
///
/// 弹层只改自己的草稿；关闭即取消，页面原选择不变。选中房间才带结果返回。
/// [loadRooms] 由页面提供并负责身份复核：身份已变化时返回 `null`（弹层直接
/// 关闭、不带结果），失败时抛出可展示的异常。
Future<DormRoomPick?> showDormRoomPickerSheet(
  BuildContext context, {
  required List<DormAreaOption> areas,
  required Future<List<DormRoom>?> Function(DormBuilding building) loadRooms,
  String? initialAreaId,
  DormBuilding? initialBuilding,
  List<DormRoom> initialRooms = const [],
  String? initialFloor,
  DormRoom? initialRoom,
}) {
  return AppFeedback.sheet<DormRoomPick>(
    context,
    scrollControlled: true,
    builder: (_) => _DormRoomPickerSheet(
      areas: areas,
      loadRooms: loadRooms,
      initialAreaId: initialAreaId,
      initialBuilding: initialBuilding,
      initialRooms: initialRooms,
      initialFloor: initialFloor,
      initialRoom: initialRoom,
    ),
  );
}

class _DormRoomPickerSheet extends StatefulWidget {
  const _DormRoomPickerSheet({
    required this.areas,
    required this.loadRooms,
    required this.initialAreaId,
    required this.initialBuilding,
    required this.initialRooms,
    required this.initialFloor,
    required this.initialRoom,
  });

  final List<DormAreaOption> areas;
  final Future<List<DormRoom>?> Function(DormBuilding building) loadRooms;
  final String? initialAreaId;
  final DormBuilding? initialBuilding;
  final List<DormRoom> initialRooms;
  final String? initialFloor;
  final DormRoom? initialRoom;

  @override
  State<_DormRoomPickerSheet> createState() => _DormRoomPickerSheetState();
}

class _DormRoomPickerSheetState extends State<_DormRoomPickerSheet> {
  static const _levelNames = ['园区', '楼幢', '楼层', '房间'];

  String? _areaId;
  DormBuilding? _building;
  List<DormRoom> _rooms = const [];
  DormFloorGroups _groups = DormFloorGroups.empty;
  String? _floor;
  DormRoom? _room;

  /// 当前展开的级（0 园区 … 3 房间）。
  int _level = 0;
  bool _loadingRooms = false;
  String? _error;
  int _roomsLoadId = 0;

  final _crumbScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _areaId = widget.initialAreaId ?? _singleAreaId;
    _building = widget.initialBuilding;
    _rooms = widget.initialRooms;
    _groups = groupDormRoomsByFloor(_rooms);
    _floor = widget.initialFloor;
    _room = widget.initialRoom;
    // 已有完整选择时停在房间级（最常见的「改一下房号」）；否则停在第一个未选级。
    _level = _areaId == null
        ? 0
        : _building == null
        ? 1
        : _floor == null
        ? 2
        : 3;
  }

  @override
  void dispose() {
    _crumbScroll.dispose();
    super.dispose();
  }

  String? get _singleAreaId =>
      widget.areas.length == 1 ? widget.areas.first.id : null;

  DormAreaOption? get _area {
    for (final a in widget.areas) {
      if (a.id == _areaId) return a;
    }
    return null;
  }

  void _goTo(int level) {
    setState(() => _level = level);
    _scrollCrumbsToEnd();
  }

  void _scrollCrumbsToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_crumbScroll.hasClients) return;
      _crumbScroll.animateTo(
        _crumbScroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _pickArea(String id) {
    if (id != _areaId) {
      _roomsLoadId++;
      _areaId = id;
      _building = null;
      _rooms = const [];
      _groups = DormFloorGroups.empty;
      _floor = null;
      _room = null;
      _loadingRooms = false;
      _error = null;
    }
    _goTo(1);
  }

  Future<void> _pickBuilding(DormBuilding b) async {
    final same =
        _building != null &&
        _building!.areaId == b.areaId &&
        _building!.buildingId == b.buildingId &&
        _rooms.isNotEmpty;
    if (same) {
      _goTo(2);
      return;
    }
    final loadId = ++_roomsLoadId;
    setState(() {
      _building = b;
      _rooms = const [];
      _groups = DormFloorGroups.empty;
      _floor = null;
      _room = null;
      _loadingRooms = true;
      _error = null;
      _level = 2;
    });
    _scrollCrumbsToEnd();
    try {
      final rooms = await widget.loadRooms(b);
      if (!mounted || loadId != _roomsLoadId) return;
      if (rooms == null) {
        // 身份已变化：草稿属于旧身份，直接关闭、不带结果。
        Navigator.of(context).pop();
        return;
      }
      final groups = groupDormRoomsByFloor(rooms);
      setState(() {
        _rooms = rooms;
        _groups = groups;
        _loadingRooms = false;
        // 只有一个楼层分组时直接选中并进到房间级，省去无意义的一步。
        if (groups.floors.length == 1) {
          _floor = groups.floors.first;
          _level = 3;
        }
      });
      _scrollCrumbsToEnd();
    } catch (e) {
      if (!mounted || loadId != _roomsLoadId) return;
      setState(() {
        _loadingRooms = false;
        _error = '$e';
      });
    }
  }

  void _pickFloor(String floor) {
    if (floor != _floor) {
      _floor = floor;
      _room = null;
    }
    _goTo(3);
  }

  void _pickRoom(DormRoom room) {
    final building = _building;
    final floor = _floor;
    if (building == null || floor == null) return;
    Navigator.of(context).pop(
      DormRoomPick(
        building: building,
        rooms: _rooms,
        groups: _groups,
        floor: floor,
        room: room,
      ),
    );
  }

  String? _labelAt(int level) => switch (level) {
    0 => _area?.label,
    1 => _building?.buildingName,
    2 => _floor,
    _ => _room?.roomName,
  };

  /// 面包屑能点到的最深一级：已选的级 + 下一个待选级。
  int get _reachableLevel {
    if (_areaId == null) return 0;
    if (_building == null) return 1;
    if (_floor == null) return 2;
    return 3;
  }

  Widget _buildCrumbs(ColorScheme cs) {
    final text = context.appText;
    final last = _reachableLevel;
    return SizedBox(
      height: 40,
      child: ListView.separated(
        controller: _crumbScroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: last + 1,
        separatorBuilder: (_, _) =>
            Icon(Icons.chevron_right_rounded, size: 18, color: cs.outline),
        itemBuilder: (context, i) {
          final label = _labelAt(i);
          final current = i == _level;
          return InkWell(
            key: Key('dorm_crumb_$i'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => _goTo(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label ?? '选择${_levelNames[i]}',
                    style: text.rowTitle.copyWith(
                      color: current
                          ? cs.primary
                          : (label == null
                                ? cs.onSurfaceVariant
                                : cs.onSurface),
                      fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 4),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    height: 2,
                    width: current ? 16 : 0,
                    decoration: BoxDecoration(
                      color: cs.primary,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRows(
    ColorScheme cs,
    List<(String, bool, VoidCallback)> options,
  ) {
    final text = context.appText;
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      children: [
        for (final (label, selected, onTap) in options)
          ListTile(
            dense: true,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            title: Text(
              label,
              style: text.listTitle.copyWith(
                color: selected ? cs.primary : null,
                fontWeight: selected ? FontWeight.w600 : null,
              ),
            ),
            trailing: selected
                ? Icon(Icons.check_rounded, size: 20, color: cs.primary)
                : null,
            onTap: onTap,
          ),
      ],
    );
  }

  Widget _buildChips<T>(
    List<AppFilterOption<T?>> options,
    T? selected,
    ValueChanged<T> onSelected,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 16),
      child: AppFilterChips<T?>(
        wrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        options: options,
        selected: selected,
        onSelected: (v) {
          if (v != null) onSelected(v);
        },
      ),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_level >= 2 && _loadingRooms) {
      return const Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_level >= 2 && _error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppBanner(
              message: _error!,
              tone: AppBannerTone.error,
              actionLabel: '重试',
              onAction: () {
                final b = _building;
                if (b == null) return;
                _rooms = const [];
                _pickBuilding(b);
              },
            ),
          ],
        ),
      );
    }
    switch (_level) {
      case 0:
        return _buildRows(cs, [
          for (final a in widget.areas)
            (a.label, a.id == _areaId, () => _pickArea(a.id)),
        ]);
      case 1:
        final selected = _building;
        return _buildRows(cs, [
          for (final b in _area?.buildings ?? const <DormBuilding>[])
            (
              b.buildingName,
              selected != null &&
                  selected.areaId == b.areaId &&
                  selected.buildingId == b.buildingId,
              () => _pickBuilding(b),
            ),
        ]);
      case 2:
        return _buildChips<String>(
          [for (final f in _groups.floors) AppFilterOption(f, f)],
          _floor,
          _pickFloor,
        );
      default:
        final rooms = _groups.byFloor[_floor] ?? const <DormRoom>[];
        return _buildChips<DormRoom>(
          [for (final r in rooms) AppFilterOption(r, r.roomName)],
          _room == null
              ? null
              : rooms.cast<DormRoom?>().firstWhere(
                  (r) =>
                      r!.roomId == _room!.roomId && r.floorId == _room!.floorId,
                  orElse: () => null,
                ),
          _pickRoom,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final height = MediaQuery.sizeOf(context).height * 0.6;
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '选择寝室',
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: '取消',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          _buildCrumbs(cs),
          const SizedBox(height: 8),
          Expanded(child: _buildBody(cs)),
        ],
      ),
    );
  }
}
