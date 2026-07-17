#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${RAWSR_TEST_ARW:?Set RAWSR_TEST_ARW to a readable Sony .ARW file}"

cd "$root"
mkdir -p artifacts/smoke
cargo build --release --workspace

binary="target/release/rawsr"
if [[ -x target/release/rawsr.exe ]]; then
  binary="target/release/rawsr.exe"
fi

"$binary" assets/test/sample.jpg --manifest assets/test/manifest.json --sr tiny-sr-x2 -o artifacts/smoke/jpeg-sr.tif
jpeg_info="$("$binary" --inspect-tiff artifacts/smoke/jpeg-sr.tif)"
[[ "$jpeg_info" == 64x48$'\t'* ]]

"$binary" assets/test/sample.jpg --manifest assets/test/manifest.json --denoise tiny-denoise --sr tiny-sr-x2 --crop 4,4,8,6 -o artifacts/smoke/crop-chain.tif
crop_info="$("$binary" --inspect-tiff artifacts/smoke/crop-chain.tif)"
[[ "$crop_info" == 16x12$'\t'* ]]

"$binary" "$RAWSR_TEST_ARW" -o artifacts/smoke/sony-arw.tif
raw_info="$("$binary" --inspect-tiff artifacts/smoke/sony-arw.tif)"
[[ "$raw_info" == 7968x5320$'\t'* ]]

printf 'JPEG: %s\nCrop: %s\nARW: %s\n' "$jpeg_info" "$crop_info" "$raw_info"
