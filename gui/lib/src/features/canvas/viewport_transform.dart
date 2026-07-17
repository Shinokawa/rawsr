import 'package:flutter/widgets.dart';
import 'dart:math' as math;

class ViewportTransform {
  const ViewportTransform({
    required this.viewportSize,
    required this.imageSize,
    required this.zoom,
    required this.pan,
  });

  final Size viewportSize;
  final Size imageSize;
  final double zoom;
  final Offset pan;

  double get fitScale {
    if (viewportSize.isEmpty || imageSize.isEmpty) return 1;
    return math.min(
      viewportSize.width / imageSize.width,
      viewportSize.height / imageSize.height,
    );
  }

  double get scale => fitScale * zoom;

  Offset get center => viewportSize.center(Offset.zero) + pan;

  Rect get imageRect {
    final size = Size(imageSize.width * scale, imageSize.height * scale);
    return Rect.fromCenter(
      center: center,
      width: size.width,
      height: size.height,
    );
  }

  Offset imageToViewport(Offset point) {
    final rect = imageRect;
    return Offset(rect.left + point.dx * scale, rect.top + point.dy * scale);
  }

  Offset viewportToImage(Offset point) {
    final rect = imageRect;
    return Offset(
      ((point.dx - rect.left) / scale).clamp(0, imageSize.width),
      ((point.dy - rect.top) / scale).clamp(0, imageSize.height),
    );
  }

  Rect imageRectToViewport(Rect rect) {
    return Rect.fromPoints(
      imageToViewport(rect.topLeft),
      imageToViewport(rect.bottomRight),
    );
  }

  Rect viewportRectToImage(Rect rect) {
    return Rect.fromPoints(
      viewportToImage(rect.topLeft),
      viewportToImage(rect.bottomRight),
    );
  }

  Rect visibleImageRect() {
    final visible = viewportRectToImage(Offset.zero & viewportSize);
    return visible.intersect(Offset.zero & imageSize);
  }
}
