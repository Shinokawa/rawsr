import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rawsr_gui/src/backend/rawsr_backend.dart';
import 'package:rawsr_gui/src/features/canvas/canvas_controller.dart';
import 'package:rawsr_gui/src/features/canvas/image_canvas.dart';
import 'package:rawsr_gui/src/features/library/library_controller.dart';
import 'package:rawsr_gui/src/theme/rawsr_theme.dart';

import 'support/fake_backend.dart';

void main() {
  testWidgets('zoomed image paint is clipped before the filmstrip', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fake = FakeRawsrBackend();

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[rawsrBackendProvider.overrideWithValue(fake)],
        child: MaterialApp(
          theme: buildRawsrTheme(),
          home: Scaffold(
            body: const Row(
              children: <Widget>[
                SizedBox(
                  width: 100,
                  child: ColoredBox(color: Color(0xFF123456)),
                ),
                Expanded(child: ImageCanvas()),
              ],
            ),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ImageCanvas)),
    );
    await container
        .read(canvasProvider.notifier)
        .open(
          const LibraryItem(
            path: r'C:\照片\样片.ARW',
            name: '样片.ARW',
            loading: false,
          ),
        );
    container.read(canvasProvider.notifier).setView(zoom: 4, pan: Offset.zero);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final clipFinder = find.byKey(const ValueKey<String>('canvas-paint-clip'));
    expect(clipFinder, findsOneWidget);
    expect(
      find.descendant(of: clipFinder, matching: find.byType(CustomPaint)),
      findsOneWidget,
    );
    final clip = tester.renderObject<RenderClipRect>(clipFinder);
    expect(clip.clipBehavior, Clip.hardEdge);
    expect(clip.size, const Size(300, 300));
    expect(tester.getTopLeft(clipFinder), const Offset(100, 0));
  });
}
