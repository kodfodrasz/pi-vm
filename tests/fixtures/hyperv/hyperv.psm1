# Offline Hyper-V command doubles. Loaded only by tests/hyperv.ps1.
$script:state = $null

function Set-PiVmMockState {
    param([hashtable]$State)
    $script:state = $State
}

function Add-Call($Text) {
    $script:state.Calls.Add($Text)
}

function Fail-At($Step) {
    if ($script:state.Fail -eq $Step) {
        throw "Injected failure: $Step"
    }
}

function Assert-ExactVm($Vm) {
    if (-not $Vm -or -not $script:state.VM -or
        $Vm.Id -ne $script:state.VM.Id) {
        throw 'VM object is not the registered VM'
    }
}

function Get-VM {
    [CmdletBinding()]
    param($Name, $Id)

    if ($script:state.LookupFails -and $script:state.VM) {
        throw 'Injected lookup failure'
    }
    if ($Id) {
        if ($script:state.VM -and $script:state.VM.Id -eq $Id) {
            return $script:state.VM
        }
        throw [System.Management.Automation.ItemNotFoundException]::new('VM ID not found')
    }
    if ($script:state.VM -and $script:state.VM.Name -eq $Name) {
        return $script:state.VM
    }
}

function Get-VMHardDiskDrive {
    [CmdletBinding()]
    param($VM, $VMName)

    if ($VM) {
        Assert-ExactVm $VM
    } elseif (-not $script:state.VM -or $script:state.VM.Name -ne $VMName) {
        throw 'VM is not registered'
    }
    [pscustomobject]@{ Path = $script:state.VM.Disk }
}

function Get-VMSwitch {
    [CmdletBinding()]
    param($Name)

    Add-Call 'switch'
    Fail-At 'switch'
    [pscustomobject]@{ Name = $Name }
}

function Get-Volume {
    [CmdletBinding()]
    param($FilePath)

    $key = 'shared'
    $free = $script:state.Free
    if ($script:state.SplitVolumes) {
        if ($FilePath.StartsWith($script:state.Cache)) {
            $key = 'cache'
            $free = $script:state.CacheFree
        } else {
            $key = 'build'
            $free = $script:state.BuildFree
        }
    }
    [pscustomobject]@{
        UniqueId = $key
        SizeRemaining = $free
    }
}

function Get-FileHash {
    [CmdletBinding()]
    param($Path, $LiteralPath, $Algorithm)

    if ($LiteralPath) {
        $Path = $LiteralPath
    }
    $script:state.FileReads.Add($Path)
    Add-Call ('hash:' + [IO.Path]::GetFileName($Path))
    $hash = 'dd0c36585f1da3d19866804600e272428a381af9cc83b7fe6a1d4f9e72770835'
    if ($Path -match '\.xz$') {
        $hash = 'daa212a316a94d7a4584a704cad89dfd0bac45e70ee83c4212c095b3b8d55ce5'
        if ($script:state.Fail -eq 'archive-hash') {
            $hash = 'bad'
        }
    } elseif (($script:state.RawCorrupt -or $script:state.Fail -eq 'raw-hash') -and
              $Path -match '\.azure-stage-') {
        $hash = 'bad'
    } elseif ($script:state.PayloadCorrupt) {
        $hash = 'bad'
    }
    if ($script:state.Fail -eq 'archive-hash') {
        $hash = 'bad'
    }
    [pscustomobject]@{ Hash = $hash }
}

function Invoke-WebRequest {
    [CmdletBinding()]
    param($Uri, $OutFile, [switch]$UseBasicParsing)

    Add-Call 'download'
    Fail-At 'download'
    [IO.File]::WriteAllText($OutFile, 'mock archive; no network')
}

function 7z {
    $output = ($args | Where-Object { $_ -like '-o*' } |
        Select-Object -First 1).Substring(2)
    $script:state.ExtractionPaths.Add($output)
    Add-Call 'extract'
    Fail-At 'extract'
    $global:LASTEXITCODE = $script:state.ExtractExit
    if ($script:state.ExtractExit) {
        return
    }

    $path = Join-Path $output 'Fedora-Cloud-Base-Azure-44-1.7.x86_64.vhdfixed'
    $file = [IO.File]::Open($path, [IO.FileMode]::Create)
    try {
        $bytes = [Text.Encoding]::ASCII.GetBytes('candidate')
        $file.Write($bytes, 0, $bytes.Length)
        $file.SetLength($script:state.ExpandedLength)
    } finally {
        $file.Dispose()
    }
}

function Get-VHD {
    [CmdletBinding()]
    param($Path)

    $script:state.NativeReads.Add($Path)
    if (-not ($Path.EndsWith('.vhd') -or $Path.EndsWith('.vhdx'))) {
        throw 'Unsupported native VHD suffix'
    }
    if ($Path.EndsWith('.vhd')) {
        $type = 'Fixed'
        if ($script:state.RawCorrupt -or $script:state.Fail -eq 'raw-hash') {
            $type = 'Dynamic'
        }
        return [pscustomobject]@{
            Size = 5GB
            VhdFormat = 'VHD'
            VhdType = $type
            ParentPath = $null
        }
    }
    if ($Path -eq $script:state.ChildPath) {
        return [pscustomobject]@{
            Size = $script:state.BaseSize
            VhdType = 'Differencing'
            ParentPath = $script:state.ChildParent
        }
    }
    [pscustomobject]@{
        Size = $script:state.BaseSize
        VhdType = 'Dynamic'
        ParentPath = $null
    }
}

function Convert-VHD {
    [CmdletBinding()]
    param($Path, $DestinationPath, $VHDType)

    Add-Call 'convert'
    if (-not $Path.EndsWith('.vhd')) {
        throw 'Wrong Azure source suffix'
    }
    if (-not $DestinationPath.EndsWith('.vhdx')) {
        throw 'Wrong conversion suffix'
    }
    [IO.File]::WriteAllText($DestinationPath, 'mock converted base')
    Fail-At 'convert'
}

function Resize-VHD {
    [CmdletBinding()]
    param($Path, $SizeBytes)

    Add-Call 'resize'
    Fail-At 'resize'
    $script:state.BaseSize = $SizeBytes
    $script:state.ResizeBytes = $SizeBytes
}

function New-VHD {
    [CmdletBinding()]
    param($Path, $ParentPath, [switch]$Differencing)

    Add-Call 'child'
    Fail-At 'child'
    if (-not $Differencing -or -not (Test-Path $ParentPath)) {
        throw 'Invalid child parent'
    }
    $script:state.ChildParent = $ParentPath
    $script:state.ChildPath = $Path
    [IO.File]::WriteAllText($Path, 'mock child')
}

function New-VM {
    [CmdletBinding()]
    param($Name, $Generation, $MemoryStartupBytes, $VHDPath, $SwitchName)

    Add-Call 'new-vm'
    $script:state.VM = [pscustomobject]@{
        Name = $Name
        Id = if ($script:state.NewVmId) { $script:state.NewVmId } else { [Guid]::NewGuid() }
        State = 'Off'
        Generation = $Generation
        Memory = $MemoryStartupBytes
        Disk = $VHDPath
    }
    Fail-At 'new-vm'
    $script:state.VM
}

function Set-VMProcessor {
    [CmdletBinding()]
    param($VM, $VMName, $Count, $ExposeVirtualizationExtensions)

    Assert-ExactVm $VM
    Add-Call "cpu:$Count`:$ExposeVirtualizationExtensions"
    Fail-At 'cpu'
}

function Set-VMFirmware {
    [CmdletBinding()]
    param($VM, $VMName, $EnableSecureBoot)

    Assert-ExactVm $VM
    Add-Call "secureboot:$EnableSecureBoot"
    Fail-At 'firmware'
}

function Set-VMMemory {
    [CmdletBinding()]
    param($VM, $VMName, $DynamicMemoryEnabled, $MinimumBytes, $StartupBytes, $MaximumBytes)

    Assert-ExactVm $VM
    Add-Call "dynamic:$DynamicMemoryEnabled"
    Fail-At 'memory'
    $script:state.MinimumBytes = $MinimumBytes
    $script:state.StartupBytes = $StartupBytes
    $script:state.MaximumBytes = $MaximumBytes
}

function Add-VMDvdDrive {
    [CmdletBinding()]
    param($VM, $VMName, $Path)

    Assert-ExactVm $VM
    Add-Call 'dvd'
    Fail-At 'dvd'
    $script:state.DvdPath = $Path
    if (-not [IO.Path]::IsPathRooted($Path)) {
        throw 'DVD path is not absolute'
    }
}

function Start-VM {
    [CmdletBinding()]
    param($VM, $Name)

    Assert-ExactVm $VM
    Add-Call 'start'
    $script:state.VM.State = 'Running'
    Fail-At 'start'
}

function Stop-VM {
    [CmdletBinding()]
    param($VM, $Name, [switch]$TurnOff, [switch]$Force)

    if ($script:state.LookupFails) {
        throw 'Injected lookup failure'
    }
    Assert-ExactVm $VM
    Add-Call 'stop'
    $script:state.StopTurnOff = [bool]$TurnOff
    $script:state.StopForce = [bool]$Force
    if ($script:state.StopFails) {
        throw 'Injected stop failure'
    }
    $script:state.VM.State = 'Off'
}

function Remove-VM {
    [CmdletBinding()]
    param($VM, $Name, [switch]$Force)

    if ($script:state.LookupFails) {
        throw 'Injected lookup failure'
    }
    Assert-ExactVm $VM
    Add-Call 'remove'
    if ($script:state.RemoveFails) {
        throw 'Injected remove failure'
    }
    $script:state.VM = $null
}

Export-ModuleMember -Function Set-PiVmMockState, Get-VM, Get-VMHardDiskDrive,
    Get-VMSwitch, Get-Volume, Get-FileHash, Invoke-WebRequest, 7z, Get-VHD,
    Convert-VHD, Resize-VHD, New-VHD, New-VM, Set-VMProcessor, Set-VMFirmware,
    Set-VMMemory, Add-VMDvdDrive, Start-VM, Stop-VM, Remove-VM
