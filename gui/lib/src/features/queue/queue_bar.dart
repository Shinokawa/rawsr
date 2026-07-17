import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/features/queue/queue_controller.dart';
import 'package:rawsr_gui/src/theme/rawsr_theme.dart';
import 'package:rawsr_gui/src/widgets/rawsr_button.dart';
import 'package:rawsr_gui/src/widgets/rawsr_controls.dart';

class QueueBar extends ConsumerWidget {
  const QueueBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(queueProvider);
    final palette = context.palette;
    final active = state.tasks
        .where((task) => task.status == ExportTaskStatus.running)
        .firstOrNull;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Material(
          color: palette.chrome1,
          child: InkWell(
            onTap: ref.read(queueProvider.notifier).toggleExpanded,
            child: Container(
              height: 42,
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: palette.line)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: <Widget>[
                  Icon(
                    state.expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 17,
                    color: palette.textLo,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '队列 · ${state.tasks.length} 个任务',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  if (active != null) ...<Widget>[
                    const SizedBox(width: 14),
                    SizedBox(
                      width: 180,
                      child: RawsrProgressBar(value: active.progress),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${(active.progress * 100).round()}%',
                      style: context.mono.copyWith(fontSize: 11),
                    ),
                  ],
                  const Spacer(),
                  Text(
                    state.tasks.isEmpty
                        ? '定片后可加入全图导出队列'
                        : _summary(state.tasks),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (state.expanded)
          Container(
            height: 210,
            color: palette.chrome0,
            child: state.tasks.isEmpty
                ? Center(
                    child: Text(
                      '队列为空',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(8),
                    itemCount: state.tasks.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 6),
                    itemBuilder: (context, index) =>
                        _TaskRow(task: state.tasks[index]),
                  ),
          ),
      ],
    );
  }

  static String _summary(List<ExportTask> tasks) {
    final completed = tasks
        .where((task) => task.status == ExportTaskStatus.completed)
        .length;
    final failed = tasks
        .where((task) => task.status == ExportTaskStatus.failed)
        .length;
    return '完成 $completed · 失败 $failed';
  }
}

class _TaskRow extends ConsumerWidget {
  const _TaskRow({required this.task});

  final ExportTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final terminal = <ExportTaskStatus>{
      ExportTaskStatus.completed,
      ExportTaskStatus.failed,
      ExportTaskStatus.cancelled,
    }.contains(task.status);
    final remaining = task.remaining;
    return Container(
      height: 74,
      decoration: BoxDecoration(
        color: palette.chrome1,
        border: Border.all(color: palette.line),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(8),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 72,
            child: task.thumbnail == null
                ? Icon(Icons.photo_outlined, color: palette.textLo)
                : ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.memory(task.thumbnail!, fit: BoxFit.cover),
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        task.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                    Text(
                      _statusLabel(task.status),
                      style: context.mono.copyWith(fontSize: 10),
                    ),
                  ],
                ),
                Text(
                  task.modelChain,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                if (task.status == ExportTaskStatus.failed)
                  Text(
                    '${task.message}：${task.reason ?? '未提供原因'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall!.copyWith(color: palette.danger),
                  )
                else
                  Row(
                    children: <Widget>[
                      Expanded(child: RawsrProgressBar(value: task.progress)),
                      const SizedBox(width: 8),
                      Text(
                        remaining == null
                            ? task.message
                            : '约 ${remaining.inSeconds}s',
                        style: context.mono.copyWith(
                          fontSize: 10,
                          color: palette.textLo,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (!terminal)
            RawsrButton(
              label: '取消',
              kind: RawsrButtonKind.text,
              onPressed: () =>
                  ref.read(queueProvider.notifier).cancel(task.localId),
            )
          else if (task.status == ExportTaskStatus.completed)
            RawsrButton(
              label: '在资源管理器中显示',
              kind: RawsrButtonKind.secondary,
              onPressed: () => ref
                  .read(queueProvider.notifier)
                  .revealOutput(task.job.outputPath),
            ),
        ],
      ),
    );
  }

  static String _statusLabel(ExportTaskStatus status) => switch (status) {
    ExportTaskStatus.queued => '排队',
    ExportTaskStatus.running => '运行',
    ExportTaskStatus.completed => '完成',
    ExportTaskStatus.failed => '失败',
    ExportTaskStatus.cancelled => '取消',
  };
}
