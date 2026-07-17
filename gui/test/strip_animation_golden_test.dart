import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rawsr_gui/src/features/test_strip/test_strip_view.dart';
import 'package:rawsr_gui/src/theme/rawsr_theme.dart';
import 'package:rawsr_gui/src/widgets/rgba_frame.dart';

import 'support/fake_backend.dart';

void main() {
  testWidgets('test strip reveal fixed frames', (tester) async {
    await _pump(tester, 0);
    await expectLater(
      find.byKey(const ValueKey<String>('strip-reveal')),
      matchesGoldenFile('goldens/windows/strip_reveal_0.png'),
    );
    await _pump(tester, 1);
    await expectLater(
      find.byKey(const ValueKey<String>('strip-reveal')),
      matchesGoldenFile('goldens/windows/strip_reveal_100.png'),
    );
  }, skip: !Platform.isWindows);
}

Future<void> _pump(WidgetTester tester, double progress) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildRawsrTheme(),
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: const ValueKey<String>('strip-reveal'),
            child: SizedBox(
              width: 240,
              height: 180,
              child: StripRevealFrame(
                progress: progress,
                zoom: 1,
                pan: Offset.zero,
                child: RgbaFrameView(
                  frame: FakeRawsrBackend.frame,
                  fit: BoxFit.fill,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
