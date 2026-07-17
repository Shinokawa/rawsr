import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/features/canvas/canvas_controller.dart';
import 'package:rawsr_gui/src/features/canvas/image_canvas.dart';
import 'package:rawsr_gui/src/features/inspector/inspector.dart';
import 'package:rawsr_gui/src/features/library/filmstrip.dart';
import 'package:rawsr_gui/src/features/library/library_controller.dart';
import 'package:rawsr_gui/src/features/queue/queue_bar.dart';
import 'package:rawsr_gui/src/features/queue/export_dialog.dart';
import 'package:rawsr_gui/src/features/test_strip/test_strip_controller.dart';
import 'package:rawsr_gui/src/features/test_strip/test_strip_view.dart';
import 'package:rawsr_gui/src/features/settings/settings_dialog.dart';
import 'package:rawsr_gui/src/localization/locale_controller.dart';
import 'package:rawsr_gui/src/theme/rawsr_theme.dart';

class RawsrApp extends ConsumerWidget {
  const RawsrApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'RawSR',
      debugShowCheckedModeBanner: false,
      theme: buildRawsrTheme(),
      locale: ref.watch(localeProvider),
      supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: const RawsrWorkspace(),
    );
  }
}

class RawsrWorkspace extends ConsumerStatefulWidget {
  const RawsrWorkspace({super.key});

  @override
  ConsumerState<RawsrWorkspace> createState() => _RawsrWorkspaceState();
}

class _RawsrWorkspaceState extends ConsumerState<RawsrWorkspace> {
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual<LibraryState>(libraryProvider, (previous, next) {
      final previousPath = previous?.selected?.path;
      final nextItem = next.selected;
      if (nextItem != null && previousPath != nextItem.path) {
        unawaited(ref.read(canvasProvider.notifier).open(nextItem));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final showTestStrip = ref.watch(
      testStripProvider.select((state) => state.visible),
    );
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyO, control: true):
            _ImportIntent(),
        SingleActivator(LogicalKeyboardKey.keyL): _ToggleLightboxIntent(),
        SingleActivator(LogicalKeyboardKey.keyC): _ToggleCropIntent(),
        SingleActivator(LogicalKeyboardKey.enter, control: true):
            _EnqueueIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _ImportIntent: CallbackAction<_ImportIntent>(
            onInvoke: (_) => _pickFiles(),
          ),
          _ToggleLightboxIntent: CallbackAction<_ToggleLightboxIntent>(
            onInvoke: (_) => ref.read(canvasProvider.notifier).toggleGrayMode(),
          ),
          _ToggleCropIntent: CallbackAction<_ToggleCropIntent>(
            onInvoke: (_) => ref.read(canvasProvider.notifier).toggleCropMode(),
          ),
          _EnqueueIntent: CallbackAction<_EnqueueIntent>(
            onInvoke: (_) => showExportDialog(context, ref),
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: DropTarget(
              onDragEntered: (_) => setState(() => _dragging = true),
              onDragExited: (_) => setState(() => _dragging = false),
              onDragDone: (details) {
                setState(() => _dragging = false);
                ref
                    .read(libraryProvider.notifier)
                    .importPaths(details.files.map((file) => file.path));
              },
              child: Stack(
                children: <Widget>[
                  Column(
                    children: <Widget>[
                      Expanded(
                        child: Row(
                          children: <Widget>[
                            SizedBox(
                              width: 196,
                              child: Filmstrip(
                                onImport: _pickFiles,
                                onSettings: () =>
                                    showSettingsDialog(context, ref),
                              ),
                            ),
                            VerticalDivider(
                              width: 1,
                              thickness: 1,
                              color: palette.line,
                            ),
                            Expanded(
                              child: showTestStrip
                                  ? const TestStripView()
                                  : const ImageCanvas(),
                            ),
                            VerticalDivider(
                              width: 1,
                              thickness: 1,
                              color: palette.line,
                            ),
                            const SizedBox(width: 292, child: Inspector()),
                          ],
                        ),
                      ),
                      const QueueBar(),
                    ],
                  ),
                  if (_dragging)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: palette.safelightDim,
                            border: Border.all(
                              color: palette.safelight,
                              width: 2,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              '松开以导入照片',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                        ),
                      ),
                    ),
                  const _LibraryMessage(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickFiles() async {
    const group = XTypeGroup(
      label: 'RAW 与照片',
      extensions: <String>['arw', 'jpg', 'jpeg', 'png', 'tif', 'tiff'],
    );
    final files = await openFiles(
      acceptedTypeGroups: const <XTypeGroup>[group],
    );
    if (files.isEmpty) return;
    await ref
        .read(libraryProvider.notifier)
        .importPaths(files.map((file) => file.path));
  }
}

class _LibraryMessage extends ConsumerWidget {
  const _LibraryMessage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = ref.watch(libraryProvider.select((state) => state.message));
    if (message == null) return const SizedBox.shrink();
    final palette = context.palette;
    return Positioned(
      left: 212,
      right: 308,
      top: 12,
      child: Material(
        color: palette.chrome1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: palette.danger),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: <Widget>[
              Icon(Icons.info_outline, color: palette.danger, size: 17),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: ref.read(libraryProvider.notifier).clearMessage,
                icon: const Icon(Icons.close, size: 16),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImportIntent extends Intent {
  const _ImportIntent();
}

class _ToggleLightboxIntent extends Intent {
  const _ToggleLightboxIntent();
}

class _ToggleCropIntent extends Intent {
  const _ToggleCropIntent();
}

class _EnqueueIntent extends Intent {
  const _EnqueueIntent();
}
