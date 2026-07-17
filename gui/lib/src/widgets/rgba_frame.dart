import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';

class RgbaFrameView extends StatefulWidget {
  const RgbaFrameView({
    required this.frame,
    this.fit = BoxFit.contain,
    this.filterQuality = FilterQuality.medium,
    super.key,
  });

  final RgbaBytes frame;
  final BoxFit fit;
  final FilterQuality filterQuality;

  @override
  State<RgbaFrameView> createState() => _RgbaFrameViewState();
}

class _RgbaFrameViewState extends State<RgbaFrameView> {
  ui.Image? _image;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(covariant RgbaFrameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.frame, oldWidget.frame)) _decode();
  }

  Future<void> _decode() async {
    final generation = ++_generation;
    final frame = widget.frame;
    final buffer = await ui.ImmutableBuffer.fromUint8List(frame.bytes);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: frame.width,
      height: frame.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final decoded = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    if (!mounted || generation != _generation) {
      decoded.image.dispose();
      return;
    }
    _image?.dispose();
    setState(() => _image = decoded.image);
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return const SizedBox.expand();
    return RawImage(
      image: image,
      fit: widget.fit,
      filterQuality: widget.filterQuality,
    );
  }
}
