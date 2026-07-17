import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:rawsr_gui/src/backend/rawsr_backend.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';

enum ExportTaskStatus { queued, running, completed, failed, cancelled }

class ExportTask {
  const ExportTask({
    required this.localId,
    required this.job,
    required this.label,
    required this.modelChain,
    required this.startedAt,
    this.thumbnail,
    this.jobId,
    this.status = ExportTaskStatus.queued,
    this.progress = 0,
    this.message = '已加入队列',
    this.reason,
  });

  final int localId;
  final ExportJob job;
  final String label;
  final String modelChain;
  final DateTime startedAt;
  final Uint8List? thumbnail;
  final BigInt? jobId;
  final ExportTaskStatus status;
  final double progress;
  final String message;
  final String? reason;

  ExportTask copyWith({
    BigInt? jobId,
    ExportTaskStatus? status,
    double? progress,
    String? message,
    String? reason,
  }) {
    return ExportTask(
      localId: localId,
      job: job,
      label: label,
      modelChain: modelChain,
      startedAt: startedAt,
      thumbnail: thumbnail,
      jobId: jobId ?? this.jobId,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      message: message ?? this.message,
      reason: reason ?? this.reason,
    );
  }

  Duration? get remaining {
    if (status != ExportTaskStatus.running || progress <= 0 || progress >= 1) {
      return null;
    }
    final elapsed = DateTime.now().difference(startedAt);
    final totalMs = elapsed.inMilliseconds / progress;
    return Duration(
      milliseconds: (totalMs - elapsed.inMilliseconds).round().clamp(
        0,
        1 << 31,
      ),
    );
  }
}

class QueueState {
  const QueueState({this.tasks = const <ExportTask>[], this.expanded = false});

  final List<ExportTask> tasks;
  final bool expanded;

  QueueState copyWith({List<ExportTask>? tasks, bool? expanded}) {
    return QueueState(
      tasks: tasks ?? this.tasks,
      expanded: expanded ?? this.expanded,
    );
  }
}

class QueueController extends StateNotifier<QueueState> {
  QueueController(this._backend) : super(const QueueState());

  final RawsrBackend _backend;
  final Map<int, StreamSubscription<JobEvent>> _subscriptions =
      <int, StreamSubscription<JobEvent>>{};
  int _nextLocalId = 1;

  void toggleExpanded() => state = state.copyWith(expanded: !state.expanded);

  Future<void> enqueue({
    required ExportJob job,
    required String label,
    required String modelChain,
    Uint8List? thumbnail,
  }) async {
    final localId = _nextLocalId++;
    final task = ExportTask(
      localId: localId,
      job: job,
      label: label,
      modelChain: modelChain,
      startedAt: DateTime.now(),
      thumbnail: thumbnail,
    );
    state = state.copyWith(tasks: <ExportTask>[...state.tasks, task]);
    final subscription = _backend
        .enqueueExport(job)
        .listen(
          (event) => _onEvent(localId, event),
          onError: (Object error, StackTrace stackTrace) {
            _update(
              localId,
              (value) => value.copyWith(
                status: ExportTaskStatus.failed,
                message: '导出流中断',
                reason: '$error',
              ),
            );
          },
        );
    _subscriptions[localId] = subscription;
  }

  Future<void> cancel(int localId) async {
    final task = state.tasks
        .where((value) => value.localId == localId)
        .firstOrNull;
    if (task == null) return;
    final jobId = task.jobId;
    if (jobId == null) {
      _update(
        localId,
        (value) => value.copyWith(
          status: ExportTaskStatus.cancelled,
          message: '任务已取消',
        ),
      );
      return;
    }
    await _backend.cancelJob(jobId);
  }

  Future<void> revealOutput(String path) async {
    if (Platform.isWindows) {
      await Process.run('explorer.exe', <String>['/select,', path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', <String>['-R', path]);
    }
  }

  void _onEvent(int localId, JobEvent event) {
    final status = switch (event.state) {
      'queued' => ExportTaskStatus.queued,
      'running' => ExportTaskStatus.running,
      'completed' => ExportTaskStatus.completed,
      'failed' => ExportTaskStatus.failed,
      'cancelled' => ExportTaskStatus.cancelled,
      _ => ExportTaskStatus.running,
    };
    _update(
      localId,
      (value) => value.copyWith(
        jobId: event.jobId,
        status: status,
        progress: event.progress,
        message: event.message,
        reason: event.reason,
      ),
    );
    if (status == ExportTaskStatus.completed) {
      unawaited(_notifyCompleted(event.outputPath));
    }
    if (<ExportTaskStatus>{
      ExportTaskStatus.completed,
      ExportTaskStatus.failed,
      ExportTaskStatus.cancelled,
    }.contains(status)) {
      _subscriptions.remove(localId)?.cancel();
    }
  }

  Future<void> _notifyCompleted(String? outputPath) async {
    try {
      await LocalNotification(
        title: 'RawSR 导出完成',
        body: outputPath ?? '照片已完成冲洗。',
      ).show();
    } catch (_) {
      // Export completion must not be downgraded when the OS notification
      // service is unavailable (for example during widget tests).
    }
  }

  void _update(int localId, ExportTask Function(ExportTask value) update) {
    state = state.copyWith(
      tasks: <ExportTask>[
        for (final task in state.tasks)
          if (task.localId == localId) update(task) else task,
      ],
    );
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions.values) {
      subscription.cancel();
    }
    super.dispose();
  }
}

final queueProvider = StateNotifierProvider<QueueController, QueueState>((ref) {
  return QueueController(ref.watch(rawsrBackendProvider));
});
