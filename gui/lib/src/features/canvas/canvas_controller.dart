import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/backend/rawsr_backend.dart';
import 'package:rawsr_gui/src/features/canvas/viewport_transform.dart';
import 'package:rawsr_gui/src/features/library/grade_bridge.dart';
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
    this.grade = identityGradeParams,
    this.gradePreviewing = false,
    this.gradeCommitRevision = 0,
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
  final GradeParamsDto grade;
  final bool gradePreviewing;
  final int gradeCommitRevision;

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
    bool? loading,
    String? error,
    bool clearError = false,
    double? zoom,
    Offset? pan,
    Rect? crop,
    bool clearCrop = false,
    bool? cropMode,
    bool? grayMode,
    GradeParamsDto? grade,
    bool? gradePreviewing,
    int? gradeCommitRevision,
  }) {
    return CanvasState(
      path: path ?? this.path,
      handle: clearHandle ? null : handle ?? this.handle,
      preview: clearPreview ? null : preview ?? this.preview,
      region: clearRegion ? null : region ?? this.region,
      regionRect: clearRegion ? null : regionRect ?? this.regionRect,
      loading: loading ?? this.loading,
      error: clearError ? null : error ?? this.error,
      zoom: zoom ?? this.zoom,
      pan: pan ?? this.pan,
      crop: clearCrop ? null : crop ?? this.crop,
      cropMode: cropMode ?? this.cropMode,
      grayMode: grayMode ?? this.grayMode,
      grade: grade ?? this.grade,
      gradePreviewing: gradePreviewing ?? this.gradePreviewing,
      gradeCommitRevision: gradeCommitRevision ?? this.gradeCommitRevision,
    );
  }
}

class CanvasController extends StateNotifier<CanvasState> {
  CanvasController(
    this._backend, {
    this.gradePreviewThrottle = const Duration(milliseconds: 120),
  }) : super(const CanvasState());

  final RawsrBackend _backend;
  final Duration gradePreviewThrottle;
  int _generation = 0;
  Timer? _gradeTimer;
  LibraryItem? _desiredGradeItem;
  GradeParamsDto? _desiredGrade;
  bool _gradeRendering = false;
  bool _disposed = false;
  Completer<void>? _gradeIdleCompleter;

  Future<void> open(LibraryItem item) async {
    _cancelPendingGradePreview();
    final generation = ++_generation;
    final oldHandle = state.handle;
    final grade = gradeParamsFromSettings(item.grade);
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
        grade: grade,
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
        grade: grade,
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

  void requestGradePreview(LibraryItem item, {required bool immediate}) {
    if (_disposed || state.handle == null || state.path != item.path) return;
    final grade = gradeParamsFromSettings(item.grade);
    _desiredGradeItem = item;
    _desiredGrade = grade;

    if (grade == state.grade && !_gradeRendering) {
      _gradeTimer?.cancel();
      _gradeTimer = null;
      _desiredGradeItem = null;
      _desiredGrade = null;
      _setGradePreviewing(false);
      _completeGradeIdleIfPossible();
      return;
    }

    _markGradeBusy();
    _setGradePreviewing(true);
    if (_gradeRendering) return;
    if (immediate) {
      _gradeTimer?.cancel();
      _gradeTimer = null;
      unawaited(_renderDesiredGrade());
      return;
    }
    _gradeTimer ??= Timer(gradePreviewThrottle, () {
      _gradeTimer = null;
      unawaited(_renderDesiredGrade());
    });
  }

  Future<void> waitForGradePreviewIdle() {
    if (!_gradeRendering && _gradeTimer == null && _desiredGrade == null) {
      return Future<void>.value();
    }
    _gradeIdleCompleter ??= Completer<void>();
    return _gradeIdleCompleter!.future;
  }

  Future<bool> applyGrade(LibraryItem item) async {
    final target = gradeParamsFromSettings(item.grade);
    final revision = state.gradeCommitRevision;
    requestGradePreview(item, immediate: true);
    await waitForGradePreviewIdle();
    return state.gradeCommitRevision > revision && state.grade == target;
  }

  Future<void> _renderDesiredGrade() async {
    if (_disposed || _gradeRendering) return;
    _gradeTimer?.cancel();
    _gradeTimer = null;
    final item = _desiredGradeItem;
    final grade = _desiredGrade;
    final handle = state.handle;
    if (item == null ||
        grade == null ||
        handle == null ||
        state.path != item.path) {
      _desiredGradeItem = null;
      _desiredGrade = null;
      _setGradePreviewing(false);
      _completeGradeIdleIfPossible();
      return;
    }
    if (grade == state.grade) {
      _desiredGradeItem = null;
      _desiredGrade = null;
      _setGradePreviewing(false);
      _completeGradeIdleIfPossible();
      return;
    }

    _gradeRendering = true;
    final generation = ++_generation;
    try {
      final preview = await _backend.renderPreview(
        handle: handle,
        maxEdge: 2048,
        grade: grade,
      );
      final isLatest = _desiredGrade == grade;
      if (!_disposed &&
          generation == _generation &&
          state.handle == handle &&
          state.path == item.path &&
          isLatest) {
        _desiredGradeItem = null;
        _desiredGrade = null;
        state = state.copyWith(
          preview: preview,
          grade: grade,
          gradePreviewing: false,
          gradeCommitRevision: state.gradeCommitRevision + 1,
          clearRegion: true,
          clearError: true,
        );
      }
    } catch (error) {
      final isLatest = _desiredGrade == grade;
      if (!_disposed &&
          generation == _generation &&
          state.handle == handle &&
          state.path == item.path &&
          isLatest) {
        _desiredGradeItem = null;
        _desiredGrade = null;
        state = state.copyWith(
          gradePreviewing: false,
          error: '调色预览渲染失败：$error。已保留上一次成功应用的画面。',
        );
      }
    } finally {
      _gradeRendering = false;
      if (_disposed) {
        _completeGradeIdleIfPossible();
      } else {
        final pending = _desiredGrade;
        if (pending != null && pending != state.grade) {
          unawaited(_renderDesiredGrade());
        } else {
          _desiredGradeItem = null;
          _desiredGrade = null;
          _setGradePreviewing(false);
          _completeGradeIdleIfPossible();
        }
      }
    }
  }

  void _cancelPendingGradePreview() {
    _gradeTimer?.cancel();
    _gradeTimer = null;
    _desiredGradeItem = null;
    _desiredGrade = null;
    _setGradePreviewing(false);
    _completeGradeIdleIfPossible();
  }

  void _setGradePreviewing(bool value) {
    if (_disposed || state.gradePreviewing == value) return;
    state = state.copyWith(gradePreviewing: value);
  }

  void _markGradeBusy() {
    if (_gradeIdleCompleter == null || _gradeIdleCompleter!.isCompleted) {
      _gradeIdleCompleter = Completer<void>();
    }
  }

  void _completeGradeIdleIfPossible() {
    if (_gradeRendering || _gradeTimer != null || _desiredGrade != null) return;
    final completer = _gradeIdleCompleter;
    _gradeIdleCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
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
    if (handle == null ||
        state.zoom < 2 ||
        state.loading ||
        state.gradePreviewing) {
      return;
    }
    final generation = _generation;
    final grade = state.grade;
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
        grade: grade,
      );
      if (generation != _generation ||
          state.handle != handle ||
          state.grade != grade) {
        return;
      }
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
    _disposed = true;
    _gradeTimer?.cancel();
    _gradeTimer = null;
    _desiredGradeItem = null;
    _desiredGrade = null;
    _generation++;
    final gradeIdle = _gradeIdleCompleter;
    _gradeIdleCompleter = null;
    if (gradeIdle != null && !gradeIdle.isCompleted) gradeIdle.complete();
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
