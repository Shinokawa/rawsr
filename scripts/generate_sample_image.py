#!/usr/bin/env python3
"""Generate the deterministic small JPEG used by CLI smoke tests."""

import argparse
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "assets" / "test" / "sample.jpg"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--width", type=int, default=32)
    parser.add_argument("--height", type=int, default=24)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    width, height = args.width, args.height
    if width < 2 or height < 2:
        raise ValueError("sample image dimensions must both be at least 2 pixels")
    image = Image.new("RGB", (width, height))
    pixels = image.load()
    for y in range(height):
        for x in range(width):
            pixels[x, y] = (
                round(255 * x / (width - 1)),
                round(255 * y / (height - 1)),
                round(255 * (x + y) / (width + height - 2)),
            )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    image.save(args.output, quality=95, subsampling=0)
    print(f"wrote {args.output} ({args.output.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
