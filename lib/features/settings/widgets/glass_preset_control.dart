import 'package:flutter/material.dart';

class GlassPresetControl extends StatefulWidget {
  const GlassPresetControl({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.presets,
    required this.decimals,
    required this.suffix,
    required this.onPreview,
    required this.onCommit,
    this.displayMultiplier = 1,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final List<double> presets;
  final int decimals;
  final String suffix;
  final double displayMultiplier;
  final ValueChanged<double> onPreview;
  final ValueChanged<double> onCommit;

  @override
  State<GlassPresetControl> createState() => _GlassPresetControlState();
}

class _GlassPresetControlState extends State<GlassPresetControl> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _formatValue(widget.value));
  }

  @override
  void didUpdateWidget(covariant GlassPresetControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.value - oldWidget.value).abs() > 0.001) {
      final text = _formatValue(widget.value);
      if (_controller.text != text) {
        _controller.text = text;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final closest = _closestPresetIndex(widget.value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(
          height: 1,
          thickness: 1,
          indent: 16,
          color: cs.outlineVariant.withValues(alpha: 0.35),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.label}  ${_formatValue(widget.value)}${widget.suffix}',
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 76,
                    child: TextField(
                      controller: _controller,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                      decoration: InputDecoration(
                        isDense: true,
                        suffixText: widget.suffix.isEmpty
                            ? null
                            : widget.suffix,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onSubmitted: _commitText,
                      onTapOutside: (_) => _commitText(_controller.text),
                    ),
                  ),
                ],
              ),
              Slider.adaptive(
                value: closest.toDouble(),
                min: 0,
                max: (widget.presets.length - 1).toDouble(),
                divisions: widget.presets.length - 1,
                label:
                    '${_formatValue(widget.presets[closest])}${widget.suffix}',
                onChanged: (index) {
                  final value = widget.presets[index.round()];
                  widget.onPreview(value);
                },
                onChangeEnd: (index) {
                  widget.onCommit(widget.presets[index.round()]);
                },
              ),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final preset in widget.presets)
                    ChoiceChip(
                      label: Text('${_formatValue(preset)}${widget.suffix}'),
                      selected: (widget.value - preset).abs() < 0.001,
                      onSelected: (_) {
                        widget.onPreview(preset);
                        widget.onCommit(preset);
                      },
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  int _closestPresetIndex(double value) {
    var closest = 0;
    var diff = double.infinity;
    for (var i = 0; i < widget.presets.length; i++) {
      final itemDiff = (widget.presets[i] - value).abs();
      if (itemDiff < diff) {
        closest = i;
        diff = itemDiff;
      }
    }
    return closest;
  }

  String _formatValue(double value) {
    final displayValue = value * widget.displayMultiplier;
    return widget.decimals == 0
        ? displayValue.round().toString()
        : displayValue.toStringAsFixed(widget.decimals);
  }

  void _commitText(String text) {
    final parsed = double.tryParse(text.trim());
    if (parsed == null) {
      _controller.text = _formatValue(widget.value);
      return;
    }
    final rawValue = (parsed / widget.displayMultiplier).clamp(
      widget.min,
      widget.max,
    );
    widget.onPreview(rawValue);
    widget.onCommit(rawValue);
  }
}
