import 'package:flutter/material.dart';
import 'package:rawsr_gui/src/theme/rawsr_theme.dart';

class RawsrPanel extends StatelessWidget {
  const RawsrPanel({required this.child, this.title, this.padding, super.key});

  final Widget child;
  final String? title;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.chrome1,
        border: Border.all(color: palette.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: padding ?? const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (title != null) ...<Widget>[
              Text(title!, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 10),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

class RawsrDivider extends StatelessWidget {
  const RawsrDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Divider(height: 1, thickness: 1, color: context.palette.line);
  }
}

class RawsrBadge extends StatelessWidget {
  const RawsrBadge({required this.label, this.selected = false, super.key});

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected ? palette.safelightDim : palette.chrome2,
        border: Border.all(color: selected ? palette.safelight : palette.line),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall!.copyWith(
            color: selected ? palette.safelight : palette.textLo,
          ),
        ),
      ),
    );
  }
}
