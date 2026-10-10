$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root ('build/test-tmp/hyperv-mock-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

# An isolated module supplies all hyperv, storage, hash, and network commands.
# Production has no environment-variable switch to bypass its module import.
$oldModulePath = $env:PSModulePath
$modules = Join-Path $work 'modules'
$module = Join-Path $modules 'Hyper-V'
New-Item -ItemType Directory -Force -Path $module | Out-Null
Copy-Item "$PSScriptRoot/fixtures/hyperv/hyperv.psm1" "$module/Hyper-V.psm1"
$env:PSModulePath = $modules + [IO.Path]::PathSeparator + $env:PSModulePath
Remove-Module Hyper-V -ErrorAction SilentlyContinue
Import-Module "$module/Hyper-V.psm1" -Force -DisableNameChecking

$scriptPath = Join-Path $root 'scripts/hyperv/hyperv.ps1'
$script:caseDir = $null
$script:count = 0

function Assert {
    param($Condition, $Message)

    if (-not $Condition) {
        throw $Message
    }
}

function New-Case {
    param([bool]$Prepare = $true)

    if ($script:caseDir) {
        Remove-Item -LiteralPath $script:caseDir -Recurse -Force
    }
    $script:caseDir = Join-Path $work 'case'
    New-Item -ItemType Directory -Path $script:caseDir | Out-Null

    $script:build = Join-Path $script:caseDir 'build'
    $script:cache = Join-Path $script:caseDir 'cache'
    $script:seed = Join-Path $script:caseDir 'seed.iso'
    [IO.File]::WriteAllText($script:seed, 'mock ISO')

    $script:state = @{
        VM = $null
        Calls = [Collections.Generic.List[string]]::new()
        FileReads = [Collections.Generic.List[string]]::new()
        NativeReads = [Collections.Generic.List[string]]::new()
        ExtractionPaths = [Collections.Generic.List[string]]::new()
        Fail = ''
        RemoveFails = $false
        StopFails = $false
        LookupFails = $false
        Free = 100GB
        SplitVolumes = $false
        CacheFree = 100GB
        BuildFree = 100GB
        BaseSize = 5GB
        RawCorrupt = $false
        PayloadCorrupt = $false
        Cache = $script:cache
        ExtractExit = 0
        ExpandedLength = 5368709632L
    }
    Set-PiVmMockState $script:state

    if ($Prepare) {
        New-Item -ItemType Directory -Path $script:build, $script:cache | Out-Null
        $archive = Join-Path $script:cache 'Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhdfixed.xz'
        [IO.File]::WriteAllText($archive, 'mock archive')

        $fixed = Join-Path $script:cache 'Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhd'
        $file = [IO.File]::Open($fixed, [IO.FileMode]::Create)
        try {
            $bytes = [Text.Encoding]::ASCII.GetBytes('original')
            $file.Write($bytes, 0, $bytes.Length)
            $file.SetLength(5368709632L)
        } finally {
            $file.Dispose()
        }
    }

    $script:options = @{
        Action = 'start'
        Id = 'test'
        Build = $script:build
        Cache = $script:cache
        SeedIso = $script:seed
    }
    $script:count++
}

function Expect-Failure($Pattern) {
    $caught = $false
    try {
        & $scriptPath @script:options
    } catch {
        $caught = $true
        if ($_.Exception.Message -notmatch $Pattern) {
            throw
        }
    }
    Assert $caught "Expected failure matching $Pattern"
}

function Assert-No-Instance {
    $instance = Join-Path $script:build 'test'
    Assert (-not (Test-Path $instance)) 'Failed operation left an instance directory'
}

function New-FileSymlink {
    param($Link, $Target)

    New-Item -ItemType SymbolicLink -Path $Link -Target $Target | Out-Null
}

function Assert-TextUnchanged {
    param($Path, $Expected)

    Assert ((Get-Content -LiteralPath $Path -Raw) -eq $Expected) "Changed protected file: $Path"
}

try {
    New-Case $false
    $script:options.DiskSize = '1GiB'
    Expect-Failure 'at least 5 GiB'
    Assert (-not(Test-Path $build)) 'Size preflight created build state'

    New-Case $false
    $script:options.SeedIso = 'relative.iso'
    Expect-Failure 'absolute path'
    Assert (-not(Test-Path $build)) 'Seed preflight created build state'

    New-Case $false
    $script:options.SeedIso = Join-Path $caseDir 'missing.iso'
    Expect-Failure 'nonempty file'
    Assert (-not(Test-Path $build)) 'Missing seed created build state'

    New-Case $false
    $state.VM = [pscustomobject]@{
        Name = 'pi-vm-test'
        Id = [Guid]::NewGuid()
        State = 'Running'
    }
    Expect-Failure 'ownership|reparse'
    Assert (-not(Test-Path $build)) 'Active VM preflight mutated files'
    $script:options.Force = $true
    Expect-Failure 'ownership|reparse'
    Assert ($state.Calls.Count -eq 0) 'Force changed an unowned VM'

    New-Case $false
    $state.VM = [pscustomobject]@{
        Name = 'pi-vm-test'
        Id = [Guid]::NewGuid()
        State = 'Off'
    }
    Expect-Failure 'ownership|reparse'

    New-Case $false
    $state.Fail = 'switch'
    Expect-Failure 'switch'
    Assert (-not (Test-Path $build)) 'Missing switch created build state'

    New-Case $false
    $state.Free = 30GB
    Expect-Failure '32 GiB'
    Assert (-not (Test-Path $build)) 'Space preflight created build state'

    New-Case
    $state.SplitVolumes = $true
    $state.CacheFree = 11GB
    Expect-Failure '12 GiB'
    Assert-No-Instance

    New-Case
    $state.SplitVolumes = $true
    $state.BuildFree = 19GB
    Expect-Failure '20 GiB'
    Assert-No-Instance

    # Windows consumes a prepared Linux ISO and never invokes Python or uv.
    New-Case $false
    $script:options.SeedIso = Join-Path $caseDir 'empty.iso'
    [IO.File]::WriteAllText($script:options.SeedIso,'')
    Expect-Failure 'nonempty file'
    Assert ($state.Calls.Count -eq 0) 'Empty supplied ISO caused external work'

    New-Case $false
    $script:options.SeedIso = 'relative.iso'
    Expect-Failure 'absolute path'
    Assert ($state.Calls.Count -eq 0) 'Relative ISO caused external work'

    New-Case $false
    $script:options.Build = 'C:drive-relative-build'
    Expect-Failure 'absolute path'

    New-Case $false
    $script:options.Build = '\\current-drive-rooted-build'
    Expect-Failure 'absolute path'

    if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
        New-Case $false
        $realRoot = Join-Path $caseDir 'real-root'
        $target = Join-Path $realRoot 'inner-build'
        $ordinaryTop = Join-Path $caseDir 'ordinary-top'
        $redirect = Join-Path $ordinaryTop 'redirected-root'
        $nestedBuild = Join-Path $redirect 'inner-build'
        New-Item -ItemType Directory -Path $target, $ordinaryTop | Out-Null
        New-Item -ItemType SymbolicLink -Path $redirect -Target $realRoot | Out-Null
        $script:options.Build = $nestedBuild
        Expect-Failure 'reparse'
        Assert ($state.Calls.Count -eq 0) 'Ancestor symlink caused lifecycle work'
    }

    New-Case $false
    New-Item -ItemType Directory -Path $build, $cache, (Join-Path $build 'test') | Out-Null
    [IO.File]::WriteAllText((Join-Path $build 'test/unmanaged.txt'), 'manual file')
    $script:options.Force = $true
    Expect-Failure 'Instance files exist'
    Assert (Test-Path (Join-Path $build 'test/unmanaged.txt')) 'Force deleted unmanaged instance files'

    if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
        # A lock symlink must be rejected before opening or changing its target.
        New-Case
        $downloadTarget = Join-Path $caseDir 'download-lock-target'
        [IO.File]::WriteAllText($downloadTarget, 'download-lock-sentinel')
        New-FileSymlink (Join-Path $cache '.download.lock') $downloadTarget
        Expect-Failure 'reparse'
        Assert-TextUnchanged $downloadTarget 'download-lock-sentinel'
        Assert-No-Instance

        New-Case
        $buildTarget = Join-Path $caseDir 'hyperv-lock-target'
        [IO.File]::WriteAllText($buildTarget, 'hyperv-lock-sentinel')
        New-FileSymlink (Join-Path $build '.hyperv.lock') $buildTarget
        Expect-Failure 'reparse'
        Assert-TextUnchanged $buildTarget 'hyperv-lock-sentinel'
        Assert-No-Instance

        # Cached archive, fixed image, and converted parent links fail before reads.
        New-Case
        $archiveTarget = Join-Path $caseDir 'archive-target'
        [IO.File]::WriteAllText($archiveTarget, 'archive-sentinel')
        Remove-Item (Join-Path $cache 'Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhdfixed.xz')
        New-FileSymlink (Join-Path $cache 'Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhdfixed.xz') $archiveTarget
        Expect-Failure 'reparse'
        Assert-TextUnchanged $archiveTarget 'archive-sentinel'
        Assert-No-Instance

        New-Case
        $fixedTarget = Join-Path $caseDir 'fixed-target'
        [IO.File]::WriteAllText($fixedTarget, 'fixed-sentinel')
        Remove-Item (Join-Path $cache 'Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhd')
        New-FileSymlink (Join-Path $cache 'Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhd') $fixedTarget
        Expect-Failure 'reparse'
        Assert-TextUnchanged $fixedTarget 'fixed-sentinel'
        Assert-No-Instance
        Assert (-not $state.FileReads.Contains($fixedTarget)) 'Fixed-image link was read before rejection'
        Assert (-not $state.NativeReads.Contains($fixedTarget)) 'Fixed-image link reached Get-VHD'
        Assert ($state.ExtractionPaths.Count -eq 0) 'Fixed-image link reached extraction'
        Assert (-not $state.Calls.Contains('convert') -and -not $state.Calls.Contains('child')) 'Fixed-image link reached disk creation'

        New-Case
        $parentTarget = Join-Path $caseDir 'parent-target'
        [IO.File]::WriteAllText($parentTarget, 'parent-sentinel')
        $parentPath = Join-Path $build 'fedora44-azure-base-17179869184.vhdx'
        New-FileSymlink $parentPath $parentTarget
        Expect-Failure 'reparse'
        Assert-TextUnchanged $parentTarget 'parent-sentinel'
        Assert-No-Instance
        Assert (-not $state.NativeReads.Contains($parentPath)) 'Linked parent reached Get-VHD'
        Assert (-not $state.Calls.Contains('convert') -and -not $state.Calls.Contains('child')) 'Linked parent reached disk creation'
    }

    # First creation: conversion and resize must precede the differencing child.
    New-Case
    & $scriptPath @script:options
    Assert ($state.VM.Generation -eq 2 -and $state.VM.Memory -eq 2GB) 'Wrong VM generation or memory'
    Assert (-not $state.Calls.Contains('seed') -and $state.DvdPath -eq $seed) 'Supplied absolute ISO did not bypass uv'
    Assert ($state.ResizeBytes -eq 17179869184L) 'Wrong target disk size'
    Assert ($state.ChildParent -eq (Join-Path $build 'fedora44-azure-base-17179869184.vhdx')) 'Wrong differencing parent'
    Assert ($state.Calls.Contains('cpu:2:True')) 'Nested CPU setting missing'
    Assert ($state.Calls.Contains('dynamic:False')) 'Static RAM is not the default'
    Assert ($state.Calls.IndexOf('convert') -lt $state.Calls.IndexOf('resize')) 'Wrong conversion ordering'
    Assert ($state.Calls.IndexOf('resize') -lt $state.Calls.IndexOf('child')) 'Base resize happened after child creation'
    Assert (Test-Path (Join-Path $build 'test/creation-complete')) 'Successful configuration has no marker'
    # Memory bounds are enforced only for dynamic memory; static mode remains compatible.
    New-Case
    $script:options.MinimumMemoryMB = 512
    $script:options.MaximumMemoryMB = 0
    & $scriptPath @script:options
    Assert ($state.Calls.Contains('dynamic:False')) 'Static memory unexpectedly validated dynamic bounds'

    New-Case
    $script:options.DynamicMemory = $true
    & $scriptPath @script:options
    Assert ($state.MinimumBytes -eq 1GB -and $state.StartupBytes -eq 2GB -and
    $state.MaximumBytes -eq 2GB) 'Dynamic defaults did not use minimum, startup, and maximum memory'

    New-Case
    $script:options.DynamicMemory = $true
    $script:options.MemoryMB = 4096
    $script:options.MinimumMemoryMB = 2048
    $script:options.MaximumMemoryMB = 8192
    & $scriptPath @script:options
    Assert ($state.MinimumBytes -eq 2GB -and $state.StartupBytes -eq 4GB -and
    $state.MaximumBytes -eq 8GB) 'Custom dynamic memory bounds were not propagated'

    # A same-name replacement registration with a new VM ID cannot be acted on.
    New-Case
    & $scriptPath @script:options
    $state.Calls.Clear()
    $state.VM.Id = [Guid]::NewGuid()
    $script:options.Action = 'stop'
    $script:options.Force = $true
    Expect-Failure 'exact registration'
    Assert ($state.VM.State -eq 'Running' -and $state.Calls.Count -eq 0) 'Replacement VM was acted on'

    $script:options.Action = 'delete'
    Expect-Failure 'exact registration'
    Assert ($state.VM.State -eq 'Running' -and $state.Calls.Count -eq 0) 'Replacement VM was deleted'

    foreach($invalid in @(
    @{
        MemoryMB = 2048
        MinimumMemoryMB = 512
        MaximumMemoryMB = 8192
    }
    @{
        MemoryMB = 2048
        MinimumMemoryMB = -1
        MaximumMemoryMB = 8192
    }
    @{
        MemoryMB = 2048
        MinimumMemoryMB = 4096
        MaximumMemoryMB = 8192
    }
    @{
        MemoryMB = 2048
        MinimumMemoryMB = 1024
        MaximumMemoryMB = 1024
    }
    @{
        MemoryMB = 2048
        MinimumMemoryMB = 1024
        MaximumMemoryMB = 0
    }
    @{
        MemoryMB = 2048
        MinimumMemoryMB = 1024
        MaximumMemoryMB = -1
    }
    @{
        MemoryMB = 8192
        MinimumMemoryMB = 1024
        MaximumMemoryMB = 4096
    }
    )) {
        New-Case $false
        $script:options.DynamicMemory = $true
        $script:options.MemoryMB = $invalid.MemoryMB
        $script:options.MinimumMemoryMB = $invalid.MinimumMemoryMB
        $script:options.MaximumMemoryMB = $invalid.MaximumMemoryMB
        Expect-Failure 'Dynamic memory requires'
        Assert (-not(Test-Path $build)) 'Invalid dynamic memory created build state'
        Assert ($state.Calls.Count -eq 0 -and -not $state.VM) 'Invalid dynamic memory caused creation side effects'
    }

    New-Case
    $script:options.DiskSize = '5GiB'
    & $scriptPath @script:options
    Assert (-not $state.Calls.Contains('resize')) 'Equal source size was unnecessarily resized'

    $state.VM.State = 'Off'
    $state.Calls.Clear()
    & $scriptPath @script:options
    Assert ($state.Calls.Count -eq 1 -and $state.Calls[0] -eq 'start') 'Restart rebuilt or reconfigured a disk'

    New-Case
    $state.BaseSize = 16GB
    $existingBase = Join-Path $build 'fedora44-azure-base-17179869184.vhdx'
    [IO.File]::WriteAllText($existingBase, 'existing base')
    $script:options.DynamicMemory = $true
    & $scriptPath @script:options
    Assert (-not $state.Calls.Contains('convert') -and -not $state.Calls.Contains('resize')) 'Reused base was modified'
    Assert ($state.Calls.Contains('dynamic:True')) 'Dynamic RAM opt-in missing'

    # A changed payload must be rejected even when its VHD metadata remains valid.
    New-Case
    $state.PayloadCorrupt = $true
    Expect-Failure 'fixed VHD'
    Assert (-not (Get-ChildItem $cache -Filter '.azure-stage-*')) 'Payload rejection left extraction scratch'

    New-Case
    Remove-Item (Join-Path $cache '*.vhd')
    $state.ExpandedLength = 5368709631L
    Expect-Failure 'fixed VHD'
    Assert-No-Instance
    Assert (-not $state.Calls.Contains('convert')) 'Wrong expanded length reached conversion'

    New-Case
    Remove-Item (Join-Path $cache '*.vhd')
    $state.ExtractExit = 2
    Expect-Failure '7-Zip decompression failed'
    Assert-No-Instance
    Assert (-not (Get-ChildItem $cache -Filter '.azure-stage-*')) 'Nonzero extractor left scratch'

    # Exclusive build/cache locks refuse concurrent writers before touching VM disks.
    New-Case
    $lock = [IO.File]::Open((Join-Path $build '.hyperv.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        Expect-Failure 'being used|another process'
        Assert-No-Instance
    } finally {
        $lock.Dispose()
    }
    & $scriptPath @script:options

    New-Case
    $lock = [IO.File]::Open((Join-Path $cache '.download.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        Expect-Failure 'being used|another process'
        Assert-No-Instance
    } finally {
        $lock.Dispose()
    }
    & $scriptPath @script:options

    foreach ($step in 'convert', 'resize', 'child', 'cpu', 'firmware', 'memory', 'dvd', 'start') {
        New-Case
        $state.Fail = $step
        Expect-Failure $step
        Assert-No-Instance
        Assert (-not $state.VM) "Rollback retained VM after $step"
        $partialBase = Join-Path $build 'fedora44-azure-base-17179869184.vhdx.part.vhdx'
        Assert (-not (Test-Path $partialBase)) 'Partial base survived failure'

        $state.Fail = ''
        & $scriptPath @script:options
        Assert ($state.VM.State -eq 'Running') "Retry failed after $step"
    }

    # Failure after registration, but before New-VM returns, must preserve its disk.
    New-Case
    $state.Fail = 'new-vm'
    Expect-Failure 'new-vm'
    $child = Join-Path $build 'test/disk.vhdx'
    Assert ($state.VM -and (Test-Path $child)) 'Ambiguous registration deleted a disk'

    New-Case
    $state.Fail = 'cpu'
    $state.RemoveFails = $true
    Expect-Failure 'cpu'
    Assert ($state.VM -and (Test-Path (Join-Path $build 'test/disk.vhdx'))) 'Failed VM removal deleted its disk'

    New-Case
    $state.Fail = 'start'
    $state.StopFails = $true
    Expect-Failure 'start'
    Assert ($state.VM.State -eq 'Running' -and
    (Test-Path (Join-Path $build 'test/disk.vhdx'))) 'Failed stop deleted a running VM disk'

    New-Case
    $state.Fail = 'cpu'
    $state.LookupFails = $true
    Expect-Failure 'cpu'
    Assert ($state.VM -and (Test-Path (Join-Path $build 'test/disk.vhdx'))) 'Uncertain VM lookup deleted its disk'

    # Cached VHD replacement is staged and must retain the original on validation failure.
    New-Case
    $state.RawCorrupt = $true
    $state.Fail = 'raw-hash'
    Expect-Failure 'fixed VHD'
    $fixed = Join-Path $cache 'Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhd'
    $file = [IO.File]::OpenRead($fixed)
    $bytes = New-Object byte[] 8
    try {
        $null = $file.Read($bytes, 0, 8)
    } finally {
        $file.Dispose()
    }
    Assert ([Text.Encoding]::ASCII.GetString($bytes) -eq 'original') 'Failed staged extraction replaced cached VHD'
    Assert (-not (Get-ChildItem $cache -Filter '.azure-stage-*')) 'Extraction scratch survived failure'
    Remove-Item $fixed

    $state.RawCorrupt = $false
    $state.Fail = ''
    & $scriptPath @script:options
    $file = [IO.File]::OpenRead($fixed)
    try {
        $null = $file.Read($bytes, 0, 8)
    } finally {
        $file.Dispose()
    }
    $actualPrefix = [Text.Encoding]::ASCII.GetString($bytes)
    Assert ($actualPrefix -eq 'candidat') "Validated VHD replacement was not published: $actualPrefix"

    New-Case
    $archive = Join-Path $cache 'Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhdfixed.xz'
    Remove-Item $archive
    $state.Fail = 'archive-hash'
    Expect-Failure 'Compressed image SHA-256 mismatch'
    Assert (-not(Get-ChildItem $cache -Filter '.download-*')) 'Failed download scratch survived'
    Assert ($state.Calls.Contains('download')) 'Download mock was not exercised'
    # Status and stop validate ownership, but do not repeat creation preflight.
    New-Case
    & $scriptPath @script:options
    $state.Calls.Clear()
    $script:options.Action = 'status'
    $script:options.MemoryMB = 1
    $script:options.DiskSize = 'not a disk size'
    $result = & $scriptPath @script:options
    Assert ($result.Name -eq 'pi-vm-test' -and $result.State -eq 'Running') 'Status returned the wrong VM'
    Assert ($state.Calls.Count -eq 0) 'Status invoked startup work'

    $script:options.Action = 'stop'
    $script:options.MemoryMB = 1
    & $scriptPath @script:options
    Assert ($state.Calls.Count -eq 1 -and $state.Calls[0] -eq 'stop') 'Stop invoked startup work'
    Assert (-not $state.StopTurnOff -and -not $state.StopForce) 'Default stop was not graceful'
    $state.VM.State = 'Running'
    $script:options.Force = $true
    $state.Calls.Clear()
    & $scriptPath @script:options
    Assert ($state.StopTurnOff -and $state.StopForce -and $state.VM.State -eq 'Off') 'Forced stop did not turn off VM'

    # Delete turns off only an owned VM, removes registration before private files,
    # and leaves the immutable parent in place.
    $script:options.Action = 'delete'
    $state.Calls.Clear()
    & $scriptPath @script:options
    Assert (-not $state.VM) 'Delete retained the registered VM'
    Assert (-not (Test-Path (Join-Path $build 'test'))) 'Delete retained managed instance files'
    Assert (Test-Path (Join-Path $build 'fedora44-azure-base-17179869184.vhdx')) 'Delete removed cached parent'

    New-Case
    & $scriptPath @script:options
    $state.VM.State = 'Running'
    $script:options.Action = 'delete'
    $script:options.Force = $true
    & $scriptPath @script:options
    Assert (-not $state.VM) 'Forced delete retained the VM'

    # Delete refuses an exact-name collision without an ownership record.
    New-Case $false
    $state.VM = [pscustomobject]@{
        Name = 'pi-vm-test'
        Id = [Guid]::NewGuid()
        State = 'Off'
    }
    $script:options.Action = 'delete'
    Expect-Failure 'ownership|reparse'

    # A changed identity record cannot authorize a disk cleanup.
    New-Case
    & $scriptPath @script:options
    $metadataPath = Join-Path $build 'test/ownership.json'
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $metadata.ChildPath = Join-Path $build 'other.vhdx'
    $metadata | ConvertTo-Json -Compress | Set-Content -LiteralPath $metadataPath -Encoding UTF8 -NoNewline
    $script:options.Action = 'delete'
    Expect-Failure 'child disk'
    Assert ($state.VM -and (Test-Path $metadataPath)) 'Tampered ownership was accepted'

    # The registered disk must be the exact private child.
    New-Case
    & $scriptPath @script:options
    $state.VM.Disk = Join-Path $caseDir 'unrelated.vhdx'
    $script:options.Action = 'delete'
    Expect-Failure 'Registered VM disk'
    Assert ($state.VM -and (Test-Path (Join-Path $build 'test/disk.vhdx'))) 'Unrelated VM disk was accepted'

    # A failed Remove-VM leaves the full managed instance in place.
    New-Case
    & $scriptPath @script:options
    $state.RemoveFails = $true
    $state.VM.State = 'Off'
    $script:options.Action = 'delete'
    Expect-Failure 'remove failure'
    Assert ($state.VM -and (Test-Path (Join-Path $build 'test/ownership.json'))) 'Failed VM removal deleted metadata'

    # Unknown files stop cleanup after registration has been removed.
    New-Case
    & $scriptPath @script:options
    $state.VM.State = 'Off'
    [IO.File]::WriteAllText((Join-Path $build 'test/unmanaged.txt'), 'manual file')
    $script:options.Action = 'delete'
    Expect-Failure 'unmanaged files'
    Assert ($state.VM -and
    (Test-Path (Join-Path $build 'test/disk.vhdx')) -and
    (Test-Path (Join-Path $build 'test/ownership.json')) -and
    (Test-Path (Join-Path $build 'test/creation-complete')) -and
    (Test-Path (Join-Path $build 'test/unmanaged.txt'))) 'Unmanaged file changed managed state'

    New-Case $false
    $script:options.Action = 'delete'
    Expect-Failure 'ownership|reparse'

    Write-Output "Hyper-V offline orchestration checks passed ($script:count isolated cases; no real Hyper-V or network)"
} finally {
  Remove-Module Hyper-V -ErrorAction SilentlyContinue
  $env:PSModulePath = $oldModulePath
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
