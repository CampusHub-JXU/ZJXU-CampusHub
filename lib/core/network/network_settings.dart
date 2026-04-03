import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NetworkSettings {
  NetworkSettings._();

  static final NetworkSettings instance = NetworkSettings._();

  static const _keyIgnoreSystemProxy = 'ignore_system_proxy';

  final ValueNotifier<bool> ignoreSystemProxy = ValueNotifier<bool>(true);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    ignoreSystemProxy.value = prefs.getBool(_keyIgnoreSystemProxy) ?? true;
  }

  Future<void> setIgnoreSystemProxy(bool value) async {
    if (ignoreSystemProxy.value == value) return;
    ignoreSystemProxy.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyIgnoreSystemProxy, value);
  }
}
