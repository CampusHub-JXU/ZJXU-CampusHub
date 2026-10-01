import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/unified_auth.dart';
import '../../core/logging/app_logger.dart';
import 'dorm_electricity_background.dart';
import 'dorm_electricity_service.dart';
import 'epay_electricity_gateway.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_dropdown.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/plain_list.dart';

/// 寝室配置（房间选择 + 电量预警）原生页面。
///
/// 认证门面（epay100 目录 RPC 继续走 [Epay100Gateway] 隐藏 WebView，不改原生直连）：
/// * 明确未登录：首帧直接整页登录闸门 [AuthRequiredView]，不进转圈/错误态、不打网关；
///   进入页面一次性 post-frame 自动弹出登录弹窗 [showUnifiedAuthLoginModal]（dismiss
///   后不再自动弹，闸门按钮可手动重试，避免自动弹窗循环）；
/// * 身份尚未水合时谨慎 [UnifiedAuthService.restoreSession]（`syncWebViewCookies:
///   false`）一次，恢复成功立即自动拉取目录，无需再次点击；
/// * 身份绑定（账号 + sessionRevision）：A→B 换号（含两者都已登录）作废旧身份
///   在途请求、清空旧目录/选择并为新身份重拉；每个 await 后同时按代际与身份
///   复核，旧身份的迟到结果（成功或失败）一律丢弃，绝不把 B 说成未登录；
/// * 请求后明确的 epay 会话失效（[EpaySessionUnavailableException]）：仅当统一
///   认证确实未登录才展示登录闸门；统一认证仍有效时保留「原始原因 + 可重试错误
///   态」（登录弹窗会被本地登录态自动登录成功，展示它只会陷入无效重试循环）；
///   网关/网络未知错误一律保持可重试错误态，绝不当认证过期处理，也绝不清理
///   全局统一认证会话。
class DormElectricitySettingsPage extends StatefulWidget {
  const DormElectricitySettingsPage({
    super.key,
    this.debugBeforeAlertSettingsAdopt,
  });

  /// 测试注入：读到预警设置之后、写回界面之前的挂起点（用法同服务层
  /// `debugBeforeCacheAdopt`），用于确定性验证「旧身份迟到的预警设置不得
  /// 覆盖新身份的界面」。
  final Future<void> Function()? debugBeforeAlertSettingsAdopt;

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

  /// 当前选中的校区区期（[_AreaGroup.areaId]）。先于楼幢提交：换校区会清空
  /// 楼幢/房间选择，选中楼幢时始终与其 `areaId` 一致。
  String? _selectedAreaId;
  DormBuilding? _selectedBuilding;

  /// 当前选中的楼层分组（[_floorList] 的成员）；换楼层清空房间选择。
  String? _selectedFloor;
  DormRoom? _selectedRoom;

  bool _loadingBuildings = false;
  bool _loadingRooms = false;
  bool _saving = false;
  String? _error;

  /// 整页统一认证登录闸门（明确未登录 / 请求后明确会话失效）。
  bool _authGate = false;

  /// 登录弹窗一次性自动弹出标记：进入页面自动弹一次，dismiss 后不再自动弹。
  bool _loginPromptShown = false;
  bool _loginPromptInFlight = false;

  /// 目录/房间拉取代际：身份变化或重新拉取后，旧请求的迟到结果一律丢弃。
  int _loadId = 0;

  /// 当前绑定的统一认证身份（账号 + sessionRevision）：目录拉取属于该身份，
  /// A→B 换号（两者都处于已登录）时必须作废旧身份在途请求并清空旧目录/选择。
  String? _boundAccount;
  int _boundRevision = -1;

  bool _alertEnabled = false;
  double _alertThreshold = DormElectricityService.defaultAlertThreshold;

  /// 当前身份是否已有**保存的**寝室配置（归属由服务层 fail-closed 判定）。
  /// 没有配置时预警开关禁用并提示先保存寝室：服务层对无归属的预警写入是
  /// no-op，展示可开启的开关会假装 opt-in 已生效。
  bool _hasSavedRoomConfig = false;
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

  /// 当前已验证的统一认证身份；未登录一律 null（空账号不算身份）。
  static String? _identityOf(UnifiedAuthService auth) =>
      auth.isLoggedIn ? auth.currentAccount?.trim() : null;

  /// 逐 await 复核（fail closed）：捕获的 owner + sessionRevision 必须同时
  /// 匹配「绑定身份」与**实时**统一认证身份（账号 + sessionRevision），且
  /// 加载代际未变。同账号重登推进 sessionRevision；静默换号 / 身份失效在
  /// 监听器通知到达前也立即失效旧回调——旧会话的迟到结果绝不写入新会话的
  /// 界面、反馈或后台调度。
  bool _isLiveBoundIdentity(String? owner, int revision, {int? loadId}) {
    if (!mounted) return false;
    if (loadId != null && loadId != _loadId) return false;
    if (owner != _boundAccount || revision != _boundRevision) return false;
    final auth = UnifiedAuthService.instance;
    return auth.sessionRevision == revision && _identityOf(auth) == owner;
  }

  @override
  void initState() {
    super.initState();
    final auth = UnifiedAuthService.instance;
    _boundAccount = _identityOf(auth);
    _boundRevision = auth.sessionRevision;
    auth.addListener(_onAuthChanged);
    _loadAlertSettings();
    if (auth.isLoggedIn) {
      _loadingBuildings = true;
      unawaited(_loadBuildings());
    } else {
      // 明确未登录（或身份尚未水合）：首帧直接整页登录闸门，不进转圈/错误态。
      _loadingBuildings = false;
      _authGate = true;
      unawaited(_handleLoggedOutEntry());
    }
  }

  @override
  void dispose() {
    UnifiedAuthService.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  /// 未登录进入寝室配置的引导流程。
  ///
  /// 仅当本进程还没有任何身份时，谨慎冷恢复一次本地会话元数据
  /// （[UnifiedAuthService.restoreSession] 且 `syncWebViewCookies: false`，不触
  /// WebView）；限时完成，超时/读取失败一律按未登录处理，不误判为认证过期。
  /// 恢复成功由 [_onAuthChanged] 立即拉取目录；恢复不出身份则一次性自动弹出
  /// 登录弹窗（post-frame），dismiss 后不再自动弹。
  Future<void> _handleLoggedOutEntry() async {
    final auth = UnifiedAuthService.instance;
    if (auth.currentAccount == null) {
      try {
        await auth
            .restoreSession(syncWebViewCookies: false)
            .timeout(const Duration(seconds: 1));
      } catch (error) {
        AppLogger.instance.auth(
          LogLevel.warn,
          '寝室配置冷恢复统一认证身份失败，按未登录处理',
          error: error,
        );
      }
    }
    if (!mounted) return;
    if (auth.isLoggedIn) return; // 身份已恢复：_onAuthChanged 已触发拉取
    _scheduleAutoLoginPrompt();
  }

  /// 进入页面（明确未登录）后的一次性 post-frame 登录弹窗，避免自动弹窗循环。
  void _scheduleAutoLoginPrompt() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loginPromptShown || _loginPromptInFlight) return;
      if (UnifiedAuthService.instance.isLoggedIn) return;
      unawaited(_presentLoginPrompt(auto: true));
    });
  }

  Future<void> _presentLoginPrompt({bool auto = false}) async {
    if (!mounted || _loginPromptInFlight) return;
    // 自动弹窗一次性：dismiss 后不再自动弹；闸门按钮仍可手动重试。
    if (auto && _loginPromptShown) return;
    _loginPromptShown = true;
    _loginPromptInFlight = true;
    var loggedIn = false;
    try {
      loggedIn = await showUnifiedAuthLoginModal(
        context,
        title: '登录一卡通',
        description: '登录一卡通后在后台完成电费认证，当前页面仍保持原生界面',
        barrierDismissible: true,
      );
    } finally {
      _loginPromptInFlight = false;
    }
    if (!mounted || !loggedIn) return;
    await _reloadAfterLogin();
  }

  /// 登录成功（弹窗回调 / 身份恢复 / A→B 换号）后的统一动作：绑定当前身份，
  /// 作废全部在途拉取，只废 epay100 隐藏 WebView 会话（绝不清理全局统一认证
  /// Cookie），清空旧身份的目录/选择后立即重拉，无需用户再次点击。
  Future<void> _reloadAfterLogin() async {
    if (!mounted) return;
    final auth = UnifiedAuthService.instance;
    final owner = _identityOf(auth);
    final revision = auth.sessionRevision;
    _boundAccount = owner;
    _boundRevision = revision;
    final loadId = ++_loadId; // 丢弃旧身份在途请求的迟到结果
    await _service.invalidateGatewaySession();
    // 作废会话期间身份可能已再次变化（含尚未通知的静默换号 / 同账号重登）：
    // 代际 + 绑定身份 + 实时身份（账号 + sessionRevision）全部复核后才动
    // UI / 拉取；A 的迟到作废不得清掉 B 的表单/预警开关、不得复活转圈、
    // 不得重复拉目录。
    if (!_isLiveBoundIdentity(owner, revision, loadId: loadId)) return;
    setState(() {
      _authGate = false;
      _loadingBuildings = true;
      _loadingRooms = false;
      _saving = false;
      _error = null;
      // 旧身份的目录、选择与预警设置绝不留给新身份展示；预警设置在当前
      // 身份的设置读回前保持关闭（[_loadAlertSettings]）。
      _areaGroups = [];
      _allBuildings = [];
      _rooms = [];
      _floorMap = {};
      _floorList = [];
      _selectedAreaId = null;
      _selectedBuilding = null;
      _selectedFloor = null;
      _selectedRoom = null;
      _hasSavedRoomConfig = false;
      _alertEnabled = false;
      _alertThreshold = DormElectricityService.defaultAlertThreshold;
    });
    unawaited(_loadAlertSettings());
    await _loadBuildings();
  }

  void _onAuthChanged() {
    final auth = UnifiedAuthService.instance;
    final account = _identityOf(auth);
    final revision = auth.sessionRevision;
    if (account == null) {
      // 登出 / 身份失效：清空目录与表单回登录闸门（不自动再弹登录弹窗）。
      _boundAccount = null;
      _boundRevision = revision;
      _loadId++;
      if (!mounted) return;
      setState(() {
        _authGate = true;
        _loadingBuildings = false;
        _loadingRooms = false;
        _saving = false;
        _error = null;
        _areaGroups = [];
        _allBuildings = [];
        _rooms = [];
        _floorMap = {};
        _floorList = [];
        _selectedAreaId = null;
        _selectedBuilding = null;
        _selectedFloor = null;
        _selectedRoom = null;
        _hasSavedRoomConfig = false;
        _alertEnabled = false;
        _alertThreshold = DormElectricityService.defaultAlertThreshold;
      });
      return;
    }
    // 登录成功 / 冷恢复 / **A→B 换号（两者都已登录）** / 同账号 revision 变化：
    // 作废旧身份在途请求、清空旧目录与选择，立即为新身份拉一次目录。同身份的
    // 重复通知不动，避免无谓重拉。
    if (account != _boundAccount || revision != _boundRevision || _authGate) {
      _boundAccount = account;
      _boundRevision = revision;
      unawaited(_reloadAfterLogin());
    }
  }

  Future<void> _loadAlertSettings() async {
    final owner = _boundAccount;
    final revision = _boundRevision;
    final enabled = await _service.getAlertEnabled();
    final threshold = await _service.getAlertThreshold();
    await widget.debugBeforeAlertSettingsAdopt?.call();
    // 预警设置按身份归属（fail closed）：读取途中换号 / 登出 / 同账号重登
    //（即使监听器尚未通知），旧身份的迟到结果一律丢弃，绝不覆盖新身份的
    // opt-in 界面。
    if (!_isLiveBoundIdentity(owner, revision)) return;
    setState(() {
      _alertEnabled = enabled;
      _alertThreshold = threshold;
    });
  }

  Future<void> _loadBuildings() async {
    final loadId = ++_loadId;
    final owner = _boundAccount;
    final revision = _boundRevision;
    try {
      final areas = await _service.fetchAreas();
      if (!_isLiveBoundIdentity(owner, revision, loadId: loadId)) return;
      if (areas.isEmpty) {
        setState(() {
          _error = '未获取到园区列表';
          _authGate = false;
          _loadingBuildings = false;
        });
        return;
      }

      // 园区数量少（≤2），整表预取让下拉切换零等待。
      final groups = <_AreaGroup>[];
      final allBuildings = <DormBuilding>[];
      for (final area in areas) {
        final buildings = await _service.fetchBuildings(area);
        if (!_isLiveBoundIdentity(owner, revision, loadId: loadId)) return;
        if (buildings.isEmpty) continue;
        groups.add(_AreaGroup(area: area, buildings: buildings));
        allBuildings.addAll(buildings);
      }
      if (!_isLiveBoundIdentity(owner, revision, loadId: loadId)) return;
      if (groups.isEmpty) {
        setState(() {
          _error = '未获取到楼幢列表';
          _authGate = false;
          _loadingBuildings = false;
        });
        return;
      }
      _areaGroups = groups;
      _allBuildings = allBuildings;

      // 目录重载后实例已换：把尚未保存的当前选择按 (areaId, buildingId) 重新绑到
      // 新实例；目录里已不存在则连同楼层 / 房间一并清空。已保存配置的恢复仍在
      // 下面执行并优先于此。
      final stale = _selectedBuilding;
      if (stale != null) {
        DormBuilding? rebound;
        for (final b in allBuildings) {
          if (b.areaId == stale.areaId && b.buildingId == stale.buildingId) {
            rebound = b;
            break;
          }
        }
        _selectedBuilding = rebound;
        if (rebound == null) {
          _selectedAreaId = null;
          _selectedFloor = null;
          _selectedRoom = null;
          _rooms = [];
          _floorMap = {};
          _floorList = [];
        }
      }

      // Restore previously saved config
      final savedConfig = await _service.loadRoomConfig();
      if (!_isLiveBoundIdentity(owner, revision, loadId: loadId)) return;
      if (savedConfig != null) {
        for (final b in _allBuildings) {
          if (b.areaId == savedConfig.areaId &&
              b.buildingId == savedConfig.buildingId) {
            _selectedBuilding = b;
            _selectedAreaId = b.areaId;
            break;
          }
        }
      }

      if (!_isLiveBoundIdentity(owner, revision, loadId: loadId)) return;
      setState(() {
        _error = null;
        _authGate = false;
        _loadingBuildings = false;
        // 归属当前身份的已保存配置存在时预警开关才可用（服务层同口径
        // fail closed：loadRoomConfig 对无主/他人数据一律返回 null）。
        _hasSavedRoomConfig = savedConfig != null;
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
      if (!_isLiveBoundIdentity(owner, revision, loadId: loadId)) return;
      final sessionUnavailable = e is EpaySessionUnavailableException;
      setState(() {
        // DormServiceException / EpaySessionUnavailableException 均携带
        // 可直接展示的原因（维护中 / 会话失效 / 网络错误等），保留原文重试。
        _error =
            e is DormServiceException ||
                sessionUnavailable ||
                e is EpayGatewayException
            ? e.toString()
            : '加载楼幢列表失败';
        // 只有统一认证确实未登录才进登录闸门。epay 明确失效但统一认证仍有效时
        // 保留「原始原因 + 重试」错误态——绝不展示会被本地登录态自动登录成功
        // 的登录闸门/弹窗（会陷入无效重试循环）；网关/网络未知错误同样保持可
        // 重试，绝不误判为认证过期、绝不清理全局统一认证会话。
        _authGate =
            sessionUnavailable && !UnifiedAuthService.instance.isLoggedIn;
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
    final loadId = ++_loadId;
    final owner = _boundAccount;
    final revision = _boundRevision;
    setState(() {
      _loadingRooms = true;
      _rooms = [];
      _floorMap = {};
      _floorList = [];
      _selectedFloor = null;
      _selectedRoom = null;
      _error = null;
    });
    try {
      final rooms = await _service.fetchRooms(
        areaId: areaId,
        buildingId: buildingId,
      );
      if (!_isLiveBoundIdentity(owner, revision, loadId: loadId)) return;
      _rooms = rooms;
      _buildFloorMap();
      // 只有一个楼层分组时直接选中，省去无意义的一步。
      if (_floorList.length == 1) _selectedFloor = _floorList.first;

      if (savedRoomId != null) {
        for (final r in _rooms) {
          if (r.roomId == savedRoomId && r.floorId == savedFloorId) {
            _selectedRoom = r;
            _selectedFloor = _floorKeyOf(r) ?? _selectedFloor;
            break;
          }
        }
      }

      setState(() => _loadingRooms = false);
    } catch (e) {
      if (!_isLiveBoundIdentity(owner, revision, loadId: loadId)) return;
      final sessionUnavailable = e is EpaySessionUnavailableException;
      setState(() {
        _error =
            e is DormServiceException ||
                sessionUnavailable ||
                e is EpayGatewayException
            ? e.toString()
            : '加载房间列表失败';
        // 与楼幢拉取同口径：仅统一认证确实未登录才进登录闸门，epay 明确失效
        // 但统一认证仍有效时保留「原始原因 + 重试」，未知网络错误保留重试。
        _authGate =
            sessionUnavailable && !UnifiedAuthService.instance.isLoggedIn;
        _loadingRooms = false;
      });
    }
  }

  Future<void> _save() async {
    final building = _selectedBuilding;
    final room = _selectedRoom;
    if (building == null || room == null) return;
    final owner = _boundAccount;
    final revision = _boundRevision;

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
      // 保存期间换号/登出/重登（含尚未通知的静默变化）：服务层已按归属拒绝
      // 或回滚写入，绝不把 A 的保存失败反馈到 B 的界面。
      if (!mounted || !_isLiveBoundIdentity(owner, revision)) return;
      setState(() => _saving = false);
      AppFeedback.toast(context, '保存寝室配置失败：$error');
      return;
    }
    // 同上：身份已变化（含静默变化）时不展示 A 的保存成功、不导航。
    if (!mounted || !_isLiveBoundIdentity(owner, revision)) return;
    setState(() {
      _saving = false;
      _hasSavedRoomConfig = true;
    });
    // 保存会按归属重置/落盘预警设置：重新载入当前身份的预警设置再反馈。
    unawaited(_loadAlertSettings());
    if (!mounted) return;
    AppFeedback.toast(context, '寝室配置成功');
    Navigator.of(context).pop();
  }

  Future<void> _saveAlertSettings({bool? enabled, double? threshold}) async {
    final owner = _boundAccount;
    final revision = _boundRevision;
    if (enabled != null) {
      await _service.setAlertEnabled(enabled);
    }
    if (threshold != null) {
      await _service.setAlertThreshold(threshold);
    }
    // 身份已变化（含尚未通知的静默变化）：服务层已按归属拒绝/回滚写入，
    // 不再以旧身份的名义重注册后台任务，也不把写入结果反馈到新身份的界面。
    if (!_isLiveBoundIdentity(owner, revision)) return;
    try {
      await DormElectricityBackground.instance.reRegisterIfNeeded();
    } catch (error) {
      // 后台任务重注册失败不应让设置静默回滚或抛未处理异常，记录即可，
      // 下次切换开关或冷启动仍会重试。
      AppLogger.instance.storage(LogLevel.warn, '电费预警后台任务重注册失败', error: error);
    }
  }

  // ── 下拉选择：预警阈值 / 校区区期 + 楼幢 / 楼层 + 房间号 ──

  void _onThresholdChanged(double? value) {
    if (value == null || value == _alertThreshold) return;
    setState(() => _alertThreshold = value);
    unawaited(_saveAlertSettings(threshold: value));
  }

  /// 换校区区期：只提交到「校区」这一层。已选楼幢若属于别的校区则连同房间
  /// 选择一并清空（并作废在途的房间拉取），绝不留下「校区 A + 楼幢 B」的
  /// 错配组合；选回同一校区不动。
  void _onAreaChanged(String? areaId) {
    if (areaId == null || areaId == _selectedAreaId) return;
    _loadId++; // 丢弃旧楼幢的在途房间拉取
    setState(() {
      _selectedAreaId = areaId;
      _selectedBuilding = null;
      _selectedRoom = null;
      _selectedFloor = null;
      _loadingRooms = false;
      _rooms = [];
      _floorMap = {};
      _floorList = [];
    });
  }

  void _onBuildingChanged(DormBuilding? b) {
    if (b == null) return;
    // 选回当前楼幢（按 areaId+buildingId，目录重载后实例会换）不动，避免清掉
    // 已选房间并重复拉取。
    final current = _selectedBuilding;
    if (current != null &&
        current.areaId == b.areaId &&
        current.buildingId == b.buildingId) {
      return;
    }
    setState(() {
      _selectedAreaId = b.areaId;
      _selectedBuilding = b;
      _selectedRoom = null;
    });
    _loadRooms(areaId: b.areaId, buildingId: b.buildingId);
  }

  /// 换楼层：房间选择属于旧楼层，清空后由用户在新楼层下重选。
  void _onFloorChanged(String? floor) {
    if (floor == null || floor == _selectedFloor) return;
    setState(() {
      _selectedFloor = floor;
      _selectedRoom = null;
    });
  }

  void _onRoomChanged(DormRoom? room) {
    if (room == null) return;
    setState(() => _selectedRoom = room);
  }

  /// 已选房间所属的楼层分组：优先取房间名解析出的楼层，找不到再回退 API 楼层名。
  String? _floorKeyOf(DormRoom room) {
    final label =
        DormElectricityService.parseFloorLabel(room.roomName) ?? room.floorName;
    if (_floorList.contains(label)) return label;
    if (_floorList.contains(room.floorName)) return room.floorName;
    return null;
  }

  // ── 公共 UI ──

  Widget _buildBuildingFields() {
    final groupBuildings = _selectedAreaId == null
        ? const <DormBuilding>[]
        : _areaGroups
              .where((g) => g.areaId == _selectedAreaId)
              .expand((g) => g.buildings)
              .toList();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 3,
          child: AppDropdown<String>(
            key: const Key('dorm_area_dropdown'),
            label: '园区',
            hint: '请选择',
            value: _selectedAreaId,
            items: [
              for (final g in _areaGroups)
                AppDropdownItem(value: g.areaId, label: g.label),
            ],
            onChanged: _onAreaChanged,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: AppDropdown<DormBuilding>(
            key: const Key('dorm_building_dropdown'),
            label: '楼幢',
            hint: '请选择',
            value: _selectedBuilding,
            items: [
              for (final b in groupBuildings)
                AppDropdownItem(value: b, label: b.buildingName),
            ],
            onChanged: _onBuildingChanged,
          ),
        ),
      ],
    );
  }

  Widget _buildRoomFields() {
    final floorRooms = _selectedFloor == null
        ? const <DormRoom>[]
        : (_floorMap[_selectedFloor] ?? const <DormRoom>[]);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: AppDropdown<String>(
            key: const Key('dorm_floor_dropdown'),
            label: '楼层',
            hint: '请选择',
            value: _selectedFloor,
            items: [
              for (final f in _floorList) AppDropdownItem(value: f, label: f),
            ],
            onChanged: _onFloorChanged,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: AppDropdown<DormRoom>(
            key: const Key('dorm_room_dropdown'),
            label: '房间号',
            hint: '请选择',
            value: _selectedRoom,
            items: [
              for (final r in floorRooms)
                AppDropdownItem(value: r, label: '${r.roomName}号'),
            ],
            onChanged: _onRoomChanged,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppAppBar(title: const Text('选择寝室')),
      body: _authGate
          ? AuthRequiredView(
              title: '需要登录一卡通后继续',
              message: '登录一卡通后可选择寝室并管理电费预警',
              buttonLabel: '登录一卡通',
              icon: Icons.king_bed_outlined,
              onAction: () => _presentLoginPrompt(),
            )
          : _loadingBuildings
          // 切换数据主体（目录 / 身份）时旧选择不应再显示，允许阻塞式加载。
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? AppErrorView(
              title: '加载失败',
              message: _error,
              onRetry: () {
                setState(() {
                  _error = null;
                  _loadingBuildings = true;
                });
                _loadBuildings();
              },
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                kPlainListGutter,
                16,
                kPlainListGutter,
                32,
              ),
              children: [
                const PlainSectionHeader('寝室'),
                _buildBuildingFields(),
                const SizedBox(height: 16),
                if (_loadingRooms)
                  const Center(child: CircularProgressIndicator())
                else
                  _buildRoomFields(),
                const SizedBox(height: kPlainListGroupGap),
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
                const SizedBox(height: kPlainListGroupGap + 8),
                const PlainSectionHeader('提醒'),
                PlainListGroup(
                  children: [
                    PlainSwitchRow(
                      title: '低电量预警',
                      // 没有归属当前身份的已保存寝室配置时，预警写入会被
                      // 服务层 no-op：禁用开关并提示先保存寝室，绝不展示
                      // 「可开启」的乐观开关。
                      subtitle: _hasSavedRoomConfig
                          ? '当剩余电量低于设定阈值时发送提醒'
                          : '保存寝室后可开启低电量预警',
                      value: _hasSavedRoomConfig && _alertEnabled,
                      enabled: _hasSavedRoomConfig,
                      onChanged: (v) {
                        setState(() => _alertEnabled = v);
                        _saveAlertSettings(enabled: v);
                      },
                    ),
                  ],
                ),
                if (_hasSavedRoomConfig && _alertEnabled) ...[
                  const SizedBox(height: 12),
                  AppDropdown<double>(
                    key: const Key('dorm_threshold_dropdown'),
                    label: '预警阈值',
                    // 历史遗留的非选项值不在列表里：按钮回落显示当前值。
                    hint: '${_alertThreshold.toInt()} 度',
                    value: _thresholdOptions.contains(_alertThreshold)
                        ? _alertThreshold
                        : null,
                    items: [
                      for (final v in _thresholdOptions)
                        AppDropdownItem(value: v, label: '${v.toInt()} 度'),
                    ],
                    onChanged: _onThresholdChanged,
                  ),
                ],
              ],
            ),
    );
  }
}
