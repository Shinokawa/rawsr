set windows-shell := ["powershell.exe", "-NoLogo", "-NoProfile", "-Command"]

gen:
    cd gui; flutter_rust_bridge_codegen generate

icons:
    python scripts/generate_app_icons.py

pub-get-win:
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File scripts/setup-flutter-plugins.ps1

run-win: pub-get-win gen
    cd gui; flutter run -d windows

run-mac: gen
    cd gui; flutter pub get; flutter run -d macos

test-rust:
    cargo test --workspace

smoke-models device="direct-ml":
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File scripts/smoke-models.ps1 -Device {{device}}

bench-models device="direct-ml":
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File scripts/benchmark-models.ps1 -Device {{device}}

test-flutter: pub-get-win gen
    cd gui; flutter test

build-win: pub-get-win gen
    cd gui; flutter build windows

build-mac: gen
    cd gui; flutter pub get; flutter build macos
