import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rawsr_gui/src/theme/rawsr_theme.dart';
import 'package:rawsr_gui/src/widgets/rawsr_button.dart';
import 'package:rawsr_gui/src/widgets/rawsr_controls.dart';
import 'package:rawsr_gui/src/widgets/rawsr_panel.dart';

void main() {
  final windowsOnly = !Platform.isWindows;

  setUpAll(() async {
    await (FontLoader('SourceHanSansSC')
          ..addFont(rootBundle.load('assets/fonts/SourceHanSansSC-Regular.otf'))
          ..addFont(rootBundle.load('assets/fonts/SourceHanSansSC-Medium.otf'))
          ..addFont(rootBundle.load('assets/fonts/SourceHanSansSC-Bold.otf')))
        .load();
    await (FontLoader('IBMPlexMono')
          ..addFont(rootBundle.load('assets/fonts/IBMPlexMono-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/IBMPlexMono-Medium.ttf')))
        .load();
  });

  testWidgets('button variants golden', (tester) async {
    await _pump(
      tester,
      Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          RawsrButton(label: '主按钮', onPressed: () {}),
          const SizedBox(width: 8),
          RawsrButton(
            label: '次按钮',
            kind: RawsrButtonKind.secondary,
            onPressed: () {},
          ),
          const SizedBox(width: 8),
          RawsrButton(
            label: '文字按钮',
            kind: RawsrButtonKind.text,
            onPressed: () {},
          ),
        ],
      ),
    );
    await expectLater(
      find.byKey(_surfaceKey),
      matchesGoldenFile('goldens/windows/buttons.png'),
    );
  }, skip: windowsOnly);

  testWidgets('text input golden', (tester) async {
    final controller = TextEditingController(text: 'A7R II');
    addTearDown(controller.dispose);
    await _pump(
      tester,
      SizedBox(
        width: 280,
        child: RawsrTextInput(controller: controller, label: '相机'),
      ),
    );
    await expectLater(
      find.byKey(_surfaceKey),
      matchesGoldenFile('goldens/windows/input.png'),
    );
  }, skip: windowsOnly);

  testWidgets('slider golden', (tester) async {
    await _pump(
      tester,
      SizedBox(
        width: 320,
        child: RawsrSlider(
          label: '曝光 EV',
          value: 0.75,
          min: -4,
          max: 4,
          onChanged: (_) {},
          displayValue: '+0.75',
        ),
      ),
    );
    await expectLater(
      find.byKey(_surfaceKey),
      matchesGoldenFile('goldens/windows/slider.png'),
    );
  }, skip: windowsOnly);

  testWidgets('panel and divider golden', (tester) async {
    await _pump(
      tester,
      const SizedBox(
        width: 320,
        child: RawsrPanel(
          title: '面板标题',
          child: Column(
            children: <Widget>[
              Text('第一项'),
              SizedBox(height: 8),
              RawsrDivider(),
              SizedBox(height: 8),
              Text('第二项'),
            ],
          ),
        ),
      ),
    );
    await expectLater(
      find.byKey(_surfaceKey),
      matchesGoldenFile('goldens/windows/panel.png'),
    );
  }, skip: windowsOnly);

  testWidgets('badge golden', (tester) async {
    await _pump(
      tester,
      const Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          RawsrBadge(label: '未选择'),
          SizedBox(width: 8),
          RawsrBadge(label: '已定片', selected: true),
        ],
      ),
    );
    await expectLater(
      find.byKey(_surfaceKey),
      matchesGoldenFile('goldens/windows/badge.png'),
    );
  }, skip: windowsOnly);

  testWidgets('progress golden', (tester) async {
    await _pump(
      tester,
      const SizedBox(
        width: 320,
        child: RawsrProgressBar(value: 0.62, label: '正在冲洗 62%'),
      ),
    );
    await expectLater(
      find.byKey(_surfaceKey),
      matchesGoldenFile('goldens/windows/progress.png'),
    );
  }, skip: windowsOnly);

  testWidgets('shortcut hint golden', (tester) async {
    await _pump(tester, const RawsrShortcutHint('Ctrl Enter'));
    await expectLater(
      find.byKey(_surfaceKey),
      matchesGoldenFile('goldens/windows/shortcut.png'),
    );
  }, skip: windowsOnly);
}

const _surfaceKey = ValueKey<String>('golden-surface');

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildRawsrTheme(),
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: _surfaceKey,
            child: Padding(padding: const EdgeInsets.all(20), child: child),
          ),
        ),
      ),
    ),
  );
}
