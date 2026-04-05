import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'dorm_electricity_service.dart';

class DormElectricityPage extends StatefulWidget {
  const DormElectricityPage({super.key});

  @override
  State<DormElectricityPage> createState() => _DormElectricityPageState();
}

class _DormElectricityPageState extends State<DormElectricityPage> {
  final _service = DormElectricityService.instance;
  double? _electricity;
  bool _loading = true;
  bool _hasConfig = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    _hasConfig = await _service.hasRoomConfig();
    if (_hasConfig) {
      _electricity = await _service.fetchElectricity();
      _error = _service.lastError;
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('寝室电费'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '选择寝室',
            onPressed: () async {
              await context.pushNamed('dorm-electricity-settings');
              _load();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !_hasConfig
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.home_outlined,
                    size: 64,
                    color: colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  const Text('尚未配置寝室'),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () async {
                      await context.pushNamed('dorm-electricity-settings');
                      _load();
                    },
                    child: const Text('去选择寝室'),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  if (_error != null)
                    Card(
                      color: colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(
                              Icons.wifi_off,
                              color: colorScheme.onErrorContainer,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                '请确认已连接校园网络',
                                style: TextStyle(
                                  color: colorScheme.onErrorContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_error != null) const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 40,
                        horizontal: 24,
                      ),
                      child: Column(
                        children: [
                          Icon(Icons.bolt, size: 56, color: Colors.amber[600]),
                          const SizedBox(height: 16),
                          Text(
                            _service.formatElectricity(_electricity),
                            style: Theme.of(context).textTheme.displayMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.primary,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '度（剩余电量）',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: colorScheme.outline),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                    label: const Text('刷新'),
                  ),
                ],
              ),
            ),
    );
  }
}
