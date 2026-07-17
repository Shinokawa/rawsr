# RawSR model benchmarks

Measured on 2026-07-17 (Asia/Shanghai). Every entry below is a completed production-model run; no value is extrapolated.

## Test system

| Component | Value |
|---|---|
| OS | Windows 11 Pro for Workstations 10.0.26200 |
| CPU | AMD Ryzen 5 5600G, 6 cores / 12 threads |
| GPU | AMD Radeon Graphics integrated GPU, driver 31.0.12027.9001 |
| Reported dedicated VRAM | 512 MiB (system memory is shared) |
| RAM | 31.4 GiB visible |
| Rust | rustc 1.97.0 |
| ONNX EP | DirectML, bundled DirectML.dll 1.15.4+241025-1615.1.dml-1.15.fac7597 |
| Tile policy | 256px tile, 32px overlap |

The source is a real Sony ILCE-7RM2 ARW from the local Immich library. RawSR developed it once into a 7968×5320 RGB16 TIFF (42.39MP), then produced a 2000×2000 crop (4MP). Benchmark runs use those two TIFFs so the table measures the same decode/develop/model/export path for every model without repeating RAW demosaic work.

Elapsed time covers TIFF decode, sRGB development, ONNX session creation, tiled inference, blending, and RGB16 TIFF/BigTIFF export. Peak RSS is the maximum Windows process working set sampled during the run; it does not include GPU memory that the Windows driver does not charge to process RSS.

## Results

| Model | Kind | Input | Output | Time | Peak RSS | Actual EP |
|---|---|---:|---:|---:|---:|---|
| SCUNet-GAN | denoise | 2000×2000 | 2000×2000 | 231.385 s (3:51.4) | 2493.7 MiB | DirectML |
| SCUNet-GAN | denoise | 7968×5320 | 7968×5320 | 2438.517 s (40:38.5) | 3926.3 MiB | DirectML |
| NAFNet width-32 | denoise | 2000×2000 | 2000×2000 | 14.925 s | 585.4 MiB | DirectML |
| NAFNet width-32 | denoise | 7968×5320 | 7968×5320 | 141.978 s (2:22.0) | 1700.9 MiB | DirectML |
| SPAN x4 | super-resolution | 2000×2000 | 8000×8000 | 10.389 s | 470.4 MiB | DirectML |
| SPAN x4 | super-resolution | 7968×5320 | 31872×21280 | 100.989 s (1:41.0) | 1734.1 MiB | DirectML |
| RealESRGAN general x4v3 | super-resolution | 2000×2000 | 8000×8000 | 13.887 s | 347.8 MiB | DirectML |
| RealESRGAN general x4v3 | super-resolution | 7968×5320 | 31872×21280 | 138.977 s (2:19.0) | 1609.0 MiB | DirectML |
| RealESRGAN x4plus | super-resolution | 2000×2000 | 8000×8000 | 259.817 s (4:19.8) | 1526.8 MiB | DirectML |
| RealESRGAN x4plus | super-resolution | 7968×5320 | 31872×21280 | 2675.951 s (44:36.0) | 2790.5 MiB | DirectML |

ONNX Runtime fused each production graph into one profiled `DmlExecutionProvider` graph node. No production smoke or benchmark run reported a CPU fallback node.

All ten output files were reopened through RawSR's TIFF reader and verified as RGB16 with a 588-byte embedded sRGB ICC profile. The three 42MP x4 outputs selected BigTIFF and wrote 31872×21280 pixels (about 4.07 GB of uncompressed RGB16 samples) through the row-band sink; temporary benchmark outputs were deleted only after successful verification.

## Acceptance interpretation

- Peak RSS stayed below the 6GB requirement for every model and size.
- The 4MP/30-second target is met by SPAN x4 (10.389s) and RealESRGAN general x4v3 (13.887s). RealESRGAN x4plus does not meet it on this integrated GPU.
- The 42MP/2-minute denoise target is not met on this host: NAFNet is 141.978s and SCUNet-GAN is substantially heavier. This is recorded as a hardware-performance limitation, not a functional failure; both completed on DirectML and produced valid TIFF files.

## Reproduce

```powershell
$env:RAWSR_TEST_ARW = 'E:\path\to\sony-a7r2.ARW'
.\scripts\benchmark-models.ps1 -Device direct-ml
```

Raw measurements are written to the ignored local file `artifacts/bench/results.csv`. The script resumes completed model/size/device rows and supports `-Force`, `-OnlyModel`, `-OnlySize`, and `-KeepOutputs`.
