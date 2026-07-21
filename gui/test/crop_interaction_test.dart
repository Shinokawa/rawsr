import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rawsr_gui/src/features/canvas/crop_interaction.dart';
import 'package:rawsr_gui/src/features/canvas/viewport_transform.dart';

void main() {
  const transform = ViewportTransform(
    viewportSize: Size(1000, 800),
    imageSize: Size(1000, 800),
    zoom: 1,
    pan: Offset.zero,
  );
  const crop = Rect.fromLTWH(100, 120, 300, 200);

  test('dragging inside an existing crop moves it', () {
    final drag = beginCropDrag(
      crop: crop,
      viewportPoint: crop.center,
      transform: transform,
    );
    expect(drag.mode, CropDragMode.move);
    expect(
      drag.update(
        viewportPoint: crop.center + const Offset(50, 25),
        transform: transform,
      ),
      crop.shift(const Offset(50, 25)),
    );
  });

  test('dragging a crop handle resizes the existing crop', () {
    final drag = beginCropDrag(
      crop: crop,
      viewportPoint: crop.bottomRight,
      transform: transform,
    );
    expect(drag.mode, CropDragMode.southEast);
    expect(
      drag.update(viewportPoint: const Offset(470, 390), transform: transform),
      const Rect.fromLTRB(100, 120, 470, 390),
    );
  });

  test('dragging outside the crop creates a new crop', () {
    final drag = beginCropDrag(
      crop: crop,
      viewportPoint: const Offset(600, 500),
      transform: transform,
    );
    expect(drag.mode, CropDragMode.create);
    expect(
      drag.update(viewportPoint: const Offset(750, 650), transform: transform),
      const Rect.fromLTRB(600, 500, 750, 650),
    );
  });
}
