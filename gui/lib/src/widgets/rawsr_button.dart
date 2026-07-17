import 'package:flutter/material.dart';
import 'package:rawsr_gui/src/theme/rawsr_theme.dart';

enum RawsrButtonKind { primary, secondary, text }

class RawsrButton extends StatelessWidget {
  const RawsrButton({
    required this.label,
    required this.onPressed,
    this.kind = RawsrButtonKind.primary,
    this.icon,
    this.shortcut,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final RawsrButtonKind kind;
  final IconData? icon;
  final String? shortcut;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final foreground = kind == RawsrButtonKind.primary
        ? palette.chrome0
        : palette.textHi;
    final background = switch (kind) {
      RawsrButtonKind.primary => palette.safelight,
      RawsrButtonKind.secondary => palette.chrome2,
      RawsrButtonKind.text => palette.transparent,
    };
    final side = kind == RawsrButtonKind.secondary
        ? BorderSide(color: palette.line)
        : BorderSide.none;
    return FilledButton(
      onPressed: onPressed,
      style: ButtonStyle(
        elevation: const WidgetStatePropertyAll<double>(0),
        minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 34)),
        padding: const WidgetStatePropertyAll<EdgeInsets>(
          EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        ),
        backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
          if (states.contains(WidgetState.disabled)) {
            return palette.chrome2;
          }
          if (states.contains(WidgetState.hovered)) {
            return kind == RawsrButtonKind.primary
                ? palette.safelight
                : palette.safelightDim;
          }
          return background;
        }),
        foregroundColor: WidgetStateProperty.resolveWith<Color>((states) {
          if (states.contains(WidgetState.disabled)) return palette.textLo;
          return foreground;
        }),
        side: WidgetStatePropertyAll<BorderSide>(side),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        textStyle: WidgetStatePropertyAll<TextStyle>(
          Theme.of(context).textTheme.labelLarge!,
        ),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 16),
              const SizedBox(width: 6),
            ],
            Text(label),
            if (shortcut != null) ...<Widget>[
              const SizedBox(width: 8),
              RawsrShortcutHint(shortcut!),
            ],
          ],
        ),
      ),
    );
  }
}

class RawsrShortcutHint extends StatelessWidget {
  const RawsrShortcutHint(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.chrome1,
        border: Border.all(color: palette.line),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        child: Text(
          label,
          style: context.mono.copyWith(fontSize: 10, color: palette.textLo),
        ),
      ),
    );
  }
}
