[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('start', 'stop', 'status')]
    [string]$Action,
    [Parameter(Mandatory=$true)]
    [string]$Id,
    [string]$Cache = "$HOME/.cache/pi-vm/images",
    [string]$Build = "$PSScriptRoot/../build",
    [string]$Switch = 'Default Switch',
    [string]$SeedIso,
    [string]$Hostname = 'pipette',
    [int]$MemoryMB = 2048,
    [int]$CpuCount = 2,
    [string]$DiskSize = '16GiB',
    [switch]$Force,
    [switch]$DynamicMemory
)
$ErrorActionPreference = 'Stop'

function New-PiVmSettings {
    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,100}$') {
        throw 'Invalid instance id'
    }

    $buildDirectory = [IO.Path]::GetFullPath($Build)
    return [pscustomobject]@{
        InstanceId = $Id
        VmName = "pi-vm-$Id"
        InstanceDirectory = Join-Path $buildDirectory $Id
        BuildDirectory = $buildDirectory
        CacheDirectory = [IO.Path]::GetFullPath($Cache)
        SwitchName = $Switch
        SeedIso = $SeedIso
        Hostname = $Hostname
        MemoryMB = $MemoryMB
        CpuCount = $CpuCount
        DiskSize = $DiskSize
        DiskBytes = 0L
        Force = [bool]$Force
        DynamicMemory = [bool]$DynamicMemory
    }
}

function ConvertTo-DiskBytes($Size) {
    if ($Size -notmatch '^\s*(\d+(?:\.\d+)?)\s*(GB|GIB)\s*$') {
        throw 'Use a disk size such as 8GiB or 16GiB'
    }

    $unit = if ($Matches[2].ToUpperInvariant() -eq 'GIB') { 1GB } else { 1000000000L }
    $bytes = [Int64][Math]::Floor([double]$Matches[1] * [double]$unit)
    if ($bytes -lt 5368709120L -or $bytes % 1MB) {
        throw 'Disk size must be at least 5 GiB and aligned to 1 MiB'
    }
    return $bytes
}

function Assert-StartSettings($Settings) {
    if ($Settings.MemoryMB -lt 1024 -or $Settings.CpuCount -lt 1) {
        throw 'Use at least 1024 MiB RAM and one CPU'
    }
    if ($Settings.Hostname -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$') {
        throw 'Invalid hostname'
    }
    $Settings.DiskBytes = ConvertTo-DiskBytes $Settings.DiskSize

    if ($Settings.SeedIso) {
        if (-not [IO.Path]::IsPathRooted($Settings.SeedIso)) {
            throw 'The supplied -SeedIso must be an absolute path'
        }
        $Settings.SeedIso = [IO.Path]::GetFullPath($Settings.SeedIso)
        if (-not (Test-Path -LiteralPath $Settings.SeedIso -PathType Leaf)) {
            throw 'The supplied seed ISO does not exist'
        }
    }
}

function Restart-ExistingVm($Settings) {
    $existing = Get-VM -Name $Settings.VmName -ErrorAction SilentlyContinue
    if (-not $existing) {
        return $false
    }
    if ($Settings.Force) {
        throw 'Force cannot replace a registered VM. Remove the VM explicitly first.'
    }
    if ($existing.State -ne 'Off') {
        throw "VM is not stopped: $($Settings.VmName)"
    }
    $marker = Join-Path $Settings.InstanceDirectory 'creation-complete'
    if (-not (Test-Path $marker)) {
        throw "VM is registered but incomplete; inspect it before removing it: $($Settings.VmName)"
    }

    Start-VM -Name $Settings.VmName | Out-Null
    Write-Host "Restarted $($Settings.VmName) with its existing settings and disk"
    return $true
}

function Get-StorageVolumeForPath($Path) {
    $ancestor = $Path
    while (-not (Test-Path -LiteralPath $ancestor)) {
        $parent = Split-Path -Parent $ancestor
        if (-not $parent -or $parent -eq $ancestor) {
            throw "Cannot find storage volume for $Path"
        }
        $ancestor = $parent
    }

    $volume = Get-Volume -FilePath $ancestor -ErrorAction Stop
    if (-not $volume -or $null -eq $volume.SizeRemaining) {
        throw "Cannot check free space for $Path; use a local disk drive"
    }
    if (-not $volume.UniqueId) {
        throw 'Storage volume has no unique ID'
    }
    return $volume
}

function Assert-StorageCapacity($Settings) {
    $requirements = @(
        @{ Path = $Settings.CacheDirectory; Bytes = 8GB }
        @{ Path = $Settings.BuildDirectory; Bytes = 12GB }
    )
    $volumes = @{}
    foreach ($requirement in $requirements) {
        $volume = Get-StorageVolumeForPath $requirement.Path
        $volumeId = [string]$volume.UniqueId
        if (-not $volumes.ContainsKey($volumeId)) {
            $volumes[$volumeId] = @{ FreeBytes = [Int64]$volume.SizeRemaining; RequiredBytes = 0L }
        }
        $volumes[$volumeId].RequiredBytes += $requirement.Bytes
    }
    foreach ($volumeId in $volumes.Keys) {
        $capacity = $volumes[$volumeId]
        if ($capacity.FreeBytes -lt $capacity.RequiredBytes) {
            throw "Insufficient free space on $volumeId (need $($capacity.RequiredBytes / 1GB) GiB)"
        }
    }
}

function Assert-NewVmPrerequisites($Settings) {
    Get-VMSwitch -Name $Settings.SwitchName -ErrorAction Stop | Out-Null
    if ((Test-Path $Settings.InstanceDirectory) -and -not $Settings.Force) {
        throw 'Instance files exist; -Force explicitly recreates them'
    }
    Assert-StorageCapacity $Settings
}

function Initialize-StorageDirectories($Settings) {
    $directories = @($Settings.BuildDirectory, $Settings.CacheDirectory)
    New-Item -ItemType Directory -Force -Path $directories | Out-Null
}

function Open-BuildLock($Settings) {
    $path = Join-Path $Settings.BuildDirectory '.hyperv.lock'
    return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate,
                          [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}

function Assert-VmNotRegistered($Settings) {
    if (Get-VM -Name $Settings.VmName -ErrorAction SilentlyContinue) {
        throw "VM exists: $($Settings.VmName)"
    }
}

function Prepare-SeedIso($Settings) {
    if ($Settings.SeedIso) {
        return
    }
    $seedDirectory = Join-Path $Settings.BuildDirectory 'seeds'
    $Settings.SeedIso = Join-Path $seedDirectory "$($Settings.InstanceId).iso"
    if (-not (Test-Path -LiteralPath $Settings.SeedIso)) {
        New-Item -ItemType Directory -Force -Path $seedDirectory | Out-Null
        & "$PSScriptRoot/seed.ps1" -Id $Settings.InstanceId `
            -Hostname $Settings.Hostname -OutputIso $Settings.SeedIso
    }
}

function Prepare-InstanceDirectory($Settings, $Creation) {
    if (Test-Path $Settings.InstanceDirectory) {
        if (-not $Settings.Force) {
            throw 'Instance files exist; -Force explicitly recreates them'
        }
        Remove-Item -LiteralPath $Settings.InstanceDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Settings.InstanceDirectory | Out-Null
    $Creation.OwnedInstance = $true
}

function Get-FedoraImageSettings($CacheDirectory) {
    return [pscustomobject]@{
        ArchivePath = Join-Path $CacheDirectory 'Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw.xz'
        RawPath = Join-Path $CacheDirectory 'Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw'
        Url = 'https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw.xz'
        ArchiveHash = '7e4fb73907abdc761d226ddaf3263bdfca62a0b0bfb5f0798545a9981fdd1953'
        RawHash = 'ccf0412fa9e3f7d8ce8824e03e3c7369d0fef6dffb00a786a6bc9e895ccdb9ce'
        RawSize = 5368709120L
    }
}

function Test-FileHash($Path, $ExpectedHash) {
    return (Test-Path $Path) -and `
        (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $ExpectedHash
}

function Test-RawImage($Path, $Image) {
    return (Test-Path $Path) -and (Get-Item $Path).Length -eq $Image.RawSize -and `
        (Test-FileHash $Path $Image.RawHash)
}

# These APIs also work in Windows PowerShell 5.1.
function Move-FileIntoPlace($Source, $Destination) {
    if (Test-Path -LiteralPath $Destination) {
        [IO.File]::Replace($Source, $Destination, [NullString]::Value)
    } else {
        [IO.File]::Move($Source, $Destination)
    }
}

function Prepare-ImageArchive($Settings, $Image) {
    if (Test-FileHash $Image.ArchivePath $Image.ArchiveHash) {
        return
    }
    $download = Join-Path $Settings.CacheDirectory ('.download-' + [Guid]::NewGuid().ToString('N'))
    try {
        Invoke-WebRequest $Image.Url -OutFile $download -UseBasicParsing
        if (-not (Test-FileHash $download $Image.ArchiveHash)) {
            throw 'Compressed image SHA-256 mismatch'
        }
        Move-FileIntoPlace $download $Image.ArchivePath
    } finally {
        Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
    }
}

function Prepare-RawImage($Settings, $Image) {
    if (Test-RawImage $Image.RawPath $Image) {
        return
    }
    $stage = Join-Path $Settings.CacheDirectory ('.raw-stage-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        if (-not (Get-Command 7z -ErrorAction SilentlyContinue)) {
            throw 'Install 7-Zip and put 7z.exe in PATH'
        }
        & 7z x $Image.ArchivePath "-o$stage" -y | Out-Null
        if ($LASTEXITCODE) {
            throw '7-Zip decompression failed'
        }
        $candidate = Join-Path $stage (Split-Path $Image.RawPath -Leaf)
        if (-not (Test-RawImage $candidate $Image)) {
            throw 'Raw image size/SHA-256 mismatch'
        }
        Move-FileIntoPlace $candidate $Image.RawPath
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-VerifiedRawImage($Settings) {
    $image = Get-FedoraImageSettings $Settings.CacheDirectory
    $lockPath = Join-Path $Settings.CacheDirectory '.download.lock'
    $cacheLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
                               [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Prepare-ImageArchive $Settings $image
        Prepare-RawImage $Settings $image
    } finally {
        $cacheLock.Dispose()
    }
    return $image.RawPath
}

function Get-OrCreateBaseDisk($Settings, $Creation, $RawPath) {
    $base = Join-Path $Settings.BuildDirectory "fedora44-base-$($Settings.DiskBytes).vhdx"
    if (Test-Path $base) {
        $disk = Get-VHD -Path $base
        if ($disk.Size -ne $Settings.DiskBytes -or $disk.ParentPath) {
            throw 'Cached base has unexpected size or parent'
        }
        return $base
    }

    $fixed = Join-Path $Settings.BuildDirectory "fedora44-base-$($Settings.DiskBytes).vhd"
    if (-not (Test-Path $fixed)) {
        & "$PSScriptRoot/raw-to-vhd.ps1" -RawPath $RawPath -VhdPath $fixed
    }
    $Creation.PartialBase = "$base.part.vhdx"
    Remove-Item -LiteralPath $Creation.PartialBase -Force -ErrorAction SilentlyContinue
    Convert-VHD -Path $fixed -DestinationPath $Creation.PartialBase -VHDType Dynamic
    Resize-VHD -Path $Creation.PartialBase -SizeBytes $Settings.DiskBytes
    [IO.File]::Move($Creation.PartialBase, $base)
    return $base
}

function New-InstanceDisk($Settings, $BasePath) {
    $child = Join-Path $Settings.InstanceDirectory 'disk.vhdx'
    New-VHD -Path $child -ParentPath $BasePath -Differencing | Out-Null
    return $child
}

function Register-NewVm($Settings, $Creation, $DiskPath) {
    New-VM -Name $Settings.VmName -Generation 2 `
        -MemoryStartupBytes ($Settings.MemoryMB * 1MB) `
        -VHDPath $DiskPath -SwitchName $Settings.SwitchName | Out-Null
    # Only mark success after New-VM returns. Rollback also checks ambiguous failures.
    $Creation.CreatedVm = $true
}

function Configure-NewVm($Settings) {
    Set-VMProcessor -VMName $Settings.VmName -Count $Settings.CpuCount `
        -ExposeVirtualizationExtensions $true
    Set-VMFirmware -VMName $Settings.VmName -EnableSecureBoot Off
    if ($Settings.DynamicMemory) {
        Set-VMMemory -VMName $Settings.VmName -DynamicMemoryEnabled $true `
            -MinimumBytes 1GB -StartupBytes ($Settings.MemoryMB * 1MB) `
            -MaximumBytes ($Settings.MemoryMB * 1MB)
    } else {
        Set-VMMemory -VMName $Settings.VmName -DynamicMemoryEnabled $false
    }
    Add-VMDvdDrive -VMName $Settings.VmName -Path $Settings.SeedIso | Out-Null
}

function Complete-VmCreation($Settings) {
    $marker = Join-Path $Settings.InstanceDirectory 'creation-complete'
    Set-Content -LiteralPath $marker -Value 'complete' -NoNewline
}

function Start-CreatedVm($Settings) {
    Start-VM -Name $Settings.VmName | Out-Null
    Write-Host "Started $($Settings.VmName); console: vmconnect.exe localhost $($Settings.VmName)"
}

function Remove-CreatedVm($Settings) {
    try {
        $current = Get-VM -Name $Settings.VmName -ErrorAction SilentlyContinue
        if ($current -and $current.State -ne 'Off') {
            Stop-VM -Name $Settings.VmName -TurnOff -Force -ErrorAction Stop
        }
        Remove-VM -Name $Settings.VmName -Force -ErrorAction Stop
    } catch {
        Write-Warning "VM rollback failed; keep instance files and inspect $($Settings.VmName): $_"
    }
}

function Test-VmRegistrationAbsent($Settings) {
    try {
        return -not (Get-VM -Name $Settings.VmName -ErrorAction Stop)
    } catch {
        if ($_.CategoryInfo.Category -eq 'ObjectNotFound') {
            return $true
        }
        Write-Warning 'Cannot confirm VM removal; keeping instance files'
        return $false
    }
}

function Undo-VmCreation($Settings, $Creation) {
    if ($Creation.CreatedVm) {
        Remove-CreatedVm $Settings
    }
    if ($Creation.PartialBase) {
        Remove-Item -LiteralPath $Creation.PartialBase -Force -ErrorAction SilentlyContinue
    }
    if ($Creation.OwnedInstance) {
        # New-VM may have registered a VM even if it threw. Retain disks on uncertainty.
        if (Test-VmRegistrationAbsent $Settings) {
            Remove-Item -LiteralPath $Settings.InstanceDirectory -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Warning "Instance retained at $($Settings.InstanceDirectory); inspect the registered VM before manual cleanup"
        }
    }
}

function New-VmCreationState {
    return [pscustomobject]@{
        OwnedInstance = $false
        CreatedVm = $false
        PartialBase = $null
    }
}

function Start-NewVm($Settings) {
    Initialize-StorageDirectories $Settings
    $buildLock = Open-BuildLock $Settings
    $creation = New-VmCreationState
    try {
        Assert-VmNotRegistered $Settings
        Prepare-SeedIso $Settings
        Prepare-InstanceDirectory $Settings $creation
        $rawImagePath = Get-VerifiedRawImage $Settings
        $baseDiskPath = Get-OrCreateBaseDisk $Settings $creation $rawImagePath
        $instanceDiskPath = New-InstanceDisk $Settings $baseDiskPath
        Register-NewVm $Settings $creation $instanceDiskPath
        Configure-NewVm $Settings
        Complete-VmCreation $Settings
        Start-CreatedVm $Settings
    } catch {
        $failure = $_
        Undo-VmCreation $Settings $creation
        throw $failure
    } finally {
        $buildLock.Dispose()
    }
}

function Start-PiVm($Settings) {
    Assert-StartSettings $Settings
    if (Restart-ExistingVm $Settings) {
        return
    }
    Assert-NewVmPrerequisites $Settings
    Start-NewVm $Settings
}

function Show-PiVmStatus($Settings) {
    Get-VM -Name $Settings.VmName -ErrorAction SilentlyContinue |
        Select-Object Name, State, Status
}

function Stop-PiVm($Settings) {
    Stop-VM -Name $Settings.VmName -ErrorAction Stop
}

# Entry point: use the real module, resolve settings, then dispatch.
Import-Module Hyper-V -ErrorAction Stop
$settings = New-PiVmSettings
# Avoid a switch statement: its automatic $switch variable conflicts with
# the public -Switch parameter used to select a Hyper-V network.
if ($Action -eq 'start') {
    Start-PiVm $settings
} elseif ($Action -eq 'stop') {
    Stop-PiVm $settings
} else {
    Show-PiVmStatus $settings
}
