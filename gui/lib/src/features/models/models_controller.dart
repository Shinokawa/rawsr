import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/backend/rawsr_backend.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';

final modelsProvider = FutureProvider<List<ModelEntry>>((ref) {
  return ref.watch(rawsrBackendProvider).listModels();
});

class SelectedModelsController extends StateNotifier<Set<String>> {
  SelectedModelsController() : super(<String>{});

  void toggle(String name) {
    if (state.contains(name)) {
      state = <String>{...state}..remove(name);
      return;
    }
    if (state.length >= 4) return;
    state = <String>{...state, name};
  }

  void chooseOnly(String name) => state = <String>{name};
}

final selectedModelsProvider =
    StateNotifierProvider<SelectedModelsController, Set<String>>(
      (ref) => SelectedModelsController(),
    );
