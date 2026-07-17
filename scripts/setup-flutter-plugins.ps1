[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$gui = Join-Path $root 'gui'

Push-Location $gui
try {
    & flutter pub get
    if ($LASTEXITCODE -eq 0) {
        exit 0
    }

    $dependencyFile = Join-Path $gui '.flutter-plugins-dependencies'
    if (-not (Test-Path -LiteralPath $dependencyFile -PathType Leaf)) {
        throw 'Flutter did not create .flutter-plugins-dependencies.'
    }

    $metadata = Get-Content -Raw -Encoding UTF8 -LiteralPath $dependencyFile | ConvertFrom-Json
    $linkRoot = Join-Path $gui 'windows\flutter\ephemeral\.plugin_symlinks'
    New-Item -ItemType Directory -Force -Path $linkRoot | Out-Null

    foreach ($plugin in $metadata.plugins.windows) {
        $destination = Join-Path $linkRoot $plugin.name
        $target = [System.IO.Path]::GetFullPath($plugin.path)
        if (Test-Path -LiteralPath $destination) {
            continue
        }
        if (-not (Test-Path -LiteralPath $target -PathType Container)) {
            throw "Flutter plugin source does not exist: $target"
        }
        & cmd.exe /d /c mklink /J "`"$destination`"" "`"$target`""
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create plugin junction: $destination -> $target"
        }
    }

    & flutter pub get
    if ($LASTEXITCODE -ne 0) {
        throw 'flutter pub get still failed after creating plugin junctions.'
    }
}
finally {
    Pop-Location
}
