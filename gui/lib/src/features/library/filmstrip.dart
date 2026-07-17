import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/features/library/library_controller.dart';
import 'package:rawsr_gui/src/theme/rawsr_theme.dart';
import 'package:rawsr_gui/src/widgets/rawsr_button.dart';

class Filmstrip extends ConsumerWidget {
  const Filmstrip({
    required this.onImport,
    required this.onSettings,
    super.key,
  });

  final VoidCallback onImport;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(libraryProvider);
    final palette = context.palette;
    return ColoredBox(
      color: palette.chrome0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '胶片库',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Text(
                  '${state.items.length}',
                  style: context.mono.copyWith(fontSize: 11),
                ),
                IconButton(
                  tooltip: '设置与模型',
                  onPressed: onSettings,
                  icon: const Icon(Icons.settings_outlined, size: 17),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: RawsrButton(
              label: '导入照片',
              icon: Icons.add_photo_alternate_outlined,
              shortcut: 'Ctrl O',
              onPressed: onImport,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: state.items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            Icons.photo_library_outlined,
                            size: 28,
                            color: palette.textLo,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '拖入 RAW 或 JPEG 开始',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    key: const ValueKey<String>('filmstrip-list'),
                    itemCount: state.items.length,
                    itemExtent: 138,
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                    itemBuilder: (context, index) {
                      final item = state.items[index];
                      final selected = state.selectedIndex == index;
                      return _FilmItem(
                        item: item,
                        selected: selected,
                        onTap: () =>
                            ref.read(libraryProvider.notifier).select(index),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _FilmItem extends StatelessWidget {
  const _FilmItem({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final LibraryItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? palette.safelightDim : palette.chrome1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: selected ? palette.safelight : palette.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: item.thumbnail != null
                    ? Image.memory(
                        item.thumbnail!.jpeg,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (context, error, stackTrace) =>
                            _error(context),
                      )
                    : item.loading
                    ? Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: palette.safelight,
                          ),
                        ),
                      )
                    : _error(context),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall!.copyWith(
                    color: selected ? palette.textHi : palette.textLo,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _error(BuildContext context) {
    return Tooltip(
      message: item.error ?? '缩略图不可用',
      child: Center(
        child: Icon(Icons.broken_image_outlined, color: context.palette.danger),
      ),
    );
  }
}
