import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/backend/rawsr_backend.dart';
import 'package:rawsr_gui/src/features/canvas/viewport_transform.dart';
import 'package:rawsr_gui/src/features/library/library_controller.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';

class CanvasState {
  const CanvasState({
    this.path,
    this.handle,
    this.preview,
    this.region,
    this.regionRect,
    this.loading = false,
    this.error,
    this.zoom = 1,
    this.pan = Offset.zero,
    this.crop,
    this.cropMode = false,
    this.grayMode = false,
  });

  final String? path;
  final ImageHandle? handle;
  final RgbaBytes? preview;
  final RgbaBytes? region;
  final Rect? regionRect;
  final bool loading;
  final String? error;
  final double zoom;
  final Offset pan;
  final Rect? crop;
  final bool cropMode;
  final bool grayMode;

  Size get imageSize {
    final value = handle;
    return value == null
        ? Size.zero
        : Size(value.width.toDouble(), value.height.toDouble());
  }

  CanvasState copyWith({
    String? path,
    ImageHandle? handle,
    bool clearHandle = false,
    RgbaBytes? preview,
    bool clearPreview = false,
    RgbaBytes? region,
    bool clearRegion = false,
    Rect? regionRect,
    bool loading = false,
    String? error,
    bool clearError = false,
    double? zoom,
    Offset? pan,
    Rect? crop,
    bool clearCrop = false,
    bool? cropMode,
    bool? grayMode,
  }) {
    return CanvasState(
      path: path ?? this.path,
      handle: clearHandle ? null : handle ?? this.handle,
      preview: clearPreview ? null : preview ?? this.preview,
      region: clearRegion ? null : region ?? this.region,
      regionRect: clearRegion ? null : regionRect ?? this.regionRect,
      loading: loading,
      error: clearError ? null : error ?? this.error,
      zoom: zoom ?? this.zoom,
      pan: pan ?? this.pan,
      crop: clearCrop ? null : crop ?? this.crop,
      cropMode: cropMode ?? this.cropMode,
      grayMode: grayMode ?? this.grayMode,
    );
  }
}

class CanvasController extends StateNotifier<CanvasState> {
  CanvasController(this._backend) : super(const CanvasState());

  final RawsrBackend _backend;
  int _generation = 0;

  Future<void> open(LibraryItem item) async {
    final generation = ++_generation;
    final oldHandle = state.handle;
    state = CanvasState(
      path: item.path,
      loading: true,
      grayMode: state.grayMode,
      cropMode: state.cropMode,
    );
    if (oldHandle != null) {
      await _backend.closeImage(oldHandle);
    }
    try {
      final handle = await _backend.openImage(
        path: item.path,
        exposureEv: item.exposureEv,
        filmicContrast: item.baseCurve == BaseCurveOption.filmic ? 1.25 : null,
      );
      final preview = await _backend.renderPreview(
        handle: handle,
        maxEdge: 2048,
      );
      if (generation != _generation) {
        await _backend.closeImage(handle);
        return;
      }
      state = CanvasState(
        path: item.path,
        handle: handle,
        preview: preview,
        grayMode: state.grayMode,
        cropMode: state.cropMode,
      );
    } catch (error) {
      if (generation != _generation) return;
      state = CanvasState(
        path: item.path,
        error: '照片打开失败：$error。请检查文件权限、RAW 支持和可用内存。',
        grayMode: state.grayMode,
        cropMode: state.cropMode,
      );
    }
  }

  void setView({required double zoom, required Offset pan}) {
    state = state.copyWith(
      zoom: zoom.clamp(0.25, 8),
      pan: pan,
      clearRegion: zoom < 2,
    );
  }

  void resetView() {
    state = state.copyWith(zoom: 1, pan: Offset.zero, clearRegion: true);
  }

  void toggleGrayMode() {
    state = state.copyWith(grayMode: !state.grayMode);
  }

  void toggleCropMode() {
    state = state.copyWith(cropMode: !state.cropMode);
  }

  void setCrop(Rect? crop) {
    if (crop == null) {
      state = state.copyWith(clearCrop: true);
      return;
    }
    final bounds = Offset.zero & state.imageSize;
    final normalized = Rect.fromLTRB(
      math.min(crop.left, crop.right),
      math.min(crop.top, crop.bottom),
      math.max(crop.left, crop.right),
      math.max(crop.top, crop.bottom),
    ).intersect(bounds);
    if (normalized.width < 1 || normalized.height < 1) return;
    state = state.copyWith(crop: normalized);
  }

  Future<void> requestVisibleRegion(ViewportTransform transform) async {
    final handle = state.handle;
    if (handle == null || state.zoom < 2) return;
    final generation = _generation;
    final rect = transform.visibleImageRect();
    if (rect.isEmpty) return;
    final regionRect = RegionRect(
      x: rect.left.floor(),
      y: rect.top.floor(),
      width: math.max(1, rect.width.ceil()),
      height: math.max(1, rect.height.ceil()),
    );
    try {
      final frame = await _backend.renderRegion(
        handle: handle,
        rect: regionRect,
        maxEdge: 4096,
      );
      if (generation != _generation || state.handle != handle) return;
      state = state.copyWith(
        region: frame,
        regionRect: Rect.fromLTWH(
          regionRect.x.toDouble(),
          regionRect.y.toDouble(),
          regionRect.width.toDouble(),
          regionRect.height.toDouble(),
        ),
      );
    } catch (error) {
      state = state.copyWith(error: '局部预览渲染失败：$error。已保留低分辨率预览，可缩小后继续。');
    }
  }

  @override
  void dispose() {
    final handle = state.handle;
    if (handle != null) {
      _backend.closeImage(handle);
    }
    super.dispose();
  }
}

final canvasProvider = StateNotifierProvider<CanvasController, CanvasState>((
  ref,
) {
  return CanvasController(ref.watch(rawsrBackendProvider));
});
