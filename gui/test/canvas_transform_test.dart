import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rawsr_gui/src/features/canvas/canvas_controller.dart';
import 'package:rawsr_gui/src/features/canvas/viewport_transform.dart';
import 'package:rawsr_gui/src/features/library/library_controller.dart';

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
}
