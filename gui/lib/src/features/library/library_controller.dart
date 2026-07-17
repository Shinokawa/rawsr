import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/backend/rawsr_backend.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';

enum BaseCurveOption { srgb, filmic }

class LibraryItem {
  const LibraryItem({
    required this.path,
    required this.name,
    this.thumbnail,
    this.loading = true,
    this.error,
    this.exposureEv = 0,
    this.baseCurve = BaseCurveOption.srgb,
  });

  final String path;
  final String name;
  final ThumbData? thumbnail;
  final bool loading;
  final String? error;
  final double exposureEv;
  final BaseCurveOption baseCurve;

  LibraryItem copyWith({
    ThumbData? thumbnail,
    bool? loading,
    String? error,
    bool clearError = false,
    double? exposureEv,
    BaseCurveOption? baseCurve,
  }) {
    return LibraryItem(
      path: path,
      name: name,
      thumbnail: thumbnail ?? this.thumbnail,
      loading: loading ?? this.loading,
      error: clearError ? null : error ?? this.error,
      exposureEv: exposureEv ?? this.exposureEv,
      baseCurve: baseCurve ?? this.baseCurve,
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
    _updateSelected((item) => item.copyWith(exposureEv: value));
  }

  void updateBaseCurve(BaseCurveOption curve) {
    _updateSelected((item) => item.copyWith(baseCurve: curve));
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
