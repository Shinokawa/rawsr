import 'dart:io';
import 'dart:ui' show FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/app/rawsr_app.dart';
import 'package:rawsr_gui/src/backend/rawsr_backend.dart';
import 'package:rawsr_gui/src/features/canvas/canvas_controller.dart';
import 'package:rawsr_gui/src/features/inspector/inspector.dart';
import 'package:rawsr_gui/src/features/library/library_controller.dart';
import 'package:rawsr_gui/src/features/test_strip/test_strip_controller.dart';
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

  test('develop edits update a versioned per-photo recipe', () async {
    final controller = LibraryController(FakeRawsrBackend());
    await controller.importPaths(<String>[r'C:\照片\样片.ARW']);
    expect(controller.state.selected?.recipeRevision, 0);
    expect(controller.state.selected?.recipe.schemaVersion, 2);

    controller.updateExposure(1.25);
    expect(controller.state.selected?.exposureEv, 1.25);
    expect(controller.state.selected?.recipeRevision, 1);
    controller.updateExposure(1.25);
    expect(controller.state.selected?.recipeRevision, 1);

    controller.updateBaseCurve(BaseCurveOption.filmic);
    expect(controller.state.selected?.baseCurve, BaseCurveOption.filmic);
    expect(controller.state.selected?.recipeRevision, 2);
    controller.updateExposure(double.nan);
    expect(controller.state.selected?.recipeRevision, 2);

    controller.updateContrast(140);
    expect(controller.state.selected?.grade.contrast, 100);
    expect(controller.state.selected?.recipeRevision, 3);
    controller.updateContrast(100);
    expect(controller.state.selected?.recipeRevision, 3);

    controller.updateHighlights(-125);
    expect(controller.state.selected?.grade.highlights, -100);
    expect(controller.state.selected?.recipeRevision, 4);
    controller.updateShadows(double.infinity);
    expect(controller.state.selected?.recipeRevision, 4);

    controller.updateWhites(12.5);
    controller.updateBlacks(-9.5);
    controller.updateVibrance(25);
    controller.updateSaturation(-20);
    expect(
      controller.state.selected?.grade,
      const GradeSettings(
        contrast: 100,
        highlights: -100,
        whites: 12.5,
        blacks: -9.5,
        vibrance: 25,
        saturation: -20,
      ),
    );
    expect(controller.state.selected?.recipeRevision, 8);
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

  testWidgets('exposure accepts direct numeric input and can reset to zero', (
    tester,
  ) async {
    final fake = FakeRawsrBackend();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[rawsrBackendProvider.overrideWithValue(fake)],
        child: MaterialApp(
          theme: buildRawsrTheme(),
          home: const Scaffold(body: SizedBox(width: 292, child: Inspector())),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Inspector)),
    );
    await container.read(libraryProvider.notifier).importPaths(<String>[
      r'C:\照片\样片.ARW',
    ]);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('exposure-input')),
      '1.25',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(container.read(libraryProvider).selected?.exposureEv, 1.25);

    await tester.tap(find.byKey(const ValueKey<String>('exposure-reset')));
    await tester.pump();
    expect(container.read(libraryProvider).selected?.exposureEv, 0);
  });

  testWidgets('grade accepts direct numeric input and can reset to zero', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fake = FakeRawsrBackend();
    final seededStrip = _SeededTestStripController(
      fake,
      TestStripState(
        results: <StripResult>[
          StripResult(
            model: 'sr-b',
            elapsedMs: BigInt.one,
            image: FakeRawsrBackend.frame,
          ),
        ],
        champions: const <String, String>{'denoise': 'denoise-a'},
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          rawsrBackendProvider.overrideWithValue(fake),
          testStripProvider.overrideWith((ref) => seededStrip),
        ],
        child: MaterialApp(
          theme: buildRawsrTheme(),
          home: const Scaffold(body: SizedBox(width: 292, child: Inspector())),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Inspector)),
    );
    await container.read(libraryProvider.notifier).importPaths(<String>[
      r'C:\照片\样片.ARW',
    ]);
    await tester.pumpAndSettle();
    await container
        .read(canvasProvider.notifier)
        .open(container.read(libraryProvider).selected!);
    final openCalls = fake.openCalls;
    final previewCalls = fake.renderPreviewCalls;

    final input = find.byKey(const ValueKey<String>('contrast-input'));
    await tester.enterText(input, '35.5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await container.read(canvasProvider.notifier).waitForGradePreviewIdle();
    await tester.pump();
    expect(container.read(libraryProvider).selected?.grade.contrast, 35.5);
    expect(fake.lastPreviewGrade?.contrast, closeTo(0.355, 1e-6));
    expect(fake.openCalls, openCalls);
    expect(fake.renderPreviewCalls, previewCalls + 1);
    expect(container.read(testStripProvider).results, isEmpty);
    expect(
      container.read(testStripProvider).championFor('denoise'),
      'denoise-a',
    );

    final reset = find.byKey(const ValueKey<String>('contrast-reset'));
    final resetPreviewCalls = fake.renderPreviewCalls;
    await tester.tap(reset);
    await tester.pump();
    await container.read(canvasProvider.notifier).waitForGradePreviewIdle();
    await tester.pump();
    expect(container.read(libraryProvider).selected?.grade.contrast, 0);
    expect(tester.widget<TextField>(input).controller?.text, '0');
    expect(fake.lastPreviewGrade?.contrast, 0);
    expect(fake.renderPreviewCalls, resetPreviewCalls + 1);

    final slider = find.byKey(const ValueKey<String>('saturation-slider'));
    await tester.ensureVisible(slider);
    await tester.pump();
    final sliderPreviewCalls = fake.renderPreviewCalls;
    await tester.drag(slider, const Offset(-60, 0));
    await container.read(canvasProvider.notifier).waitForGradePreviewIdle();
    await tester.pump();
    expect(
      container.read(libraryProvider).selected?.grade.saturation,
      lessThan(0),
    );
    expect(fake.lastPreviewGrade?.saturation, lessThan(0));
    expect(fake.renderPreviewCalls, greaterThan(sliderPreviewCalls));
    expect(find.byKey(const ValueKey<String>('grade-apply')), findsNothing);
  });

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

class _SeededTestStripController extends TestStripController {
  _SeededTestStripController(super.backend, TestStripState initial) {
    state = initial;
  }
}
