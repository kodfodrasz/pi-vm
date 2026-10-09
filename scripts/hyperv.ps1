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
        # The Azure archive expands to a fixed 5 GiB VHD plus its 512-byte footer while staged.
        @{ Path = $Settings.CacheDirectory; Bytes = 12GB }
        # Leave room for the converted parent and a new differencing disk.
        @{ Path = $Settings.BuildDirectory; Bytes = 20GB }
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

$azureFixedLength = 5368709632L
$azureVirtualSize = 5368709120L
$azureFixedSha256 = 'dd0c36585f1da3d19866804600e272428a381af9cc83b7fe6a1d4f9e72770835'

function Test-FixedVhd($Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Get-Item -LiteralPath $Path).Length -ne $azureFixedLength -or
        -not (Test-FileHash $Path $azureFixedSha256)) {
        return $false
    }
    try {
        $disk = Get-VHD -Path $Path
        return $disk.VhdFormat -eq 'VHD' -and
            $disk.VhdType -eq 'Fixed' -and
            [string]::IsNullOrEmpty([string]$disk.ParentPath) -and
            $disk.Size -eq $azureVirtualSize
    } catch {
        return $false
    }
}

function Get-VerifiedAzureImage($Settings) {
    $archive = Join-Path $Settings.CacheDirectory 'Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhdfixed.xz'
    # Keep the archive's .vhdfixed name, but use .vhd for native Hyper-V tools.
    $fixed = Join-Path $Settings.CacheDirectory 'Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhd'
    $url = 'https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhdfixed.xz'
    # Fedora-Cloud-44-1.7-x86_64-CHECKSUM, retrieved from Fedora's release mirror.
    $archiveHash = 'daa212a316a94d7a4584a704cad89dfd0bac45e70ee83c4212c095b3b8d55ce5'

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

        if (-not (Test-FixedVhd $fixed)) {
            $stage = Join-Path $Settings.CacheDirectory ('.azure-stage-' + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $stage | Out-Null
            try {
                if (-not (Get-Command 7z -ErrorAction SilentlyContinue)) {
                    throw 'Install 7-Zip and put 7z.exe in PATH'
                }
                & 7z x $archive "-o$stage" -y | Out-Null
                if ($LASTEXITCODE) {
                    throw '7-Zip decompression failed'
                }
                $candidate = Join-Path $stage (Split-Path $fixed -Leaf)
                $archiveImageName = [IO.Path]::GetFileNameWithoutExtension((Split-Path $archive -Leaf))
                $extracted = Join-Path $stage $archiveImageName
                if (-not (Test-Path -LiteralPath $extracted -PathType Leaf)) {
                    $extracted = $candidate
                }
                if ($extracted -ne $candidate) {
                    [IO.File]::Move($extracted, $candidate)
                }
                if (-not (Test-FixedVhd $candidate)) {
                    throw 'Decompressed Azure image is not a fixed VHD'
                }
                Move-FileIntoPlace $candidate $fixed
            } finally {
                Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } finally {
        $cacheLock.Dispose()
    }
    $fixed
}

function Publish-NewFile($Source, $Destination) {
    if (Test-Path -LiteralPath $Destination) {
        throw "Refusing to replace existing parent: $Destination"
    }
    [IO.File]::Move($Source, $Destination)
}

function Get-OrCreateBaseDisk($Settings, $Creation, $FixedPath) {
    if ($Settings.DiskBytes -lt $azureVirtualSize) {
        throw 'Disk size is smaller than the Azure source virtual size'
    }
    $base = Join-Path $Settings.BuildDirectory "fedora44-azure-base-$($Settings.DiskBytes).vhdx"
    if (Test-Path $base) {
        $disk = Get-VHD -Path $base
        if ($disk.Size -ne $Settings.DiskBytes -or $disk.ParentPath) {
            throw 'Cached Azure base has unexpected size or parent'
        }
        return $base
    }

    $Creation.PartialBase = "$base.part.vhdx"
    Remove-Item -LiteralPath $Creation.PartialBase -Force -ErrorAction SilentlyContinue
    Convert-VHD -Path $FixedPath -DestinationPath $Creation.PartialBase -VHDType Dynamic
    if ($Settings.DiskBytes -gt $azureVirtualSize) {
        Resize-VHD -Path $Creation.PartialBase -SizeBytes $Settings.DiskBytes
    }
    Publish-NewFile $Creation.PartialBase $base
    $Creation.PartialBase = $null
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

        $fixedPath = Get-VerifiedAzureImage $Settings
        $basePath = Get-OrCreateBaseDisk $Settings $creation $fixedPath
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
