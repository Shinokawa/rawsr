import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart' as bridge;

abstract class RawsrBackend {
  Future<bridge.ThumbData> extractThumb(String path);

  Future<bridge.ImageHandle> openImage({
    required String path,
    required double exposureEv,
    double? filmicContrast,
  });

  Future<bridge.RgbaBytes> renderPreview({
    required bridge.ImageHandle handle,
    required int maxEdge,
    required bridge.GradeParamsDto grade,
  });

  Future<bridge.RgbaBytes> renderRegion({
    required bridge.ImageHandle handle,
    required bridge.RegionRect rect,
    required int maxEdge,
    required bridge.GradeParamsDto grade,
  });

  Future<bool> closeImage(bridge.ImageHandle handle);

  Future<List<bridge.ModelEntry>> listModels();

  Stream<bridge.StripEvent> runTestStrip({
    required bridge.ImageHandle handle,
    required bridge.RegionRect rect,
    required List<String> models,
    required String? denoiseModel,
    required bridge.GradeParamsDto grade,
  });

  Stream<bridge.JobEvent> enqueueExport(bridge.ExportJob job);

  Future<bool> cancelJob(BigInt jobId);

  Future<bridge.ModelEntry> importModel(bridge.ImportModelRequest request);

  Future<bridge.RuntimeInfo> runtimeInfo();
}

class FfiRawsrBackend implements RawsrBackend {
  const FfiRawsrBackend();

  @override
  Future<bridge.ThumbData> extractThumb(String path) {
    return bridge.extractThumb(path: path);
  }

  @override
  Future<bridge.ImageHandle> openImage({
    required String path,
    required double exposureEv,
    double? filmicContrast,
  }) {
    return bridge.openImage(
      path: path,
      exposureEv: exposureEv,
      filmicContrast: filmicContrast,
    );
  }

  @override
  Future<bridge.RgbaBytes> renderPreview({
    required bridge.ImageHandle handle,
    required int maxEdge,
    required bridge.GradeParamsDto grade,
  }) {
    return bridge.renderPreview(handle: handle, maxEdge: maxEdge, grade: grade);
  }

  @override
  Future<bridge.RgbaBytes> renderRegion({
    required bridge.ImageHandle handle,
    required bridge.RegionRect rect,
    required int maxEdge,
    required bridge.GradeParamsDto grade,
  }) {
    return bridge.renderRegion(
      handle: handle,
      rect: rect,
      maxEdge: maxEdge,
      grade: grade,
    );
  }

  @override
  Future<bool> closeImage(bridge.ImageHandle handle) {
    return bridge.closeImage(handle: handle);
  }

  @override
  Future<List<bridge.ModelEntry>> listModels() => bridge.listModels();

  @override
  Stream<bridge.StripEvent> runTestStrip({
    required bridge.ImageHandle handle,
    required bridge.RegionRect rect,
    required List<String> models,
    required String? denoiseModel,
    required bridge.GradeParamsDto grade,
  }) {
    return bridge.runTestStrip(
      handle: handle,
      rect: rect,
      models: models,
      denoiseModel: denoiseModel,
      grade: grade,
    );
  }

  @override
  Stream<bridge.JobEvent> enqueueExport(bridge.ExportJob job) {
    return bridge.enqueueExport(job: job);
  }

  @override
  Future<bool> cancelJob(BigInt jobId) => bridge.cancelJob(jobId: jobId);

  @override
  Future<bridge.ModelEntry> importModel(bridge.ImportModelRequest request) {
    return bridge.importModel(request: request);
  }

  @override
  Future<bridge.RuntimeInfo> runtimeInfo() => bridge.runtimeInfo();
}

final rawsrBackendProvider = Provider<RawsrBackend>(
  (ref) => const FfiRawsrBackend(),
);
