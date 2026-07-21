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
import 'package:rawsr_gui/src/widgets/rawsr_panel.dart';

class Inspector extends ConsumerWidget {
  const Inspector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<int>(
      canvasProvider.select((state) => state.gradeCommitRevision),
      (previous, next) {
        if (previous != null && next > previous) {
          ref.read(testStripProvider.notifier).invalidateForGradeChange();
        }
      },
    );
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
                _GradePanel(item: item),
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

class _DevelopPanel extends ConsumerStatefulWidget {
  const _DevelopPanel({required this.item});

  final LibraryItem item;

  @override
  ConsumerState<_DevelopPanel> createState() => _DevelopPanelState();
}

class _DevelopPanelState extends ConsumerState<_DevelopPanel> {
  late final TextEditingController _exposureController;
  late final FocusNode _exposureFocus;

  LibraryItem get item => widget.item;

  @override
  void initState() {
    super.initState();
    _exposureController = TextEditingController(
      text: _formatExposure(item.exposureEv),
    );
    _exposureFocus = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _DevelopPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.exposureEv != item.exposureEv &&
        !_exposureFocus.hasFocus) {
      _syncExposureText(item.exposureEv);
    }
  }

  @override
  void dispose() {
    _exposureController.dispose();
    _exposureFocus.dispose();
    super.dispose();
  }

  void _commitExposure() {
    final parsed = double.tryParse(
      _exposureController.text.trim().replaceAll(',', '.'),
    );
    if (parsed == null || !parsed.isFinite) {
      _syncExposureText(item.exposureEv);
      return;
    }
    _setExposure(parsed.clamp(-4.0, 4.0).toDouble());
  }

  void _setExposure(double value) {
    ref.read(libraryProvider.notifier).updateExposure(value);
    _syncExposureText(value);
  }

  void _syncExposureText(double value) {
    final text = _formatExposure(value);
    if (_exposureController.text == text) return;
    _exposureController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  String _formatExposure(double value) => value.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    return RawsrPanel(
      title: '显影参数',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '曝光 EV',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              SizedBox(
                width: 92,
                child: TextField(
                  key: const ValueKey<String>('exposure-input'),
                  controller: _exposureController,
                  focusNode: _exposureFocus,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                  textInputAction: TextInputAction.done,
                  textAlign: TextAlign.right,
                  style: context.mono.copyWith(fontSize: 11),
                  decoration: const InputDecoration(
                    isDense: true,
                    suffixText: ' EV',
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                  onSubmitted: (_) => _commitExposure(),
                  onTapOutside: (_) {
                    _commitExposure();
                    _exposureFocus.unfocus();
                  },
                ),
              ),
              const SizedBox(width: 4),
              RawsrButton(
                key: const ValueKey<String>('exposure-reset'),
                label: '归零',
                kind: RawsrButtonKind.text,
                onPressed: item.exposureEv == 0 ? null : () => _setExposure(0),
              ),
            ],
          ),
          Slider(
            value: item.exposureEv,
            min: -4,
            max: 4,
            divisions: 160,
            onChanged: _setExposure,
          ),
          Text(
            '可直接输入 -4.00 至 +4.00，按 Enter 应用。',
            style: Theme.of(context).textTheme.bodySmall,
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
            onPressed: () {
              _commitExposure();
              final updated = ref.read(libraryProvider).selected;
              if (updated != null) {
                ref.read(testStripProvider.notifier).resetForSourceChange();
                unawaited(ref.read(canvasProvider.notifier).open(updated));
              }
            },
          ),
        ],
      ),
    );
  }
}

class _GradePanel extends ConsumerWidget {
  const _GradePanel({required this.item});

  final LibraryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grade = item.grade;
    final controller = ref.read(libraryProvider.notifier);
    final previewing = ref.watch(
      canvasProvider.select((state) => state.gradePreviewing),
    );

    void updateGrade(ValueChanged<double> update, double value) {
      update(value);
      final updated = ref.read(libraryProvider).selected;
      if (updated != null) {
        ref
            .read(canvasProvider.notifier)
            .requestGradePreview(updated, immediate: false);
      }
    }

    void commitGrade() {
      final updated = ref.read(libraryProvider).selected;
      if (updated != null) {
        ref
            .read(canvasProvider.notifier)
            .requestGradePreview(updated, immediate: true);
      }
    }

    return RawsrPanel(
      title: '基础调色',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _GradeControl(
            id: 'contrast',
            label: '对比度',
            value: grade.contrast,
            onChanged: (value) => updateGrade(controller.updateContrast, value),
            onCommitted: commitGrade,
          ),
          _GradeControl(
            id: 'highlights',
            label: '高光',
            value: grade.highlights,
            onChanged: (value) =>
                updateGrade(controller.updateHighlights, value),
            onCommitted: commitGrade,
          ),
          _GradeControl(
            id: 'shadows',
            label: '阴影',
            value: grade.shadows,
            onChanged: (value) => updateGrade(controller.updateShadows, value),
            onCommitted: commitGrade,
          ),
          _GradeControl(
            id: 'whites',
            label: '白色色阶',
            value: grade.whites,
            onChanged: (value) => updateGrade(controller.updateWhites, value),
            onCommitted: commitGrade,
          ),
          _GradeControl(
            id: 'blacks',
            label: '黑色色阶',
            value: grade.blacks,
            onChanged: (value) => updateGrade(controller.updateBlacks, value),
            onCommitted: commitGrade,
          ),
          _GradeControl(
            id: 'vibrance',
            label: '自然饱和度',
            value: grade.vibrance,
            onChanged: (value) => updateGrade(controller.updateVibrance, value),
            onCommitted: commitGrade,
          ),
          _GradeControl(
            id: 'saturation',
            label: '饱和度',
            value: grade.saturation,
            onChanged: (value) =>
                updateGrade(controller.updateSaturation, value),
            onCommitted: commitGrade,
          ),
          const SizedBox(height: 4),
          Text(
            previewing ? '正在更新调色预览…' : '滑杆、数值输入与归零会自动更新预览。',
            key: const ValueKey<String>('grade-preview-status'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _GradeControl extends StatefulWidget {
  const _GradeControl({
    required this.id,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.onCommitted,
  });

  final String id;
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback onCommitted;

  @override
  State<_GradeControl> createState() => _GradeControlState();
}

class _GradeControlState extends State<_GradeControl> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _format(widget.value));
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _GradeControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_focusNode.hasFocus) {
      _syncText(widget.value);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _commit() {
    final parsed = double.tryParse(
      _controller.text.trim().replaceAll(',', '.'),
    );
    if (parsed == null || !parsed.isFinite) {
      _syncText(widget.value);
      return;
    }
    _setValue(parsed, committed: true);
  }

  void _setValue(double value, {bool committed = false}) {
    final clamped = value.clamp(gradeMinimum, gradeMaximum).toDouble();
    widget.onChanged(clamped);
    _syncText(clamped);
    if (committed) widget.onCommitted();
  }

  void _syncText(double value) {
    final text = _format(value);
    if (_controller.text == text) return;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  String _format(double value) {
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  widget.label,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              SizedBox(
                width: 58,
                height: 30,
                child: TextField(
                  key: ValueKey<String>('${widget.id}-input'),
                  controller: _controller,
                  focusNode: _focusNode,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                  textInputAction: TextInputAction.done,
                  textAlign: TextAlign.right,
                  style: context.mono.copyWith(fontSize: 11),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 7,
                    ),
                  ),
                  onSubmitted: (_) => _commit(),
                  onTapOutside: (_) {
                    _commit();
                    _focusNode.unfocus();
                  },
                ),
              ),
              IconButton(
                key: ValueKey<String>('${widget.id}-reset'),
                tooltip: '重置${widget.label}',
                onPressed: widget.value == 0
                    ? null
                    : () => _setValue(0, committed: true),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 30,
                  height: 30,
                ),
                icon: const Icon(Icons.restart_alt, size: 15),
              ),
            ],
          ),
          SizedBox(
            height: 24,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 11),
              ),
              child: Slider(
                key: ValueKey<String>('${widget.id}-slider'),
                value: widget.value,
                min: gradeMinimum,
                max: gradeMaximum,
                divisions: 200,
                onChanged: _setValue,
                onChangeEnd: (_) => widget.onCommitted(),
              ),
            ),
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
      title: '降噪 / 超分',
      child: models.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (error, stackTrace) => Text(
          '模型清单读取失败：$error。请检查 models/manifest.json。',
          style: Theme.of(
            context,
          ).textTheme.bodySmall!.copyWith(color: context.palette.danger),
        ),
        data: (entries) {
          final denoiseEntries = entries
              .where((entry) => entry.kind == 'denoise')
              .toList(growable: false);
          final srEntries = entries
              .where((entry) => entry.kind == 'sr')
              .toList(growable: false);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _ModelGroup(
                title: '降噪',
                kind: 'denoise',
                entries: denoiseEntries,
                selected: selected.denoise,
                canvas: canvas,
                strip: strip,
                onToggle: (name) => ref
                    .read(selectedModelsProvider.notifier)
                    .toggle('denoise', name),
                onGenerate: () => unawaited(
                  ref
                      .read(testStripProvider.notifier)
                      .generate(
                        kind: 'denoise',
                        canvas: canvas,
                        models: selected.denoise.toList(growable: false),
                        maxScale: _selectedMaxScale(
                          denoiseEntries,
                          selected.denoise,
                        ),
                      ),
                ),
              ),
              const SizedBox(height: 10),
              Divider(height: 1, color: context.palette.line),
              const SizedBox(height: 10),
              _ModelGroup(
                title: '超分',
                kind: 'sr',
                entries: srEntries,
                selected: selected.sr,
                canvas: canvas,
                strip: strip,
                onToggle: (name) => ref
                    .read(selectedModelsProvider.notifier)
                    .toggle('sr', name),
                onGenerate: () => unawaited(
                  ref
                      .read(testStripProvider.notifier)
                      .generate(
                        kind: 'sr',
                        canvas: canvas,
                        models: selected.sr.toList(growable: false),
                        maxScale: _selectedMaxScale(srEntries, selected.sr),
                      ),
                ),
              ),
              if (strip.results.isNotEmpty && !strip.visible) ...<Widget>[
                const SizedBox(height: 10),
                RawsrButton(
                  label: '查看${strip.kind == 'sr' ? '超分' : '降噪'}试片',
                  kind: RawsrButtonKind.secondary,
                  onPressed: ref
                      .read(testStripProvider.notifier)
                      .showComparison,
                ),
              ],
              const SizedBox(height: 10),
              RawsrButton(
                label: '处理 / 导出',
                shortcut: 'Ctrl Enter',
                onPressed:
                    canvas.handle == null ||
                        canvas.loading ||
                        canvas.gradePreviewing
                    ? null
                    : () => unawaited(showExportDialog(context, ref)),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ModelGroup extends StatelessWidget {
  const _ModelGroup({
    required this.title,
    required this.kind,
    required this.entries,
    required this.selected,
    required this.canvas,
    required this.strip,
    required this.onToggle,
    required this.onGenerate,
  });

  final String title;
  final String kind;
  final List<ModelEntry> entries;
  final Set<String> selected;
  final CanvasState canvas;
  final TestStripState strip;
  final ValueChanged<String> onToggle;
  final VoidCallback onGenerate;

  @override
  Widget build(BuildContext context) {
    final champion = strip.championFor(kind);
    final preDenoise = kind == 'sr' ? strip.championFor('denoise') : null;
    final canGenerate =
        selected.length == 1 &&
        canvas.handle != null &&
        !canvas.loading &&
        !canvas.gradePreviewing &&
        !strip.running;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          preDenoise == null ? title : '$title · 前级 $preDenoise',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 6),
        if (entries.isEmpty)
          Text('没有可用模型。', style: Theme.of(context).textTheme.bodySmall)
        else
          for (final entry in entries) ...<Widget>[
            _ModelChoice(
              entry: entry,
              selected: selected.contains(entry.name),
              onTap: entry.installed ? () => onToggle(entry.name) : null,
            ),
            const SizedBox(height: 6),
          ],
        RawsrButton(
          label: '生成$title试片',
          kind: RawsrButtonKind.secondary,
          onPressed: canGenerate ? onGenerate : null,
        ),
        const SizedBox(height: 5),
        Text(
          kind == 'sr' && strip.srNeedsRetest
              ? '降噪定片已变化，请重新生成超分试片。'
              : champion != null
              ? '已定片：$champion'
              : selected.length != 1
              ? '选择 1 个$title模型；选择另一个会自动替换。'
              : canvas.crop == null
              ? '未框选：从全图中央自动取样；最终导出仍可处理全图。'
              : preDenoise == null
              ? '将对框选区域生成试片。'
              : '将先运行 $preDenoise，再比较框选区域的超分结果。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

int _selectedMaxScale(List<ModelEntry> entries, Set<String> selected) {
  return entries
      .where((entry) => selected.contains(entry.name))
      .fold<int>(
        1,
        (value, entry) => entry.scale > value ? entry.scale : value,
      );
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
                          ? '${entry.kind == 'sr' ? '超分' : '降噪'} · ${entry.scale}×'
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
