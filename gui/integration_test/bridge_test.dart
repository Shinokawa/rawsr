import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rawsr_gui/src/rust/api/simple.dart';
import 'package:rawsr_gui/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(RustLib.init);

  testWidgets('extracts a real Sony ARW embedded thumbnail', (tester) async {
    final path = Platform.environment['RAWSR_TEST_ARW'];
    expect(path, isNotNull, reason: 'RAWSR_TEST_ARW must point to a Sony ARW');
    expect(File(path!).existsSync(), isTrue);

    final thumbnail = await extractThumb(path: path);

    expect(thumbnail.jpeg, isNotEmpty);
    expect(thumbnail.jpeg.take(2), orderedEquals(<int>[0xff, 0xd8]));
    expect(thumbnail.width, greaterThan(100));
    expect(thumbnail.height, greaterThan(100));
    expect(thumbnail.exif.make, 'Sony');
    expect(thumbnail.exif.model, 'ILCE-7RM2');
  });

  testWidgets('opens the Sony ARW and renders preview pyramid levels', (
    tester,
  ) async {
    final path = Platform.environment['RAWSR_TEST_ARW'];
    expect(path, isNotNull, reason: 'RAWSR_TEST_ARW must point to a Sony ARW');
    final handle = await openImage(path: path!, exposureEv: 0);
    addTearDown(() => closeImage(handle: handle));

    expect(handle.width, 7968);
    expect(handle.height, 5320);
    final preview = await renderPreview(handle: handle, maxEdge: 512);
    expect(preview.width, 512);
    expect(preview.height, greaterThan(300));
    expect(preview.bytes.length, preview.width * preview.height * 4);

    final region = await renderRegion(
      handle: handle,
      rect: const RegionRect(x: 3600, y: 2400, width: 512, height: 512),
      maxEdge: 512,
    );
    expect(region.width, 512);
    expect(region.height, 512);
    expect(region.bytes.length, 512 * 512 * 4);
  });
}
