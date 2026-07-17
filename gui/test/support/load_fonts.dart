import 'package:flutter/services.dart';

Future<void> loadTestFonts() async {
  await (FontLoader('SourceHanSansSC')
        ..addFont(rootBundle.load('assets/fonts/SourceHanSansSC-Regular.otf'))
        ..addFont(rootBundle.load('assets/fonts/SourceHanSansSC-Medium.otf'))
        ..addFont(rootBundle.load('assets/fonts/SourceHanSansSC-Bold.otf')))
      .load();
  await (FontLoader('IBMPlexMono')
        ..addFont(rootBundle.load('assets/fonts/IBMPlexMono-Regular.ttf'))
        ..addFont(rootBundle.load('assets/fonts/IBMPlexMono-Medium.ttf')))
      .load();
}
