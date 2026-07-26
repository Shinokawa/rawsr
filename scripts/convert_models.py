#!/usr/bin/env python3
"""Download, verify, and export RawSR production checkpoints to dynamic ONNX."""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path

import onnx
import torch
from spandrel import ImageModelDescriptor, ModelLoader


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "models" / "source"
OUTPUT_DIR = ROOT / "models"


@dataclass(frozen=True)
class ModelSpec:
    source_file: str
    output_file: str
    download_url: str
    canonical_url: str
    sha256: str
    sample_edge: int


MODELS: dict[str, ModelSpec] = {
    "scunet-gan": ModelSpec(
        source_file="scunet_color_real_gan.pth",
        output_file="scunet-gan.onnx",
        download_url="https://github.com/cszn/KAIR/releases/download/v1.0/scunet_color_real_gan.pth",
        canonical_url="https://github.com/cszn/KAIR/releases/download/v1.0/scunet_color_real_gan.pth",
        sha256="892c83f812c59173273b74f4f34a14ecaf57a2fdb68df056664589beb55c966e",
        sample_edge=256,
    ),
    "nafnet-width32": ModelSpec(
        source_file="nafnet_sidd_width32.pth",
        output_file="nafnet-width32.onnx",
        download_url="https://hf-mirror.com/mikestealth/nafnet-models/resolve/main/NAFNet-SIDD-width32.pth?download=true",
        canonical_url="https://drive.google.com/file/d/1lsByk21Xw-6aW7epCwOQxvm6HYCQZPHZ/view",
        sha256="89c70e808d1783b6c07911306e106aaf0d4f7f3da8c61078b99ff7f8929a26f4",
        sample_edge=256,
    ),
    "span-x4": ModelSpec(
        source_file="span_x4.pth",
        output_file="span-x4.onnx",
        download_url="https://github.com/OpenModelDB/model-hub/releases/download/span/4x-spanx4_ch48.pth",
        canonical_url="https://drive.google.com/file/d/1iYUA2TzKuxI0vzmA-UXr_nB43XgPOXUg/view",
        sha256="a5f85dbf6f13cc54011f849577508be4923a61555c9755a961036055e521a961",
        sample_edge=64,
    ),
    "span-x2": ModelSpec(
        source_file="span_x2.pth",
        output_file="span-x2.onnx",
        download_url="https://github.com/OpenModelDB/model-hub/releases/download/span/2x-spanx2_ch48.pth",
        canonical_url="https://github.com/OpenModelDB/model-hub/releases/download/span/2x-spanx2_ch48.pth",
        sha256="2f965167188762269f9f7ca5cad9d4028ae0814ec9b7c2cb101e61fae7753d81",
        sample_edge=64,
    ),
    "realesrgan-x2plus": ModelSpec(
        source_file="realesrgan_x2plus.pth",
        output_file="realesrgan-x2plus.onnx",
        download_url="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth",
        canonical_url="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth",
        sha256="49fafd45f8fd7aa8d31ab2a22d14d91b536c34494a5cfe31eb5d89c2fa266abb",
        sample_edge=64,
    ),
    "realesrgan-general-x4v3": ModelSpec(
        source_file="realesr-general-x4v3.pth",
        output_file="realesrgan-general-x4v3.onnx",
        download_url="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth",
        canonical_url="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth",
        sha256="8dc7edb9ac80ccdc30c3a5dca6616509367f05fbc184ad95b731f05bece96292",
        sample_edge=64,
    ),
    "realesrgan-x4plus": ModelSpec(
        source_file="realesrgan-x4plus.pth",
        output_file="realesrgan-x4plus.onnx",
        download_url="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth",
        canonical_url="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth",
        sha256="4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1",
        sample_edge=64,
    ),
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(spec: ModelSpec, force: bool) -> Path:
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    destination = SOURCE_DIR / spec.source_file
    if destination.exists() and not force:
        verify_hash(destination, spec.sha256)
        return destination

    partial = destination.with_suffix(destination.suffix + ".part")
    print(f"download {spec.download_url}")
    request = urllib.request.Request(
        spec.download_url,
        headers={"User-Agent": "rawsr-model-converter/1.0"},
    )
    with urllib.request.urlopen(request, timeout=180) as response, partial.open("wb") as output:
        while block := response.read(1024 * 1024):
            output.write(block)
    verify_hash(partial, spec.sha256)
    os.replace(partial, destination)
    return destination


def verify_hash(path: Path, expected: str) -> None:
    actual = sha256(path)
    if actual.lower() != expected.lower():
        raise RuntimeError(
            f"checkpoint hash mismatch for {path}: expected {expected}, got {actual}"
        )


def export_model(name: str, spec: ModelSpec, force: bool) -> Path:
    source = download(spec, force=False)
    destination = OUTPUT_DIR / spec.output_file
    if destination.exists() and not force:
        verify_onnx(destination)
        print(f"keep verified {destination.relative_to(ROOT)}")
        return destination

    print(f"load {name} from {source.relative_to(ROOT)}")
    descriptor = ModelLoader().load_from_file(source)
    if not isinstance(descriptor, ImageModelDescriptor):
        raise TypeError(f"{name} is not an image-to-image model")
    if descriptor.input_channels != 3 or descriptor.output_channels != 3:
        raise ValueError(
            f"{name} must use three input/output channels, got "
            f"{descriptor.input_channels}/{descriptor.output_channels}"
        )

    model = descriptor.model.cpu().eval()
    sample = torch.rand(1, 3, spec.sample_edge, spec.sample_edge, dtype=torch.float32)
    destination.parent.mkdir(parents=True, exist_ok=True)
    print(
        f"export {name}: architecture={type(model).__name__} "
        f"scale={descriptor.scale} sample={spec.sample_edge}x{spec.sample_edge}"
    )
    with torch.inference_mode():
        torch.onnx.export(
            model,
            (sample,),
            destination,
            input_names=["input"],
            output_names=["output"],
            dynamic_axes={
                "input": {2: "height", 3: "width"},
                "output": {2: "output_height", 3: "output_width"},
            },
            opset_version=17,
            do_constant_folding=True,
            dynamo=False,
        )
    verify_onnx(destination)
    print(f"wrote {destination.relative_to(ROOT)} ({destination.stat().st_size:,} bytes)")
    return destination


def verify_onnx(path: Path) -> None:
    model = onnx.load(path, load_external_data=False)
    onnx.checker.check_model(model)
    shape = model.graph.input[0].type.tensor_type.shape.dim
    if len(shape) != 4 or not shape[2].dim_param or not shape[3].dim_param:
        raise RuntimeError(f"{path} does not have dynamic H/W input axes")
    output_shape = model.graph.output[0].type.tensor_type.shape.dim
    if len(output_shape) != 4 or not output_shape[2].dim_param or not output_shape[3].dim_param:
        raise RuntimeError(f"{path} does not have dynamic H/W output axes")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "models",
        nargs="*",
        choices=sorted(MODELS),
        help="model names to process; defaults to every production model",
    )
    parser.add_argument("--download-only", action="store_true")
    parser.add_argument("--force", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    selected = args.models or list(MODELS)
    print(f"torch={torch.__version__} device=cpu spandrel models={len(selected)}")
    for name in selected:
        spec = MODELS[name]
        download(spec, force=args.force and args.download_only)
        if not args.download_only:
            export_model(name, spec, force=args.force)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, TypeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
