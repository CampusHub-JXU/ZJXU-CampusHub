import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_logger.dart';
import 'calendar_event_ledger_store.dart';
import 'calendar_sync_models.dart';
import 'calendar_sync_control.dart' show CalendarSyncControl;

// 自 calendar_sync_control.dart 拆出：控制状态枚举、持久化绑定与其单 key 存储。
// 由 calendar_sync_control.dart re-export，调用方无需改 import。

/// 系统日历同步的控制状态。
///
/// - [off]：默认；未绑定任何 owner，不允许写入。
/// - [enabled]：已由用户显式开启，绑定一个已验证正方 owner + 目标日历。
///   当前没有已验证身份（教务未登录 / 会话过期 / 冷启动尚未恢复）时仍保持
///   [enabled]，只是处于 [CalendarSyncControl.isWaitingForIdentity]（不写日历）。
/// - [paused]：原 owner 的账本保留，但当前**已验证身份是另一个账号**（真正换号），
///   停止一切写入；同账号重登或重新显式 [CalendarSyncControl.enable] 才恢复。
///   登出 / 会话缺失**不会**进入 [paused]。
/// - [cleanupPending]：用户已要求关闭并清理，未来写入被阻断；仍有删不掉/权限
///   拒绝/日历被移的事件残留，等待用户再次触发清理。绝不以清空账本假装完成。
enum CalendarSyncControlState { off, enabled, paused, cleanupPending }

/// 持久化的控制绑定：状态 + 已验证 owner + 目标日历。
///
/// 只存 owner 标识与日历 id，**不存任何凭据**（密码 / cookie / token 都不在此）。
@immutable
class CalendarSyncControlBinding {
  const CalendarSyncControlBinding({
    required this.state,
    this.ownerKey,
    this.calendarId,
  });

  static const CalendarSyncControlBinding off = CalendarSyncControlBinding(
    state: CalendarSyncControlState.off,
  );

  final CalendarSyncControlState state;

  /// 绑定 owner（私有的已验证正方学号标识）；[off] 时为 null。
  final String? ownerKey;

  /// 绑定目标日历 id；[off] 时为 null。
  final int? calendarId;

  bool get isValid {
    if (state == CalendarSyncControlState.off) {
      return ownerKey == null && calendarId == null;
    }
    return ownerKey != null &&
        ownerKey!.trim().isNotEmpty &&
        calendarId != null &&
        calendarId! > 0;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'v': CalendarSyncControlStore.schemaVersion,
    'state': state.name,
    'ownerKey': ownerKey,
    'calendarId': calendarId,
  };

  /// 严格解析；版本/结构不符返回 null（由 store 失败关闭为 off）。
  static CalendarSyncControlBinding? tryParse(Object? raw) {
    if (raw is! Map) return null;
    if (raw['v'] != CalendarSyncControlStore.schemaVersion) return null;

    final rawState = raw['state'];
    if (rawState is! String) return null;
    CalendarSyncControlState? state;
    for (final value in CalendarSyncControlState.values) {
      if (value.name == rawState) {
        state = value;
        break;
      }
    }
    if (state == null) return null;

    final rawOwner = raw['ownerKey'];
    if (rawOwner != null && rawOwner is! String) return null;
    final ownerKey = rawOwner is String && rawOwner.trim().isNotEmpty
        ? rawOwner.trim()
        : null;

    final rawCalendarId = raw['calendarId'];
    if (rawCalendarId != null && rawCalendarId is! int) return null;
    final calendarId = rawCalendarId is int && rawCalendarId > 0
        ? rawCalendarId
        : null;

    final binding = CalendarSyncControlBinding(
      state: state,
      ownerKey: ownerKey,
      calendarId: calendarId,
    );
    return binding.isValid ? binding : null;
  }

  @override
  String toString() =>
      'CalendarSyncControlBinding(state: ${state.name}, '
      'calendarId: $calendarId)';
}

/// 控制态持久化抽象，便于测试注入可控 store（内存/可阻塞）。
///
/// 生产实现为 [CalendarSyncControlStore]（单 JSON key）。
abstract interface class CalendarSyncStateStore {
  Future<CalendarSyncControlBinding> read();
  Future<void> write(CalendarSyncControlBinding binding);
  Future<void> clear();
}

/// 控制状态的单 JSON key 持久化（同 isolate 串行；仅前台主 isolate 使用）。
///
/// 损坏时**失败关闭为 [CalendarSyncControlBinding.off]**（不写入、不删原值），
/// 因为控制态不是事件归属数据；真正的归属账本由
/// [CalendarEventLedgerStore] 独立持久化且绝不静默丢弃。
class CalendarSyncControlStore implements CalendarSyncStateStore {
  CalendarSyncControlStore._();

  static final CalendarSyncControlStore instance = CalendarSyncControlStore._();

  static const String storageKey = 'calendar_sync_control_v1';
  static const int schemaVersion = 1;

  @visibleForTesting
  static CalendarSyncControlStore debugNew() => CalendarSyncControlStore._();

  /// 读盘；空值 / 损坏一律返回 [CalendarSyncControlBinding.off]（失败关闭）。
  @override
  Future<CalendarSyncControlBinding> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return CalendarSyncControlBinding.off;

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      AppLogger.instance.warn('日历同步控制状态 JSON 损坏，失败关闭为 off（原值保留）');
      return CalendarSyncControlBinding.off;
    }
    final binding = CalendarSyncControlBinding.tryParse(decoded);
    if (binding == null) {
      AppLogger.instance.warn('日历同步控制状态结构不符合协议，失败关闭为 off（原值保留）');
      return CalendarSyncControlBinding.off;
    }
    return binding;
  }

  @override
  Future<void> write(CalendarSyncControlBinding binding) async {
    assert(binding.isValid);
    final prefs = await SharedPreferences.getInstance();
    final written = await prefs.setString(
      storageKey,
      jsonEncode(binding.toJson()),
    );
    if (!written) {
      throw CalendarSyncException.ledgerUnavailable('日历同步控制状态写入未确认');
    }
  }

  /// 显式清除控制态（仅 [CalendarSyncControl] 在清理完成或重置时调用）。
  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    final existed = prefs.containsKey(storageKey);
    final removed = await prefs.remove(storageKey);
    if (existed && !removed) {
      throw CalendarSyncException.ledgerUnavailable('日历同步控制状态清除失败');
    }
  }
}
