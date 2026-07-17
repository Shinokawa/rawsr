import 'package:flutter/material.dart';

@immutable
class RawsrPalette extends ThemeExtension<RawsrPalette> {
  const RawsrPalette({
    required this.chrome0,
    required this.chrome1,
    required this.chrome2,
    required this.line,
    required this.textHi,
    required this.textLo,
    required this.canvas,
    required this.canvasGray,
    required this.safelight,
    required this.safelightDim,
    required this.danger,
    required this.transparent,
  });

  static const dark = RawsrPalette(
    chrome0: Color(0xff161616),
    chrome1: Color(0xff1f1f1f),
    chrome2: Color(0xff2a2a2a),
    line: Color(0xff383838),
    textHi: Color(0xffe6e6e6),
    textLo: Color(0xff9a9a9a),
    canvas: Color(0xff202020),
    canvasGray: Color(0xff808080),
    safelight: Color(0xffe5953b),
    safelightDim: Color(0x3de5953b),
    danger: Color(0xffc4574e),
    transparent: Color(0x00000000),
  );

  final Color chrome0;
  final Color chrome1;
  final Color chrome2;
  final Color line;
  final Color textHi;
  final Color textLo;
  final Color canvas;
  final Color canvasGray;
  final Color safelight;
  final Color safelightDim;
  final Color danger;
  final Color transparent;

  @override
  RawsrPalette copyWith({
    Color? chrome0,
    Color? chrome1,
    Color? chrome2,
    Color? line,
    Color? textHi,
    Color? textLo,
    Color? canvas,
    Color? canvasGray,
    Color? safelight,
    Color? safelightDim,
    Color? danger,
    Color? transparent,
  }) {
    return RawsrPalette(
      chrome0: chrome0 ?? this.chrome0,
      chrome1: chrome1 ?? this.chrome1,
      chrome2: chrome2 ?? this.chrome2,
      line: line ?? this.line,
      textHi: textHi ?? this.textHi,
      textLo: textLo ?? this.textLo,
      canvas: canvas ?? this.canvas,
      canvasGray: canvasGray ?? this.canvasGray,
      safelight: safelight ?? this.safelight,
      safelightDim: safelightDim ?? this.safelightDim,
      danger: danger ?? this.danger,
      transparent: transparent ?? this.transparent,
    );
  }

  @override
  RawsrPalette lerp(covariant RawsrPalette? other, double t) {
    if (other == null) return this;
    return RawsrPalette(
      chrome0: Color.lerp(chrome0, other.chrome0, t)!,
      chrome1: Color.lerp(chrome1, other.chrome1, t)!,
      chrome2: Color.lerp(chrome2, other.chrome2, t)!,
      line: Color.lerp(line, other.line, t)!,
      textHi: Color.lerp(textHi, other.textHi, t)!,
      textLo: Color.lerp(textLo, other.textLo, t)!,
      canvas: Color.lerp(canvas, other.canvas, t)!,
      canvasGray: Color.lerp(canvasGray, other.canvasGray, t)!,
      safelight: Color.lerp(safelight, other.safelight, t)!,
      safelightDim: Color.lerp(safelightDim, other.safelightDim, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      transparent: Color.lerp(transparent, other.transparent, t)!,
    );
  }
}

extension RawsrThemeContext on BuildContext {
  RawsrPalette get palette => Theme.of(this).extension<RawsrPalette>()!;

  TextStyle get mono => Theme.of(this).textTheme.bodyMedium!.copyWith(
    fontFamily: 'IBMPlexMono',
    fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
  );
}

ThemeData buildRawsrTheme() {
  const palette = RawsrPalette.dark;
  final baseText = TextStyle(
    fontFamily: 'SourceHanSansSC',
    fontSize: 13,
    height: 1.5,
    color: palette.textHi,
  );
  final textTheme = TextTheme(
    bodyLarge: baseText,
    bodyMedium: baseText,
    bodySmall: TextStyle(
      fontFamily: 'SourceHanSansSC',
      fontSize: 11,
      height: 1.5,
      color: palette.textLo,
    ),
    labelLarge: TextStyle(
      fontFamily: 'SourceHanSansSC',
      fontSize: 13,
      fontWeight: FontWeight.w500,
      height: 1.5,
      color: palette.textHi,
    ),
    labelSmall: TextStyle(
      fontFamily: 'SourceHanSansSC',
      fontSize: 11,
      height: 1.5,
      color: palette.textLo,
    ),
    titleSmall: TextStyle(
      fontFamily: 'SourceHanSansSC',
      fontSize: 13,
      fontWeight: FontWeight.w700,
      height: 1.5,
      color: palette.textHi,
    ),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: palette.chrome0,
    canvasColor: palette.chrome0,
    dividerColor: palette.line,
    splashColor: palette.safelightDim,
    highlightColor: palette.safelightDim,
    focusColor: palette.safelightDim,
    colorScheme: ColorScheme.dark(
      primary: palette.safelight,
      onPrimary: palette.chrome0,
      secondary: palette.safelight,
      onSecondary: palette.chrome0,
      error: palette.danger,
      onError: palette.textHi,
      surface: palette.chrome1,
      onSurface: palette.textHi,
      outline: palette.line,
    ),
    textTheme: textTheme,
    iconTheme: IconThemeData(color: palette.textLo, size: 18),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: palette.chrome2,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: palette.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: palette.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: palette.safelight),
      ),
      labelStyle: textTheme.labelSmall,
      hintStyle: textTheme.bodySmall,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: palette.safelight,
      inactiveTrackColor: palette.line,
      thumbColor: palette.safelight,
      overlayColor: palette.safelightDim,
      trackHeight: 2,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: palette.chrome2,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.line),
      ),
      textStyle: textTheme.bodySmall,
    ),
    extensions: <ThemeExtension<dynamic>>[palette],
  );
}
