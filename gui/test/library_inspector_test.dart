import 'dart:io';
import 'dart:ui' show FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/app/rawsr_app.dart';
import 'package:rawsr_gui/src/backend/rawsr_backend.dart';
import 'package:rawsr_gui/src/features/inspector/inspector.dart';
import 'package:rawsr_gui/src/features/library/library_controller.dart';
import 'package:rawsr_gui/src/theme/rawsr_theme.dart';

import 'support/fake_backend.dart';
import 'support/load_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadTestFonts);

  test('keeps Chinese paths and explains unsupported formats', () async {
    final controller = LibraryController(FakeRawsrBackend());
    await controller.importPaths(<String>[
      r'C:\照片\索尼样片.ARW',
      r'C:\照片\说明文档.txt',
    ]);
    expect(controller.state.items, hasLength(1));
    expect(controller.state.items.single.path, r'C:\照片\索尼样片.ARW');
    expect(controller.state.items.single.thumbnail?.exif.make, 'Sony');
    expect(controller.state.message, contains('仅支持 ARW、JPEG、PNG、TIFF'));
    controller.dispose();
  });

  testWidgets(
    'virtual filmstrip scrolls through 20 imported files within budget',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fake = FakeRawsrBackend();
      final timings = <FrameTiming>[];
      tester.binding.addTimingsCallback(timings.addAll);
      addTearDown(() => tester.binding.removeTimingsCallback(timings.addAll));

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[rawsrBackendProvider.overrideWithValue(fake)],
          child: const RawsrApp(),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(RawsrWorkspace)),
      );
      await container
          .read(libraryProvider.notifier)
          .importPaths(
            List<String>.generate(20, (index) => 'C:\\照片\\中文样片_$index.ARW'),
          );
      await tester.pump();
      expect(find.text('中文样片_0.ARW'), findsOneWidget);
      await tester.drag(
        find.byKey(const ValueKey<String>('filmstrip-list')),
        const Offset(0, -2200),
      );
      await tester.pump();
      expect(find.text('中文样片_19.ARW'), findsOneWidget);
      if (timings.isNotEmpty) {
        expect(
          timings
              .map((timing) => timing.buildDuration.inMilliseconds)
              .reduce((a, b) => a > b ? a : b),
          lessThan(50),
        );
      }
    },
  );

  testWidgets('EXIF panel golden', (tester) async {
    final fake = FakeRawsrBackend();
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[rawsrBackendProvider.overrideWithValue(fake)],
        child: MaterialApp(
          theme: buildRawsrTheme(),
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: const ValueKey<String>('exif-golden'),
                child: const SizedBox(
                  width: 292,
                  height: 560,
                  child: Inspector(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    container = ProviderScope.containerOf(
      tester.element(find.byType(Inspector)),
    );
    await container.read(libraryProvider.notifier).importPaths(<String>[
      r'C:\照片\样片.ARW',
    ]);
    await tester.pumpAndSettle();
    expect(find.text('预览'), findsOneWidget);
    await expectLater(
      find.byKey(const ValueKey<String>('exif-golden')),
      matchesGoldenFile('goldens/windows/exif_panel.png'),
    );
  }, skip: !Platform.isWindows);
}
