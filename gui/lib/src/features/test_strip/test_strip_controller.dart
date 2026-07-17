import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/backend/rawsr_backend.dart';
import 'package:rawsr_gui/src/features/canvas/canvas_controller.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';

class StripResult {
  const StripResult({
    required this.model,
    required this.elapsedMs,
    this.image,
    this.reason,
  });

  final String model;
  final BigInt elapsedMs;
  final RgbaBytes? image;
  final String? reason;
}

class TestStripState {
  const TestStripState({
    this.visible = false,
    this.running = false,
    this.models = const <String>[],
    this.results = const <StripResult>[],
    this.progress = const <String, double>{},
    this.champion,
    this.error,
  });

  final bool visible;
  final bool running;
  final List<String> models;
  final List<StripResult> results;
  final Map<String, double> progress;
  final String? champion;
  final String? error;

  TestStripState copyWith({
    bool? visible,
    bool? running,
    List<String>? models,
    List<StripResult>? results,
    Map<String, double>? progress,
    String? champion,
    String? error,
    bool clearError = false,
  }) {
    return TestStripState(
      visible: visible ?? this.visible,
      running: running ?? this.running,
      models: models ?? this.models,
      results: results ?? this.results,
      progress: progress ?? this.progress,
      champion: champion ?? this.champion,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class TestStripController extends StateNotifier<TestStripState> {
  TestStripController(this._backend) : super(const TestStripState());

  final RawsrBackend _backend;
  StreamSubscription<StripEvent>? _subscription;

  Future<void> generate(CanvasState canvas, List<String> models) async {
    final handle = canvas.handle;
    final crop = canvas.crop;
    if (handle == null) {
      state = state.copyWith(error: '无法生成试片：请先打开一张照片。');
      return;
    }
    if (crop == null) {
      state = state.copyWith(error: '无法生成试片：请先在画布上框选细节区域。');
      return;
    }
    if (models.length < 2 || models.length > 4) {
      state = state.copyWith(error: '无法生成试片：请选择 2–4 个模型。');
      return;
    }
    await _subscription?.cancel();
    state = TestStripState(
      visible: true,
      running: true,
      models: List<String>.of(models),
      progress: <String, double>{for (final model in models) model: 0},
      champion: state.champion,
    );
    final rect = RegionRect(
      x: crop.left.floor(),
      y: crop.top.floor(),
      width: crop.width.ceil(),
      height: crop.height.ceil(),
    );
    final stream = _backend.runTestStrip(
      handle: handle,
      rect: rect,
      models: models,
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
    final progress = <String, double>{
      ...state.progress,
      event.model: event.progress,
    };
    if (event.state == 'completed' || event.state == 'failed') {
      final results = <StripResult>[
        ...state.results.where((result) => result.model != event.model),
        StripResult(
          model: event.model,
          elapsedMs: event.elapsedMs,
          image: event.image,
          reason: event.reason,
        ),
      ];
      state = state.copyWith(results: results, progress: progress);
    } else {
      state = state.copyWith(progress: progress);
    }
  }

  void chooseChampion(String model) {
    if (!state.results.any(
      (result) => result.model == model && result.image != null,
    )) {
      return;
    }
    state = state.copyWith(champion: model, visible: false);
  }

  void showComparison() {
    if (state.results.isNotEmpty) {
      state = state.copyWith(visible: true);
    }
  }

  void closeComparison() => state = state.copyWith(visible: false);

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

final testStripProvider =
    StateNotifierProvider<TestStripController, TestStripState>((ref) {
      return TestStripController(ref.watch(rawsrBackendProvider));
    });
