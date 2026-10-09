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

function Get-PiVmSettings {
    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,100}$') {
        throw 'Invalid instance id'
    }

    $buildDirectory = [IO.Path]::GetFullPath($Build)
    [pscustomobject]@{
        Id = $Id
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
    $bytes
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

function Get-StorageVolume($Path) {
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
    $volume
}

function Assert-StorageCapacity($Settings) {
    $required = @{}
    foreach ($item in @(
        @{ Path = $Settings.CacheDirectory; Bytes = 8GB }
        @{ Path = $Settings.BuildDirectory; Bytes = 12GB }
    )) {
        $volume = Get-StorageVolume $item.Path
        $volumeId = [string]$volume.UniqueId
        if (-not $required.ContainsKey($volumeId)) {
            $required[$volumeId] = @{
                FreeBytes = [Int64]$volume.SizeRemaining
                RequiredBytes = 0L
            }
        }
        $required[$volumeId].RequiredBytes += $item.Bytes
    }

    foreach ($volumeId in $required.Keys) {
        $capacity = $required[$volumeId]
        if ($capacity.FreeBytes -lt $capacity.RequiredBytes) {
            throw "Insufficient free space on $volumeId (need $($capacity.RequiredBytes / 1GB) GiB)"
        }
    }
}

function Move-FileIntoPlace($Source, $Destination) {
    # These overloads work in Windows PowerShell 5.1.
    if (Test-Path -LiteralPath $Destination) {
        [IO.File]::Replace($Source, $Destination, [NullString]::Value)
    } else {
        [IO.File]::Move($Source, $Destination)
    }
}

function Test-FileHash($Path, $ExpectedHash) {
    (Test-Path $Path) -and
        (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $ExpectedHash
}

function Get-VerifiedRawImage($Settings) {
    $archive = Join-Path $Settings.CacheDirectory 'Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw.xz'
    $raw = Join-Path $Settings.CacheDirectory 'Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw'
    $url = 'https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw.xz'
    $archiveHash = '7e4fb73907abdc761d226ddaf3263bdfca62a0b0bfb5f0798545a9981fdd1953'
    $rawHash = 'ccf0412fa9e3f7d8ce8824e03e3c7369d0fef6dffb00a786a6bc9e895ccdb9ce'
    $rawSize = 5368709120L

    $lockPath = Join-Path $Settings.CacheDirectory '.download.lock'
    $cacheLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
                                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        if (-not (Test-FileHash $archive $archiveHash)) {
            $download = Join-Path $Settings.CacheDirectory ('.download-' + [Guid]::NewGuid().ToString('N'))
            try {
                Invoke-WebRequest $url -OutFile $download -UseBasicParsing
                if (-not (Test-FileHash $download $archiveHash)) {
                    throw 'Compressed image SHA-256 mismatch'
                }
                Move-FileIntoPlace $download $archive
            } finally {
                Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
            }
        }

        $rawIsValid = (Test-Path $raw) -and (Get-Item $raw).Length -eq $rawSize
        if ($rawIsValid) {
            $rawIsValid = Test-FileHash $raw $rawHash
        }
        if (-not $rawIsValid) {
            $stage = Join-Path $Settings.CacheDirectory ('.raw-stage-' + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $stage | Out-Null
            try {
                if (-not (Get-Command 7z -ErrorAction SilentlyContinue)) {
                    throw 'Install 7-Zip and put 7z.exe in PATH'
                }
                & 7z x $archive "-o$stage" -y | Out-Null
                if ($LASTEXITCODE) {
                    throw '7-Zip decompression failed'
                }
                $candidate = Join-Path $stage (Split-Path $raw -Leaf)
                $candidateIsValid = (Test-Path $candidate) -and
                    (Get-Item $candidate).Length -eq $rawSize -and
                    (Test-FileHash $candidate $rawHash)
                if (-not $candidateIsValid) {
                    throw 'Raw image size/SHA-256 mismatch'
                }
                Move-FileIntoPlace $candidate $raw
            } finally {
                Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } finally {
        $cacheLock.Dispose()
    }
    $raw
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
    $base
}

function Configure-Vm($Settings, $Creation, $DiskPath) {
    New-VM -Name $Settings.VmName -Generation 2 `
        -MemoryStartupBytes ($Settings.MemoryMB * 1MB) `
        -VHDPath $DiskPath -SwitchName $Settings.SwitchName | Out-Null
    $Creation.RegisteredVm = $true

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

function Undo-VmCreation($Settings, $Creation) {
    if ($Creation.RegisteredVm) {
        try {
            $vm = Get-VM -Name $Settings.VmName -ErrorAction SilentlyContinue
            if ($vm -and $vm.State -ne 'Off') {
                Stop-VM -Name $Settings.VmName -TurnOff -Force -ErrorAction Stop
            }
            Remove-VM -Name $Settings.VmName -Force -ErrorAction Stop
        } catch {
            Write-Warning "VM rollback failed; keep instance files and inspect $($Settings.VmName): $_"
        }
    }
    if ($Creation.PartialBase) {
        Remove-Item -LiteralPath $Creation.PartialBase -Force -ErrorAction SilentlyContinue
    }
    if (-not $Creation.OwnedInstance) {
        return
    }

    # New-VM may register a VM before it reports failure. Keep disks unless absence is certain.
    $safeToRemove = $false
    try {
        $safeToRemove = -not (Get-VM -Name $Settings.VmName -ErrorAction Stop)
    } catch {
        if ($_.CategoryInfo.Category -eq 'ObjectNotFound') {
            $safeToRemove = $true
        } else {
            Write-Warning 'Cannot confirm VM removal; keeping instance files'
        }
    }
    if ($safeToRemove) {
        Remove-Item -LiteralPath $Settings.InstanceDirectory -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Warning "Instance retained at $($Settings.InstanceDirectory); inspect the registered VM before manual cleanup"
    }
}

function New-PiVm($Settings) {
    New-Item -ItemType Directory -Force `
        -Path $Settings.BuildDirectory, $Settings.CacheDirectory | Out-Null
    $lockPath = Join-Path $Settings.BuildDirectory '.hyperv.lock'
    $buildLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
                                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $creation = [pscustomobject]@{
        OwnedInstance = $false
        RegisteredVm = $false
        PartialBase = $null
    }

    try {
        if (Get-VM -Name $Settings.VmName -ErrorAction SilentlyContinue) {
            throw "VM exists: $($Settings.VmName)"
        }

        if (-not $Settings.SeedIso) {
            $seedDirectory = Join-Path $Settings.BuildDirectory 'seeds'
            $Settings.SeedIso = Join-Path $seedDirectory "$($Settings.Id).iso"
            if (-not (Test-Path -LiteralPath $Settings.SeedIso)) {
                New-Item -ItemType Directory -Force -Path $seedDirectory | Out-Null
                & "$PSScriptRoot/seed.ps1" -Id $Settings.Id `
                    -Hostname $Settings.Hostname -OutputIso $Settings.SeedIso
            }
        }

        if (Test-Path $Settings.InstanceDirectory) {
            if (-not $Settings.Force) {
                throw 'Instance files exist; -Force explicitly recreates them'
            }
            Remove-Item -LiteralPath $Settings.InstanceDirectory -Recurse -Force
        }
        New-Item -ItemType Directory -Path $Settings.InstanceDirectory | Out-Null
        $creation.OwnedInstance = $true

        $rawPath = Get-VerifiedRawImage $Settings
        $basePath = Get-OrCreateBaseDisk $Settings $creation $rawPath
        $childPath = Join-Path $Settings.InstanceDirectory 'disk.vhdx'
        New-VHD -Path $childPath -ParentPath $basePath -Differencing | Out-Null

        Configure-Vm $Settings $creation $childPath
        $marker = Join-Path $Settings.InstanceDirectory 'creation-complete'
        Set-Content -LiteralPath $marker -Value 'complete' -NoNewline
        Start-VM -Name $Settings.VmName | Out-Null
        Write-Host "Started $($Settings.VmName); console: vmconnect.exe localhost $($Settings.VmName)"
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

    $existing = Get-VM -Name $Settings.VmName -ErrorAction SilentlyContinue
    if ($existing) {
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
        return
    }

    Get-VMSwitch -Name $Settings.SwitchName -ErrorAction Stop | Out-Null
    if ((Test-Path $Settings.InstanceDirectory) -and -not $Settings.Force) {
        throw 'Instance files exist; -Force explicitly recreates them'
    }
    Assert-StorageCapacity $Settings
    New-PiVm $Settings
}

Import-Module Hyper-V -ErrorAction Stop
$settings = Get-PiVmSettings
if ($Action -eq 'start') {
    Start-PiVm $settings
} elseif ($Action -eq 'stop') {
    Stop-VM -Name $settings.VmName -ErrorAction Stop
} else {
    Get-VM -Name $settings.VmName -ErrorAction SilentlyContinue |
        Select-Object Name, State, Status
}
