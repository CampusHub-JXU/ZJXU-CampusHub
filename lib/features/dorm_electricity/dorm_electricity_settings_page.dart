import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/notification/background_task_service.dart';
import 'dorm_electricity_service.dart';
import '../../shared/widgets/app_app_bar.dart';

class DormElectricitySettingsPage extends StatefulWidget {
  const DormElectricitySettingsPage({super.key});

  @override
  State<DormElectricitySettingsPage> createState() =>
      _DormElectricitySettingsPageState();
}

class _CommunityGroup {
  final String label;
  final String communityId;
  final List<DormBuilding> buildings;
  const _CommunityGroup({
    required this.label,
    required this.communityId,
    required this.buildings,
  });
}

class _DormElectricitySettingsPageState
    extends State<DormElectricitySettingsPage> {
  final _service = DormElectricityService.instance;

  List<DormBuilding> _allBuildings = [];
  List<DormRoom> _rooms = [];

  List<_CommunityGroup> _communityGroups = [];

  // floorName → [DormRoom, ...]
  Map<String, List<DormRoom>> _floorMap = {};
  List<String> _floorList = [];

  DormBuilding? _selectedBuilding;
  DormRoom? _selectedRoom;

  bool _loadingBuildings = true;
  bool _loadingRooms = false;
  bool _saving = false;
  String? _error;

  bool _alertEnabled = false;
  double _alertThreshold = DormElectricityService.defaultAlertThreshold;
  static const _thresholdOptions = [
    5.0,
    10.0,
    15.0,
    20.0,
    25.0,
    30.0,
    40.0,
    50.0,
  ];

  @override
  void initState() {
    super.initState();
    _loadBuildings();
    _loadAlertSettings();
  }

  Future<void> _loadAlertSettings() async {
    final enabled = await _service.getAlertEnabled();
    final threshold = await _service.getAlertThreshold();
    if (!mounted) return;
    setState(() {
      _alertEnabled = enabled;
      _alertThreshold = threshold;
    });
  }

  Future<void> _loadBuildings() async {
    try {
      final buildings = await _service.fetchBuildings();
      if (!mounted) return;
      _allBuildings = buildings;
      _buildCommunityGroups();

      // Restore previously saved config
      final savedConfig = await _service.loadRoomConfig();
      if (savedConfig != null) {
        for (final b in _allBuildings) {
          if (b.communityId == savedConfig.communityId &&
              b.buildingId == savedConfig.buildingId) {
            _selectedBuilding = b;
            break;
          }
        }
      }

      setState(() => _loadingBuildings = false);

      if (_selectedBuilding != null) {
        _loadRooms(
          _selectedBuilding!.buildingId,
          savedRoomId: savedConfig?.roomId,
          savedFloorId: savedConfig?.floorId,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载楼幢列表失败';
        _loadingBuildings = false;
      });
    }
  }

  void _buildCommunityGroups() {
    final temp = <String, List<DormBuilding>>{};
    for (final b in _allBuildings) {
      temp.putIfAbsent(b.communityId, () => []).add(b);
    }
    _communityGroups = temp.values.map((buildings) {
      return _CommunityGroup(
        label: buildings.first.communityName,
        communityId: buildings.first.communityId,
        buildings: buildings,
      );
    }).toList();
  }

  void _buildFloorMap() {
    _floorMap = {};
    for (final r in _rooms) {
      _floorMap.putIfAbsent(r.floorName, () => []).add(r);
    }
    _floorList = _floorMap.keys.toList();
  }

  Future<void> _loadRooms(
    String buildingId, {
    String? savedRoomId,
    String? savedFloorId,
  }) async {
    setState(() {
      _loadingRooms = true;
      _rooms = [];
      _floorMap = {};
      _floorList = [];
      _selectedRoom = null;
    });
    try {
      final rooms = await _service.fetchRooms(buildingId);
      if (!mounted) return;
      _rooms = rooms;
      _buildFloorMap();

      if (savedRoomId != null) {
        for (final r in _rooms) {
          if (r.roomId == savedRoomId && r.floorId == savedFloorId) {
            _selectedRoom = r;
            break;
          }
        }
      }

      setState(() => _loadingRooms = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载房间列表失败';
        _loadingRooms = false;
      });
    }
  }

  Future<void> _save() async {
    final building = _selectedBuilding;
    final room = _selectedRoom;
    if (building == null || room == null) return;

    setState(() => _saving = true);
    await _service.saveRoomConfig(
      DormRoomConfig(
        communityId: building.communityId,
        buildingId: building.buildingId,
        floorId: room.floorId,
        roomId: room.roomId,
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('寝室配置成功')));
    Navigator.of(context).pop();
  }

  Future<void> _saveAlertSettings({bool? enabled, double? threshold}) async {
    if (enabled != null) {
      await _service.setAlertEnabled(enabled);
    }
    if (threshold != null) {
      await _service.setAlertThreshold(threshold);
    }
    await BackgroundTaskService.instance.reRegisterIfNeeded();
  }

  void _showThresholdPicker() {
    int selectedIdx = _thresholdOptions.indexOf(_alertThreshold);
    if (selectedIdx < 0) selectedIdx = _thresholdOptions.indexOf(20.0);

    var tempThreshold = _thresholdOptions[selectedIdx];
    final scrollCtrl = FixedExtentScrollController(initialItem: selectedIdx);

    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: 280,
            child: Column(
              children: [
                _pickerHeader(
                  title: '预警阈值',
                  onCancel: () => Navigator.of(ctx).pop(),
                  onConfirm: () {
                    Navigator.of(ctx).pop();
                    setState(() => _alertThreshold = tempThreshold);
                    _saveAlertSettings(threshold: tempThreshold);
                  },
                ),
                Expanded(
                  child: CupertinoPicker(
                    scrollController: scrollCtrl,
                    itemExtent: 36,
                    onSelectedItemChanged: (i) {
                      tempThreshold = _thresholdOptions[i];
                    },
                    children: _thresholdOptions
                        .map(
                          (v) => Center(
                            child: Text(
                              '${v.toInt()} 度',
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── 两列波轮：校区区期 / 楼幢 ──

  void _showBuildingPicker() {
    if (_communityGroups.isEmpty) return;

    int groupIdx = 0;
    int buildingIdx = 0;

    if (_selectedBuilding != null) {
      groupIdx = _communityGroups.indexWhere(
        (g) => g.communityId == _selectedBuilding!.communityId,
      );
      if (groupIdx < 0) groupIdx = 0;
      buildingIdx = _communityGroups[groupIdx].buildings.indexWhere(
        (b) => b.buildingId == _selectedBuilding!.buildingId,
      );
      if (buildingIdx < 0) buildingIdx = 0;
    }

    var currentGroup = _communityGroups[groupIdx];
    var currentBuildings = currentGroup.buildings;
    var tempBuildingIdx = buildingIdx;

    final groupCtrl = FixedExtentScrollController(initialItem: groupIdx);
    final buildingCtrl = FixedExtentScrollController(initialItem: buildingIdx);

    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: 300,
            child: StatefulBuilder(
              builder: (ctx, setModalState) {
                return Column(
                  children: [
                    _pickerHeader(
                      title: '选择楼幢',
                      onCancel: () => Navigator.of(ctx).pop(),
                      onConfirm: currentBuildings.isEmpty
                          ? null
                          : () {
                              Navigator.of(ctx).pop();
                              final b =
                                  currentBuildings[tempBuildingIdx.clamp(
                                    0,
                                    currentBuildings.length - 1,
                                  )];
                              setState(() {
                                _selectedBuilding = b;
                                _selectedRoom = null;
                              });
                              _loadRooms(b.buildingId);
                            },
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          // 左：校区区期
                          Expanded(
                            flex: 3,
                            child: CupertinoPicker(
                              scrollController: groupCtrl,
                              itemExtent: 36,
                              onSelectedItemChanged: (i) {
                                setModalState(() {
                                  currentGroup = _communityGroups[i];
                                  currentBuildings = currentGroup.buildings;
                                  tempBuildingIdx = 0;
                                });
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  buildingCtrl.jumpToItem(0);
                                });
                              },
                              children: _communityGroups
                                  .map(
                                    (g) => Center(
                                      child: Text(
                                        g.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                          // 右：楼幢
                          Expanded(
                            flex: 2,
                            child: CupertinoPicker(
                              scrollController: buildingCtrl,
                              itemExtent: 36,
                              onSelectedItemChanged: (i) {
                                tempBuildingIdx = i;
                              },
                              children: currentBuildings
                                  .map(
                                    (b) => Center(
                                      child: Text(
                                        b.buildingName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  // ── 两列波轮：楼层 / 房间号 ──

  void _showRoomPicker() {
    if (_floorList.isEmpty) return;

    int floorIdx = 0;
    if (_selectedRoom != null) {
      floorIdx = _floorList.indexOf(_selectedRoom!.floorName);
      if (floorIdx < 0) floorIdx = 0;
    }

    var currentFloor = _floorList[floorIdx];
    var currentRooms = _floorMap[currentFloor]!;
    var tempRoomIdx = 0;

    if (_selectedRoom != null && currentFloor == _selectedRoom!.floorName) {
      final ri = currentRooms.indexWhere(
        (r) => r.roomId == _selectedRoom!.roomId,
      );
      if (ri >= 0) tempRoomIdx = ri;
    }

    final floorCtrl = FixedExtentScrollController(initialItem: floorIdx);
    final roomCtrl = FixedExtentScrollController(initialItem: tempRoomIdx);

    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: 300,
            child: StatefulBuilder(
              builder: (ctx, setModalState) {
                return Column(
                  children: [
                    _pickerHeader(
                      title: '选择房间',
                      onCancel: () => Navigator.of(ctx).pop(),
                      onConfirm: currentRooms.isEmpty
                          ? null
                          : () {
                              Navigator.of(ctx).pop();
                              setState(() {
                                _selectedRoom =
                                    currentRooms[tempRoomIdx.clamp(
                                      0,
                                      currentRooms.length - 1,
                                    )];
                              });
                            },
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          // 左：楼层
                          Expanded(
                            child: CupertinoPicker(
                              scrollController: floorCtrl,
                              itemExtent: 36,
                              onSelectedItemChanged: (i) {
                                setModalState(() {
                                  currentFloor = _floorList[i];
                                  currentRooms = _floorMap[currentFloor]!;
                                  tempRoomIdx = 0;
                                });
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  roomCtrl.jumpToItem(0);
                                });
                              },
                              children: _floorList
                                  .map(
                                    (f) => Center(
                                      child: Text(
                                        f,
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                          // 右：房间号
                          Expanded(
                            child: CupertinoPicker(
                              scrollController: roomCtrl,
                              itemExtent: 36,
                              onSelectedItemChanged: (i) {
                                tempRoomIdx = i;
                              },
                              children: currentRooms
                                  .map(
                                    (r) => Center(
                                      child: Text(
                                        '${r.roomName}号',
                                        style: const TextStyle(fontSize: 14),
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  // ── 公共 UI ──

  Widget _pickerHeader({
    required String title,
    required VoidCallback? onCancel,
    required VoidCallback? onConfirm,
  }) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          TextButton(onPressed: onCancel, child: const Text('取消')),
          const Spacer(),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          TextButton(
            onPressed: onConfirm,
            child: Text(
              '确定',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: onConfirm != null
                    ? null
                    : cs.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPickerField({
    required String label,
    required String displayText,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: const Icon(Icons.unfold_more),
        ),
        child: Text(
          displayText,
          style: TextStyle(
            color: enabled && displayText != '请选择'
                ? null
                : Theme.of(context).hintColor,
          ),
        ),
      ),
    );
  }

  String get _buildingDisplayText {
    final b = _selectedBuilding;
    if (b == null) return '请选择';
    return '${b.communityName}  ${b.buildingName}';
  }

  String get _roomDisplayText {
    final r = _selectedRoom;
    if (r == null) return '请选择';
    return '${r.floorName}  ${r.roomName}号';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppAppBar(title: const Text('选择寝室')),
      body: _loadingBuildings
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!, style: TextStyle(color: cs.error)),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () {
                      setState(() {
                        _error = null;
                        _loadingBuildings = true;
                      });
                      _loadBuildings();
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildPickerField(
                    label: '园区 / 楼幢',
                    displayText: _buildingDisplayText,
                    onTap: _showBuildingPicker,
                  ),
                  const SizedBox(height: 20),
                  if (_loadingRooms)
                    const Center(child: CircularProgressIndicator())
                  else
                    _buildPickerField(
                      label: '楼层 / 房间号',
                      displayText: _roomDisplayText,
                      onTap: _showRoomPicker,
                      enabled: _rooms.isNotEmpty,
                    ),
                  const SizedBox(height: 32),
                  FilledButton(
                    onPressed:
                        (_selectedBuilding != null &&
                            _selectedRoom != null &&
                            !_saving)
                        ? _save
                        : null,
                    child: _saving
                        ? SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: cs.onPrimary,
                            ),
                          )
                        : const Text('保存'),
                  ),
                  const SizedBox(height: 24),
                  const Divider(),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '低电量预警',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '当剩余电量低于设定阈值时发送提醒',
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).hintColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: _alertEnabled,
                        onChanged: (v) {
                          setState(() => _alertEnabled = v);
                          _saveAlertSettings(enabled: v);
                        },
                      ),
                    ],
                  ),
                  if (_alertEnabled) ...[
                    const SizedBox(height: 12),
                    _buildPickerField(
                      label: '预警阈值',
                      displayText: '${_alertThreshold.toInt()} 度',
                      onTap: _showThresholdPicker,
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}
