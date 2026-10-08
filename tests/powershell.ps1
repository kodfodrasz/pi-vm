$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
foreach($file in Get-ChildItem "$root/scripts/*.ps1") {
  [void][scriptblock]::Create((Get-Content -Raw $file.FullName))
}
# Parsing alone does not compile the C# helper used to save a COM ISO stream.
$text=Get-Content -Raw "$root/scripts/seed.ps1"
$match=[regex]::Match($text, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if(-not $match.Success){throw 'Seed stream helper missing'}
Add-Type -TypeDefinition $match.Groups[1].Value
Write-Output 'PowerShell syntax and ISO stream helper compilation passed'
