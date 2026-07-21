import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:rawsr_gui/src/backend/rawsr_backend.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';

class FakeRawsrBackend implements RawsrBackend {
  FakeRawsrBackend({
    this.stripCompletionOrder = const <String>[],
    this.exportStates = const <String>['queued', 'running', 'completed'],
    this.stripCacheHit = false,
    this.previewError,
  });

  final List<String> stripCompletionOrder;
  final List<String> exportStates;
  final bool stripCacheHit;
  Object? previewError;
  final List<ModelEntry> importedModels = <ModelEntry>[];
  int renderPreviewCalls = 0;
  int renderRegionCalls = 0;
  int openCalls = 0;
  ExportJob? lastExportJob;
  GradeParamsDto? lastPreviewGrade;
  GradeParamsDto? lastRegionGrade;
  GradeParamsDto? lastStripGrade;
  RegionRect? lastStripRect;
  String? lastStripDenoiseModel;
  List<String>? lastStripModels;
  BigInt _nextHandle = BigInt.one;

  static RgbaBytes get frame => RgbaBytes(
    bytes: Uint8List.fromList(<int>[
      230,
      149,
      59,
      255,
      64,
      64,
      64,
      255,
      96,
      96,
      96,
      255,
      230,
      230,
      230,
      255,
    ]),
    width: 2,
    height: 2,
  );

  @override
  Future<bool> cancelJob(BigInt jobId) async => true;

  @override
  Future<bool> closeImage(ImageHandle handle) async => true;

  @override
  Stream<JobEvent> enqueueExport(ExportJob job) async* {
    lastExportJob = job;
    for (var index = 0; index < exportStates.length; index++) {
      final state = exportStates[index];
      yield JobEvent(
        jobId: BigInt.one,
        state: state,
        progress: exportStates.length == 1
            ? 1
            : index / (exportStates.length - 1),
        message: switch (state) {
          'queued' => '已加入队列',
          'running' => '正在导出',
          'completed' => '导出完成',
          'failed' => '导出失败',
          'cancelled' => '任务已取消',
          _ => state,
        },
        outputPath: state == 'completed' ? job.outputPath : null,
        reason: state == 'failed' ? '模型算子不受支持' : null,
      );
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  Future<ThumbData> extractThumb(String path) async {
    return ThumbData(
      jpeg: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
      width: 1616,
      height: 1080,
      exif: const ExifData(
        make: 'Sony',
        model: 'ILCE-7RM2',
        lensModel: 'FE 35mm F1.4 GM',
        iso: 100,
        exposureSeconds: 0.008,
        aperture: 2.8,
        focalLengthMm: 35,
        capturedAt: '2026:07:17 03:00:00',
        orientation: 1,
      ),
    );
  }

  @override
  Future<ModelEntry> importModel(ImportModelRequest request) async {
    final entry = ModelEntry(
      name: request.name,
      file: '${request.name}.onnx',
      scale: request.scale,
      kind: request.kind,
      tile: request.tile,
      overlap: request.overlap,
      channelOrder: request.channelOrder,
      inputRange: request.inputRange,
      notes: request.notes,
      installed: true,
      fileSizeBytes: BigInt.from(1024 * 1024),
    );
    importedModels.add(entry);
    return entry;
  }

  @override
  Future<List<ModelEntry>> listModels() async {
    return <ModelEntry>[
      ModelEntry(
        name: 'denoise-a',
        file: 'denoise-a.onnx',
        scale: 1,
        kind: 'denoise',
        tile: 256,
        overlap: 32,
        channelOrder: 'RGB',
        inputRange: 'zero_to_one',
        notes: 'Denoiser',
        installed: true,
        fileSizeBytes: BigInt.from(4 * 1024 * 1024),
      ),
      ModelEntry(
        name: 'sr-b',
        file: 'sr-b.onnx',
        scale: 4,
        kind: 'sr',
        tile: 256,
        overlap: 32,
        channelOrder: 'RGB',
        inputRange: 'zero_to_one',
        notes: 'Super resolution',
        installed: true,
        fileSizeBytes: BigInt.from(8 * 1024 * 1024),
      ),
      ModelEntry(
        name: 'sr-c',
        file: 'sr-c.onnx',
        scale: 4,
        kind: 'sr',
        tile: 256,
        overlap: 32,
        channelOrder: 'RGB',
        inputRange: 'zero_to_one',
        notes: 'Super resolution',
        installed: true,
        fileSizeBytes: BigInt.from(12 * 1024 * 1024),
      ),
      ...importedModels,
    ];
  }

  @override
  Future<ImageHandle> openImage({
    required String path,
    required double exposureEv,
    double? filmicContrast,
  }) async {
    openCalls++;
    final id = _nextHandle;
    _nextHandle += BigInt.one;
    return ImageHandle(id: id, width: 8000, height: 5320);
  }

  @override
  Future<RgbaBytes> renderPreview({
    required ImageHandle handle,
    required int maxEdge,
    required GradeParamsDto grade,
  }) async {
    renderPreviewCalls++;
    lastPreviewGrade = grade;
    final error = previewError;
    if (error != null) throw error;
    return frame;
  }

  @override
  Future<RgbaBytes> renderRegion({
    required ImageHandle handle,
    required RegionRect rect,
    required int maxEdge,
    required GradeParamsDto grade,
  }) async {
    renderRegionCalls++;
    lastRegionGrade = grade;
    return frame;
  }

  @override
  Stream<StripEvent> runTestStrip({
    required ImageHandle handle,
    required RegionRect rect,
    required List<String> models,
    required String? denoiseModel,
    required GradeParamsDto grade,
  }) async* {
    lastStripRect = rect;
    lastStripDenoiseModel = denoiseModel;
    lastStripModels = List<String>.of(models);
    lastStripGrade = grade;
    if (denoiseModel != null) {
      for (final model in models) {
        yield StripEvent(
          model: model,
          isReference: false,
          state: stripCacheHit ? 'cached' : 'preparing',
          progress: stripCacheHit ? 0.5 : 0.25,
          elapsedMs: BigInt.from(3),
        );
      }
    }
    yield StripEvent(
      model: 'reference',
      isReference: true,
      state: 'completed',
      progress: 1,
      elapsedMs: BigInt.zero,
      image: frame,
    );
    final order = stripCompletionOrder.isEmpty ? models : stripCompletionOrder;
    for (final model in order) {
      yield StripEvent(
        model: model,
        isReference: false,
        state: 'running',
        progress: denoiseModel == null ? 0.5 : 0.75,
        elapsedMs: BigInt.from(5),
      );
      await Future<void>.delayed(Duration.zero);
      yield StripEvent(
        model: model,
        isReference: false,
        state: 'completed',
        progress: 1,
        elapsedMs: BigInt.from(10 + order.indexOf(model)),
        image: frame,
      );
    }
  }

  @override
  Future<RuntimeInfo> runtimeInfo() async {
    return const RuntimeInfo(
      platform: 'windows',
      compiledProviders: <String>[
        'DmlExecutionProvider',
        'CPUExecutionProvider',
      ],
      lastAllocations: <ProviderAllocation>[
        ProviderAllocation(provider: 'DmlExecutionProvider', nodeCount: 42),
      ],
      preferredDevice: 'DirectML → CPU',
    );
  }
}
