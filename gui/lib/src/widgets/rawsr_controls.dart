import 'package:flutter/material.dart';
import 'package:rawsr_gui/src/theme/rawsr_theme.dart';

class RawsrTextInput extends StatelessWidget {
  const RawsrTextInput({
    required this.controller,
    this.label,
    this.hint,
    this.onChanged,
    super.key,
  });

  final TextEditingController controller;
  final String? label;
  final String? hint;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: Theme.of(context).textTheme.bodyMedium,
      decoration: InputDecoration(labelText: label, hintText: hint),
    );
  }
}

class RawsrSlider extends StatelessWidget {
  const RawsrSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.displayValue,
    super.key,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final String? displayValue;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.labelSmall),
            ),
            Text(
              displayValue ?? value.toStringAsFixed(2),
              style: context.mono.copyWith(
                color: context.palette.textHi,
                fontSize: 11,
              ),
            ),
          ],
        ),
        Slider(value: value, min: min, max: max, onChanged: onChanged),
      ],
    );
  }
}

class RawsrProgressBar extends StatelessWidget {
  const RawsrProgressBar({required this.value, this.label, super.key});

  final double value;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (label != null) ...<Widget>[
          Text(label!, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 4),
        ],
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: value.clamp(0, 1),
            minHeight: 4,
            color: palette.safelight,
            backgroundColor: palette.line,
          ),
        ),
      ],
    );
  }
}
