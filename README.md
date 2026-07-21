# rawsr

`rawsr` 是本地 GPU 加速的 RAW 降噪与超分工具，包含 Rust CLI/Core 和 Flutter 桌面 GUI。固定管线为：解码 → 显影 → 降噪 → 选区优先超分 → 调色 → 16-bit TIFF 导出。

实现依据与验收约束见：

- [后端任务书](docs/backend-task-v1.md)
- [Flutter 桌面前端任务书](docs/frontend-task-v1.md)

## 环境

- Rust stable（edition 2024）
- Flutter 3.x stable
- Windows 使用 DirectML → CPU；macOS 使用 CoreML → CPU；启用 `rawsr-core/cuda` feature 后可使用 CUDA
- 模型转换需要 Python 3.11+，依赖见 `scripts/requirements-models.txt`

## 构建与测试

```powershell
cargo build --workspace
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings

./scripts/setup-flutter-plugins.ps1
cd gui
flutter analyze
flutter test
flutter build windows
```

Flutter/Rust 桥锁定为 `flutter_rust_bridge 2.12.0`。重新生成绑定：

```powershell
just gen
```

## 生产模型

五个首发权重不会提交到 Git。下载、校验 SHA-256 并导出动态 H/W ONNX：

```powershell
python -m venv .venv
.\.venv\Scripts\python -m pip install -r scripts\requirements-models.txt
.\.venv\Scripts\python scripts\convert_models.py
```

生产模型冒烟（Windows DirectML）：

```powershell
.\scripts\smoke-models.ps1 -Device direct-ml
```

## CLI

```powershell
cargo build --release -p rawsr-cli

.\target\release\rawsr.exe photo.ARW --denoise scunet-gan -o denoised.tif
.\target\release\rawsr.exe photo.ARW --sr realesrgan-x4plus --crop 1200,800,2000,1500 -o crop-x4.tif
.\target\release\rawsr.exe --list-models --manifest models\manifest.json
```

输出为带 sRGB ICC 的 RGB16 TIFF；超分通过重叠 tile 和行带流式写出，不在内存中保存整幅 4x f32 图像。

## GUI

```powershell
just run-win
```

GUI 支持 RAW/JPEG/PNG/TIFF 导入、内嵌 RAW 缩略图、局部金字塔预览、可移动/缩放裁切框、分离的降噪与超分试片、基础调色、定片、导出队列、模型导入和实际 EP 节点统计。调色滑杆采用节流实时预览，松手、数值输入和归零会立即刷新；调色参数以同一份已应用快照贯穿主预览、局部预览、AI 试片和最终导出，并且调色刷新不会重新解码 RAW。降噪和超分试片每次选择一个模型，统一采用左侧基准、右侧处理结果的同步缩放 A/B 对比；超分左侧显示超分前输入，存在降噪定片时则显示固定降噪前级的结果。相同照片、范围和降噪模型再次生成时会复用受内存上限约束的中间缓存，ONNX Runtime 会话也会按模型与设备复用。未框选时最终导出仍可处理全图，而交互试片会自动选取受控的中央样本区域。

## Windows 发行版

首发仅提供 Windows x64 包。从 [Releases](https://github.com/Shinokawa/rawsr/releases) 下载 `RawSR-windows-x64-v0.1.0.zip`，解压后运行 `rawsr_gui.exe` 即可；压缩包内已包含首发模型。需要 Windows 10/11 与支持 DirectX 12 的显卡，无法使用 DirectML 时会自动回退 CPU。

## 真实 Sony ARW 验收

真实 RAW 测试通过环境变量传入，避免把大型照片提交进仓库：

```powershell
$env:RAWSR_TEST_ARW = 'E:\path\to\sample.ARW'
cargo test -p rawsr-core decode_real_arw -- --ignored --nocapture
.\scripts\smoke.ps1 -ArwPath $env:RAWSR_TEST_ARW

cd gui
flutter test integration_test/bridge_test.dart -d windows
```

本地开发夹具可记录在忽略提交的 `.rawsr/local-fixtures.toml`，示例见 `.rawsr/local-fixtures.example.toml`。

模型基准可用 `scripts/benchmark-models.ps1` 复现；已验证数据见 `BENCH.md`。
