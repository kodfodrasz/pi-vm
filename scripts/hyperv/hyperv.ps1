[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('start', 'stop', 'status', 'delete')]
    [string]$Action,
    [Parameter(Mandatory=$true)]
    [string]$Id,
    [string]$Cache = (Join-Path $HOME '.cache/pi-vm/images'),
    [string]$Build = (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path '..' 'build'))),
    [string]$Switch = 'Default Switch',
    [string]$SeedIso,
    [int]$MemoryMB = 2048,
    [int]$MinimumMemoryMB = 1024,
    [Nullable[int]]$MaximumMemoryMB,
    [int]$CpuCount = 2,
    [string]$DiskSize = '16GiB',
    [switch]$Force,
    [switch]$DynamicMemory
)
$ErrorActionPreference = 'Stop'
$script:IsWindowsPlatform = [Environment]::OSVersion.Platform -eq 'Win32NT'

function ConvertTo-FullyQualifiedPath($Path, $Label) {
    if (-not $Path) {
        throw "$Label path is required"
    }
    if ($script:IsWindowsPlatform) {
        if ($Path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))') {
            throw "$Label must be an absolute path (fully qualified drive or UNC path)"
        }
    } elseif (-not [IO.Path]::IsPathRooted($Path)) {
        throw "$Label must be an absolute path"
    }
    [IO.Path]::GetFullPath($Path)
}

function Get-CanonicalComparisonPath($Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($script:IsWindowsPlatform) {
        $full = $full.Replace('/', '\')
    }
    while ($full.Length -gt 1 -and ($full.EndsWith('\') -or $full.EndsWith('/'))) {
        if ($script:IsWindowsPlatform -and $full -match '^[A-Za-z]:[\\/]$') {
            break
        }
        $full = $full.Substring(0, $full.Length - 1)
    }
    $full
}

function Test-PathEqualOrDescendant($Candidate, $Root) {
    $candidatePath = Get-CanonicalComparisonPath $Candidate
    $rootPath = Get-CanonicalComparisonPath $Root
    if ($candidatePath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($rootPath.EndsWith('\') -or $rootPath.EndsWith('/')) {
        return $candidatePath.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)
    }
    return $candidatePath.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)
}

function Get-CanonicalGuid($Value, $Label) {
    try {
        return ([Guid]$Value).ToString('D')
    } catch {
        throw "$Label is not a valid GUID"
    }
}

function Assert-NoReparseAncestors($Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        try {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing reparse-point path or ancestor: $cursor"
            }
        } catch {
            if ($_.CategoryInfo.Category -ne 'ObjectNotFound') {
                throw
            }
        }
        $parent = Split-Path -Parent $cursor
        if (-not $parent -or $parent -eq $cursor) {
            break
        }
        $cursor = $parent
    }
}

function Test-NoReparsePath($Path) {
    try {
        Assert-NoReparseAncestors $Path
        return $true
    } catch {
        return $false
    }
}

function Test-TrustedExecutableFile($Path) {
    if (-not $Path) {
        return $false
    }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return $false
        }
        Assert-NoReparseAncestors $Path
        return $true
    } catch {
        return $false
    }
}

function Resolve-7ZipExecutable {
    $command = Get-Command 7z.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command -and (Test-TrustedExecutableFile $command.Path)) {
        return [IO.Path]::GetFullPath($command.Path)
    }

    foreach ($programFiles in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $programFiles) {
            continue
        }
        $candidate = Join-Path $programFiles '7-Zip\7z.exe'
        if (Test-TrustedExecutableFile $candidate) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    throw 'Install 7-Zip, or add 7z.exe to PATH; no usable 7z.exe was found'
}

function Get-PiVmSettings {
    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,100}$') {
        throw 'Invalid instance id'
    }

    $buildDirectory = ConvertTo-FullyQualifiedPath $Build 'Build'
    $cacheDirectory = ConvertTo-FullyQualifiedPath $Cache 'Cache'
    $instanceDirectory = ConvertTo-FullyQualifiedPath (Join-Path $buildDirectory $Id) 'Instance'
    if (Test-PathEqualOrDescendant $cacheDirectory $instanceDirectory) {
        throw 'Cache directory must not equal or be inside the instance directory'
    }
    Assert-NoReparseAncestors $buildDirectory
    Assert-NoReparseAncestors $cacheDirectory
    [pscustomobject]@{
        Id = $Id
        VmName = "pi-vm-$Id"
        InstanceDirectory = $instanceDirectory
        BuildDirectory = $buildDirectory
        CacheDirectory = $cacheDirectory
        SwitchName = $Switch
        SeedIso = $SeedIso
        MemoryMB = $MemoryMB
        MinimumMemoryMB = $MinimumMemoryMB
        MaximumMemoryMB = if ($null -eq $MaximumMemoryMB) { $MemoryMB } else { $MaximumMemoryMB }
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
    if ($Settings.DynamicMemory -and
        ($Settings.MinimumMemoryMB -lt 1024 -or
         $Settings.MinimumMemoryMB -gt $Settings.MemoryMB -or
         $Settings.MemoryMB -gt $Settings.MaximumMemoryMB)) {
        throw 'Dynamic memory requires 1024 <= minimum <= startup <= maximum MiB'
    }
    $Settings.DiskBytes = ConvertTo-DiskBytes $Settings.DiskSize

    if (-not $Settings.SeedIso) {
        throw 'A supplied -SeedIso absolute path is required for new VM creation'
    }
    $Settings.SeedIso = ConvertTo-FullyQualifiedPath $Settings.SeedIso 'Seed ISO'
    Assert-NoReparseAncestors $Settings.SeedIso
    if (-not (Test-Path -LiteralPath $Settings.SeedIso -PathType Leaf) -or
        -not (Test-NoReparsePath $Settings.SeedIso) -or
        (Get-Item -LiteralPath $Settings.SeedIso).Length -eq 0) {
        throw 'The supplied seed ISO must be an existing nonempty file'
    }
}

function Assert-StorageCapacity($Settings) {
    $required = @{}
    foreach ($item in @(
        @{ Path = $Settings.CacheDirectory; Bytes = 12GB }
        @{ Path = $Settings.BuildDirectory; Bytes = 20GB }
    )) {
        $ancestor = $item.Path
        while (-not (Test-Path -LiteralPath $ancestor)) {
            $parent = Split-Path -Parent $ancestor
            if (-not $parent -or $parent -eq $ancestor) {
                throw "Cannot find storage volume for $($item.Path)"
            }
            $ancestor = $parent
        }
        $volume = Get-Volume -FilePath $ancestor -ErrorAction Stop
        if (-not $volume -or $null -eq $volume.SizeRemaining -or -not $volume.UniqueId) {
            throw "Cannot check free space for $($item.Path)"
        }
        $volumeId = [string]$volume.UniqueId
        if (-not $required.ContainsKey($volumeId)) {
            $required[$volumeId] = @{ FreeBytes = [Int64]$volume.SizeRemaining; RequiredBytes = 0L }
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
    Assert-NoReparseAncestors $Source
    Assert-NoReparseAncestors $Destination
    if (Test-Path -LiteralPath $Destination) {
        [IO.File]::Replace($Source, $Destination, [NullString]::Value)
    } else {
        [IO.File]::Move($Source, $Destination)
    }
}

function Test-FileHash($Path, $ExpectedHash) {
    Assert-NoReparseAncestors $Path
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $ExpectedHash
}

$azureFixedLength = 5368709632L
$azureVirtualSize = 5368709120L
$azureFixedSha256 = 'dd0c36585f1da3d19866804600e272428a381af9cc83b7fe6a1d4f9e72770835'

function Test-FixedVhd($Path) {
    Assert-NoReparseAncestors $Path
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

function Get-VerifiedAzureImage($Settings, $SevenZipPath) {
    $archive = Join-Path $Settings.CacheDirectory 'Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhdfixed.xz'
    $fixed = Join-Path $Settings.CacheDirectory 'Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhd'
    $url = 'https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhdfixed.xz'
    $archiveHash = 'daa212a316a94d7a4584a704cad89dfd0bac45e70ee83c4212c095b3b8d55ce5'
    $fixedValid = Test-FixedVhd $fixed
    if (-not $fixedValid -and -not $SevenZipPath) {
        $SevenZipPath = Resolve-7ZipExecutable
    }

    $lockPath = Join-Path $Settings.CacheDirectory '.download.lock'
    Assert-NoReparseAncestors $lockPath
    $cacheLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
                                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Assert-NoReparseAncestors $archive
        Assert-NoReparseAncestors $fixed
        if (-not (Test-FileHash $archive $archiveHash)) {
            $download = Join-Path $Settings.CacheDirectory ('.download-' + [Guid]::NewGuid().ToString('N'))
            Assert-NoReparseAncestors $download
            try {
                Invoke-WebRequest $url -OutFile $download -UseBasicParsing
                if (-not (Test-FileHash $download $archiveHash)) {
                    throw 'Compressed image SHA-256 mismatch'
                }
                Move-FileIntoPlace $download $archive
            } finally {
                Assert-NoReparseAncestors $download
                Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
            }
        }

        if (-not $fixedValid) {
            $stage = Join-Path $Settings.CacheDirectory ('.azure-stage-' + [Guid]::NewGuid().ToString('N'))
            Assert-NoReparseAncestors $stage
            New-Item -ItemType Directory -Path $stage | Out-Null
            try {
                & $SevenZipPath x $archive "-o$stage" -y | Out-Null
                $extractExitCode = $LASTEXITCODE
                if ($extractExitCode -ne 0) {
                    throw '7-Zip decompression failed'
                }
                $extracted = Join-Path $stage 'Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhdfixed'
                Assert-NoReparseAncestors $extracted
                if (-not (Test-Path -LiteralPath $extracted -PathType Leaf)) {
                    throw '7-Zip archive did not contain the expected fixed VHD'
                }
                $candidate = Join-Path $stage 'candidate.vhd'
                Assert-NoReparseAncestors $candidate
                [IO.File]::Move($extracted, $candidate)
                if (-not (Test-FixedVhd $candidate)) {
                    throw 'Decompressed Azure image is not a fixed VHD'
                }
                Move-FileIntoPlace $candidate $fixed
            } finally {
                Assert-NoReparseAncestors $stage
                Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } finally {
        $cacheLock.Dispose()
    }
    $fixed
}

function Publish-NewFile($Source, $Destination) {
    Assert-NoReparseAncestors $Source
    Assert-NoReparseAncestors $Destination
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
    Assert-NoReparseAncestors $base
    if (Test-Path -LiteralPath $base) {
        $disk = Get-VHD -Path $base
        if ($disk.Size -ne $Settings.DiskBytes -or $disk.ParentPath) {
            throw 'Cached Azure base has unexpected size or parent'
        }
        return $base
    }

    $Creation.PartialBase = "$base.part.vhdx"
    Assert-NoReparseAncestors $Creation.PartialBase
    Remove-Item -LiteralPath $Creation.PartialBase -Force -ErrorAction SilentlyContinue
    Convert-VHD -Path $FixedPath -DestinationPath $Creation.PartialBase -VHDType Dynamic
    if ($Settings.DiskBytes -gt $azureVirtualSize) {
        Resize-VHD -Path $Creation.PartialBase -SizeBytes $Settings.DiskBytes
    }
    Publish-NewFile $Creation.PartialBase $base
    $Creation.PartialBase = $null
    $base
}

function Write-OwnershipMetadata($Settings, $Vm, $ChildPath, $ParentPath, $PreexistingFiles, $InstanceDirectoryCreated) {
    $metadata = [ordered]@{
        Version = 2
        VmId = Get-CanonicalGuid $Vm.Id 'New VM ID'
        Id = $Settings.Id
        VmName = $Settings.VmName
        InstanceDirectory = [IO.Path]::GetFullPath($Settings.InstanceDirectory)
        InstanceDirectoryCreated = [bool]$InstanceDirectoryCreated
        ChildPath = [IO.Path]::GetFullPath($ChildPath)
        ParentPath = [IO.Path]::GetFullPath($ParentPath)
        SeedIso = [IO.Path]::GetFullPath($Settings.SeedIso)
        PreexistingFiles = @($PreexistingFiles)
    }
    Assert-NoReparseAncestors $ChildPath
    Assert-NoReparseAncestors $ParentPath
    Assert-NoReparseAncestors $Settings.SeedIso
    $path = Join-Path $Settings.InstanceDirectory 'ownership.json'
    Assert-NoReparseAncestors $path
    $temporary = "$path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $metadata | ConvertTo-Json -Compress | Set-Content -LiteralPath $temporary -Encoding UTF8 -NoNewline
        Move-FileIntoPlace $temporary $path
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Test-ManagedInstanceName($Name) {
    $Name -ieq 'disk.vhdx' -or $Name -ieq 'ownership.json' -or $Name -ieq 'creation-complete'
}

function Get-PreexistingInstanceFiles($Settings) {
    Assert-NoReparseAncestors $Settings.InstanceDirectory
    if (-not (Test-Path -LiteralPath $Settings.InstanceDirectory -PathType Container)) {
        return @()
    }

    $files = @()
    foreach ($entry in @(Get-ChildItem -LiteralPath $Settings.InstanceDirectory -Force)) {
        if ($entry.PSIsContainer -or -not (Test-NoReparsePath $entry.FullName)) {
            throw 'Instance directory contains a directory, non-regular file, or reparse point'
        }
        if (Test-ManagedInstanceName $entry.Name) {
            throw "Instance directory contains reserved managed file: $($entry.Name)"
        }
        $files += $entry.Name
    }
    return $files
}

function Get-ValidatedPreexistingFiles($Metadata) {
    if ($null -eq $Metadata.PreexistingFiles) {
        return @()
    }
    $files = @($Metadata.PreexistingFiles)
    if ($files.Count -eq 0 -or ($files.Count -eq 1 -and $null -eq $files[0])) {
        return @()
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $files) {
        if (($name -isnot [string]) -or [string]::IsNullOrEmpty($name) -or
            ($name -match '[\\/]') -or ($name -eq '.') -or ($name -eq '..') -or
            (Test-ManagedInstanceName $name) -or (-not $seen.Add($name))) {
            throw 'VM ownership preexisting-file list is invalid'
        }
    }
    return $files
}

function Get-OwnedVmDiskPath($Vm) {
    if (Get-Command Get-VMHardDiskDrive -ErrorAction SilentlyContinue) {
        $drives = @(Get-VMHardDiskDrive -VM $Vm -ErrorAction Stop)
        if ($drives.Count -ne 1) {
            throw 'Managed VM must have exactly one hard disk'
        }
        return [IO.Path]::GetFullPath([string]$drives[0].Path)
    }
    return [IO.Path]::GetFullPath([string]$Vm.Disk)
}

function Assert-ManagedOwnership($Settings, $Vm) {
    if (-not $Vm -or $Vm.Name -cne $Settings.VmName) {
        throw 'Registered VM name does not match the requested instance'
    }
    $registeredId = Get-CanonicalGuid $Vm.Id 'Registered VM ID'
    $directory = ConvertTo-FullyQualifiedPath $Settings.InstanceDirectory 'Instance'
    Assert-NoReparseAncestors $directory

    $marker = Join-Path $directory 'creation-complete'
    $metadataPath = Join-Path $directory 'ownership.json'
    Assert-NoReparseAncestors $marker
    Assert-NoReparseAncestors $metadataPath
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
        (Get-Content -LiteralPath $marker -Raw) -cne 'complete' -or
        -not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw 'VM ownership marker is missing or incomplete'
    }
    try {
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    } catch {
        throw 'VM ownership metadata is invalid'
    }

    $metadataId = Get-CanonicalGuid $metadata.VmId 'Recorded VM ID'
    if ($metadata.Version -ne 2 -or
        $metadataId -cne $registeredId -or
        $metadata.Id -cne $Settings.Id -or
        $metadata.VmName -cne $Settings.VmName -or
        (ConvertTo-FullyQualifiedPath $metadata.InstanceDirectory 'Recorded instance') -ine $directory) {
        throw 'VM ownership identity does not match this exact registration'
    }
    $preexistingFiles = Get-ValidatedPreexistingFiles $metadata
    $instanceDirectoryCreated = $true
    if ($null -ne $metadata.InstanceDirectoryCreated) {
        if ($metadata.InstanceDirectoryCreated -isnot [bool]) {
            throw 'VM ownership directory provenance is invalid'
        }
        $instanceDirectoryCreated = [bool]$metadata.InstanceDirectoryCreated
    }

    $child = ConvertTo-FullyQualifiedPath $metadata.ChildPath 'Recorded child disk'
    $expectedChild = ConvertTo-FullyQualifiedPath (Join-Path $directory 'disk.vhdx') 'Child disk'
    Assert-NoReparseAncestors $child
    Assert-NoReparseAncestors $expectedChild
    if ($child -ine $expectedChild -or -not (Test-Path -LiteralPath $child -PathType Leaf)) {
        throw 'VM ownership child disk does not match the recorded identity'
    }

    $parent = ConvertTo-FullyQualifiedPath $metadata.ParentPath 'Recorded parent disk'
    Assert-NoReparseAncestors $parent
    if (-not (Test-Path -LiteralPath $parent -PathType Leaf) -or
        [IO.Path]::GetExtension($parent) -ine '.vhdx' -or
        [IO.Path]::GetDirectoryName($parent) -ine $Settings.BuildDirectory -or
        $parent.StartsWith($directory, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'VM ownership parent disk is unsafe'
    }

    $seed = ConvertTo-FullyQualifiedPath $metadata.SeedIso 'Recorded seed ISO'
    Assert-NoReparseAncestors $seed
    $registeredDisk = Get-OwnedVmDiskPath $Vm
    if ($registeredDisk -ine $expectedChild) {
        throw 'Registered VM disk does not match the managed child'
    }
    $childInfo = Get-VHD -Path $expectedChild
    if ([IO.Path]::GetFullPath([string]$childInfo.ParentPath) -ine $parent) {
        throw 'Managed child does not reference the recorded immutable parent'
    }
    [pscustomobject]@{
        Metadata = $metadata
        Vm = $Vm
        Child = $expectedChild
        Parent = $parent
        PreexistingFiles = $preexistingFiles
        InstanceDirectoryCreated = $instanceDirectoryCreated
    }
}

function Assert-ManagedInstanceLayout($Settings, $Ownership) {
    Assert-NoReparseAncestors $Settings.InstanceDirectory
    $expected = @{
        'disk.vhdx' = $Ownership.Child
        'ownership.json' = Join-Path $Settings.InstanceDirectory 'ownership.json'
        'creation-complete' = Join-Path $Settings.InstanceDirectory 'creation-complete'
    }
    $allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $expected.Keys) {
        $null = $allowed.Add($name)
    }
    foreach ($name in $Ownership.PreexistingFiles) {
        if (-not $allowed.Add($name)) {
            throw 'VM ownership preexisting-file list overlaps managed files'
        }
    }
    $entries = @(Get-ChildItem -LiteralPath $Settings.InstanceDirectory -Force)
    if ($entries.Count -ne $allowed.Count) {
        throw 'Instance directory contains unmanaged files; no lifecycle action was taken'
    }
    foreach ($entry in $entries) {
        if (-not $allowed.Contains($entry.Name) -or $entry.PSIsContainer -or
            -not (Test-NoReparsePath $entry.FullName)) {
            throw 'Instance directory contains unmanaged or unsafe files; no lifecycle action was taken'
        }
    }
    foreach ($path in $expected.Values) {
        Assert-NoReparseAncestors $path
    }
}

function Configure-Vm($Settings, $Creation, $DiskPath) {
    $vm = New-VM -Name $Settings.VmName -Generation 2 `
        -MemoryStartupBytes ($Settings.MemoryMB * 1MB) `
        -VHDPath $DiskPath -SwitchName $Settings.SwitchName
    if (-not $vm -or -not $vm.Id) {
        throw 'New-VM did not return a VM identity'
    }
    $Creation.Vm = $vm
    $Creation.RegisteredVm = $true

    Set-VM -VM $vm -CheckpointType ProductionOnly
    $guestService = @(Get-VMIntegrationService -VM $vm |
        Where-Object { $_.Name -ceq 'Guest Service Interface' })
    if ($guestService.Count -ne 1) {
        throw 'Guest Service Interface integration service was not found'
    }
    if (-not $guestService[0].Enabled) {
        Enable-VMIntegrationService -VMIntegrationService $guestService[0]
    }

    Set-VMProcessor -VM $vm -Count $Settings.CpuCount `
        -ExposeVirtualizationExtensions $true
    Set-VMFirmware -VM $vm -EnableSecureBoot Off
    if ($Settings.DynamicMemory) {
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $true `
            -MinimumBytes ($Settings.MinimumMemoryMB * 1MB) `
            -StartupBytes ($Settings.MemoryMB * 1MB) `
            -MaximumBytes ($Settings.MaximumMemoryMB * 1MB)
    } else {
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $false
    }
    Add-VMDvdDrive -VM $vm -Path $Settings.SeedIso
    $vm
}

function Remove-CreatedManagedFilesSafely($Settings, $Creation) {
    Assert-NoReparseAncestors $Settings.InstanceDirectory
    foreach ($path in $Creation.CreatedManagedFiles) {
        Assert-NoReparseAncestors $path
        if (Test-Path -LiteralPath $path) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
                -not (Test-NoReparsePath $path)) {
                throw 'Creation rollback found an unmanaged or reparse-point entry; manual cleanup required'
            }
            Remove-Item -LiteralPath $path -Force
        }
    }
    if ($Creation.NewInstanceDirectory -and
        (Test-Path -LiteralPath $Settings.InstanceDirectory -PathType Container) -and
        @(Get-ChildItem -LiteralPath $Settings.InstanceDirectory -Force).Count -eq 0) {
        Remove-Item -LiteralPath $Settings.InstanceDirectory -Force
    }
}

function Undo-VmCreation($Settings, $Creation) {
    if ($Creation.RegisteredVm -and $Creation.Vm) {
        try {
            $vm = $Creation.Vm
            if ($vm.State -ne 'Off') {
                Stop-VM -VM $vm -TurnOff -Force -ErrorAction Stop
            }
            Remove-VM -VM $vm -Force -ErrorAction Stop
        } catch {
            Write-Warning "VM rollback failed; keep instance files and inspect $($Settings.VmName): $_"
        }
    }
    if ($Creation.PartialBase) {
        Remove-Item -LiteralPath $Creation.PartialBase -Force -ErrorAction SilentlyContinue
    }
    if (-not $Creation.OwnedInstance -or $Creation.RegistrationAttempted -and -not $Creation.RegisteredVm) {
        if ($Creation.RegistrationAttempted -and -not $Creation.RegisteredVm) {
            Write-Warning "VM registration is ambiguous; keeping instance files and inspect $($Settings.VmName)"
        }
        return
    }

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
        try {
            Remove-CreatedManagedFilesSafely $Settings $Creation
        } catch {
            Write-Warning "Instance retained at $($Settings.InstanceDirectory); inspect rollback entries before manual cleanup: $_"
        }
    } else {
        Write-Warning "Instance retained at $($Settings.InstanceDirectory); inspect the registered VM before manual cleanup"
    }
}

function New-PiVm($Settings, $SevenZipPath) {
    Assert-NoReparseAncestors $Settings.InstanceDirectory
    $instanceExists = Test-Path -LiteralPath $Settings.InstanceDirectory
    if ($instanceExists -and -not (Test-Path -LiteralPath $Settings.InstanceDirectory -PathType Container)) {
        throw 'Instance path exists but is not a directory'
    }
    $preexistingFiles = if ($instanceExists) {
        Get-PreexistingInstanceFiles $Settings
    } else {
        @()
    }

    New-Item -ItemType Directory -Force -Path $Settings.BuildDirectory, $Settings.CacheDirectory | Out-Null
    $lockPath = Join-Path $Settings.BuildDirectory '.hyperv.lock'
    Assert-NoReparseAncestors $lockPath
    $buildLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
                                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    Assert-NoReparseAncestors $Settings.BuildDirectory
    Assert-NoReparseAncestors $Settings.CacheDirectory
    $creation = [pscustomobject]@{
        OwnedInstance = $false
        NewInstanceDirectory = $false
        RegisteredVm = $false
        RegistrationAttempted = $false
        Vm = $null
        PartialBase = $null
        CreatedManagedFiles = [Collections.Generic.List[string]]::new()
        PreexistingFiles = $preexistingFiles
    }

    try {
        if (Get-VM -Name $Settings.VmName -ErrorAction SilentlyContinue) {
            throw "VM exists: $($Settings.VmName)"
        }
        if (-not $instanceExists) {
            Assert-NoReparseAncestors $Settings.InstanceDirectory
            New-Item -ItemType Directory -Path $Settings.InstanceDirectory | Out-Null
            $creation.NewInstanceDirectory = $true
        }
        $creation.OwnedInstance = $true

        $fixedPath = Get-VerifiedAzureImage $Settings $SevenZipPath
        $basePath = Get-OrCreateBaseDisk $Settings $creation $fixedPath
        $childPath = Join-Path $Settings.InstanceDirectory 'disk.vhdx'
        Assert-NoReparseAncestors $childPath
        Assert-NoReparseAncestors $basePath
        $creation.CreatedManagedFiles.Add($childPath)
        New-VHD -Path $childPath -ParentPath $basePath -Differencing | Out-Null

        $creation.RegistrationAttempted = $true
        $vm = Configure-Vm $Settings $creation $childPath
        $metadataPath = Join-Path $Settings.InstanceDirectory 'ownership.json'
        $creation.CreatedManagedFiles.Add($metadataPath)
        Write-OwnershipMetadata $Settings $vm $childPath $basePath $creation.PreexistingFiles $creation.NewInstanceDirectory
        $marker = Join-Path $Settings.InstanceDirectory 'creation-complete'
        Assert-NoReparseAncestors $marker
        $creation.CreatedManagedFiles.Add($marker)
        Set-Content -LiteralPath $marker -Value 'complete' -NoNewline
        Start-VM -VM $vm | Out-Null
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
    $existing = Get-VM -Name $Settings.VmName -ErrorAction SilentlyContinue
    if ($existing) {
        $ownership = Assert-ManagedOwnership $Settings $existing
        Assert-ManagedInstanceLayout $Settings $ownership
        if ($Settings.Force) {
            throw 'Force cannot replace a registered VM. Remove the VM explicitly first.'
        }
        if ($existing.State -ne 'Off') {
            throw "VM is not stopped: $($Settings.VmName)"
        }
        Start-VM -VM $existing | Out-Null
        Write-Host "Restarted $($Settings.VmName) with its existing settings and disk"
        return
    }

    Assert-StartSettings $Settings
    Get-VMSwitch -Name $Settings.SwitchName -ErrorAction Stop | Out-Null
    Assert-StorageCapacity $Settings
    $sevenZipPath = $null
    $fixedPath = Join-Path $Settings.CacheDirectory 'Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhd'
    if (-not (Test-FixedVhd $fixedPath)) {
        $sevenZipPath = Resolve-7ZipExecutable
    }
    New-PiVm $Settings $sevenZipPath
}

function Stop-PiVm($Settings) {
    $vm = Get-VM -Name $Settings.VmName -ErrorAction Stop
    $ownership = Assert-ManagedOwnership $Settings $vm
    Assert-ManagedInstanceLayout $Settings $ownership
    if ($vm.State -eq 'Off') {
        return
    }
    if ($Settings.Force) {
        Stop-VM -VM $vm -TurnOff -Force -ErrorAction Stop
    } else {
        Stop-VM -VM $vm -ErrorAction Stop
    }
}

function Remove-ManagedInstance($Settings, $Ownership) {
    Assert-ManagedInstanceLayout $Settings $Ownership
    $paths = @(
        $Ownership.Child
        Join-Path $Settings.InstanceDirectory 'ownership.json'
        Join-Path $Settings.InstanceDirectory 'creation-complete'
    )
    foreach ($path in $paths) {
        Assert-NoReparseAncestors $path
    }
    foreach ($path in $paths) {
        Remove-Item -LiteralPath $path -Force
    }
    Assert-NoReparseAncestors $Settings.InstanceDirectory
    if ($Ownership.InstanceDirectoryCreated -and
        @(Get-ChildItem -LiteralPath $Settings.InstanceDirectory -Force).Count -eq 0) {
        Remove-Item -LiteralPath $Settings.InstanceDirectory -Force
    } else {
        Write-Host "Preserved instance directory $($Settings.InstanceDirectory) and preexisting files"
    }
}

function Remove-PiVm($Settings) {
    Assert-NoReparseAncestors $Settings.BuildDirectory
    if (-not (Test-Path -LiteralPath $Settings.BuildDirectory -PathType Container)) {
        throw 'Managed build directory is missing or a reparse point'
    }
    $lockPath = Join-Path $Settings.BuildDirectory '.hyperv.lock'
    Assert-NoReparseAncestors $lockPath
    $buildLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
                                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $vm = Get-VM -Name $Settings.VmName -ErrorAction Stop
        $ownership = Assert-ManagedOwnership $Settings $vm
        Assert-ManagedInstanceLayout $Settings $ownership
        if ($vm.State -ne 'Off') {
            if (-not $Settings.Force) {
                throw 'Managed VM is running; use -Force to turn it off before delete'
            }
            Stop-VM -VM $vm -TurnOff -Force -ErrorAction Stop
            $vm = Get-VM -Id $vm.Id -ErrorAction Stop
            if ($vm.State -ne 'Off') {
                throw 'Managed VM did not stop; instance files were preserved'
            }
        }
        Remove-VM -VM $vm -Force -ErrorAction Stop
        try {
            $remaining = Get-VM -Id $vm.Id -ErrorAction Stop
            if ($remaining) {
                throw 'VM removal could not be confirmed; instance files were preserved'
            }
        } catch {
            if ($_.CategoryInfo.Category -ne 'ObjectNotFound' -and
                $_.Exception -isnot [System.Management.Automation.ItemNotFoundException]) {
                throw 'VM removal could not be confirmed; instance files were preserved'
            }
        }
        Remove-ManagedInstance $Settings $ownership
        Write-Host "Deleted managed VM $($Settings.VmName); cached parent was preserved"
    } finally {
        $buildLock.Dispose()
    }
}

Import-Module Hyper-V -ErrorAction Stop
$settings = Get-PiVmSettings
if ($Action -eq 'start') {
    Start-PiVm $settings
} elseif ($Action -eq 'stop') {
    Stop-PiVm $settings
} elseif ($Action -eq 'delete') {
    Remove-PiVm $settings
} else {
    $vm = Get-VM -Name $settings.VmName -ErrorAction Stop
    $ownership = Assert-ManagedOwnership $settings $vm
    Assert-ManagedInstanceLayout $settings $ownership
    $vm | Select-Object Name, Id, State, Status
}
