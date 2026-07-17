$ErrorActionPreference = 'Stop'
$gui = Split-Path -Parent $PSScriptRoot
$matches = & rg -n 'Color\(0x|#[0-9A-Fa-f]{6,8}' (Join-Path $gui 'lib') -g '*.dart' -g '!**/rawsr_theme.dart'
if ($LASTEXITCODE -eq 0) {
    $matches
    throw 'Hard-coded colors are only allowed in lib/src/theme/rawsr_theme.dart.'
}
if ($LASTEXITCODE -gt 1) {
    throw 'rg failed while checking Flutter colors.'
}
