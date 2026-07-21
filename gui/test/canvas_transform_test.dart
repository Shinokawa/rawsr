import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rawsr_gui/src/features/canvas/canvas_controller.dart';
import 'package:rawsr_gui/src/features/canvas/viewport_transform.dart';
import 'package:rawsr_gui/src/features/library/library_controller.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';

import 'support/fake_backend.dart';

void main() {
  test('viewport and image coordinates round-trip within one pixel', () {
    const transform = ViewportTransform(
      viewportSize: Size(1200, 800),
      imageSize: Size(8000, 5320),
      zoom: 3.75,
      pan: Offset(83, -41),
    );
    for (final point in <Offset>[
      const Offset(0, 0),
      const Offset(4000, 2660),
      const Offset(7999, 5319),
      const Offset(1234.5, 4321.25),
    ]) {
      final roundTrip = transform.viewportToImage(
        transform.imageToViewport(point),
      );
      expect((roundTrip - point).distance, lessThanOrEqualTo(1));
    }
  });

  test('400 percent zoom requests a Rust region render', () async {
    final fake = FakeRawsrBackend();
    final controller = CanvasController(fake);
    await controller.open(
      const LibraryItem(path: r'C:\照片\样片.ARW', name: '样片.ARW', loading: false),
    );
    controller.setView(zoom: 4, pan: Offset.zero);
    await controller.requestVisibleRegion(
      ViewportTransform(
        viewportSize: const Size(1200, 800),
        imageSize: controller.state.imageSize,
        zoom: controller.state.zoom,
        pan: controller.state.pan,
      ),
    );
    expect(fake.renderRegionCalls, 1);
    expect(controller.state.region, isNotNull);
    controller.dispose();
  });

  test(
    'grade apply reuses the RAW handle across preview and region renders',
    () async {
      final fake = FakeRawsrBackend();
      final controller = CanvasController(fake);
      const item = LibraryItem(
        path: r'C:\照片\样片.ARW',
        name: '样片.ARW',
        loading: false,
      );
      await controller.open(item);
      final handle = controller.state.handle;
      controller.setView(zoom: 4, pan: const Offset(17, -9));
      controller.setCrop(const Rect.fromLTWH(100, 120, 640, 480));
      final openCalls = fake.openCalls;
      final previewCalls = fake.renderPreviewCalls;

      final applied = await controller.applyGrade(
        item.copyWith(
          recipe: const EditRecipe(
            grade: GradeSettings(contrast: 50, saturation: -25),
          ),
        ),
      );

      expect(applied, isTrue);
      expect(fake.openCalls, openCalls);
      expect(fake.renderPreviewCalls, previewCalls + 1);
      expect(controller.state.handle, handle);
      expect(controller.state.zoom, 4);
      expect(controller.state.pan, const Offset(17, -9));
      expect(controller.state.crop, const Rect.fromLTWH(100, 120, 640, 480));
      expect(fake.lastPreviewGrade?.contrast, 0.5);
      expect(fake.lastPreviewGrade?.saturation, -0.25);
      expect(controller.state.grade, fake.lastPreviewGrade);

      await controller.requestVisibleRegion(
        ViewportTransform(
          viewportSize: const Size(1200, 800),
          imageSize: controller.state.imageSize,
          zoom: controller.state.zoom,
          pan: controller.state.pan,
        ),
      );
      expect(fake.lastRegionGrade, controller.state.grade);

      final unchangedPreviewCalls = fake.renderPreviewCalls;
      expect(
        await controller.applyGrade(
          item.copyWith(
            recipe: const EditRecipe(
              grade: GradeSettings(contrast: 50, saturation: -25),
            ),
          ),
        ),
        isFalse,
      );
      expect(fake.renderPreviewCalls, unchangedPreviewCalls);
      controller.dispose();
    },
  );

  test(
    'failed grade render keeps the last committed canvas snapshot',
    () async {
      final fake = FakeRawsrBackend();
      final controller = CanvasController(fake);
      const item = LibraryItem(
        path: r'C:\照片\样片.ARW',
        name: '样片.ARW',
        loading: false,
      );
      await controller.open(item);
      final oldHandle = controller.state.handle;
      final oldPreview = controller.state.preview;
      final oldGrade = controller.state.grade;
      fake.previewError = StateError('preview failed');

      final applied = await controller.applyGrade(
        item.copyWith(
          recipe: const EditRecipe(grade: GradeSettings(contrast: 40)),
        ),
      );

      expect(applied, isFalse);
      expect(controller.state.handle, oldHandle);
      expect(controller.state.preview, same(oldPreview));
      expect(controller.state.grade, oldGrade);
      expect(controller.state.loading, isFalse);
      expect(controller.state.gradePreviewing, isFalse);
      expect(controller.state.error, contains('preview failed'));
      controller.dispose();
    },
  );

  test(
    'live grade preview is single-flight and only commits the latest value',
    () async {
      final fake = _ControlledPreviewBackend();
      final controller = CanvasController(
        fake,
        gradePreviewThrottle: const Duration(milliseconds: 1),
      );
      const item = LibraryItem(
        path: r'C:\照片\样片.ARW',
        name: '样片.ARW',
        loading: false,
      );
      await controller.open(item);
      fake.holdPreviews = true;
      final revision = controller.state.gradeCommitRevision;
      final openCalls = fake.openCalls;

      controller.requestGradePreview(_gradedItem(item, 10), immediate: true);
      await fake.waitForHeldCalls(1);
      controller.requestGradePreview(_gradedItem(item, 20), immediate: false);
      controller.requestGradePreview(_gradedItem(item, 30), immediate: true);

      expect(fake.maxConcurrentPreviews, 1);
      expect(fake.heldGrades, hasLength(1));
      expect(controller.state.grade.contrast, 0);
      fake.completeNextPreview();
      await fake.waitForHeldCalls(2);

      expect(fake.maxConcurrentPreviews, 1);
      expect(fake.heldGrades.map((grade) => grade.contrast), <double>[
        0.1,
        0.3,
      ]);
      expect(controller.state.grade.contrast, 0);
      expect(controller.state.gradeCommitRevision, revision);
      fake.completeNextPreview();
      await controller.waitForGradePreviewIdle();

      expect(controller.state.grade.contrast, closeTo(0.3, 1e-6));
      expect(controller.state.gradeCommitRevision, revision + 1);
      expect(controller.state.gradePreviewing, isFalse);
      expect(fake.maxConcurrentPreviews, 1);
      expect(fake.openCalls, openCalls);
      controller.dispose();
    },
  );

  test(
    'returning to the committed grade cancels a throttled preview',
    () async {
      final fake = _ControlledPreviewBackend()..holdPreviews = true;
      final controller = CanvasController(
        fake,
        gradePreviewThrottle: const Duration(milliseconds: 15),
      );
      const item = LibraryItem(
        path: r'C:\照片\样片.ARW',
        name: '样片.ARW',
        loading: false,
      );
      fake.holdPreviews = false;
      await controller.open(item);
      fake.holdPreviews = true;

      controller.requestGradePreview(_gradedItem(item, 40), immediate: false);
      expect(controller.state.gradePreviewing, isTrue);
      controller.requestGradePreview(item, immediate: false);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(fake.heldGrades, isEmpty);
      expect(controller.state.gradePreviewing, isFalse);
      controller.dispose();
    },
  );

  test('view changes do not clear the live grade busy state', () async {
    final fake = _ControlledPreviewBackend();
    final controller = CanvasController(fake);
    const item = LibraryItem(
      path: r'C:\照片\样片.ARW',
      name: '样片.ARW',
      loading: false,
    );
    await controller.open(item);
    fake.holdPreviews = true;
    controller.requestGradePreview(_gradedItem(item, 25), immediate: true);
    await fake.waitForHeldCalls(1);

    controller.setView(zoom: 3, pan: const Offset(8, -4));

    expect(controller.state.gradePreviewing, isTrue);
    expect(controller.state.zoom, 3);
    fake.completeNextPreview();
    await controller.waitForGradePreviewIdle();
    controller.dispose();
  });

  test('disposing cancels a throttled live preview', () async {
    final fake = _ControlledPreviewBackend();
    final controller = CanvasController(
      fake,
      gradePreviewThrottle: const Duration(milliseconds: 20),
    );
    const item = LibraryItem(
      path: r'C:\照片\样片.ARW',
      name: '样片.ARW',
      loading: false,
    );
    await controller.open(item);
    fake.holdPreviews = true;

    controller.requestGradePreview(_gradedItem(item, 55), immediate: false);
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(fake.heldGrades, isEmpty);
  });

  test(
    'a grade render from the previous photo cannot commit after switching',
    () async {
      final fake = _ControlledPreviewBackend();
      final controller = CanvasController(fake);
      const first = LibraryItem(
        path: r'C:\照片\第一张.ARW',
        name: '第一张.ARW',
        loading: false,
      );
      const second = LibraryItem(
        path: r'C:\照片\第二张.ARW',
        name: '第二张.ARW',
        loading: false,
      );
      await controller.open(first);
      fake.holdPreviews = true;
      controller.requestGradePreview(_gradedItem(first, 60), immediate: true);
      await fake.waitForHeldCalls(1);

      fake.holdPreviews = false;
      await controller.open(second);
      fake.completeNextPreview();
      await controller.waitForGradePreviewIdle();

      expect(controller.state.path, second.path);
      expect(controller.state.grade.contrast, 0);
      expect(controller.state.gradeCommitRevision, 0);
      controller.dispose();
    },
  );
}

LibraryItem _gradedItem(LibraryItem item, double contrast) {
  return item.copyWith(
    recipe: EditRecipe(grade: GradeSettings(contrast: contrast)),
  );
}

class _ControlledPreviewBackend extends FakeRawsrBackend {
  bool holdPreviews = false;
  int concurrentPreviews = 0;
  int maxConcurrentPreviews = 0;
  final List<GradeParamsDto> heldGrades = <GradeParamsDto>[];
  final Queue<Completer<RgbaBytes>> _pending = Queue<Completer<RgbaBytes>>();

  @override
  Future<RgbaBytes> renderPreview({
    required ImageHandle handle,
    required int maxEdge,
    required GradeParamsDto grade,
  }) async {
    if (!holdPreviews) {
      return super.renderPreview(
        handle: handle,
        maxEdge: maxEdge,
        grade: grade,
      );
    }
    renderPreviewCalls++;
    lastPreviewGrade = grade;
    heldGrades.add(grade);
    concurrentPreviews++;
    maxConcurrentPreviews = maxConcurrentPreviews < concurrentPreviews
        ? concurrentPreviews
        : maxConcurrentPreviews;
    final completer = Completer<RgbaBytes>();
    _pending.add(completer);
    try {
      return await completer.future;
    } finally {
      concurrentPreviews--;
    }
  }

  void completeNextPreview() {
    _pending.removeFirst().complete(FakeRawsrBackend.frame);
  }

  Future<void> waitForHeldCalls(int count) async {
    for (
      var attempt = 0;
      attempt < 100 && heldGrades.length < count;
      attempt++
    ) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(heldGrades, hasLength(count));
  }
}
