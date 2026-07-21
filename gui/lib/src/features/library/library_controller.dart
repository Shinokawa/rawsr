import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/backend/rawsr_backend.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';

enum BaseCurveOption { srgb, filmic }

const currentRecipeSchemaVersion = 2;

const gradeMinimum = -100.0;
const gradeMaximum = 100.0;

class DevelopSettings {
  const DevelopSettings({
    this.exposureEv = 0,
    this.baseCurve = BaseCurveOption.srgb,
  });

  final double exposureEv;
  final BaseCurveOption baseCurve;

  DevelopSettings copyWith({double? exposureEv, BaseCurveOption? baseCurve}) {
    return DevelopSettings(
      exposureEv: exposureEv ?? this.exposureEv,
      baseCurve: baseCurve ?? this.baseCurve,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is DevelopSettings &&
            exposureEv == other.exposureEv &&
            baseCurve == other.baseCurve;
  }

  @override
  int get hashCode => Object.hash(exposureEv, baseCurve);
}

class GradeSettings {
  const GradeSettings({
    this.contrast = 0,
    this.highlights = 0,
    this.shadows = 0,
    this.whites = 0,
    this.blacks = 0,
    this.vibrance = 0,
    this.saturation = 0,
  });

  final double contrast;
  final double highlights;
  final double shadows;
  final double whites;
  final double blacks;
  final double vibrance;
  final double saturation;

  GradeSettings copyWith({
    double? contrast,
    double? highlights,
    double? shadows,
    double? whites,
    double? blacks,
    double? vibrance,
    double? saturation,
  }) {
    return GradeSettings(
      contrast: contrast ?? this.contrast,
      highlights: highlights ?? this.highlights,
      shadows: shadows ?? this.shadows,
      whites: whites ?? this.whites,
      blacks: blacks ?? this.blacks,
      vibrance: vibrance ?? this.vibrance,
      saturation: saturation ?? this.saturation,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is GradeSettings &&
            contrast == other.contrast &&
            highlights == other.highlights &&
            shadows == other.shadows &&
            whites == other.whites &&
            blacks == other.blacks &&
            vibrance == other.vibrance &&
            saturation == other.saturation;
  }

  @override
  int get hashCode => Object.hash(
    contrast,
    highlights,
    shadows,
    whites,
    blacks,
    vibrance,
    saturation,
  );
}

class EditRecipe {
  const EditRecipe({
    this.schemaVersion = currentRecipeSchemaVersion,
    this.develop = const DevelopSettings(),
    this.grade = const GradeSettings(),
  });

  final int schemaVersion;
  final DevelopSettings develop;
  final GradeSettings grade;

  EditRecipe copyWith({
    int? schemaVersion,
    DevelopSettings? develop,
    GradeSettings? grade,
  }) {
    return EditRecipe(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      develop: develop ?? this.develop,
      grade: grade ?? this.grade,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is EditRecipe &&
            schemaVersion == other.schemaVersion &&
            develop == other.develop &&
            grade == other.grade;
  }

  @override
  int get hashCode => Object.hash(schemaVersion, develop, grade);
}

class LibraryItem {
  const LibraryItem({
    required this.path,
    required this.name,
    this.thumbnail,
    this.loading = true,
    this.error,
    this.recipe = const EditRecipe(),
    this.recipeRevision = 0,
  });

  final String path;
  final String name;
  final ThumbData? thumbnail;
  final bool loading;
  final String? error;
  final EditRecipe recipe;
  final int recipeRevision;

  double get exposureEv => recipe.develop.exposureEv;

  BaseCurveOption get baseCurve => recipe.develop.baseCurve;

  GradeSettings get grade => recipe.grade;

  LibraryItem copyWith({
    ThumbData? thumbnail,
    bool? loading,
    String? error,
    bool clearError = false,
    EditRecipe? recipe,
    int? recipeRevision,
  }) {
    return LibraryItem(
      path: path,
      name: name,
      thumbnail: thumbnail ?? this.thumbnail,
      loading: loading ?? this.loading,
      error: clearError ? null : error ?? this.error,
      recipe: recipe ?? this.recipe,
      recipeRevision: recipeRevision ?? this.recipeRevision,
    );
  }
}

class LibraryState {
  const LibraryState({
    this.items = const <LibraryItem>[],
    this.selectedIndex,
    this.message,
  });

  final List<LibraryItem> items;
  final int? selectedIndex;
  final String? message;

  LibraryItem? get selected {
    final index = selectedIndex;
    if (index == null || index < 0 || index >= items.length) return null;
    return items[index];
  }

  LibraryState copyWith({
    List<LibraryItem>? items,
    int? selectedIndex,
    bool clearSelection = false,
    String? message,
    bool clearMessage = false,
  }) {
    return LibraryState(
      items: items ?? this.items,
      selectedIndex: clearSelection
          ? null
          : selectedIndex ?? this.selectedIndex,
      message: clearMessage ? null : message ?? this.message,
    );
  }
}

class LibraryController extends StateNotifier<LibraryState> {
  LibraryController(this._backend) : super(const LibraryState());

  static const supportedExtensions = <String>{
    'arw',
    'jpg',
    'jpeg',
    'png',
    'tif',
    'tiff',
  };

  final RawsrBackend _backend;

  Future<void> importPaths(Iterable<String> paths) async {
    final existing = state.items.map((item) => item.path.toLowerCase()).toSet();
    final accepted = <String>[];
    final rejected = <String>[];
    for (final path in paths) {
      final normalized = path.toLowerCase();
      final dot = normalized.lastIndexOf('.');
      final extension = dot < 0 ? '' : normalized.substring(dot + 1);
      if (!supportedExtensions.contains(extension)) {
        rejected.add(path);
      } else if (existing.add(normalized)) {
        accepted.add(path);
      }
    }
    if (rejected.isNotEmpty) {
      state = state.copyWith(
        message:
            '无法导入 ${rejected.length} 个文件：仅支持 ARW、JPEG、PNG、TIFF。请选择受支持的照片格式。',
      );
    } else {
      state = state.copyWith(clearMessage: true);
    }
    if (accepted.isEmpty) return;

    final start = state.items.length;
    final pending = accepted
        .map((path) => LibraryItem(path: path, name: _basename(path)))
        .toList(growable: false);
    state = state.copyWith(
      items: <LibraryItem>[...state.items, ...pending],
      selectedIndex: state.selectedIndex ?? start,
    );

    await Future.wait(<Future<void>>[
      for (var offset = 0; offset < pending.length; offset++)
        _loadThumbnail(start + offset),
    ]);
  }

  void select(int index) {
    if (index < 0 || index >= state.items.length) return;
    state = state.copyWith(selectedIndex: index, clearMessage: true);
  }

  void updateExposure(double value) {
    if (!value.isFinite) return;
    _updateRecipe(
      (recipe) => recipe.copyWith(
        develop: recipe.develop.copyWith(
          exposureEv: value.clamp(-4.0, 4.0).toDouble(),
        ),
      ),
    );
  }

  void updateBaseCurve(BaseCurveOption curve) {
    _updateRecipe(
      (recipe) =>
          recipe.copyWith(develop: recipe.develop.copyWith(baseCurve: curve)),
    );
  }

  void updateContrast(double value) {
    _updateGrade(value, (grade, value) => grade.copyWith(contrast: value));
  }

  void updateHighlights(double value) {
    _updateGrade(value, (grade, value) => grade.copyWith(highlights: value));
  }

  void updateShadows(double value) {
    _updateGrade(value, (grade, value) => grade.copyWith(shadows: value));
  }

  void updateWhites(double value) {
    _updateGrade(value, (grade, value) => grade.copyWith(whites: value));
  }

  void updateBlacks(double value) {
    _updateGrade(value, (grade, value) => grade.copyWith(blacks: value));
  }

  void updateVibrance(double value) {
    _updateGrade(value, (grade, value) => grade.copyWith(vibrance: value));
  }

  void updateSaturation(double value) {
    _updateGrade(value, (grade, value) => grade.copyWith(saturation: value));
  }

  void clearMessage() => state = state.copyWith(clearMessage: true);

  Future<void> _loadThumbnail(int index) async {
    final item = state.items[index];
    try {
      final thumbnail = await _backend.extractThumb(item.path);
      _replace(
        index,
        item.copyWith(thumbnail: thumbnail, loading: false, clearError: true),
      );
    } catch (error) {
      _replace(
        index,
        item.copyWith(
          loading: false,
          error: '缩略图读取失败：$error。请确认文件未损坏且相机型号受支持。',
        ),
      );
    }
  }

  void _updateSelected(LibraryItem Function(LibraryItem item) update) {
    final index = state.selectedIndex;
    if (index == null) return;
    _replace(index, update(state.items[index]));
  }

  void _updateRecipe(EditRecipe Function(EditRecipe recipe) update) {
    _updateSelected((item) {
      final recipe = update(item.recipe);
      if (recipe == item.recipe) return item;
      return item.copyWith(
        recipe: recipe,
        recipeRevision: item.recipeRevision + 1,
      );
    });
  }

  void _updateGrade(
    double value,
    GradeSettings Function(GradeSettings grade, double value) update,
  ) {
    if (!value.isFinite) return;
    final clamped = value.clamp(gradeMinimum, gradeMaximum).toDouble();
    _updateRecipe(
      (recipe) => recipe.copyWith(grade: update(recipe.grade, clamped)),
    );
  }

  void _replace(int index, LibraryItem item) {
    if (index < 0 || index >= state.items.length) return;
    final items = List<LibraryItem>.of(state.items);
    items[index] = item;
    state = state.copyWith(items: items);
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.substring(normalized.lastIndexOf('/') + 1);
  }
}

final libraryProvider = StateNotifierProvider<LibraryController, LibraryState>((
  ref,
) {
  return LibraryController(ref.watch(rawsrBackendProvider));
});
