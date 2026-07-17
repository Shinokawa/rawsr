[CmdletBinding()]
param(
    [ValidateSet('auto', 'cpu', 'cuda', 'direct-ml', 'core-ml')]
    [string]$Device = 'direct-ml'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$OutputDir = Join-Path $Root 'artifacts\model-smoke'
$Manifest = Join-Path $Root 'models\manifest.json'
$Binary = Join-Path $Root 'target\release\rawsr.exe'
$env:RUST_LOG = 'rawsr_core=info,ort=warn'
$Python = Join-Path $Root '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $Python)) {
    $Python = 'python'
}

function Invoke-RawsrModel {
    param(
        [Parameter(Mandatory)] [string]$InputPath,
        [Parameter(Mandatory)] [ValidateSet('denoise', 'sr')] [string]$Kind,
        [Parameter(Mandatory)] [string]$Model,
        [Parameter(Mandatory)] [string]$OutputPath,
        [Parameter(Mandatory)] [string]$ExpectedDimensions
    )

    $arguments = @(
        $InputPath,
        '--manifest', $Manifest,
        "--$Kind", $Model,
        '--device', $Device,
        '-o', $OutputPath
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $log = @(& $Binary @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $log | ForEach-Object { Write-Host $_ }
    $stopwatch.Stop()
    if ($exitCode -ne 0) {
        throw "$Model smoke failed with exit code $exitCode"
    }
    if ($Device -eq 'direct-ml' -and -not ($log -match 'ONNX Runtime actual node allocation.*DmlExecutionProvider')) {
        throw "$Model completed without a DirectML node allocation in the ONNX profile"
    }

    $info = & $Binary --inspect-tiff $OutputPath
    if ($LASTEXITCODE -ne 0 -or $info -notmatch "^$ExpectedDimensions\s+RGB16\s+ICC=\d+ bytes$") {
        throw "$Model output is not a readable $ExpectedDimensions RGB16 TIFF with ICC: $info"
    }
    [pscustomobject]@{
        Model = $Model
        Device = $Device
        Seconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
        Output = Split-Path -Leaf $OutputPath
        Tiff = $info
    }
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Push-Location $Root
try {
    cargo build --release -p rawsr-cli
    if ($LASTEXITCODE -ne 0) {
        throw 'Release CLI build failed.'
    }

    $denoiseInput = Join-Path $OutputDir 'input-256.png'
    $srInput = Join-Path $OutputDir 'input-64.png'
    & $Python scripts\generate_sample_image.py --output $denoiseInput --width 256 --height 256
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not generate the 256x256 model smoke input.'
    }
    & $Python scripts\generate_sample_image.py --output $srInput --width 64 --height 64
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not generate the 64x64 model smoke input.'
    }

    $results = @(
        Invoke-RawsrModel $denoiseInput denoise 'scunet-gan' (Join-Path $OutputDir 'scunet-gan.tif') '256x256'
        Invoke-RawsrModel $denoiseInput denoise 'nafnet-width32' (Join-Path $OutputDir 'nafnet-width32.tif') '256x256'
        Invoke-RawsrModel $srInput sr 'span-x4' (Join-Path $OutputDir 'span-x4.tif') '256x256'
        Invoke-RawsrModel $srInput sr 'realesrgan-general-x4v3' (Join-Path $OutputDir 'realesrgan-general-x4v3.tif') '256x256'
        Invoke-RawsrModel $srInput sr 'realesrgan-x4plus' (Join-Path $OutputDir 'realesrgan-x4plus.tif') '256x256'
    )
    $results | Format-Table -AutoSize
}
finally {
    Pop-Location
}
