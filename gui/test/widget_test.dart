import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/app/rawsr_app.dart';

void main() {
  testWidgets('empty workspace gives an import action', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: RawsrApp()));
    expect(find.text('拖入 RAW 或 JPEG 开始'), findsNWidgets(2));
    expect(find.text('导入照片'), findsOneWidget);
    expect(find.text('队列 · 0 个任务'), findsOneWidget);
  });
}
