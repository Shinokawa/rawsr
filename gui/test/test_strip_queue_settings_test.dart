import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/app/rawsr_app.dart';
import 'package:rawsr_gui/src/backend/rawsr_backend.dart';
import 'package:rawsr_gui/src/features/canvas/canvas_controller.dart';
import 'package:rawsr_gui/src/features/models/models_controller.dart';
import 'package:rawsr_gui/src/features/queue/queue_controller.dart';
import 'package:rawsr_gui/src/features/test_strip/test_strip_controller.dart';
import 'package:rawsr_gui/src/features/test_strip/test_strip_view.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';
import 'package:rawsr_gui/src/theme/rawsr_theme.dart';

import 'support/fake_backend.dart';

void main() {
  test(
    'three strip results appear in stream completion order and champion persists',
    () async {
      final fake = FakeRawsrBackend(
        stripCompletionOrder: const <String>['sr-b', 'denoise-a', 'sr-c'],
      );
      final controller = TestStripController(fake);
      final handle = ImageHandle(id: BigInt.one, width: 8000, height: 5320);
      await controller.generate(
        CanvasState(handle: handle, crop: Rect.fromLTWH(100, 120, 320, 240)),
        const <String>['denoise-a', 'sr-b', 'sr-c'],
      );
      expect(
        controller.state.results.map((result) => result.model),
        orderedEquals(<String>['sr-b', 'denoise-a', 'sr-c']),
      );
      controller.chooseChampion('denoise-a');
      expect(controller.state.champion, 'denoise-a');
      expect(controller.state.visible, isFalse);
      controller.dispose();
    },
  );

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
        models: const <String>['a', 'b', 'c'],
        results: <StripResult>[
          StripResult(
            model: 'a',
            elapsedMs: BigInt.one,
            image: FakeRawsrBackend.frame,
          ),
          StripResult(
            model: 'b',
            elapsedMs: BigInt.two,
            image: FakeRawsrBackend.frame,
          ),
          StripResult(
            model: 'c',
            elapsedMs: BigInt.from(3),
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
    await tester.drag(find.byType(TestStripView), const Offset(40, 25));
    await tester.pump();
    final reveals = tester
        .widgetList<StripRevealFrame>(find.byType(StripRevealFrame))
        .toList();
    expect(reveals, hasLength(3));
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
);

class _SeededStripController extends TestStripController {
  _SeededStripController(super.backend, TestStripState initial) {
    state = initial;
  }
}
