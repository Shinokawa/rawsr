import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/features/test_strip/test_strip_controller.dart';
import 'package:rawsr_gui/src/theme/rawsr_theme.dart';
import 'package:rawsr_gui/src/widgets/rawsr_button.dart';
import 'package:rawsr_gui/src/widgets/rawsr_controls.dart';
import 'package:rawsr_gui/src/widgets/rgba_frame.dart';

class TestStripView extends ConsumerStatefulWidget {
  const TestStripView({super.key});

  @override
  ConsumerState<TestStripView> createState() => _TestStripViewState();
}

class _TestStripViewState extends ConsumerState<TestStripView> {
  double _zoom = 1;
  double _startZoom = 1;
  Offset _pan = Offset.zero;
  Offset _startPan = Offset.zero;
  Offset _startFocal = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(testStripProvider);
    final palette = context.palette;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final scopeLabel = state.autoSampled
        ? state.fullImage
              ? '全图自动取样'
              : '框选内自动取样'
        : state.fullImage
        ? '全图'
        : '框选';
    final title = state.kind == 'sr' && state.preDenoiseModel != null
        ? '${state.preDenoiseModel} → 超分试片'
        : '${state.kind == 'sr' ? '超分' : '降噪'}试片对比';
    final reference = state.results
        .where((result) => result.isReference)
        .firstOrNull;
    final processed = state.results
        .where((result) => !result.isReference)
        .firstOrNull;
    final referenceLabel = state.kind == 'sr'
        ? state.preDenoiseModel == null
              ? '原图（超分前）'
              : '降噪结果（超分前）'
        : '原图';
    final processedLabel = state.models.firstOrNull ?? '处理结果';
    final stillPreparing =
        state.preDenoiseModel != null &&
        state.results.isEmpty &&
        state.progress.values.every((value) => value <= 0.5);
    return ColoredBox(
      color: palette.canvas,
      child: Column(
        children: <Widget>[
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: palette.chrome1,
              border: Border(bottom: BorderSide(color: palette.line)),
            ),
            child: Row(
              children: <Widget>[
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(width: 10),
                Text(
                  '$scopeLabel · 左侧基准 / 右侧结果',
                  style: context.mono.copyWith(
                    fontSize: 11,
                    color: palette.textLo,
                  ),
                ),
                const Spacer(),
                if (state.running)
                  Text(
                    stillPreparing
                        ? state.preprocessCacheHit
                              ? '已复用降噪缓存…'
                              : '正在运行固定降噪前级…'
                        : '正在生成右侧处理结果…',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(width: 10),
                RawsrButton(
                  label: '返回画布',
                  kind: RawsrButtonKind.secondary,
                  onPressed: ref
                      .read(testStripProvider.notifier)
                      .closeComparison,
                ),
              ],
            ),
          ),
          Expanded(
            child: state.results.isEmpty
                ? _ProgressList(state: state)
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onScaleStart: (details) {
                      _startZoom = _zoom;
                      _startPan = _pan;
                      _startFocal = details.localFocalPoint;
                    },
                    onScaleUpdate: (details) {
                      setState(() {
                        _zoom = (_startZoom * details.scale).clamp(0.5, 8);
                        _pan =
                            _startPan + details.localFocalPoint - _startFocal;
                      });
                    },
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Expanded(
                          child: _StripTile(
                            result: reference,
                            label: referenceLabel,
                            zoom: _zoom,
                            pan: _pan,
                            reducedMotion: reducedMotion,
                            allowChoose: false,
                          ),
                        ),
                        VerticalDivider(
                          width: 1,
                          thickness: 1,
                          color: palette.line,
                        ),
                        Expanded(
                          child: _StripTile(
                            result: processed,
                            label: processedLabel,
                            zoom: _zoom,
                            pan: _pan,
                            reducedMotion: reducedMotion,
                            allowChoose: true,
                            progress: state.progress[processedLabel] ?? 0,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
          if (state.error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              color: palette.chrome1,
              child: Text(
                state.error!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall!.copyWith(color: palette.danger),
              ),
            ),
        ],
      ),
    );
  }
}

class _ProgressList extends StatelessWidget {
  const _ProgressList({required this.state});

  final TestStripState state;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final model in state.models) ...<Widget>[
              RawsrProgressBar(
                value: state.progress[model] ?? 0,
                label:
                    '$model · ${((state.progress[model] ?? 0) * 100).round()}%',
              ),
              const SizedBox(height: 14),
            ],
          ],
        ),
      ),
    );
  }
}

class _StripTile extends ConsumerWidget {
  const _StripTile({
    required this.result,
    required this.label,
    required this.zoom,
    required this.pan,
    required this.reducedMotion,
    required this.allowChoose,
    this.progress = 0,
  });

  final StripResult? result;
  final String label;
  final double zoom;
  final Offset pan;
  final bool reducedMotion;
  final bool allowChoose;
  final double progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: ClipRect(
            child: result == null
                ? Center(
                    child: SizedBox(
                      width: 280,
                      child: RawsrProgressBar(
                        value: progress,
                        label: '$label · ${(progress * 100).round()}%',
                      ),
                    ),
                  )
                : result!.image == null
                ? Center(
                    child: Text(
                      '模型失败：${result!.reason ?? '未知原因'}',
                      textAlign: TextAlign.center,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall!.copyWith(color: palette.danger),
                    ),
                  )
                : TweenAnimationBuilder<double>(
                    key: ValueKey<String>(result!.model),
                    duration: reducedMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                    tween: Tween<double>(begin: 0, end: 1),
                    builder: (context, value, child) {
                      return StripRevealFrame(
                        progress: reducedMotion ? 1 : value,
                        zoom: zoom,
                        pan: pan,
                        child: child!,
                      );
                    },
                    child: RgbaFrameView(frame: result!.image!),
                  ),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: palette.chrome1,
            border: Border(top: BorderSide(color: palette.line)),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(label, style: Theme.of(context).textTheme.labelLarge),
                    if (result != null)
                      Text(
                        result!.isReference
                            ? '双线性缩放基准'
                            : '${result!.elapsedMs} ms',
                        style: context.mono.copyWith(
                          fontSize: 11,
                          color: palette.textLo,
                        ),
                      ),
                  ],
                ),
              ),
              if (allowChoose && result?.image != null)
                RawsrButton(
                  label: '定片',
                  onPressed: () => ref
                      .read(testStripProvider.notifier)
                      .chooseChampion(result!.model),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class StripRevealFrame extends StatelessWidget {
  const StripRevealFrame({
    required this.progress,
    required this.zoom,
    required this.pan,
    required this.child,
    super.key,
  });

  final double progress;
  final double zoom;
  final Offset pan;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final value = progress.clamp(0, 1).toDouble();
    return Opacity(
      opacity: 0.35 + value * 0.65,
      child: ColorFiltered(
        colorFilter: ColorFilter.matrix(_contrastMatrix(value)),
        child: Transform.translate(
          offset: pan,
          child: Transform.scale(scale: zoom, child: child),
        ),
      ),
    );
  }

  List<double> _contrastMatrix(double value) {
    final contrast = 0.25 + value * 0.75;
    final offset = 128 * (1 - contrast);
    final saturation = value;
    final red = 0.2126 * (1 - saturation);
    final green = 0.7152 * (1 - saturation);
    final blue = 0.0722 * (1 - saturation);
    return <double>[
      contrast * (red + saturation),
      contrast * green,
      contrast * blue,
      0,
      offset,
      contrast * red,
      contrast * (green + saturation),
      contrast * blue,
      0,
      offset,
      contrast * red,
      contrast * green,
      contrast * (blue + saturation),
      0,
      offset,
      0,
      0,
      0,
      1,
      0,
    ];
  }
}
