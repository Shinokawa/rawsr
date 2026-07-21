import 'package:rawsr_gui/src/features/library/library_controller.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';

const identityGradeParams = GradeParamsDto(
  contrast: 0,
  highlights: 0,
  shadows: 0,
  whites: 0,
  blacks: 0,
  vibrance: 0,
  saturation: 0,
);

GradeParamsDto gradeParamsFromSettings(GradeSettings settings) {
  return GradeParamsDto(
    contrast: _normalize(settings.contrast),
    highlights: _normalize(settings.highlights),
    shadows: _normalize(settings.shadows),
    whites: _normalize(settings.whites),
    blacks: _normalize(settings.blacks),
    vibrance: _normalize(settings.vibrance),
    saturation: _normalize(settings.saturation),
  );
}

double _normalize(double value) {
  if (!value.isFinite) return 0;
  return (value / 100).clamp(-1, 1).toDouble();
}
