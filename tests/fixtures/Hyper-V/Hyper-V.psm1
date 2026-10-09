# Offline Hyper-V command doubles. Loaded only by tests/hyperv.ps1.
$script:state=$null
function Set-PiVmMockState { param([hashtable]$State) $script:state=$State }
function Add-Call($Text) { $script:state.Calls.Add($Text) }
function Fail-At($Step) { if($script:state.Fail -eq $Step){throw "Injected failure: $Step"} }
function Get-VM {
  [CmdletBinding()]param($Name)
  if($script:state.LookupFails -and $script:state.VM){throw 'Injected lookup failure'}
  if($script:state.VM -and $script:state.VM.Name -eq $Name){$script:state.VM}
}
function Get-VMSwitch {
  [CmdletBinding()]param($Name)
  Add-Call 'switch'; Fail-At 'switch'; [pscustomobject]@{Name=$Name}
}
function Get-Volume {
  [CmdletBinding()]param($FilePath)
  $key='shared'; $free=$script:state.Free
  if($script:state.SplitVolumes){
    if($FilePath.StartsWith($script:state.Cache)){$key='cache';$free=$script:state.CacheFree}
    else {$key='build';$free=$script:state.BuildFree}
  }
  [pscustomobject]@{UniqueId=$key;SizeRemaining=$free}
}
function Get-FileHash {
  [CmdletBinding()]param($Path,$Algorithm)
  Add-Call ('hash:'+([IO.Path]::GetFileName($Path)))
  if($Path.EndsWith('.raw')){
    $hash='ccf0412fa9e3f7d8ce8824e03e3c7369d0fef6dffb00a786a6bc9e895ccdb9ce'
    if(($script:state.RawCorrupt -and $Path -notmatch '\.raw-stage-') -or ($script:state.Fail -eq 'raw-hash' -and $Path -match '\.raw-stage-')){$hash='bad'}
  } else {
    $hash='7e4fb73907abdc761d226ddaf3263bdfca62a0b0bfb5f0798545a9981fdd1953'
    if($script:state.Fail -eq 'archive-hash'){$hash='bad'}
  }
  [pscustomobject]@{Hash=$hash}
}
function Invoke-WebRequest {
  [CmdletBinding()]param($Uri,$OutFile,[switch]$UseBasicParsing)
  Add-Call 'download'; Fail-At 'download'
  [IO.File]::WriteAllText($OutFile,'mock archive; no network')
}
function 7z {
  Add-Call 'extract'; Fail-At 'extract'
  $output=($args | Where-Object {$_ -like '-o*'} | Select-Object -First 1).Substring(2)
  $path=Join-Path $output 'Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw'
  $file=[IO.File]::Open($path,[IO.FileMode]::Create)
  try {$bytes=[Text.Encoding]::ASCII.GetBytes('candidate');$file.Write($bytes,0,$bytes.Length);$file.SetLength(5368709120L)} finally {$file.Dispose()}
  $global:LASTEXITCODE=0
}
function Get-VHD {
  [CmdletBinding()]param($Path)
  [pscustomobject]@{Size=$script:state.BaseSize;ParentPath=$null}
}
function Convert-VHD {
  [CmdletBinding()]param($Path,$DestinationPath,$VHDType)
  Add-Call 'convert'
  if(-not $DestinationPath.EndsWith('.vhdx')){throw 'Wrong conversion suffix'}
  [IO.File]::WriteAllText($DestinationPath,'mock converted base')
  Fail-At 'convert'
}
function Resize-VHD {
  [CmdletBinding()]param($Path,$SizeBytes)
  Add-Call 'resize'; Fail-At 'resize'; $script:state.BaseSize=$SizeBytes
}
function New-VHD {
  [CmdletBinding()]param($Path,$ParentPath,[switch]$Differencing)
  # Intentionally no SizeBytes parameter: real differencing disks inherit size.
  Add-Call 'child'; Fail-At 'child'
  if(-not $Differencing -or -not(Test-Path $ParentPath)){throw 'Invalid child parent'}
  [IO.File]::WriteAllText($Path,'mock child')
}
function New-VM {
  [CmdletBinding()]param($Name,$Generation,$MemoryStartupBytes,$VHDPath,$SwitchName)
  Add-Call 'new-vm'
  $script:state.VM=[pscustomobject]@{Name=$Name;State='Off';Generation=$Generation;Memory=$MemoryStartupBytes;Disk=$VHDPath}
  Fail-At 'new-vm'; $script:state.VM
}
function Set-VMProcessor {
  [CmdletBinding()]param($VMName,$Count,$ExposeVirtualizationExtensions)
  Add-Call "cpu:$Count`:$ExposeVirtualizationExtensions"; Fail-At 'cpu'
}
function Set-VMFirmware {
  [CmdletBinding()]param($VMName,$EnableSecureBoot)
  Add-Call "secureboot:$EnableSecureBoot"; Fail-At 'firmware'
}
function Set-VMMemory {
  [CmdletBinding()]param($VMName,$DynamicMemoryEnabled,$MinimumBytes,$StartupBytes,$MaximumBytes)
  Add-Call "dynamic:$DynamicMemoryEnabled"; Fail-At 'memory'
}
function Add-VMDvdDrive {
  [CmdletBinding()]param($VMName,$Path)
  Add-Call 'dvd'; Fail-At 'dvd'
  if(-not [IO.Path]::IsPathRooted($Path)){throw 'DVD path is not absolute'}
}
function Start-VM {
  [CmdletBinding()]param($Name)
  Add-Call 'start'; $script:state.VM.State='Running'; Fail-At 'start'
}
function Stop-VM {
  [CmdletBinding()]param($Name,[switch]$TurnOff,[switch]$Force)
  Add-Call 'stop'
  if($script:state.StopFails){throw 'Injected stop failure'}
  $script:state.VM.State='Off'
}
function Remove-VM {
  [CmdletBinding()]param($Name,[switch]$Force)
  Add-Call 'remove'
  if($script:state.RemoveFails){throw 'Injected remove failure'}
  $script:state.VM=$null
}
Export-ModuleMember -Function Set-PiVmMockState,Get-VM,Get-VMSwitch,Get-Volume,Get-FileHash,Invoke-WebRequest,7z,Get-VHD,Convert-VHD,Resize-VHD,New-VHD,New-VM,Set-VMProcessor,Set-VMFirmware,Set-VMMemory,Add-VMDvdDrive,Start-VM,Stop-VM,Remove-VM
