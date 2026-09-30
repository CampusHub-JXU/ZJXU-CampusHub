import 'package:flutter/material.dart';

import '../../shared/widgets/app_dropdown.dart';
import 'changxing_jiada_model.dart';
import 'changxing_jiada_service.dart';

Future<ChangxingAreaSelection?> showChangxingAreaPickerDialog({
  required BuildContext context,
  required ChangxingJiadaService service,
  int? initialAreaId,
}) {
  return showDialog<ChangxingAreaSelection>(
    context: context,
    builder: (_) => _ChangxingAreaPickerDialog(
      service: service,
      initialAreaId: initialAreaId,
    ),
  );
}

class _ChangxingAreaPickerDialog extends StatefulWidget {
  const _ChangxingAreaPickerDialog({
    required this.service,
    required this.initialAreaId,
  });

  final ChangxingJiadaService service;
  final int? initialAreaId;

  @override
  State<_ChangxingAreaPickerDialog> createState() =>
      _ChangxingAreaPickerDialogState();
}

class _ChangxingAreaPickerDialogState
    extends State<_ChangxingAreaPickerDialog> {
  bool _loading = true;
  String? _error;

  List<ChangxingAreaNode> _provinces = const <ChangxingAreaNode>[];
  List<ChangxingAreaNode> _cities = const <ChangxingAreaNode>[];
  List<ChangxingAreaNode> _districts = const <ChangxingAreaNode>[];

  ChangxingAreaNode? _selectedProvince;
  ChangxingAreaNode? _selectedCity;
  ChangxingAreaNode? _selectedDistrict;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final provinces = await widget.service.fetchAreaChildren(0);
      if (provinces.isEmpty) {
        throw Exception('未获取到省份数据');
      }

      var selectedProvince = provinces.first;
      ChangxingAreaNode? selectedCity;
      ChangxingAreaNode? selectedDistrict;

      List<ChangxingAreaNode> cities = const <ChangxingAreaNode>[];
      List<ChangxingAreaNode> districts = const <ChangxingAreaNode>[];

      if ((widget.initialAreaId ?? 0) > 0) {
        final parents = await widget.service.fetchAreaParents(
          widget.initialAreaId!,
        );
        final chain = parents.reversed.toList();
        if (chain.isNotEmpty) {
          selectedProvince =
              _findById(provinces, chain.first.id) ?? selectedProvince;
        }

        cities = await widget.service.fetchAreaChildren(selectedProvince.id);
        if (cities.isNotEmpty && chain.length > 1) {
          selectedCity = _findById(cities, chain[1].id) ?? cities.first;
        } else if (cities.isNotEmpty) {
          selectedCity = cities.first;
        }

        if (selectedCity != null) {
          districts = await widget.service.fetchAreaChildren(selectedCity.id);
          if (districts.isNotEmpty && chain.length > 2) {
            selectedDistrict =
                _findById(districts, chain[2].id) ?? districts.first;
          } else if (districts.isNotEmpty) {
            selectedDistrict = districts.first;
          }
        }
      } else {
        cities = await widget.service.fetchAreaChildren(selectedProvince.id);
        if (cities.isNotEmpty) {
          selectedCity = cities.first;
          districts = await widget.service.fetchAreaChildren(selectedCity.id);
          if (districts.isNotEmpty) {
            selectedDistrict = districts.first;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _provinces = provinces;
        _cities = cities;
        _districts = districts;
        _selectedProvince = selectedProvince;
        _selectedCity = selectedCity;
        _selectedDistrict = selectedDistrict;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载地区失败：$e';
      });
    }
  }

  ChangxingAreaNode? _findById(List<ChangxingAreaNode> list, int id) {
    for (final item in list) {
      if (item.id == id) return item;
    }
    return null;
  }

  Future<void> _onProvinceChanged(ChangxingAreaNode? value) async {
    if (value == null) return;
    setState(() {
      _selectedProvince = value;
      _loading = true;
      _error = null;
    });

    try {
      final cities = await widget.service.fetchAreaChildren(value.id);
      final selectedCity = cities.isNotEmpty ? cities.first : null;
      final districts = selectedCity == null
          ? const <ChangxingAreaNode>[]
          : await widget.service.fetchAreaChildren(selectedCity.id);
      if (!mounted) return;
      setState(() {
        _cities = cities;
        _selectedCity = selectedCity;
        _districts = districts;
        _selectedDistrict = districts.isNotEmpty ? districts.first : null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载城市失败：$e';
      });
    }
  }

  Future<void> _onCityChanged(ChangxingAreaNode? value) async {
    if (value == null) return;
    setState(() {
      _selectedCity = value;
      _loading = true;
      _error = null;
    });

    try {
      final districts = await widget.service.fetchAreaChildren(value.id);
      if (!mounted) return;
      setState(() {
        _districts = districts;
        _selectedDistrict = districts.isNotEmpty ? districts.first : null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载区县失败：$e';
      });
    }
  }

  void _onConfirm() {
    final province = _selectedProvince;
    if (province == null) return;
    final city = _selectedCity;
    final district = _selectedDistrict;
    final target = district ?? city ?? province;
    Navigator.of(context).pop(
      ChangxingAreaSelection(
        id: target.id,
        province: province,
        city: city,
        district: district,
      ),
    );
  }

  Widget _buildDropdown({
    required String label,
    required List<ChangxingAreaNode> items,
    required ChangxingAreaNode? value,
    required ValueChanged<ChangxingAreaNode?> onChanged,
  }) {
    // 按 id 在当前列表里找回同一实例，避免列表刷新后 value 对不上。
    ChangxingAreaNode? effectiveValue;
    if (value != null) {
      for (final item in items) {
        if (item.id == value.id) {
          effectiveValue = item;
          break;
        }
      }
    }

    return AppDropdown<ChangxingAreaNode>(
      label: label,
      value: effectiveValue,
      items: items
          .map(
            (item) => AppDropdownItem<ChangxingAreaNode>(
              value: item,
              label: item.areaName,
            ),
          )
          .toList(),
      onChanged: _loading ? null : onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择生源地'),
      content: SizedBox(
        width: 380,
        child: _loading && _provinces.isEmpty
            ? const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_error != null) ...[
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                  _buildDropdown(
                    label: '省份',
                    items: _provinces,
                    value: _selectedProvince,
                    onChanged: _onProvinceChanged,
                  ),
                  const SizedBox(height: 10),
                  _buildDropdown(
                    label: '城市',
                    items: _cities,
                    value: _selectedCity,
                    onChanged: _onCityChanged,
                  ),
                  const SizedBox(height: 10),
                  _buildDropdown(
                    label: '区县',
                    items: _districts,
                    value: _selectedDistrict,
                    onChanged: (value) {
                      setState(() => _selectedDistrict = value);
                    },
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _loading ? null : _onConfirm,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
