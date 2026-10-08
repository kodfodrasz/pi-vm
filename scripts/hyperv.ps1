[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('start','stop','status')][string]$Action,[Parameter(Mandatory=$true)][string]$Id,[string]$Cache="$HOME/.cache/pi-vm/images",[string]$Build="$PSScriptRoot/../build",[string]$Switch='Default Switch',[string]$SeedIso,[string]$Hostname='pipette',[int]$MemoryMB=2048,[int]$CpuCount=2,[string]$DiskSize='16GiB',[switch]$Force,[switch]$DynamicMemory)
$ErrorActionPreference='Stop'
if($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,100}$'){throw 'Invalid instance id'}
Import-Module Hyper-V
$Build=[IO.Path]::GetFullPath($Build); $Cache=[IO.Path]::GetFullPath($Cache); $inst=Join-Path $Build $Id
$name="pi-vm-$Id"; $url='https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw.xz'; $hash='7e4fb73907abdc761d226ddaf3263bdfca62a0b0bfb5f0798545a9981fdd1953'
if($Action -eq 'status'){Get-VM -Name $name -ErrorAction SilentlyContinue | Select-Object Name,State,Status; exit}
if($Action -eq 'stop'){Stop-VM -Name $name -ErrorAction Stop; exit}
if($MemoryMB -lt 1024 -or $CpuCount -lt 1){throw 'Use at least 1024 MiB RAM and one CPU'}
$existing=Get-VM -Name $name -ErrorAction SilentlyContinue
if($existing){
  if($Force){throw 'Remove the existing VM explicitly before rebuilding its disk'}
  if($existing.State -ne 'Off'){throw "VM is not stopped: $name"}
  Start-VM -Name $name
  Write-Host "Restarted $name with its existing settings and disk"
  exit
}
New-Item -ItemType Directory -Force -Path $Build | Out-Null
$buildLock=[IO.File]::Open((Join-Path $Build '.hyperv.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
if($Action -eq 'start') {
  if($DiskSize -notmatch '^\s*(\d+(?:\.\d+)?)\s*(GB|GIB)\s*$'){throw "Invalid -DiskSize '$DiskSize'; use a positive number followed by GB or GiB"}
  $unit=if($Matches[2].ToUpperInvariant() -eq 'GIB'){1GB}else{1000000000L}
  $diskBytes=[Int64][Math]::Floor([double]$Matches[1]*[double]$unit)
  if($diskBytes -lt 5368709120L -or $diskBytes % 1MB){throw 'Disk size must be at least 5 GiB and aligned to 1 MiB; use 16GiB or 8GiB'}
  if($SeedIso) { if(-not (Test-Path -LiteralPath $SeedIso -PathType Leaf)){throw 'The supplied -SeedIso must be an existing file; no files or disks were changed.'} }
  else {
    $seedDir=Join-Path $Build 'seeds'; $SeedIso=Join-Path $seedDir "$Id.iso"
    if(-not(Test-Path -LiteralPath $SeedIso -PathType Leaf)) { New-Item -ItemType Directory -Force -Path $seedDir | Out-Null; & "$PSScriptRoot/seed.ps1" -Id $Id -Hostname $Hostname -OutputIso $SeedIso }
  }
}
if(Get-VM -Name $name -ErrorAction SilentlyContinue){throw "VM exists: $name"}
if(Test-Path $inst){if(-not $Force){throw "Instance files exist; -Force explicitly recreates them"}; Remove-Item $inst -Recurse -Force}
New-Item -ItemType Directory -Force -Path $Cache,$Build,$inst | Out-Null
$archive=Join-Path $Cache 'Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw.xz'; $raw=Join-Path $Cache 'Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw'
$rawHash='ccf0412fa9e3f7d8ce8824e03e3c7369d0fef6dffb00a786a6bc9e895ccdb9ce'; $rawSize=5368709120L
$lockPath=Join-Path $Cache '.download.lock'; $lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
  if(-not(Test-Path $archive) -or (Get-FileHash $archive -Algorithm SHA256).Hash.ToLower() -ne $hash){$part="$archive.part"; Remove-Item $part -Force -ErrorAction SilentlyContinue; Invoke-WebRequest $url -OutFile $part; if((Get-FileHash $part -Algorithm SHA256).Hash.ToLower() -ne $hash){Remove-Item $part;throw 'Compressed image SHA-256 mismatch'}; Move-Item $part $archive -Force}
  $validRaw=(Test-Path $raw) -and (Get-Item $raw).Length -eq $rawSize
  if($validRaw){$validRaw=(Get-FileHash $raw -Algorithm SHA256).Hash.ToLower() -eq $rawHash}
  if(-not $validRaw){Remove-Item $raw -Force -ErrorAction SilentlyContinue; $part="$raw.part"; Remove-Item $part -Force -ErrorAction SilentlyContinue; if(-not(Get-Command 7z -ErrorAction SilentlyContinue)){throw 'Install 7-Zip and ensure 7z.exe is in PATH to decompress the raw image'}; & 7z x $archive "-o$Cache" -y | Out-Null; if($LASTEXITCODE -or -not(Test-Path $raw)){throw '7-Zip decompression failed'}; if((Get-Item $raw).Length -ne $rawSize -or (Get-FileHash $raw -Algorithm SHA256).Hash.ToLower() -ne $rawHash){Remove-Item $raw -Force;throw 'Raw image size/SHA-256 mismatch'} }
} finally {$lock.Dispose()}
$base=Join-Path $Build "fedora44-base-$($diskBytes).vhdx"; $fixed=Join-Path $Build "fedora44-base-$($diskBytes).vhd"
if(Test-Path $base){$v=Get-VHD -Path $base; if($v.Size -ne $diskBytes){throw "Cached base has unexpected size: $($v.Size)"}}
else {if(-not(Test-Path $fixed)){& "$PSScriptRoot/raw-to-vhd.ps1" -RawPath $raw -VhdPath $fixed}; Convert-VHD -Path $fixed -DestinationPath "$base.part.vhdx" -VHDType Dynamic; Resize-VHD -Path "$base.part.vhdx" -SizeBytes $diskBytes; [IO.File]::Move("$base.part.vhdx",$base)}
$child=Join-Path $inst 'disk.vhdx'; New-VHD -Path $child -ParentPath $base -Differencing | Out-Null
$args=@{Name=$name;Generation=2;MemoryStartupBytes=($MemoryMB*1MB);VHDPath=$child;SwitchName=$Switch}
New-VM @args | Out-Null; Set-VMProcessor $name -Count $CpuCount -ExposeVirtualizationExtensions $true
Set-VMFirmware $name -EnableSecureBoot Off
if($DynamicMemory){Set-VMMemory $name -DynamicMemoryEnabled $true -MinimumBytes 1GB -StartupBytes ($MemoryMB*1MB) -MaximumBytes ($MemoryMB*1MB)} else {Set-VMMemory $name -DynamicMemoryEnabled $false}
Add-VMDvdDrive -VMName $name -Path $SeedIso | Out-Null; Start-VM $name | Out-Null
Write-Host "Started $name; console: vmconnect.exe localhost $name"
} finally { $buildLock.Dispose() }
