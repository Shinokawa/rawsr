param(
    [string]$ArwPath = $env:RAWSR_TEST_ARW
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$OutputDir = Join-Path $Root 'artifacts\smoke'
$Manifest = Join-Path $Root 'assets\test\manifest.json'
$SampleJpeg = Join-Path $Root 'assets\test\sample.jpg'
$Binary = Join-Path $Root 'target\release\rawsr.exe'

if ([string]::IsNullOrWhiteSpace($ArwPath) -or -not (Test-Path -LiteralPath $ArwPath)) {
    throw 'Set RAWSR_TEST_ARW or pass -ArwPath with a readable Sony .ARW file.'
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Push-Location $Root
try {
    cargo build --release --workspace

    $jpegOutput = Join-Path $OutputDir 'jpeg-sr.tif'
    & $Binary $SampleJpeg --manifest $Manifest --sr tiny-sr-x2 -o $jpegOutput
    $jpegInfo = & $Binary --inspect-tiff $jpegOutput
    if ($jpegInfo -notmatch '^64x48\s') {
        throw "JPEG smoke output has unexpected dimensions: $jpegInfo"
    }

    $cropOutput = Join-Path $OutputDir 'crop-chain.tif'
    & $Binary $SampleJpeg --manifest $Manifest --denoise tiny-denoise --sr tiny-sr-x2 --crop 4,4,8,6 -o $cropOutput
    $cropInfo = & $Binary --inspect-tiff $cropOutput
    if ($cropInfo -notmatch '^16x12\s') {
        throw "Crop smoke output has unexpected dimensions: $cropInfo"
    }

    $rawOutput = Join-Path $OutputDir 'sony-arw.tif'
    & $Binary $ArwPath -o $rawOutput
    $rawInfo = & $Binary --inspect-tiff $rawOutput
    if ($rawInfo -notmatch '^7968x5320\s') {
        throw "ARW smoke output has unexpected dimensions: $rawInfo"
    }

    Write-Output "JPEG: $jpegInfo"
    Write-Output "Crop: $cropInfo"
    Write-Output "ARW: $rawInfo"
}
finally {
    Pop-Location
}
