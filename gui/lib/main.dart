import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:rawsr_gui/src/app/rawsr_app.dart';
import 'package:rawsr_gui/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await localNotifier.setup(
    appName: 'RawSR',
    shortcutPolicy: ShortcutPolicy.requireCreate,
  );
  await RustLib.init();
  runApp(const ProviderScope(child: RawsrApp()));
}
