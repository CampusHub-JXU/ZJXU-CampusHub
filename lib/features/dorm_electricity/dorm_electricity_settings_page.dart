import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/logging/app_logger.dart';
import 'dorm_electricity_background.dart';
import 'dorm_electricity_service.dart';
import 'epay_electricity_gateway.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/login_shell.dart';

class DormElectricitySettingsPage extends StatefulWidget {
  const DormElectricitySettingsPage({super.key});

  @override
  State<DormElectricitySettingsPage> createState() =>
      _DormElectricitySettingsPageState();
}

class _AreaGroup {
  final DormArea area;
  final List<DormBuilding> buildings;
  const _AreaGroup({required this.area, required this.buildings});

  String get label => area.name;
  String get areaId => area.id;
}

class _DormElectricitySettingsPageState
    extends State<DormElectricitySettingsPage> {
  final _service = DormElectricityService.instance;

  List<DormBuilding> _allBuildings = [];
  List<DormRoom> _rooms = [];

  List<_AreaGroup> _areaGroups = [];

  // floorName → [DormRoom, ...]
  Map<String, List<DormRoom>> _floorMap = {};
  List<String> _floorList = [];

  DormBuilding? _selectedBuilding;
  DormRoom? _selectedRoom;

  bool _loadingBuildings = true;
  bool _loadingRooms = false;
  bool _saving = false;
  String? _error;
  bool _requiresUnifiedAuth = false;

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
      final areas = await _service.fetchAreas();
      if (!mounted) return;
      if (areas.isEmpty) {
        setState(() {
          _error = '未获取到园区列表';
          _requiresUnifiedAuth = false;
          _loadingBuildings = false;
        });
        return;
      }

      // 园区数量少（≤2），整表预取让滚轮切换零等待。
      final groups = <_AreaGroup>[];
      final allBuildings = <DormBuilding>[];
      for (final area in areas) {
        final buildings = await _service.fetchBuildings(area);
        if (buildings.isEmpty) continue;
        groups.add(_AreaGroup(area: area, buildings: buildings));
        allBuildings.addAll(buildings);
      }
      if (!mounted) return;
      if (groups.isEmpty) {
        setState(() {
          _error = '未获取到楼幢列表';
          _requiresUnifiedAuth = false;
          _loadingBuildings = false;
        });
        return;
      }
      _areaGroups = groups;
      _allBuildings = allBuildings;

      // Restore previously saved config
      final savedConfig = await _service.loadRoomConfig();
      if (!mounted) return;
      if (savedConfig != null) {
        for (final b in _allBuildings) {
          if (b.areaId == savedConfig.areaId &&
              b.buildingId == savedConfig.buildingId) {
            _selectedBuilding = b;
            break;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _error = null;
        _requiresUnifiedAuth = false;
        _loadingBuildings = false;
      });

      if (_selectedBuilding != null) {
        _loadRooms(
          areaId: _selectedBuilding!.areaId,
          buildingId: _selectedBuilding!.buildingId,
          savedRoomId: savedConfig?.roomId,
          savedFloorId: savedConfig?.floorId,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // DormServiceException / EpaySessionUnavailableException 均携带
        // 可直接展示的原因（维护中 / 需登录 / 网络错误等）。
        _error =
            e is DormServiceException ||
                e is EpaySessionUnavailableException ||
                e is EpayGatewayException
            ? e.toString()
            : '加载楼幢列表失败';
        _requiresUnifiedAuth = e is EpaySessionUnavailableException;
        _loadingBuildings = false;
      });
    }
  }

  void _buildFloorMap() {
    _floorMap = {};
    for (final r in _rooms) {
      _floorMap.putIfAbsent(r.floorName, () => []).add(r);
    }
    // API 只回一个「默认楼层」时，几百个房间号只能从头滚：按房间名解析
    // 楼层（HX4-105 → 1楼）追加筛选分组，解析不出的房间只留在默认楼层。
    if (_floorMap.length <= 1) {
      final parsed = <String, List<DormRoom>>{};
      for (final r in _rooms) {
        final label = DormElectricityService.parseFloorLabel(r.roomName);
        if (label == null) continue;
        parsed.putIfAbsent(label, () => []).add(r);
      }
      if (parsed.length > 1) {
        final floorKeys = parsed.keys.toList()..sort(_compareFloorLabel);
        _floorMap = {_allRoomsFloorKey: List.of(_rooms), ...parsed};
        _floorList = [_allRoomsFloorKey, ...floorKeys];
        return;
      }
    }
    _floorList = _floorMap.keys.toList();
  }

  static const _allRoomsFloorKey = '默认楼层';

  int _compareFloorLabel(String a, String b) {
    final na = int.tryParse(a.replaceAll(RegExp(r'\D'), '')) ?? 0;
    final nb = int.tryParse(b.replaceAll(RegExp(r'\D'), '')) ?? 0;
    return na.compareTo(nb);
  }

  Future<void> _loadRooms({
    required String areaId,
    required String buildingId,
    String? savedRoomId,
    String? savedFloorId,
  }) async {
    if (!mounted) return;
    setState(() {
      _loadingRooms = true;
      _rooms = [];
      _floorMap = {};
      _floorList = [];
      _selectedRoom = null;
      _error = null;
    });
    try {
      final rooms = await _service.fetchRooms(
        areaId: areaId,
        buildingId: buildingId,
      );
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
        _error =
            e is DormServiceException ||
                e is EpaySessionUnavailableException ||
                e is EpayGatewayException
            ? e.toString()
            : '加载房间列表失败';
        _requiresUnifiedAuth = e is EpaySessionUnavailableException;
        _loadingRooms = false;
      });
    }
  }

  Future<void> _save() async {
    final building = _selectedBuilding;
    final room = _selectedRoom;
    if (building == null || room == null) return;

    setState(() => _saving = true);
    try {
      await _service.saveRoomConfig(
        DormRoomConfig(
          areaId: building.areaId,
          buildingId: building.buildingId,
          floorId: room.floorId,
          roomId: room.roomId,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存寝室配置失败：$error')));
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('寝室配置成功')));
    Navigator.of(context).pop();
  }

  Future<void> _saveAlertSettings({bool? enabled, double? threshold}) async {
    if (enabled != null) {
      await _service.setAlertEnabled(enabled);
    }
    if (threshold != null) {
      await _service.setAlertThreshold(threshold);
    }
    try {
      await DormElectricityBackground.instance.reRegisterIfNeeded();
    } catch (error) {
      // 后台任务重注册失败不应让设置静默回滚或抛未处理异常，记录即可，
      // 下次切换开关或冷启动仍会重试。
      AppLogger.instance.storage(LogLevel.warn, '电费预警后台任务重注册失败', error: error);
    }
  }

  void _showThresholdPicker() {
    int selectedIdx = _thresholdOptions.indexOf(_alertThreshold);
    if (selectedIdx < 0) selectedIdx = _thresholdOptions.indexOf(20.0);

    var tempThreshold = _thresholdOptions[selectedIdx];
    final scrollCtrl = FixedExtentScrollController(initialItem: selectedIdx);

    final dismissed = showModalBottomSheet(
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
    unawaited(dismissed.whenComplete(scrollCtrl.dispose));
  }

  // ── 两列波轮：校区区期 / 楼幢 ──

  void _showBuildingPicker() {
    if (_areaGroups.isEmpty) return;

    int groupIdx = 0;
    int buildingIdx = 0;

    if (_selectedBuilding != null) {
      groupIdx = _areaGroups.indexWhere(
        (g) => g.areaId == _selectedBuilding!.areaId,
      );
      if (groupIdx < 0) groupIdx = 0;
      buildingIdx = _areaGroups[groupIdx].buildings.indexWhere(
        (b) => b.buildingId == _selectedBuilding!.buildingId,
      );
      if (buildingIdx < 0) buildingIdx = 0;
    }

    var currentGroup = _areaGroups[groupIdx];
    var currentBuildings = currentGroup.buildings;
    var tempBuildingIdx = buildingIdx;

    final groupCtrl = FixedExtentScrollController(initialItem: groupIdx);
    final buildingCtrl = FixedExtentScrollController(initialItem: buildingIdx);

    final buildingDismissed = showModalBottomSheet(
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
                              _loadRooms(
                                areaId: b.areaId,
                                buildingId: b.buildingId,
                              );
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
                                  currentGroup = _areaGroups[i];
                                  currentBuildings = currentGroup.buildings;
                                  tempBuildingIdx = 0;
                                });
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  buildingCtrl.jumpToItem(0);
                                });
                              },
                              children: _areaGroups
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
    unawaited(
      buildingDismissed.whenComplete(() {
        groupCtrl.dispose();
        buildingCtrl.dispose();
      }),
    );
  }

  // ── 两列波轮：楼层 / 房间号 ──

  void _showRoomPicker() {
    if (_floorList.isEmpty) return;

    int floorIdx = 0;
    if (_selectedRoom != null) {
      // 优先跳到房间名解析出的楼层分组，找不到再回退 API 楼层名。
      final label =
          DormElectricityService.parseFloorLabel(_selectedRoom!.roomName) ??
          _selectedRoom!.floorName;
      floorIdx = _floorList.indexOf(label);
      if (floorIdx < 0) {
        floorIdx = _floorList.indexOf(_selectedRoom!.floorName);
      }
      if (floorIdx < 0) floorIdx = 0;
    }

    var currentFloor = _floorList[floorIdx];
    var currentRooms = _floorMap[currentFloor]!;
    var tempRoomIdx = 0;

    if (_selectedRoom != null) {
      final ri = currentRooms.indexWhere(
        (r) => r.roomId == _selectedRoom!.roomId,
      );
      if (ri >= 0) tempRoomIdx = ri;
    }

    final floorCtrl = FixedExtentScrollController(initialItem: floorIdx);
    final roomCtrl = FixedExtentScrollController(initialItem: tempRoomIdx);

    final roomDismissed = showModalBottomSheet(
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
    unawaited(
      roomDismissed.whenComplete(() {
        floorCtrl.dispose();
        roomCtrl.dispose();
      }),
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
    return '${b.areaName}  ${b.buildingName}';
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
          ? Column(
              children: [
                Expanded(
                  child: AppErrorView(
                    title: '加载失败',
                    message: _error,
                    onRetry: () {
                      setState(() {
                        _error = null;
                        _loadingBuildings = true;
                      });
                      _loadBuildings();
                    },
                  ),
                ),
                if (_requiresUnifiedAuth)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                    child: FilledButton.icon(
                      onPressed: _loginAndRetry,
                      icon: const Icon(Icons.login_rounded),
                      label: const Text('登录'),
                    ),
                  ),
              ],
            )
          : SingleChildScrollView(
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

  Future<void> _loginAndRetry() async {
    final loggedIn = await showUnifiedAuthLoginModal(
      context,
      title: '登录一卡通',
      description: '登录一卡通后在后台完成电费认证，当前页面仍保持原生界面',
      barrierDismissible: true,
    );
    if (!mounted || !loggedIn) return;

    await _service.invalidateGatewaySession();
    if (!mounted) return;
    setState(() {
      _error = null;
      _requiresUnifiedAuth = false;
      _loadingBuildings = true;
    });
    await _loadBuildings();
  }
}
