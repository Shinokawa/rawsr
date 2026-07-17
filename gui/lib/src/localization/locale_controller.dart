import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class LocaleController extends StateNotifier<Locale> {
  LocaleController() : super(const Locale('zh'));

  void setLanguage(String languageCode) {
    if (languageCode == 'zh' || languageCode == 'en') {
      state = Locale(languageCode);
    }
  }
}

final localeProvider = StateNotifierProvider<LocaleController, Locale>(
  (ref) => LocaleController(),
);
