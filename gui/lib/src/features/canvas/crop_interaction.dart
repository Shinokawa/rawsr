import 'package:flutter/widgets.dart';
import 'package:rawsr_gui/src/features/canvas/viewport_transform.dart';

enum CropDragMode {
  create,
  move,
  northWest,
  north,
  northEast,
  east,
  southEast,
  south,
  southWest,
  west,
}

class CropDragSession {
  const CropDragSession({
    required this.mode,
    required this.startImagePoint,
    required this.originalCrop,
  });

  final CropDragMode mode;
  final Offset startImagePoint;
  final Rect? originalCrop;

  Rect update({
    required Offset viewportPoint,
    required ViewportTransform transform,
  }) {
    final current = transform.viewportToImage(viewportPoint);
    final bounds = Offset.zero & transform.imageSize;
    final original = originalCrop;
    if (mode == CropDragMode.create || original == null) {
      return _normalize(
        Rect.fromPoints(startImagePoint, current),
      ).intersect(bounds);
    }
    if (mode == CropDragMode.move) {
      final delta = current - startImagePoint;
      final dx = delta.dx
          .clamp(-original.left, bounds.right - original.right)
          .toDouble();
      final dy = delta.dy
          .clamp(-original.top, bounds.bottom - original.bottom)
          .toDouble();
      return original.shift(Offset(dx, dy));
    }

    var left = original.left;
    var top = original.top;
    var right = original.right;
    var bottom = original.bottom;
    switch (mode) {
      case CropDragMode.northWest:
        left = current.dx;
        top = current.dy;
      case CropDragMode.north:
        top = current.dy;
      case CropDragMode.northEast:
        right = current.dx;
        top = current.dy;
      case CropDragMode.east:
        right = current.dx;
      case CropDragMode.southEast:
        right = current.dx;
        bottom = current.dy;
      case CropDragMode.south:
        bottom = current.dy;
      case CropDragMode.southWest:
        left = current.dx;
        bottom = current.dy;
      case CropDragMode.west:
        left = current.dx;
      case CropDragMode.create:
      case CropDragMode.move:
        break;
    }
    return _normalize(
      Rect.fromLTRB(left, top, right, bottom),
    ).intersect(bounds);
  }
}

CropDragSession beginCropDrag({
  required Rect? crop,
  required Offset viewportPoint,
  required ViewportTransform transform,
  double handleRadius = 12,
}) {
  final imagePoint = transform.viewportToImage(viewportPoint);
  if (crop == null) {
    return CropDragSession(
      mode: CropDragMode.create,
      startImagePoint: imagePoint,
      originalCrop: null,
    );
  }

  final viewportCrop = transform.imageRectToViewport(crop);
  final handles = <CropDragMode, Offset>{
    CropDragMode.northWest: viewportCrop.topLeft,
    CropDragMode.north: viewportCrop.topCenter,
    CropDragMode.northEast: viewportCrop.topRight,
    CropDragMode.east: viewportCrop.centerRight,
    CropDragMode.southEast: viewportCrop.bottomRight,
    CropDragMode.south: viewportCrop.bottomCenter,
    CropDragMode.southWest: viewportCrop.bottomLeft,
    CropDragMode.west: viewportCrop.centerLeft,
  };
  CropDragMode? closestMode;
  var closestDistance = double.infinity;
  for (final entry in handles.entries) {
    final distance = (entry.value - viewportPoint).distance;
    if (distance <= handleRadius && distance < closestDistance) {
      closestMode = entry.key;
      closestDistance = distance;
    }
  }
  final mode =
      closestMode ??
      (viewportCrop.contains(viewportPoint)
          ? CropDragMode.move
          : CropDragMode.create);
  return CropDragSession(
    mode: mode,
    startImagePoint: imagePoint,
    originalCrop: crop,
  );
}

Rect _normalize(Rect rect) {
  return Rect.fromLTRB(
    rect.left < rect.right ? rect.left : rect.right,
    rect.top < rect.bottom ? rect.top : rect.bottom,
    rect.left < rect.right ? rect.right : rect.left,
    rect.top < rect.bottom ? rect.bottom : rect.top,
  );
}
