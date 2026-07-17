# rawsr — RAW 降噪/超分 CLI 核心 · Agent 任务书 v1

> 适用对象:Claude Fable / GPT-5.6-sol 等编码 agent。
> 范围:M0/M1(CLI 全链路 + 模型 manifest)。GUI 不在本任务书内。
> 执行纪律:**一个任务一个会话**;每个任务结束必须跑通该任务的验收命令并贴出输出;不得顺手修改其他任务的接口。

---

## 0. 产品一句话

本地 GPU 加速的 RAW 修复工具:解码 → 显影 → 降噪 → (裁切区域)超分 → 16-bit TIFF 导出。
核心工作流是**裁切优先**:降噪面向全图,超分默认作用于选区(救裁切),全图超分是显式的第二选项。

## 1. 钉死的技术决策(agent 不得更改)

| 项 | 决定 | 理由 |
|---|---|---|
| 语言 | Rust (stable, edition 2024) | 复用已有工程经验 |
| RAW 解码 | `rawler` crate | 纯 Rust,无 C++ 构建负担;ARW 支持完整 |
| 去马赛克 | 自实现 Malvar-He-Cutler (2004) | 论文有完整伪代码,质量够 v1 |
| 普通图片解码 | `image` crate (JPEG/PNG/TIFF 输入) | 低像素放大场景的输入多为 JPEG |
| 推理 | `ort` crate (ONNX Runtime v2 API) | 社区模型转 ONNX 成本最低 |
| EP 顺序 | macOS: CoreML→CPU;Windows: CUDA→DirectML→CPU;Linux: CUDA→CPU | 必须打日志显示实际生效的 EP |
| 导出 | `tiff` crate,16-bit,内嵌 sRGB ICC;预估 >4GB 时用 BigTIFF | |
| CLI | `clap` (derive) + `indicatif` 进度条 | |
| 工作色域 | 解码后 linear RGB f32 (0–1);降噪在 linear 域;超分输入输出 sRGB f32 | 见 §5 坑清单 |

## 2. 仓库结构

```
rawsr/
  Cargo.toml            # workspace
  crates/
    rawsr-core/         # lib:decode / develop / denoise / sr / tile / export
      src/
        decode.rs       # rawler + demosaic;image crate 旁路
        develop.rs      # WB、曝光、base curve、linear→sRGB
        infer.rs        # Restorer trait + ort 实现
        tile.rs         # 切块、overlap 混合、流式组装
        export.rs       # TIFF/BigTIFF 写出
        manifest.rs     # 模型清单解析
    rawsr-cli/          # bin
  models/
    manifest.json
    *.onnx              # 不入 git,提供下载/转换脚本
  scripts/
    convert_models.py   # PyTorch→ONNX (spandrel + torch.onnx.export)
    smoke.sh            # 端到端冒烟
  assets/test/
    sample.ARW          # 一张 A7R II 原片(裁剪过的小 ARW 或 rawler 自带测试文件)
    sample.jpg
    tiny_sr_x2.onnx     # ≤5MB 的极小 SR 模型,供单元测试
```

## 3. 核心接口(先定义,后实现)

```rust
// decode.rs
pub struct LinearImage { pub data: Vec<f32>, pub w: usize, pub h: usize } // RGB packed, 0..1, linear
pub fn decode_raw(path: &Path) -> Result<(LinearImage, RawMeta)>;
pub fn decode_std(path: &Path) -> Result<LinearImage>;   // JPEG/PNG/TIFF → 反 gamma 回 linear

// develop.rs
pub struct DevelopParams { pub wb: WhiteBalance, pub exposure_ev: f32, pub curve: BaseCurve }
pub fn develop(img: &LinearImage, p: &DevelopParams) -> SrgbImage; // f32 sRGB 0..1

// infer.rs
pub trait Restorer {
    fn scale(&self) -> u32;                      // 1 = 降噪, 2/4 = 超分
    fn tile_hint(&self) -> TileHint;             // 建议 tile 尺寸与 overlap
    fn run(&self, tile: &SrgbTile) -> Result<SrgbTile>;
}
pub fn load_model(entry: &ManifestEntry, device: DevicePref) -> Result<Box<dyn Restorer>>;

// tile.rs
pub fn process_tiled(img: &SrgbImage, r: &dyn Restorer, crop: Option<Rect>,
                     sink: &mut dyn RowBandSink, progress: &dyn Fn(f32)) -> Result<()>;
```

`RowBandSink`:超分输出**不允许**整幅驻留 f32(42MP×4x×3ch×4B ≈ 8GB)。tile 按行带(row band)组装,一个行带完成即量化为 u16 写入 TIFF,然后释放。

## 4. 任务分解(按顺序执行)

### T0 · 脚手架(半天)
workspace + CI(`cargo fmt --check`、`clippy -D warnings`、`cargo test`)+ 空 crate 骨架 + §3 接口签名落盘(todo!() 实现)。
**验收:** `cargo build --workspace && cargo test` 通过。

### T1 · 解码 + 去马赛克(1 天)
rawler 读 ARW → black/white level 归一化 → Malvar 去马赛克 → 应用相机 WB 系数 → linear RGB f32。`decode_std` 走 image crate,sRGB 反 gamma 回 linear。
**验收:**
1. `cargo test -p rawsr-core decode` — 断言:尺寸正确、无 NaN/Inf、均值在 (0.01, 0.9) 区间;
2. 输出 linear TIFF 与 darktable/RawTherapee 对同一文件的中性显影肉眼比对(agent 输出对比截图路径,人工确认一次)。

### T2 · 显影(半天)
WB 微调、曝光 EV、base curve(实现两条:纯 sRGB gamma;简化 filmic 单参对比度)、f32 sRGB 输出。
**验收:** `cargo test -p rawsr-core develop` — 灰卡测试:构造 R=G=B 的 linear 输入,输出仍 R=G=B(容差 1e-4);gamma 正确性:linear 0.5 → sRGB ≈0.7354。

### T3 · ORT 推理封装(1 天)
`OrtRestorer`:NCHW f32 输入输出、EP 选择与回退、manifest 中声明的通道序(RGB/BGR)和值域处理。**必须**在日志中打印每个 session 实际分配到的 EP;CoreML 部分算子回退 CPU 时打印回退节点数。
**验收:** `cargo test -p rawsr-core infer` — 用 `tiny_sr_x2.onnx` 跑 64×64 tile,断言输出 128×128、值域 [0,1] 内(允许 clamp)。

### T4 · Tiling(1 天)
overlap 切块(默认 32px,来自 `tile_hint`)、羽化混合(线性权重,f32 域内混合后再量化)、`--crop x,y,w,h` 支持、按 `--tile-size` 或可用显存参数动态调 tile、RowBandSink 流式组装。
**验收:** `cargo test -p rawsr-core tile` —
1. 一致性:256×256 输入,整图直跑 vs tile 跑,内部区域(去掉边缘 8px)逐像素 |Δ| < 2/65535;
2. 接缝:水平渐变图 tile 处理后,相邻列差分无突变(max 二阶差分 < 阈值);
3. 内存:处理 42MP 输入 ×2 模拟模型时,峰值 RSS < 6GB(用 `/usr/bin/time -v` 或等价手段验证)。

### T5 · CLI + manifest(1 天)
```
rawsr input.ARW --denoise scunet --sr span-x4 --crop 1200,800,2000,1500 -o out.tif
rawsr input.jpg --sr realesrgan-x4 -o out.tif
rawsr --list-models
```
manifest 条目字段:`name, file, scale, kind(denoise|sr), tile, overlap, channel_order, input_range, notes`。管线顺序固定:decode → develop → denoise(全图或 crop)→ sr(crop 优先)→ export。
**验收:** `scripts/smoke.sh` 全绿(ARW 路径 + JPEG 路径 + crop 路径三条端到端,各自输出文件可被 `tiff` crate 重新读取且尺寸正确)。

### T6 · 导出(半天,可与 T5 并行)
16-bit TIFF、sRGB ICC 内嵌、输出预估 >4GB 自动切 BigTIFF、行带写入接口对接 T4。
**验收:** 单测:写出→重读→逐像素一致;BigTIFF 分支用 mock 尺寸触发并重读验证。

### T7 · 模型打包 + 基准(1 天)
`convert_models.py`:用 spandrel 加载 → `torch.onnx.export`(动态 H/W)。首发清单:SCUNet-GAN、NAFNet-width32(降噪);SPAN、RealESRGAN-general-x4v3、RealESRGAN-x4plus(超分)。生成 bench 表(模型 × {crop 4MP, 全图 42MP} × 耗时/峰值内存)写入 `BENCH.md`。
**验收:** 五个模型全部通过 T5 冒烟;BENCH.md 生成。

## 5. 已知的坑(agent 开工前必读)

1. **black level 必须在去马赛克之前减**,否则暗部偏色;white level 归一化用 rawler 元数据,不要假设 16383。
2. rawler 的 WB 系数是 as-shot multipliers,需归一到 G=1 后再乘。
3. 社区 SR 模型**几乎全部**假设 sRGB [0,1] f32 输入;个别老模型是 BGR——通道序写进 manifest,不写死在代码里。
4. GAN 系模型 tile overlap 低于 32px 会出可见接缝;混合必须在量化前的 f32 域做。
5. `ort` CoreML EP 会**静默**把不支持的算子回退到 CPU,表现为"能跑但巨慢"——务必打印节点分配统计;DAT/HAT 类 attention 模型回退比例高属正常,记录即可。
6. Windows 上 `ort` 需启用 `download-binaries` feature,或文档写明手动放置 dylib 的路径。
7. `torch.onnx.export` 必须导出动态 H/W(`dynamic_axes`),否则 tile 尺寸被锁死。
8. 42MP 输入本身 f32 就是 ~500MB,decode 阶段可以整幅驻留;**超分输出不行**,严格走 RowBandSink。
9. 测试资产要小:ARW 用裁剪样本或 rawler 仓库自带测试文件,tiny 模型 ≤5MB,总资产 <30MB。

## 6. Definition of Done(M0/M1 整体)

- [ ] `scripts/smoke.sh` 在 macOS(CoreML)与一台 NVIDIA Windows/Linux 机器上全绿
- [ ] 42MP ARW:全图降噪端到端 ≤ 2 分钟(GPU),峰值内存 < 6GB
- [ ] 4MP crop + RealESRGAN-x4:端到端 ≤ 30 秒(GPU)
- [ ] BENCH.md 存在且含五模型数据
- [ ] 所有单测通过,clippy 零警告

## 7. 给驱动者(你)的操作建议

- 每个任务开新会话,把本文档 + §3 接口 + 该任务小节喂进去;禁止 agent"顺手重构"。
- T1 的肉眼比对和 T7 的模型转换需要你在场,其余任务 agent 可自证。
- 卡住超过 30 分钟的问题(多半是 EP/链接类)直接人工介入,不要让 agent 无限重试。
