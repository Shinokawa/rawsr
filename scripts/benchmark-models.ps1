[CmdletBinding()]
param(
    [string]$ArwPath = $env:RAWSR_TEST_ARW,
    [ValidateSet('auto', 'cpu', 'cuda', 'direct-ml', 'core-ml')]
    [string]$Device = 'direct-ml',
    [ValidateSet('', 'scunet-gan', 'nafnet-width32', 'span-x4', 'realesrgan-general-x4v3', 'realesrgan-x4plus')]
    [string]$OnlyModel = '',
    [ValidateSet('', '4MP', '42MP')]
    [string]$OnlySize = '',
    [switch]$Force,
    [switch]$KeepOutputs
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$OutputDir = Join-Path $Root 'artifacts\bench'
$Manifest = Join-Path $Root 'models\manifest.json'
$Binary = Join-Path $Root 'target\release\rawsr.exe'
$ResultsPath = Join-Path $OutputDir 'results.csv'
$env:RUST_LOG = 'rawsr_core=info,ort=warn'

function Invoke-MonitoredRawsr {
    param(
        [Parameter(Mandatory)] [string[]]$Arguments,
        [Parameter(Mandatory)] [string]$Label
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Binary
    $startInfo.WorkingDirectory = $Root
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + $_.Replace('"', '\"') + '"'
        }
        else {
            $_
        }
    }) -join ' '

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    if (-not $process.Start()) {
        throw "Could not start rawsr for $Label"
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $peakBytes = 0L
    while (-not $process.WaitForExit(200)) {
        try {
            $process.Refresh()
            $peakBytes = [math]::Max($peakBytes, $process.WorkingSet64)
        }
        catch {
            # The process may exit between WaitForExit and Refresh.
        }
    }
    $process.WaitForExit()
    $stopwatch.Stop()
    try {
        $process.Refresh()
        $peakBytes = [math]::Max($peakBytes, $process.PeakWorkingSet64)
    }
    catch {
        # PeakWorkingSet64 may be unavailable after a very fast process exits.
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $log = "$stdout`n$stderr".Trim()
    if ($log) {
        Write-Host $log
    }
    if ($process.ExitCode -ne 0) {
        throw "$Label failed with exit code $($process.ExitCode)"
    }

    [pscustomobject]@{
        Seconds = $stopwatch.Elapsed.TotalSeconds
        PeakBytes = $peakBytes
        Log = $log
    }
}

function Assert-TiffDimensions {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Expected
    )
    $info = & $Binary --inspect-tiff $Path
    if ($LASTEXITCODE -ne 0 -or $info -notmatch "^$Expected\s+RGB16\s+ICC=\d+ bytes$") {
        throw "Unexpected TIFF metadata for $Path`: $info"
    }
    $info
}

function Remove-BenchmarkOutput {
    param([Parameter(Mandatory)] [string]$Path)
    $outputRoot = [IO.Path]::GetFullPath($OutputDir).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($outputRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove benchmark output outside $outputRoot`: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Force
}

if ([string]::IsNullOrWhiteSpace($ArwPath) -or -not (Test-Path -LiteralPath $ArwPath)) {
    throw 'Set RAWSR_TEST_ARW or pass -ArwPath with a readable Sony .ARW file.'
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Push-Location $Root
try {
    cargo build --release -p rawsr-cli
    if ($LASTEXITCODE -ne 0) {
        throw 'Release CLI build failed.'
    }

    $fullInput = Join-Path $OutputDir 'input-42mp.tif'
    $cropInput = Join-Path $OutputDir 'input-4mp.tif'
    if (-not (Test-Path -LiteralPath $fullInput)) {
        Write-Host 'Preparing the developed 42MP benchmark input from the Sony ARW...'
        Invoke-MonitoredRawsr -Arguments @($ArwPath, '-o', $fullInput) -Label '42MP benchmark input' | Out-Null
    }
    Assert-TiffDimensions $fullInput '7968x5320' | Out-Null
    if (-not (Test-Path -LiteralPath $cropInput)) {
        Write-Host 'Preparing the 2000x2000 benchmark crop...'
        Invoke-MonitoredRawsr -Arguments @($fullInput, '--crop', '0,0,2000,2000', '-o', $cropInput) -Label '4MP benchmark input' | Out-Null
    }
    Assert-TiffDimensions $cropInput '2000x2000' | Out-Null

    $specs = @(
        [pscustomobject]@{ Model = 'scunet-gan'; Kind = 'denoise'; Scale = 1 }
        [pscustomobject]@{ Model = 'nafnet-width32'; Kind = 'denoise'; Scale = 1 }
        [pscustomobject]@{ Model = 'span-x4'; Kind = 'sr'; Scale = 4 }
        [pscustomobject]@{ Model = 'realesrgan-general-x4v3'; Kind = 'sr'; Scale = 4 }
        [pscustomobject]@{ Model = 'realesrgan-x4plus'; Kind = 'sr'; Scale = 4 }
    )
    $sizes = @(
        [pscustomobject]@{ Name = '4MP'; Input = $cropInput; InputDimensions = '2000x2000' }
        [pscustomobject]@{ Name = '42MP'; Input = $fullInput; InputDimensions = '7968x5320' }
    )
    $results = if (Test-Path -LiteralPath $ResultsPath) {
        @(Import-Csv -LiteralPath $ResultsPath)
    }
    else {
        @()
    }
    $results = @($results)

    foreach ($spec in $specs) {
        if ($OnlyModel -and $spec.Model -ne $OnlyModel) {
            continue
        }
        foreach ($size in $sizes) {
            if ($OnlySize -and $size.Name -ne $OnlySize) {
                continue
            }
            $existing = @($results | Where-Object {
                $_.Model -eq $spec.Model -and $_.Input -eq $size.Name -and $_.Device -eq $Device
            })
            if ($existing.Count -gt 0 -and -not $Force) {
                Write-Host "Skip existing result: $($spec.Model) $($size.Name) $Device"
                continue
            }
            if ($Force -and $existing.Count -gt 0) {
                $results = @($results | Where-Object {
                    -not ($_.Model -eq $spec.Model -and $_.Input -eq $size.Name -and $_.Device -eq $Device)
                })
            }

            $output = Join-Path $OutputDir "$($spec.Model)-$($size.Name)-$Device.tif"
            $expected = if ($spec.Scale -eq 1) {
                $size.InputDimensions
            }
            elseif ($size.Name -eq '4MP') {
                '8000x8000'
            }
            else {
                '31872x21280'
            }
            Write-Host "Benchmark $($spec.Model) on $($size.Name) using $Device..."
            $run = Invoke-MonitoredRawsr -Arguments @(
                $size.Input,
                '--manifest', $Manifest,
                "--$($spec.Kind)", $spec.Model,
                '--device', $Device,
                '-o', $output
            ) -Label "$($spec.Model) $($size.Name)"
            $tiffInfo = Assert-TiffDimensions $output $expected
            $provider = if ($run.Log -match 'providers=\{([^}]*)\}') {
                $Matches[1] -replace '"', ''
            }
            else {
                'not reported'
            }
            $row = [pscustomobject]@{
                Model = $spec.Model
                Kind = $spec.Kind
                Input = $size.Name
                InputDimensions = $size.InputDimensions
                OutputDimensions = $expected
                Device = $Device
                Seconds = [math]::Round($run.Seconds, 3)
                PeakRssMiB = [math]::Round($run.PeakBytes / 1MB, 1)
                Provider = $provider
                Tiff = $tiffInfo
                Timestamp = (Get-Date).ToString('o')
            }
            $results += $row
            $results | Export-Csv -LiteralPath $ResultsPath -NoTypeInformation -Encoding UTF8
            $row | Format-Table -AutoSize
            if (-not $KeepOutputs) {
                Remove-BenchmarkOutput $output
            }
        }
    }
    Write-Host "Benchmark results: $ResultsPath"
}
finally {
    Pop-Location
}
