import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/app/rawsr_app.dart';
import 'package:rawsr_gui/src/backend/rawsr_backend.dart';
import 'package:rawsr_gui/src/features/canvas/canvas_controller.dart';
import 'package:rawsr_gui/src/features/library/grade_bridge.dart';
import 'package:rawsr_gui/src/features/library/library_controller.dart';
import 'package:rawsr_gui/src/features/models/models_controller.dart';
import 'package:rawsr_gui/src/features/queue/queue_controller.dart';
import 'package:rawsr_gui/src/features/test_strip/test_strip_controller.dart';
import 'package:rawsr_gui/src/features/test_strip/test_strip_view.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';
import 'package:rawsr_gui/src/theme/rawsr_theme.dart';

import 'support/fake_backend.dart';

void main() {
  test(
    'SR strip auto-samples a bounded full-image region and stores its champion',
    () async {
      final fake = FakeRawsrBackend();
      final controller = TestStripController(fake);
      final handle = ImageHandle(id: BigInt.one, width: 8000, height: 5320);
      const appliedGrade = GradeParamsDto(
        contrast: 0.5,
        highlights: -0.25,
        shadows: 0,
        whites: 0,
        blacks: 0,
        vibrance: 0,
        saturation: 0.2,
      );
      await controller.generate(
        kind: 'sr',
        canvas: CanvasState(handle: handle, grade: appliedGrade),
        models: const <String>['sr-b'],
        maxScale: 4,
      );
      expect(
        controller.state.results
            .where((result) => !result.isReference)
            .map((result) => result.model),
        orderedEquals(<String>['sr-b']),
      );
      final rect = fake.lastStripRect!;
      expect(
        rect.width * rect.height * 16,
        lessThanOrEqualTo(16 * 1024 * 1024),
      );
      expect(rect.width * rect.height, lessThanOrEqualTo(512 * 512));
      expect(rect.x + rect.width ~/ 2, closeTo(4000, 1));
      expect(rect.y + rect.height ~/ 2, closeTo(2660, 1));
      expect(controller.state.fullImage, isTrue);
      expect(controller.state.autoSampled, isTrue);
      expect(fake.lastStripDenoiseModel, isNull);
      expect(fake.lastStripGrade, appliedGrade);
      controller.chooseChampion('sr-b');
      expect(controller.state.championFor('sr'), 'sr-b');
      expect(controller.state.championFor('denoise'), isNull);
      expect(controller.state.visible, isFalse);
      controller.resetForSourceChange();
      expect(controller.state.champions, isEmpty);
      expect(controller.state.results, isEmpty);
      controller.dispose();
    },
  );

  test(
    'SR strip snapshots the denoise champion and invalidates it when the chain changes',
    () async {
      final fake = FakeRawsrBackend(stripCacheHit: true);
      final controller = TestStripController(fake);
      final handle = ImageHandle(id: BigInt.one, width: 8000, height: 5320);
      final canvas = CanvasState(
        handle: handle,
        crop: const Rect.fromLTWH(100, 120, 320, 240),
      );

      await controller.generate(
        kind: 'denoise',
        canvas: canvas,
        models: const <String>['denoise-a'],
        maxScale: 1,
      );
      controller.chooseChampion('denoise-a');
      await controller.generate(
        kind: 'sr',
        canvas: canvas,
        models: const <String>['sr-b'],
        maxScale: 4,
      );
      expect(fake.lastStripDenoiseModel, 'denoise-a');
      expect(fake.lastStripModels, orderedEquals(<String>['sr-b']));
      expect(controller.state.preDenoiseModel, 'denoise-a');
      expect(controller.state.preprocessCacheHit, isTrue);
      expect(controller.state.championFor('denoise'), 'denoise-a');
      controller.chooseChampion('sr-b');
      expect(controller.state.championFor('sr'), 'sr-b');
      expect(controller.state.srChampionPreDenoiseModel, 'denoise-a');

      await controller.generate(
        kind: 'denoise',
        canvas: canvas,
        models: const <String>['denoise-c'],
        maxScale: 1,
      );
      expect(fake.lastStripDenoiseModel, isNull);
      controller.chooseChampion('denoise-c');
      expect(controller.state.championFor('sr'), isNull);
      expect(controller.state.srChampionPreDenoiseModel, isNull);
      expect(controller.state.srNeedsRetest, isTrue);
      controller.dispose();
    },
  );

  test(
    'grade changes clear stale strip images but preserve model champions',
    () {
      final controller = _SeededStripController(
        FakeRawsrBackend(),
        TestStripState(
          visible: true,
          running: true,
          kind: 'sr',
          models: const <String>['sr-b'],
          results: <StripResult>[
            StripResult(
              model: 'sr-b',
              elapsedMs: BigInt.one,
              image: FakeRawsrBackend.frame,
            ),
          ],
          progress: const <String, double>{'sr-b': 1},
          champions: const <String, String>{
            'denoise': 'denoise-a',
            'sr': 'sr-b',
          },
          srChampionPreDenoiseModel: 'denoise-a',
        ),
      );

      controller.invalidateForGradeChange();

      expect(controller.state.visible, isFalse);
      expect(controller.state.running, isFalse);
      expect(controller.state.results, isEmpty);
      expect(controller.state.progress, isEmpty);
      expect(controller.state.champions, const <String, String>{
        'denoise': 'denoise-a',
        'sr': 'sr-b',
      });
      expect(controller.state.srChampionPreDenoiseModel, 'denoise-a');
      controller.dispose();
    },
  );

  test('denoise and SR each keep only one selected model', () {
    final controller = SelectedModelsController();
    controller.toggle('denoise', 'denoise-a');
    controller.toggle('sr', 'sr-b');
    controller.toggle('sr', 'sr-c');
    expect(controller.state.denoise, <String>{'denoise-a'});
    expect(controller.state.sr, <String>{'sr-c'});
    controller.dispose();
  });

  test(
    'queue controller reaches all five task states from stream events',
    () async {
      for (final scenario in <List<String>>[
        const <String>['queued'],
        const <String>['running'],
        const <String>['queued', 'running', 'completed'],
        const <String>['failed'],
        const <String>['cancelled'],
      ]) {
        final fake = FakeRawsrBackend(exportStates: scenario);
        final controller = QueueController(fake);
        await controller.enqueue(
          job: _job,
          label: '样片.ARW',
          modelChain: 'denoise-a → sr-b',
          thumbnail: Uint8List(0),
        );
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(controller.state.tasks.single.status.name, scenario.last);
        if (scenario.last == 'failed') {
          expect(controller.state.tasks.single.reason, contains('算子'));
        }
        controller.dispose();
      }
    },
  );

  test('queued export keeps the applied grade snapshot', () async {
    final fake = FakeRawsrBackend();
    final library = LibraryController(fake);
    await library.importPaths(<String>[r'C:\照片\样片.ARW']);
    library.updateContrast(50);
    library.updateSaturation(-25);
    final appliedGrade = gradeParamsFromSettings(library.state.selected!.grade);
    final job = ExportJob(
      handle: ImageHandle(id: BigInt.one, width: 8000, height: 5320),
      outputPath: r'C:\输出\样片.tiff',
      device: 'auto',
      grade: appliedGrade,
    );
    final queue = QueueController(fake);

    await queue.enqueue(job: job, label: '样片.ARW', modelChain: '');
    library.updateContrast(-75);
    library.updateSaturation(80);

    expect(fake.lastExportJob?.grade, appliedGrade);
    expect(fake.lastExportJob?.grade.contrast, 0.5);
    expect(fake.lastExportJob?.grade.saturation, -0.25);
    queue.dispose();
    library.dispose();
  });

  test('imported mock ONNX refreshes the model provider', () async {
    final fake = FakeRawsrBackend();
    final container = ProviderContainer(
      overrides: <Override>[rawsrBackendProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    final before = await container.read(modelsProvider.future);
    expect(before.any((entry) => entry.name == 'custom-x2'), isFalse);
    await fake.importModel(
      const ImportModelRequest(
        sourcePath: r'C:\模型\custom.onnx',
        name: 'custom-x2',
        kind: 'sr',
        scale: 2,
        tile: 256,
        overlap: 32,
        channelOrder: 'RGB',
        inputRange: 'zero_to_one',
        notes: 'test',
      ),
    );
    container.invalidate(modelsProvider);
    final after = await container.read(modelsProvider.future);
    expect(
      after.any((entry) => entry.name == 'custom-x2' && entry.installed),
      isTrue,
    );
  });

  testWidgets('all rendered strips share the same pan offset', (tester) async {
    final fake = FakeRawsrBackend();
    final seeded = _SeededStripController(
      fake,
      TestStripState(
        visible: true,
        kind: 'sr',
        preDenoiseModel: 'denoise-a',
        models: const <String>['b'],
        results: <StripResult>[
          StripResult(
            model: 'reference',
            elapsedMs: BigInt.zero,
            isReference: true,
            image: FakeRawsrBackend.frame,
          ),
          StripResult(
            model: 'b',
            elapsedMs: BigInt.two,
            image: FakeRawsrBackend.frame,
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          rawsrBackendProvider.overrideWithValue(fake),
          testStripProvider.overrideWith((ref) => seeded),
        ],
        child: MaterialApp(
          theme: buildRawsrTheme(),
          home: const Scaffold(body: TestStripView()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('denoise-a → 超分试片'), findsOneWidget);
    await tester.drag(find.byType(TestStripView), const Offset(40, 25));
    await tester.pump();
    final reveals = tester
        .widgetList<StripRevealFrame>(find.byType(StripRevealFrame))
        .toList();
    expect(reveals, hasLength(2));
    expect(reveals.map((value) => value.pan).toSet(), hasLength(1));
    expect(reveals.first.pan, isNot(Offset.zero));
  });

  testWidgets('settings renders current execution provider allocation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          rawsrBackendProvider.overrideWithValue(FakeRawsrBackend()),
        ],
        child: const RawsrApp(),
      ),
    );
    await tester.tap(find.byTooltip('设置与模型'));
    await tester.pumpAndSettle();
    expect(find.text('DirectML → CPU'), findsOneWidget);
    expect(find.textContaining('DmlExecutionProvider: 42'), findsOneWidget);
  });
}

final _job = ExportJob(
  handle: ImageHandle(id: BigInt.one, width: 8000, height: 5320),
  outputPath: r'C:\输出\样片.tiff',
  denoiseModel: 'denoise-a',
  srModel: 'sr-b',
  device: 'auto',
  grade: GradeParamsDto(
    contrast: 0,
    highlights: 0,
    shadows: 0,
    whites: 0,
    blacks: 0,
    vibrance: 0,
    saturation: 0,
  ),
);

class _SeededStripController extends TestStripController {
  _SeededStripController(super.backend, TestStripState initial) {
    state = initial;
  }
}
