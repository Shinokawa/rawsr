import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/backend/rawsr_backend.dart';
import 'package:rawsr_gui/src/features/canvas/canvas_controller.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';

class StripResult {
  const StripResult({
    required this.model,
    required this.elapsedMs,
    this.isReference = false,
    this.image,
    this.reason,
  });

  final String model;
  final BigInt elapsedMs;
  final bool isReference;
  final RgbaBytes? image;
  final String? reason;
}

class TestStripState {
  const TestStripState({
    this.visible = false,
    this.running = false,
    this.kind,
    this.fullImage = false,
    this.autoSampled = false,
    this.stripRect,
    this.preDenoiseModel,
    this.preprocessCacheHit = false,
    this.models = const <String>[],
    this.results = const <StripResult>[],
    this.progress = const <String, double>{},
    this.champions = const <String, String>{},
    this.srChampionPreDenoiseModel,
    this.srNeedsRetest = false,
    this.error,
  });

  final bool visible;
  final bool running;
  final String? kind;
  final bool fullImage;
  final bool autoSampled;
  final RegionRect? stripRect;
  final String? preDenoiseModel;
  final bool preprocessCacheHit;
  final List<String> models;
  final List<StripResult> results;
  final Map<String, double> progress;
  final Map<String, String> champions;
  final String? srChampionPreDenoiseModel;
  final bool srNeedsRetest;
  final String? error;

  String? championFor(String kind) => champions[kind];

  bool get hasChampion => champions.isNotEmpty;

  TestStripState copyWith({
    bool? visible,
    bool? running,
    String? kind,
    bool? fullImage,
    bool? autoSampled,
    RegionRect? stripRect,
    String? preDenoiseModel,
    bool clearPreDenoiseModel = false,
    bool? preprocessCacheHit,
    List<String>? models,
    List<StripResult>? results,
    Map<String, double>? progress,
    Map<String, String>? champions,
    String? srChampionPreDenoiseModel,
    bool clearSrChampionPreDenoiseModel = false,
    bool? srNeedsRetest,
    String? error,
    bool clearError = false,
  }) {
    return TestStripState(
      visible: visible ?? this.visible,
      running: running ?? this.running,
      kind: kind ?? this.kind,
      fullImage: fullImage ?? this.fullImage,
      autoSampled: autoSampled ?? this.autoSampled,
      stripRect: stripRect ?? this.stripRect,
      preDenoiseModel: clearPreDenoiseModel
          ? null
          : preDenoiseModel ?? this.preDenoiseModel,
      preprocessCacheHit: preprocessCacheHit ?? this.preprocessCacheHit,
      models: models ?? this.models,
      results: results ?? this.results,
      progress: progress ?? this.progress,
      champions: champions ?? this.champions,
      srChampionPreDenoiseModel: clearSrChampionPreDenoiseModel
          ? null
          : srChampionPreDenoiseModel ?? this.srChampionPreDenoiseModel,
      srNeedsRetest: srNeedsRetest ?? this.srNeedsRetest,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class TestStripController extends StateNotifier<TestStripState> {
  TestStripController(this._backend) : super(const TestStripState());

  final RawsrBackend _backend;
  StreamSubscription<StripEvent>? _subscription;

  Future<void> generate({
    required String kind,
    required CanvasState canvas,
    required List<String> models,
    required int maxScale,
  }) async {
    final handle = canvas.handle;
    final crop = canvas.crop;
    if (handle == null) {
      state = state.copyWith(error: '无法生成试片：请先打开一张照片。');
      return;
    }
    if (canvas.loading || canvas.gradePreviewing) {
      state = state.copyWith(error: '调色预览正在更新，请完成后再生成试片。');
      return;
    }
    if (models.length != 1) {
      state = state.copyWith(error: '无法生成试片：请选择 1 个模型。');
      return;
    }
    final previous = state;
    await _subscription?.cancel();
    final rectChoice = _chooseStripRect(
      handle: handle,
      crop: crop,
      maxScale: maxScale,
    );
    final preDenoiseModel = kind == 'sr'
        ? previous.championFor('denoise')
        : null;
    state = TestStripState(
      visible: true,
      running: true,
      kind: kind,
      fullImage: crop == null,
      autoSampled: rectChoice.autoSampled,
      stripRect: rectChoice.rect,
      preDenoiseModel: preDenoiseModel,
      models: List<String>.of(models),
      progress: <String, double>{for (final model in models) model: 0},
      champions: previous.champions,
      srChampionPreDenoiseModel: previous.srChampionPreDenoiseModel,
      srNeedsRetest: previous.srNeedsRetest,
    );
    final stream = _backend.runTestStrip(
      handle: handle,
      rect: rectChoice.rect,
      models: models,
      denoiseModel: preDenoiseModel,
      grade: canvas.grade,
    );
    final done = Completer<void>();
    _subscription = stream.listen(
      _onEvent,
      onError: (Object error, StackTrace stackTrace) {
        state = state.copyWith(
          running: false,
          error: '试片推理中断：$error。请检查模型文件与推理设备。',
        );
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        state = state.copyWith(running: false);
        if (!done.isCompleted) done.complete();
      },
    );
    await done.future;
  }

  void _onEvent(StripEvent event) {
    final progress = event.isReference
        ? state.progress
        : <String, double>{...state.progress, event.model: event.progress};
    if (event.state == 'completed' || event.state == 'failed') {
      final results = <StripResult>[
        ...state.results.where(
          (result) => event.isReference
              ? !result.isReference
              : result.isReference || result.model != event.model,
        ),
        StripResult(
          model: event.model,
          elapsedMs: event.elapsedMs,
          isReference: event.isReference,
          image: event.image,
          reason: event.reason,
        ),
      ];
      state = state.copyWith(results: results, progress: progress);
    } else {
      state = state.copyWith(
        progress: progress,
        preprocessCacheHit: state.preprocessCacheHit || event.state == 'cached',
      );
    }
  }

  void chooseChampion(String model) {
    if (!state.results.any(
      (result) =>
          !result.isReference && result.model == model && result.image != null,
    )) {
      return;
    }
    final kind = state.kind;
    if (kind == null) return;
    final champions = <String, String>{...state.champions, kind: model};
    if (kind == 'denoise') {
      final changed = state.championFor('denoise') != model;
      final invalidatedSr = changed && champions.remove('sr') != null;
      state = state.copyWith(
        champions: champions,
        visible: false,
        srNeedsRetest: invalidatedSr,
        clearSrChampionPreDenoiseModel: changed,
      );
      return;
    }
    state = state.copyWith(
      champions: champions,
      srChampionPreDenoiseModel: state.preDenoiseModel,
      clearSrChampionPreDenoiseModel: state.preDenoiseModel == null,
      srNeedsRetest: false,
      visible: false,
    );
  }

  void showComparison() {
    if (state.results.isNotEmpty) {
      state = state.copyWith(visible: true);
    }
  }

  void closeComparison() => state = state.copyWith(visible: false);

  void resetForSourceChange() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    state = const TestStripState();
  }

  void invalidateForGradeChange() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    state = TestStripState(
      champions: state.champions,
      srChampionPreDenoiseModel: state.srChampionPreDenoiseModel,
      srNeedsRetest: state.srNeedsRetest,
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

class _StripRectChoice {
  const _StripRectChoice({required this.rect, required this.autoSampled});

  final RegionRect rect;
  final bool autoSampled;
}

_StripRectChoice _chooseStripRect({
  required ImageHandle handle,
  required Rect? crop,
  required int maxScale,
}) {
  final requested = crop == null
      ? RegionRect(x: 0, y: 0, width: handle.width, height: handle.height)
      : RegionRect(
          x: crop.left.floor(),
          y: crop.top.floor(),
          width: crop.width.ceil(),
          height: crop.height.ceil(),
        );
  const maxOutputPixels = 16 * 1024 * 1024;
  const automaticSamplePixels = 512 * 512;
  final scale = math.max(1, maxScale);
  final outputLimitedPixels = math.max(1, maxOutputPixels ~/ (scale * scale));
  final maxInputPixels = crop == null
      ? math.min(outputLimitedPixels, automaticSamplePixels)
      : outputLimitedPixels;
  final requestedPixels = requested.width * requested.height;
  if (requestedPixels <= maxInputPixels) {
    return _StripRectChoice(rect: requested, autoSampled: false);
  }
  final factor = math.sqrt(maxInputPixels / requestedPixels);
  final width = math.max(1, (requested.width * factor).floor());
  final height = math.max(1, (requested.height * factor).floor());
  final x = requested.x + (requested.width - width) ~/ 2;
  final y = requested.y + (requested.height - height) ~/ 2;
  return _StripRectChoice(
    rect: RegionRect(x: x, y: y, width: width, height: height),
    autoSampled: true,
  );
}

final testStripProvider =
    StateNotifierProvider<TestStripController, TestStripState>((ref) {
      return TestStripController(ref.watch(rawsrBackendProvider));
    });
