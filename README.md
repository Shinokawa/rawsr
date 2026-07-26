# RawSR

RawSR 是一款在本机处理照片的 RAW 降噪与超分桌面工具。

## 下载

在 [Releases](https://github.com/Shinokawa/rawsr/releases/latest) 下载最新的 Windows 压缩包，完整解压后运行 `rawsr_gui.exe`。

不需要安装 Python、Rust 或其他运行环境。

## 使用

1. 将照片拖进窗口。
2. 在画面上框选需要检查的细节区域。
3. 生成试片，对比处理前后的效果。
4. 选定效果后导出整张照片，或只导出框选区域。

导出时默认使用 JPEG，适合日常保存、分享和打印。需要继续在其他后期软件中处理时，也可以选择 16 位 TIFF 母版；全图超分后的 TIFF 文件可能很大。

## 支持

- Windows 10 / 11
- Sony ARW 与常见 JPEG、PNG、TIFF 照片
- 本机 GPU 加速；无法使用时会自动以 CPU 处理

## 隐私

RawSR 在本机完成解码、处理和导出，不上传照片或 EXIF 信息。

## 反馈

遇到无法导入、导出失败或效果异常，请到 [Issues](https://github.com/Shinokawa/rawsr/issues) 描述相机型号、照片格式和错误提示。请不要上传包含隐私的原片。
