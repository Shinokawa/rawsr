import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/features/canvas/canvas_controller.dart';
import 'package:rawsr_gui/src/features/library/library_controller.dart';
import 'package:rawsr_gui/src/features/models/models_controller.dart';
import 'package:rawsr_gui/src/features/queue/export_dialog.dart';
import 'package:rawsr_gui/src/features/test_strip/test_strip_controller.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';
import 'package:rawsr_gui/src/theme/rawsr_theme.dart';
import 'package:rawsr_gui/src/widgets/rawsr_button.dart';
import 'package:rawsr_gui/src/widgets/rawsr_controls.dart';
import 'package:rawsr_gui/src/widgets/rawsr_panel.dart';

class Inspector extends ConsumerWidget {
  const Inspector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider);
    final item = library.selected;
    final handle = ref.watch(canvasProvider.select((state) => state.handle));
    return ColoredBox(
      color: context.palette.chrome0,
      child: item == null
          ? Center(
              child: Text(
                '选择一张照片查看参数',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(12),
              children: <Widget>[
                _ExifPanel(
                  item: item,
                  sourceWidth: handle?.width,
                  sourceHeight: handle?.height,
                ),
                const SizedBox(height: 10),
                _DevelopPanel(item: item),
                const SizedBox(height: 10),
                const _ModelsPanel(),
              ],
            ),
    );
  }
}

class _ExifPanel extends StatelessWidget {
  const _ExifPanel({
    required this.item,
    required this.sourceWidth,
    required this.sourceHeight,
  });

  final LibraryItem item;
  final int? sourceWidth;
  final int? sourceHeight;

  @override
  Widget build(BuildContext context) {
    final thumb = item.thumbnail;
    final exif = thumb?.exif;
    return RawsrPanel(
      title: 'EXIF',
      child: Column(
        children: <Widget>[
          _ExifRow('机身', _join(exif?.make, exif?.model)),
          _ExifRow('镜头', exif?.lensModel ?? '—'),
          _ExifRow('ISO', exif?.iso?.toString() ?? '—'),
          _ExifRow('快门', _shutter(exif?.exposureSeconds)),
          _ExifRow(
            '光圈',
            exif?.aperture == null
                ? '—'
                : 'f/${exif!.aperture!.toStringAsFixed(1)}',
          ),
          _ExifRow(
            '焦距',
            exif?.focalLengthMm == null
                ? '—'
                : '${exif!.focalLengthMm!.toStringAsFixed(0)} mm',
          ),
          _ExifRow(
            '尺寸',
            sourceWidth != null && sourceHeight != null
                ? '$sourceWidth × $sourceHeight'
                : thumb == null
                ? '—'
                : '${thumb.width} × ${thumb.height}',
            suffix: sourceWidth == null && sourceHeight == null && thumb != null
                ? '预览'
                : null,
          ),
        ],
      ),
    );
  }

  static String _join(String? a, String? b) {
    return <String>[
      if (a?.isNotEmpty ?? false) a!,
      if (b?.isNotEmpty ?? false) b!,
    ].join(' ');
  }

  static String _shutter(double? seconds) {
    if (seconds == null || seconds <= 0) return '—';
    if (seconds >= 1) return '${seconds.toStringAsFixed(1)} s';
    return '1/${(1 / seconds).round()} s';
  }
}

class _ExifRow extends StatelessWidget {
  const _ExifRow(this.label, this.value, {this.suffix});

  final String label;
  final String value;
  final String? suffix;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 48,
            child: Text(label, style: Theme.of(context).textTheme.labelSmall),
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                Flexible(
                  child: Text(
                    value.isEmpty ? '—' : value,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: context.mono.copyWith(
                      fontSize: 11,
                      color: context.palette.textHi,
                    ),
                  ),
                ),
                if (suffix != null) ...<Widget>[
                  const SizedBox(width: 4),
                  Text(
                    suffix!,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: context.palette.textHi,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DevelopPanel extends ConsumerWidget {
  const _DevelopPanel({required this.item});

  final LibraryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RawsrPanel(
      title: '显影参数',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          RawsrSlider(
            label: '曝光 EV',
            value: item.exposureEv,
            min: -4,
            max: 4,
            displayValue:
                '${item.exposureEv >= 0 ? '+' : ''}${item.exposureEv.toStringAsFixed(2)}',
            onChanged: ref.read(libraryProvider.notifier).updateExposure,
          ),
          const SizedBox(height: 4),
          Text('基础曲线', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              Expanded(
                child: RawsrButton(
                  label: 'sRGB',
                  kind: item.baseCurve == BaseCurveOption.srgb
                      ? RawsrButtonKind.primary
                      : RawsrButtonKind.secondary,
                  onPressed: () => ref
                      .read(libraryProvider.notifier)
                      .updateBaseCurve(BaseCurveOption.srgb),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: RawsrButton(
                  label: 'Filmic',
                  kind: item.baseCurve == BaseCurveOption.filmic
                      ? RawsrButtonKind.primary
                      : RawsrButtonKind.secondary,
                  onPressed: () => ref
                      .read(libraryProvider.notifier)
                      .updateBaseCurve(BaseCurveOption.filmic),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          RawsrButton(
            label: '应用显影',
            kind: RawsrButtonKind.secondary,
            onPressed: () => ref.read(canvasProvider.notifier).open(item),
          ),
        ],
      ),
    );
  }
}

class _ModelsPanel extends ConsumerWidget {
  const _ModelsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(modelsProvider);
    final selected = ref.watch(selectedModelsProvider);
    final canvas = ref.watch(canvasProvider);
    final strip = ref.watch(testStripProvider);
    return RawsrPanel(
      title: '试片模型',
      child: models.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (error, stackTrace) => Text(
          '模型清单读取失败：$error。请检查 models/manifest.json。',
          style: Theme.of(
            context,
          ).textTheme.bodySmall!.copyWith(color: context.palette.danger),
        ),
        data: (entries) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final entry in entries) ...<Widget>[
              _ModelChoice(
                entry: entry,
                selected: selected.contains(entry.name),
                onTap: entry.installed
                    ? () => ref
                          .read(selectedModelsProvider.notifier)
                          .toggle(entry.name)
                    : null,
              ),
              const SizedBox(height: 6),
            ],
            const SizedBox(height: 4),
            RawsrButton(
              label: '生成试片',
              shortcut: 'Enter',
              onPressed: selected.length >= 2 && canvas.crop != null
                  ? () => unawaited(
                      ref
                          .read(testStripProvider.notifier)
                          .generate(canvas, selected.toList(growable: false)),
                    )
                  : null,
            ),
            const SizedBox(height: 6),
            Text(
              strip.champion != null
                  ? '已定片：${strip.champion}'
                  : selected.length < 2
                  ? '选择 2–4 个已安装模型。'
                  : canvas.crop == null
                  ? '在画布上框选区域后生成试片。'
                  : '已选择 ${selected.length} 个模型。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (strip.results.isNotEmpty && !strip.visible) ...<Widget>[
              const SizedBox(height: 6),
              RawsrButton(
                label: '查看试片',
                kind: RawsrButtonKind.secondary,
                onPressed: ref.read(testStripProvider.notifier).showComparison,
              ),
            ],
            if (strip.champion != null) ...<Widget>[
              const SizedBox(height: 6),
              RawsrButton(
                label: '加入队列',
                shortcut: 'Ctrl Enter',
                onPressed: () => unawaited(showExportDialog(context, ref)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModelChoice extends StatelessWidget {
  const _ModelChoice({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final ModelEntry entry;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Material(
      color: selected ? palette.safelightDim : palette.chrome2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: selected ? palette.safelight : palette.line),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          child: Row(
            children: <Widget>[
              Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                size: 16,
                color: entry.installed ? palette.safelight : palette.textLo,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      entry.name,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    Text(
                      entry.installed
                          ? '${entry.kind} · ${entry.scale}×'
                          : '未安装',
                      style: context.mono.copyWith(
                        fontSize: 10,
                        color: palette.textLo,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
