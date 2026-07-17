#!/usr/bin/env python3
"""Generate Windows and macOS application icon assets from the RawSR master PNG."""

from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "gui" / "assets" / "icon" / "rawsr-icon.png"
MACOS_DIR = (
    ROOT
    / "gui"
    / "macos"
    / "Runner"
    / "Assets.xcassets"
    / "AppIcon.appiconset"
)
WINDOWS_ICO = (
    ROOT / "gui" / "windows" / "runner" / "resources" / "app_icon.ico"
)


def resized(image: Image.Image, edge: int) -> Image.Image:
    return image.resize((edge, edge), Image.Resampling.LANCZOS)


def main() -> None:
    image = Image.open(SOURCE).convert("RGBA")
    if image.width != image.height:
        raise ValueError(f"application icon source must be square, got {image.size}")

    MACOS_DIR.mkdir(parents=True, exist_ok=True)
    for edge in (16, 32, 64, 128, 256, 512, 1024):
        destination = MACOS_DIR / f"app_icon_{edge}.png"
        resized(image, edge).save(destination, optimize=True)
        print(f"wrote {destination.relative_to(ROOT)}")

    WINDOWS_ICO.parent.mkdir(parents=True, exist_ok=True)
    windows_image = image.copy()
    alpha = Image.new("L", image.size, 0)
    ImageDraw.Draw(alpha).rounded_rectangle(
        (0, 0, image.width - 1, image.height - 1),
        radius=round(image.width * 0.2),
        fill=255,
    )
    windows_image.putalpha(alpha)
    windows_image.save(
        WINDOWS_ICO,
        format="ICO",
        sizes=[(edge, edge) for edge in (16, 24, 32, 48, 64, 128, 256)],
    )
    print(f"wrote {WINDOWS_ICO.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
