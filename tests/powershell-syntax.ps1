$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem (Join-Path $root 'scripts'), $PSScriptRoot -Recurse -File |
    Where-Object { $_.Extension -in '.ps1', '.psm1' })
foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) {
        throw "$($file.FullName): $($parseErrors -join [Environment]::NewLine)"
    }
}
Write-Output "PowerShell parser checks passed ($($files.Count) files)"
