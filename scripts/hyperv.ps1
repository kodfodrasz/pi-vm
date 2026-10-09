[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateSet('start','stop','status')][string]$Action,
  [Parameter(Mandatory=$true)][string]$Id,
  [string]$Cache="$HOME/.cache/pi-vm/images", [string]$Build="$PSScriptRoot/../build",
  [string]$Switch='Default Switch', [string]$SeedIso, [string]$Hostname='pipette',
  [int]$MemoryMB=2048, [int]$CpuCount=2, [string]$DiskSize='16GiB',
  [switch]$Force, [switch]$DynamicMemory
)
$ErrorActionPreference='Stop'
Import-Module Hyper-V -ErrorAction Stop
if($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,100}$'){throw 'Invalid instance id'}
$Build=[IO.Path]::GetFullPath($Build); $Cache=[IO.Path]::GetFullPath($Cache)
$inst=Join-Path $Build $Id; $name="pi-vm-$Id"
if($Action -eq 'status'){Get-VM -Name $name -ErrorAction SilentlyContinue | Select-Object Name,State,Status; return}
if($Action -eq 'stop'){Stop-VM -Name $name -ErrorAction Stop; return}

# File.Replace and the two-argument Move also work in Windows PowerShell 5.1.
function Publish-CacheFile($Source,$Destination) {
  if(Test-Path -LiteralPath $Destination){[IO.File]::Replace($Source,$Destination,[NullString]::Value)}
  else {[IO.File]::Move($Source,$Destination)}
}
function Assert-Storage {
  $required=@{}
  foreach($item in @(@($Cache,8GB),@($Build,12GB))){
    $ancestor=$item[0]
    while(-not(Test-Path -LiteralPath $ancestor)){
      $parent=Split-Path -Parent $ancestor
      if(-not $parent -or $parent -eq $ancestor){throw "Cannot find storage volume for $($item[0])"}
      $ancestor=$parent
    }
    $volume=Get-Volume -FilePath $ancestor -ErrorAction Stop
    if(-not $volume -or $null -eq $volume.SizeRemaining){throw "Cannot check free space for $($item[0]); use a local disk drive"}
    $key=[string]$volume.UniqueId
    if(-not $key){throw 'Storage volume has no unique ID'}
    if(-not $required.ContainsKey($key)){$required[$key]=@{Free=[Int64]$volume.SizeRemaining;Bytes=0L}}
    $required[$key].Bytes += $item[1]
  }
  foreach($root in $required.Keys){
    if($required[$root].Free -lt $required[$root].Bytes){throw "Insufficient free space on $root (need $($required[$root].Bytes / 1GB) GiB)"}
  }
}

# Reject invalid inputs before creating a directory or a lock.
if($MemoryMB -lt 1024 -or $CpuCount -lt 1){throw 'Use at least 1024 MiB RAM and one CPU'}
if($Hostname -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'){throw 'Invalid hostname'}
if($DiskSize -notmatch '^\s*(\d+(?:\.\d+)?)\s*(GB|GIB)\s*$'){throw 'Use a disk size such as 8GiB or 16GiB'}
$unit=if($Matches[2].ToUpperInvariant() -eq 'GIB'){1GB}else{1000000000L}
$diskBytes=[Int64][Math]::Floor([double]$Matches[1]*[double]$unit)
if($diskBytes -lt 5368709120L -or $diskBytes % 1MB){throw 'Disk size must be at least 5 GiB and aligned to 1 MiB'}
if($SeedIso){
  if(-not [IO.Path]::IsPathRooted($SeedIso)){throw 'The supplied -SeedIso must be an absolute path'}
  $SeedIso=[IO.Path]::GetFullPath($SeedIso)
  if(-not(Test-Path -LiteralPath $SeedIso -PathType Leaf)){throw 'The supplied seed ISO does not exist'}
}
$existing=Get-VM -Name $name -ErrorAction SilentlyContinue
if($existing){
  if($Force){throw 'Force cannot replace a registered VM. Remove the VM explicitly first.'}
  if($existing.State -ne 'Off'){throw "VM is not stopped: $name"}
  if(-not(Test-Path (Join-Path $inst 'creation-complete'))){throw "VM is registered but incomplete; inspect it before removing it: $name"}
  Start-VM -Name $name
  Write-Host "Restarted $name with its existing settings and disk"
  return
}
Get-VMSwitch -Name $Switch -ErrorAction Stop | Out-Null
if((Test-Path $inst) -and -not $Force){throw 'Instance files exist; -Force explicitly recreates them'}
Assert-Storage
New-Item -ItemType Directory -Force -Path $Build,$Cache | Out-Null
$buildLock=[IO.File]::Open((Join-Path $Build '.hyperv.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$ownedInstance=$false; $createdVm=$false; $part=$null
try {
  # Recheck state under the lock; automatic seed creation is under this lock too.
  if(Get-VM -Name $name -ErrorAction SilentlyContinue){throw "VM exists: $name"}
  if(-not $SeedIso){
    $seedDir=Join-Path $Build 'seeds'; $SeedIso=Join-Path $seedDir "$Id.iso"
    if(-not(Test-Path -LiteralPath $SeedIso)){
      New-Item -ItemType Directory -Force -Path $seedDir | Out-Null
      & "$PSScriptRoot/seed.ps1" -Id $Id -Hostname $Hostname -OutputIso $SeedIso
    }
  }
  if(Test-Path $inst){
    if(-not $Force){throw 'Instance files exist; -Force explicitly recreates them'}
    Remove-Item -LiteralPath $inst -Recurse -Force
  }
  New-Item -ItemType Directory -Path $inst | Out-Null; $ownedInstance=$true
  $archive=Join-Path $Cache 'Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw.xz'
  $raw=Join-Path $Cache 'Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw'
  $url='https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw.xz'
  $hash='7e4fb73907abdc761d226ddaf3263bdfca62a0b0bfb5f0798545a9981fdd1953'
  $rawHash='ccf0412fa9e3f7d8ce8824e03e3c7369d0fef6dffb00a786a6bc9e895ccdb9ce'; $rawSize=5368709120L
  $lock=[IO.File]::Open((Join-Path $Cache '.download.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  try {
    if(-not(Test-Path $archive) -or (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash){
      $download=Join-Path $Cache ('.download-'+[Guid]::NewGuid().ToString('N'))
      try {
        Invoke-WebRequest $url -OutFile $download -UseBasicParsing
        if((Get-FileHash $download -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash){throw 'Compressed image SHA-256 mismatch'}
        Publish-CacheFile $download $archive
      } finally {Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue}
    }
    $valid=(Test-Path $raw) -and (Get-Item $raw).Length -eq $rawSize
    if($valid){$valid=(Get-FileHash $raw -Algorithm SHA256).Hash.ToLowerInvariant() -eq $rawHash}
    if(-not $valid){
      $stage=Join-Path $Cache ('.raw-stage-'+[Guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Path $stage | Out-Null
      try {
        if(-not(Get-Command 7z -ErrorAction SilentlyContinue)){throw 'Install 7-Zip and put 7z.exe in PATH'}
        & 7z x $archive "-o$stage" -y | Out-Null
        if($LASTEXITCODE){throw '7-Zip decompression failed'}
        $candidate=Join-Path $stage (Split-Path $raw -Leaf)
        if(-not(Test-Path $candidate) -or (Get-Item $candidate).Length -ne $rawSize -or (Get-FileHash $candidate -Algorithm SHA256).Hash.ToLowerInvariant() -ne $rawHash){throw 'Raw image size/SHA-256 mismatch'}
        Publish-CacheFile $candidate $raw
      } finally {Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue}
    }
  } finally {$lock.Dispose()}
  $base=Join-Path $Build "fedora44-base-$diskBytes.vhdx"
  $fixed=Join-Path $Build "fedora44-base-$diskBytes.vhd"
  if(Test-Path $base){
    $v=Get-VHD -Path $base
    if($v.Size -ne $diskBytes -or $v.ParentPath){throw 'Cached base has unexpected size or parent'}
  } else {
    if(-not(Test-Path $fixed)){& "$PSScriptRoot/raw-to-vhd.ps1" -RawPath $raw -VhdPath $fixed}
    $part="$base.part.vhdx"
    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    Convert-VHD -Path $fixed -DestinationPath $part -VHDType Dynamic
    Resize-VHD -Path $part -SizeBytes $diskBytes
    [IO.File]::Move($part,$base)
  }
  $child=Join-Path $inst 'disk.vhdx'
  New-VHD -Path $child -ParentPath $base -Differencing | Out-Null
  New-VM -Name $name -Generation 2 -MemoryStartupBytes ($MemoryMB*1MB) -VHDPath $child -SwitchName $Switch | Out-Null
  $createdVm=$true
  Set-VMProcessor -VMName $name -Count $CpuCount -ExposeVirtualizationExtensions $true
  Set-VMFirmware -VMName $name -EnableSecureBoot Off
  if($DynamicMemory){Set-VMMemory -VMName $name -DynamicMemoryEnabled $true -MinimumBytes 1GB -StartupBytes ($MemoryMB*1MB) -MaximumBytes ($MemoryMB*1MB)}
  else {Set-VMMemory -VMName $name -DynamicMemoryEnabled $false}
  Add-VMDvdDrive -VMName $name -Path $SeedIso | Out-Null
  Set-Content -LiteralPath (Join-Path $inst 'creation-complete') -Value 'complete' -NoNewline
  Start-VM -Name $name | Out-Null
  Write-Host "Started $name; console: vmconnect.exe localhost $name"
} catch {
  $failure=$_
  if($createdVm){
    try {
      $current=Get-VM -Name $name -ErrorAction SilentlyContinue
      if($current -and $current.State -ne 'Off'){Stop-VM -Name $name -TurnOff -Force -ErrorAction Stop}
      Remove-VM -Name $name -Force -ErrorAction Stop
    } catch {Write-Warning "VM rollback failed; keep instance files and inspect ${name}: $_"}
  }
  if($part){Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue}
  if($ownedInstance){
    # A New-VM failure may still have registered a VM. Never delete its disk.
    $safeToRemove=$false
    try {$safeToRemove= -not (Get-VM -Name $name -ErrorAction Stop)} catch {
      if($_.CategoryInfo.Category -eq 'ObjectNotFound'){$safeToRemove=$true}
      else {Write-Warning 'Cannot confirm VM removal; keeping instance files'}
    }
    if($safeToRemove){Remove-Item -LiteralPath $inst -Recurse -Force -ErrorAction SilentlyContinue}
    else {Write-Warning "Instance retained at $inst; inspect the registered VM before manual cleanup"}
  }
  throw $failure
} finally {$buildLock.Dispose()}
