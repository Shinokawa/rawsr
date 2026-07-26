# RawSR production models

ONNX files in this directory are generated locally and intentionally ignored by Git. Run:

```powershell
python scripts\convert_models.py
```

The converter downloads the upstream checkpoints, verifies fixed SHA-256 hashes, loads them through Spandrel, and exports opset-17 ONNX with dynamic height/width axes.

| Manifest name | Upstream checkpoint |
|---|---|
| `scunet-gan` | KAIR `scunet_color_real_gan.pth` |
| `nafnet-width32` | NAFNet SIDD width-32 checkpoint |
| `span-x4` | OpenModelDB SPAN 4x checkpoint |
| `span-x2` | OpenModelDB SPAN 2x checkpoint (detail-preserving) |
| `realesrgan-x2plus` | Real-ESRGAN 2x checkpoint (repairing) |
| `realesrgan-general-x4v3` | Real-ESRGAN general x4v3 |
| `realesrgan-x4plus` | Real-ESRGAN x4plus |

Exact source URLs and checksums are defined in `scripts/convert_models.py`. Model weights retain their upstream licenses; review those licenses before redistribution.
