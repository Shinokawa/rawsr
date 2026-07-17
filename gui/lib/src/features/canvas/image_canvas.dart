import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/features/canvas/canvas_controller.dart';
import 'package:rawsr_gui/src/features/canvas/viewport_transform.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';
import 'package:rawsr_gui/src/theme/rawsr_theme.dart';
import 'package:rawsr_gui/src/widgets/rawsr_button.dart';

class ImageCanvas extends ConsumerStatefulWidget {
  const ImageCanvas({super.key});

  @override
  ConsumerState<ImageCanvas> createState() => _ImageCanvasState();
}

class _ImageCanvasState extends ConsumerState<ImageCanvas> {
  double _startZoom = 1;
  Offset _startPan = Offset.zero;
  Offset _startFocal = Offset.zero;
  Offset? _cropStart;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(canvasProvider);
    final palette = context.palette;
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        final transform = ViewportTransform(
          viewportSize: viewportSize,
          imageSize: state.imageSize,
          zoom: state.zoom,
          pan: state.pan,
        );
        return ColoredBox(
          color: state.grayMode ? palette.canvasGray : palette.canvas,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent && state.handle != null) {
                      _handleScroll(event, state, transform);
                    }
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onScaleStart: (details) =>
                        _scaleStart(details, state, transform),
                    onScaleUpdate: (details) =>
                        _scaleUpdate(details, state, transform),
                    onScaleEnd: (_) => ref
                        .read(canvasProvider.notifier)
                        .requestVisibleRegion(_currentTransform(viewportSize)),
                    child: _DecodedCanvas(
                      preview: state.preview,
                      region: state.region,
                      regionRect: state.regionRect,
                      transform: transform,
                      crop: state.crop,
                    ),
                  ),
                ),
              ),
              if (state.handle == null && !state.loading && state.error == null)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        Icons.photo_size_select_actual_outlined,
                        size: 36,
                        color: palette.textLo,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '拖入 RAW 或 JPEG 开始',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 6),
                      const RawsrShortcutHint('Ctrl O'),
                    ],
                  ),
                ),
              if (state.loading)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      CircularProgressIndicator(color: palette.safelight),
                      const SizedBox(height: 12),
                      Text(
                        '正在解码并显影…',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              if (state.error != null)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: _CanvasError(message: state.error!),
                ),
              if (state.handle != null)
                Positioned(
                  left: 12,
                  top: 12,
                  child: _CanvasToolbar(state: state),
                ),
              if (state.handle != null)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: palette.chrome1,
                      border: Border.all(color: palette.line),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Text(
                        '${(state.zoom * 100).round()}%',
                        style: context.mono.copyWith(fontSize: 11),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _scaleStart(
    ScaleStartDetails details,
    CanvasState state,
    ViewportTransform transform,
  ) {
    _startZoom = state.zoom;
    _startPan = state.pan;
    _startFocal = details.localFocalPoint;
    _cropStart = state.cropMode
        ? transform.viewportToImage(details.localFocalPoint)
        : null;
  }

  void _scaleUpdate(
    ScaleUpdateDetails details,
    CanvasState state,
    ViewportTransform transform,
  ) {
    final controller = ref.read(canvasProvider.notifier);
    if (state.cropMode && _cropStart != null) {
      final current = transform.viewportToImage(details.localFocalPoint);
      controller.setCrop(Rect.fromPoints(_cropStart!, current));
      return;
    }
    controller.setView(
      zoom: _startZoom * details.scale,
      pan: _startPan + details.localFocalPoint - _startFocal,
    );
  }

  void _handleScroll(
    PointerScrollEvent event,
    CanvasState state,
    ViewportTransform transform,
  ) {
    final imagePoint = transform.viewportToImage(event.localPosition);
    final zoom = (state.zoom * math.exp(-event.scrollDelta.dy * 0.0015)).clamp(
      0.25,
      8.0,
    );
    final fitScale = transform.fitScale;
    final imageCenter = state.imageSize.center(Offset.zero);
    final pan =
        event.localPosition -
        transform.viewportSize.center(Offset.zero) -
        (imagePoint - imageCenter) * fitScale * zoom;
    ref.read(canvasProvider.notifier).setView(zoom: zoom, pan: pan);
    unawaited(
      ref
          .read(canvasProvider.notifier)
          .requestVisibleRegion(
            ViewportTransform(
              viewportSize: transform.viewportSize,
              imageSize: state.imageSize,
              zoom: zoom,
              pan: pan,
            ),
          ),
    );
  }

  ViewportTransform _currentTransform(Size viewportSize) {
    final state = ref.read(canvasProvider);
    return ViewportTransform(
      viewportSize: viewportSize,
      imageSize: state.imageSize,
      zoom: state.zoom,
      pan: state.pan,
    );
  }
}

class _CanvasToolbar extends ConsumerWidget {
  const _CanvasToolbar({required this.state});

  final CanvasState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(canvasProvider.notifier);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        RawsrButton(
          label: '框选',
          icon: Icons.crop_free,
          shortcut: 'C',
          kind: state.cropMode
              ? RawsrButtonKind.primary
              : RawsrButtonKind.secondary,
          onPressed: controller.toggleCropMode,
        ),
        const SizedBox(width: 6),
        RawsrButton(
          label: '判色',
          shortcut: 'L',
          kind: state.grayMode
              ? RawsrButtonKind.primary
              : RawsrButtonKind.secondary,
          onPressed: controller.toggleGrayMode,
        ),
        const SizedBox(width: 6),
        RawsrButton(
          label: '适合窗口',
          kind: RawsrButtonKind.secondary,
          onPressed: controller.resetView,
        ),
      ],
    );
  }
}

class _CanvasError extends StatelessWidget {
  const _CanvasError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.chrome1,
        border: Border.all(color: palette.danger),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: <Widget>[
            Icon(Icons.error_outline, color: palette.danger),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DecodedCanvas extends StatefulWidget {
  const _DecodedCanvas({
    required this.preview,
    required this.region,
    required this.regionRect,
    required this.transform,
    required this.crop,
  });

  final RgbaBytes? preview;
  final RgbaBytes? region;
  final Rect? regionRect;
  final ViewportTransform transform;
  final Rect? crop;

  @override
  State<_DecodedCanvas> createState() => _DecodedCanvasState();
}

class _DecodedCanvasState extends State<_DecodedCanvas> {
  RgbaBytes? _previewFrame;
  RgbaBytes? _regionFrame;
  ui.Image? _preview;
  ui.Image? _region;
  int _decodeGeneration = 0;

  @override
  void initState() {
    super.initState();
    _decodeFrames();
  }

  @override
  void didUpdateWidget(covariant _DecodedCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.preview, _previewFrame) ||
        !identical(widget.region, _regionFrame)) {
      _decodeFrames();
    }
  }

  Future<void> _decodeFrames() async {
    final generation = ++_decodeGeneration;
    final previewFrame = widget.preview;
    final regionFrame = widget.region;
    final preview = previewFrame == null ? null : await _decode(previewFrame);
    final region = regionFrame == null ? null : await _decode(regionFrame);
    if (!mounted || generation != _decodeGeneration) {
      preview?.dispose();
      region?.dispose();
      return;
    }
    _preview?.dispose();
    _region?.dispose();
    setState(() {
      _previewFrame = previewFrame;
      _regionFrame = regionFrame;
      _preview = preview;
      _region = region;
    });
  }

  Future<ui.Image> _decode(RgbaBytes frame) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(frame.bytes);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: frame.width,
      height: frame.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final result = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return result.image;
  }

  @override
  void dispose() {
    _preview?.dispose();
    _region?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ImagePainter(
        preview: _preview,
        region: _region,
        regionRect: widget.regionRect,
        transform: widget.transform,
        crop: widget.crop,
        palette: context.palette,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _ImagePainter extends CustomPainter {
  const _ImagePainter({
    required this.preview,
    required this.region,
    required this.regionRect,
    required this.transform,
    required this.crop,
    required this.palette,
  });

  final ui.Image? preview;
  final ui.Image? region;
  final Rect? regionRect;
  final ViewportTransform transform;
  final Rect? crop;
  final RawsrPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final preview = this.preview;
    if (preview != null) {
      canvas.drawImageRect(
        preview,
        Rect.fromLTWH(
          0,
          0,
          preview.width.toDouble(),
          preview.height.toDouble(),
        ),
        transform.imageRect,
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
    final region = this.region;
    final regionRect = this.regionRect;
    if (region != null && regionRect != null) {
      canvas.drawImageRect(
        region,
        Rect.fromLTWH(0, 0, region.width.toDouble(), region.height.toDouble()),
        transform.imageRectToViewport(regionRect),
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
    final crop = this.crop;
    if (crop != null) {
      final visibleCrop = transform.imageRectToViewport(crop);
      final outside = Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRect(visibleCrop),
      );
      canvas.drawPath(outside, Paint()..color = palette.safelightDim);
      canvas.drawRect(
        visibleCrop,
        Paint()
          ..color = palette.safelight
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      for (final handle in _handles(visibleCrop)) {
        canvas.drawRect(
          Rect.fromCenter(center: handle, width: 7, height: 7),
          Paint()..color = palette.safelight,
        );
      }
      final label = TextPainter(
        text: TextSpan(
          text: '${crop.width.round()} × ${crop.height.round()}',
          style: TextStyle(
            fontFamily: 'IBMPlexMono',
            fontSize: 11,
            color: palette.textHi,
            backgroundColor: palette.chrome1,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, visibleCrop.bottomLeft + const Offset(0, 6));
    }
  }

  List<Offset> _handles(Rect rect) {
    return <Offset>[
      rect.topLeft,
      rect.topCenter,
      rect.topRight,
      rect.centerLeft,
      rect.centerRight,
      rect.bottomLeft,
      rect.bottomCenter,
      rect.bottomRight,
    ];
  }

  @override
  bool shouldRepaint(covariant _ImagePainter oldDelegate) {
    return oldDelegate.preview != preview ||
        oldDelegate.region != region ||
        oldDelegate.regionRect != regionRect ||
        oldDelegate.transform.zoom != transform.zoom ||
        oldDelegate.transform.pan != transform.pan ||
        oldDelegate.transform.viewportSize != transform.viewportSize ||
        oldDelegate.crop != crop ||
        oldDelegate.palette != palette;
  }
}
