# rawsr GUI

rawsr 的 Windows/macOS Flutter 桌面端。界面使用暗房灯箱设计，通过 `flutter_rust_bridge 2.12.0` 调用 `rawsr-core` 的真实 RAW 解码、预览、模型推理和 TIFF 导出实现。

Windows 开发：

```powershell
cd ..
.\scripts\setup-flutter-plugins.ps1
just gen
just run-win
```

验收：

```powershell
cd gui
flutter analyze
flutter test

$env:RAWSR_TEST_ARW = 'E:\path\to\sony.ARW'
flutter test integration_test/bridge_test.dart -d windows
flutter build windows
```

`integration_test/bridge_test.dart` 会通过原生桥读取真实 Sony ARW 的内嵌 JPEG，打开完整 RAW，并验证 512px 预览与局部区域渲染。
