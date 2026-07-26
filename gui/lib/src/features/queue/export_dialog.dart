import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/features/canvas/canvas_controller.dart';
import 'package:rawsr_gui/src/features/library/library_controller.dart';
import 'package:rawsr_gui/src/features/models/models_controller.dart';
import 'package:rawsr_gui/src/features/queue/queue_controller.dart';
import 'package:rawsr_gui/src/features/test_strip/test_strip_controller.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';
import 'package:rawsr_gui/src/theme/rawsr_theme.dart';
import 'package:rawsr_gui/src/widgets/rawsr_button.dart';

Future<void> showExportDialog(BuildContext context, WidgetRef ref) async {
  final canvas = ref.read(canvasProvider);
  final item = ref.read(libraryProvider).selected;
  final models = ref.read(modelsProvider).valueOrNull ?? const <ModelEntry>[];
  final strip = ref.read(testStripProvider);
  if (canvas.handle == null || item == null) {
    _showMessage(context, '无法加入队列：请先打开一张照片。');
    return;
  }
  if (canvas.loading || canvas.gradePreviewing) {
    _showMessage(context, '调色预览正在更新，请完成后再导出。');
    return;
  }

  final installedDenoise = models
      .where((entry) => entry.installed && entry.kind == 'denoise')
      .toList();
  final installedSr = models
      .where((entry) => entry.installed && entry.kind == 'sr')
      .toList();
  final denoiseChampion = strip.championFor('denoise');
  final srChampion = strip.championFor('sr');
  String? denoise =
      installedDenoise.any((entry) => entry.name == denoiseChampion)
      ? denoiseChampion
      : null;
  String? sr =
      installedSr.any((entry) => entry.name == srChampion) &&
          strip.srChampionPreDenoiseModel == denoiseChampion
      ? srChampion
      : null;
  var selectedArea = canvas.crop != null;
  var device = 'auto';
  var outputFormat = 'jpeg';
  var denoiseStrength = 0.7;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            backgroundColor: context.palette.chrome1,
            title: Text('处理与导出', style: Theme.of(context).textTheme.titleSmall),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  DropdownButtonFormField<String?>(
                    initialValue: denoise,
                    decoration: const InputDecoration(labelText: '降噪模型'),
                    items: <DropdownMenuItem<String?>>[
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('不使用降噪'),
                      ),
                      for (final entry in installedDenoise)
                        DropdownMenuItem<String?>(
                          value: entry.name,
                          child: Text(entry.name),
                        ),
                    ],
                    onChanged: (value) => setState(() {
                      denoise = value;
                      if (sr == srChampion &&
                          denoise != strip.srChampionPreDenoiseModel) {
                        sr = null;
                      }
                    }),
                  ),
                  if (denoise != null) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      '降噪强度 ${(denoiseStrength * 100).round()}% · 调低可保留更多细节',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Slider(
                      value: denoiseStrength,
                      min: 0.2,
                      max: 1,
                      divisions: 16,
                      label: '${(denoiseStrength * 100).round()}%',
                      onChanged: (value) =>
                          setState(() => denoiseStrength = value),
                    ),
                  ],
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String?>(
                    initialValue: sr,
                    decoration: const InputDecoration(labelText: '超分模型'),
                    items: <DropdownMenuItem<String?>>[
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('不使用超分'),
                      ),
                      for (final entry in installedSr)
                        DropdownMenuItem<String?>(
                          value: entry.name,
                          child: Text(entry.name),
                        ),
                    ],
                    onChanged: (value) => setState(() => sr = value),
                  ),
                  if (strip.srNeedsRetest) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      '降噪定片已变化，旧超分定片未自动带入；请重新生成超分试片，或在此手动选择。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: device,
                    decoration: const InputDecoration(labelText: '推理设备'),
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem<String>(
                        value: 'auto',
                        child: Text('自动'),
                      ),
                      DropdownMenuItem<String>(
                        value: 'directml',
                        child: Text('DirectML'),
                      ),
                      DropdownMenuItem<String>(
                        value: 'cpu',
                        child: Text('CPU'),
                      ),
                      DropdownMenuItem<String>(
                        value: 'cuda',
                        child: Text('CUDA'),
                      ),
                      DropdownMenuItem<String>(
                        value: 'coreml',
                        child: Text('CoreML'),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => device = value ?? 'auto'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: outputFormat,
                    decoration: const InputDecoration(labelText: '导出格式'),
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem(
                        value: 'jpeg',
                        child: Text('JPEG 交付版（质量 92，最长边 12000px）'),
                      ),
                      DropdownMenuItem(
                        value: 'tiff',
                        child: Text('16 位 TIFF 母版（原生尺寸）'),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => outputFormat = value ?? 'jpeg'),
                  ),
                  const SizedBox(height: 6),
                  Builder(
                    builder: (context) {
                      final sourceWidth = selectedArea && canvas.crop != null
                          ? canvas.crop!.width.ceil()
                          : canvas.handle!.width;
                      final sourceHeight = selectedArea && canvas.crop != null
                          ? canvas.crop!.height.ceil()
                          : canvas.handle!.height;
                      final scale = _scaleForModel(sr, installedSr);
                      final nativeWidth = sourceWidth * scale;
                      final nativeHeight = sourceHeight * scale;
                      final delivered = _fitDimensions(
                        nativeWidth,
                        nativeHeight,
                        12000,
                      );
                      return Text(
                        outputFormat == 'jpeg'
                            ? '交付尺寸：${delivered.$1} × ${delivered.$2}（模型原生：$nativeWidth × $nativeHeight）'
                            : '母版尺寸：$nativeWidth × $nativeHeight；全尺寸超分文件会很大。',
                        style: Theme.of(context).textTheme.bodySmall,
                      );
                    },
                  ),
                  if (canvas.crop != null) ...<Widget>[
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '仅处理框选区域',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      subtitle: Text(
                        '关闭后将处理整张照片',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      value: selectedArea,
                      activeThumbColor: context.palette.safelight,
                      onChanged: (value) =>
                          setState(() => selectedArea = value),
                    ),
                  ] else ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      '处理范围：全图（未设置框选区域）',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            actions: <Widget>[
              RawsrButton(
                label: '取消',
                kind: RawsrButtonKind.text,
                onPressed: () => Navigator.of(dialogContext).pop(false),
              ),
              RawsrButton(
                label: '选择位置并入队',
                shortcut: 'Ctrl Enter',
                onPressed: denoise == null && sr == null
                    ? null
                    : () => Navigator.of(dialogContext).pop(true),
              ),
            ],
          );
        },
      );
    },
  );
  if (confirmed != true || !context.mounted) return;

  const tiffGroup = XTypeGroup(
    label: '16 位 TIFF',
    extensions: <String>['tif', 'tiff'],
  );
  final outputGroup = outputFormat == 'jpeg'
      ? const XTypeGroup(label: 'JPEG', extensions: <String>['jpg', 'jpeg'])
      : tiffGroup;
  final stem = item.name.contains('.')
      ? item.name.substring(0, item.name.lastIndexOf('.'))
      : item.name;
  final location = await getSaveLocation(
    acceptedTypeGroups: <XTypeGroup>[outputGroup],
    suggestedName: '${stem}_rawsr.${outputFormat == 'jpeg' ? 'jpg' : 'tiff'}',
    confirmButtonText: '加入队列',
  );
  if (location == null) return;
  final lower = location.path.toLowerCase();
  final hasExtension = outputFormat == 'jpeg'
      ? lower.endsWith('.jpg') || lower.endsWith('.jpeg')
      : lower.endsWith('.tif') || lower.endsWith('.tiff');
  final outputPath = hasExtension
      ? location.path
      : '${location.path}.${outputFormat == 'jpeg' ? 'jpg' : 'tiff'}';
  final crop = selectedArea && canvas.crop != null
      ? _regionFromRect(canvas.crop!, canvas.handle!)
      : null;
  final chain = <String>[
    if (denoise != null) denoise!,
    if (sr != null) sr!,
  ].join(' → ');
  final job = ExportJob(
    handle: canvas.handle!,
    outputPath: outputPath,
    outputFormat: outputFormat,
    jpegQuality: outputFormat == 'jpeg' ? 92 : null,
    maxOutputEdge: outputFormat == 'jpeg' ? 12000 : null,
    crop: crop,
    denoiseModel: denoise,
    denoiseStrength: denoiseStrength,
    srModel: sr,
    device: device,
    memoryBudgetMib: 2048,
    grade: canvas.grade,
  );
  await ref
      .read(queueProvider.notifier)
      .enqueue(
        job: job,
        label: item.name,
        modelChain: chain,
        thumbnail: item.thumbnail?.jpeg,
      );
}

RegionRect _regionFromRect(Rect rect, ImageHandle handle) {
  final x = rect.left.floor().clamp(0, handle.width - 1);
  final y = rect.top.floor().clamp(0, handle.height - 1);
  final width = rect.width.ceil().clamp(1, handle.width - x);
  final height = rect.height.ceil().clamp(1, handle.height - y);
  return RegionRect(x: x, y: y, width: width, height: height);
}

int _scaleForModel(String? name, List<ModelEntry> models) {
  if (name == null) return 1;
  for (final model in models) {
    if (model.name == name) return model.scale;
  }
  return 1;
}

(int, int) _fitDimensions(int width, int height, int maxEdge) {
  if (width <= maxEdge && height <= maxEdge) return (width, height);
  if (width >= height) return (maxEdge, (height * maxEdge / width).floor());
  return ((width * maxEdge / height).floor(), maxEdge);
}

void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      backgroundColor: context.palette.chrome2,
      content: Text(message, style: Theme.of(context).textTheme.bodySmall),
    ),
  );
}
