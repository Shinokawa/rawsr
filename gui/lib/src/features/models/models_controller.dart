import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/backend/rawsr_backend.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';

final modelsProvider = FutureProvider<List<ModelEntry>>((ref) {
  return ref.watch(rawsrBackendProvider).listModels();
});

class SelectedModelsState {
  const SelectedModelsState({
    this.denoise = const <String>{},
    this.sr = const <String>{},
  });

  final Set<String> denoise;
  final Set<String> sr;

  Set<String> forKind(String kind) => kind == 'sr' ? sr : denoise;

  SelectedModelsState withKind(String kind, Set<String> models) {
    final value = Set<String>.unmodifiable(models);
    return kind == 'sr'
        ? SelectedModelsState(denoise: denoise, sr: value)
        : SelectedModelsState(denoise: value, sr: sr);
  }
}

class SelectedModelsController extends StateNotifier<SelectedModelsState> {
  SelectedModelsController() : super(const SelectedModelsState());

  void toggle(String kind, String name) {
    final selected = state.forKind(kind).contains(name)
        ? <String>{}
        : <String>{name};
    state = state.withKind(kind, selected);
  }
}

final selectedModelsProvider =
    StateNotifierProvider<SelectedModelsController, SelectedModelsState>(
      (ref) => SelectedModelsController(),
    );
