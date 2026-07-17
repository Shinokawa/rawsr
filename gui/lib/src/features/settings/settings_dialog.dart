import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:rawsr_gui/src/backend/rawsr_backend.dart';
import 'package:rawsr_gui/src/features/models/models_controller.dart';
import 'package:rawsr_gui/src/localization/locale_controller.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';
import 'package:rawsr_gui/src/theme/rawsr_theme.dart';
import 'package:rawsr_gui/src/widgets/rawsr_button.dart';
import 'package:rawsr_gui/src/widgets/rawsr_panel.dart';

final runtimeInfoProvider = FutureProvider<RuntimeInfo>((ref) {
  return ref.watch(rawsrBackendProvider).runtimeInfo();
});

Future<void> showSettingsDialog(BuildContext context, WidgetRef ref) {
  return showDialog<void>(
    context: context,
    builder: (context) => const _SettingsDialog(),
  );
}

class _SettingsDialog extends ConsumerWidget {
  const _SettingsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(modelsProvider);
    final runtime = ref.watch(runtimeInfoProvider);
    final locale = ref.watch(localeProvider);
    return Dialog(
      backgroundColor: context.palette.chrome0,
      child: SizedBox(
        width: 760,
        height: 580,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 10, 10),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '设置与模型',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const RawsrDivider(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  RawsrPanel(
                    title: '推理运行时',
                    child: runtime.when(
                      loading: () => const LinearProgressIndicator(),
                      error: (error, stackTrace) => Text(
                        '运行时信息读取失败：$error',
                        style: Theme.of(context).textTheme.bodySmall!.copyWith(
                          color: context.palette.danger,
                        ),
                      ),
                      data: (info) => Column(
                        children: <Widget>[
                          _InfoRow('平台', info.platform),
                          _InfoRow('默认设备', info.preferredDevice),
                          _InfoRow(
                            '已编译 EP',
                            info.compiledProviders.join(' · '),
                          ),
                          _InfoRow(
                            '最近分配',
                            info.lastAllocations.isEmpty
                                ? '尚未运行模型'
                                : info.lastAllocations
                                      .map(
                                        (value) =>
                                            '${value.provider}: ${value.nodeCount}',
                                      )
                                      .join(' · '),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  RawsrPanel(
                    title: '语言',
                    child: DropdownButtonFormField<String>(
                      initialValue: locale.languageCode,
                      decoration: const InputDecoration(labelText: '界面语言'),
                      items: const <DropdownMenuItem<String>>[
                        DropdownMenuItem<String>(
                          value: 'zh',
                          child: Text('简体中文'),
                        ),
                        DropdownMenuItem<String>(
                          value: 'en',
                          child: Text('English（骨架）'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          ref.read(localeProvider.notifier).setLanguage(value);
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  RawsrPanel(
                    title: '模型清单',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Align(
                          alignment: Alignment.centerRight,
                          child: RawsrButton(
                            label: '导入 ONNX',
                            icon: Icons.add,
                            onPressed: () => _importOnnx(context, ref),
                          ),
                        ),
                        const SizedBox(height: 8),
                        models.when(
                          loading: () => const LinearProgressIndicator(),
                          error: (error, stackTrace) => Text(
                            '模型清单读取失败：$error',
                            style: Theme.of(context).textTheme.bodySmall!
                                .copyWith(color: context.palette.danger),
                          ),
                          data: (entries) => Column(
                            children: <Widget>[
                              for (final entry in entries)
                                _ModelRow(entry: entry),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importOnnx(BuildContext context, WidgetRef ref) async {
    const onnx = XTypeGroup(label: 'ONNX 模型', extensions: <String>['onnx']);
    final file = await openFile(acceptedTypeGroups: const <XTypeGroup>[onnx]);
    if (file == null || !context.mounted) return;
    final request = await showDialog<ImportModelRequest>(
      context: context,
      builder: (context) => _ImportModelDialog(path: file.path),
    );
    if (request == null || !context.mounted) return;
    try {
      await ref.read(rawsrBackendProvider).importModel(request);
      ref.invalidate(modelsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: context.palette.chrome2,
            content: Text('模型已复制并写入 manifest：${request.name}'),
          ),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: context.palette.chrome2,
            content: Text('模型导入失败：$error。请检查 ONNX 文件、名称和倍率参数。'),
          ),
        );
      }
    }
  }
}

class _ImportModelDialog extends StatefulWidget {
  const _ImportModelDialog({required this.path});

  final String path;

  @override
  State<_ImportModelDialog> createState() => _ImportModelDialogState();
}

class _ImportModelDialogState extends State<_ImportModelDialog> {
  late final TextEditingController _name;
  var _kind = 'sr';
  var _scale = 4;

  @override
  void initState() {
    super.initState();
    final normalized = widget.path.replaceAll('\\', '/');
    final filename = normalized.substring(normalized.lastIndexOf('/') + 1);
    _name = TextEditingController(
      text: filename.toLowerCase().endsWith('.onnx')
          ? filename.substring(0, filename.length - 5)
          : filename,
    );
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.palette.chrome1,
      title: Text('导入 ONNX 模型', style: Theme.of(context).textTheme.titleSmall),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '模型名称'),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: '类型'),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem<String>(value: 'denoise', child: Text('降噪')),
                DropdownMenuItem<String>(value: 'sr', child: Text('超分辨率')),
              ],
              onChanged: (value) {
                setState(() {
                  _kind = value ?? 'sr';
                  _scale = _kind == 'denoise' ? 1 : 4;
                });
              },
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<int>(
              initialValue: _scale,
              decoration: const InputDecoration(labelText: '倍率'),
              items: <DropdownMenuItem<int>>[
                if (_kind == 'denoise')
                  const DropdownMenuItem<int>(value: 1, child: Text('1×')),
                if (_kind == 'sr') ...const <DropdownMenuItem<int>>[
                  DropdownMenuItem<int>(value: 2, child: Text('2×')),
                  DropdownMenuItem<int>(value: 4, child: Text('4×')),
                ],
              ],
              onChanged: (value) => setState(() => _scale = value ?? _scale),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        RawsrButton(
          label: '取消',
          kind: RawsrButtonKind.text,
          onPressed: () => Navigator.of(context).pop(),
        ),
        RawsrButton(
          label: '复制并添加',
          onPressed: () {
            Navigator.of(context).pop(
              ImportModelRequest(
                sourcePath: widget.path,
                name: _name.text.trim(),
                kind: _kind,
                scale: _scale,
                tile: 256,
                overlap: 32,
                channelOrder: 'RGB',
                inputRange: 'zero_to_one',
                notes:
                    'Imported ${DateFormat('yyyy-MM-dd').format(DateTime.now())}',
              ),
            );
          },
        ),
      ],
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.entry});

  final ModelEntry entry;

  @override
  Widget build(BuildContext context) {
    final bytes = entry.fileSizeBytes.toInt();
    final size = bytes == 0
        ? '—'
        : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MiB';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: <Widget>[
          Icon(
            entry.installed
                ? Icons.check_circle_outline
                : Icons.download_outlined,
            size: 16,
            color: entry.installed
                ? context.palette.safelight
                : context.palette.textLo,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry.name,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          SizedBox(
            width: 150,
            child: Text(
              '${entry.kind} · ${entry.scale}× · $size',
              textAlign: TextAlign.right,
              style: context.mono.copyWith(
                fontSize: 10,
                color: context.palette.textLo,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 88,
            child: Text(label, style: Theme.of(context).textTheme.labelSmall),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: context.mono.copyWith(
                fontSize: 10,
                color: context.palette.textHi,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
