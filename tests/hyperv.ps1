$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$work=Join-Path $root ('build/test-tmp/hyperv-mock-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null
# An isolated module supplies all Hyper-V, storage, hash and network commands.
# Production has no environment-variable switch to bypass its module import.
$oldModulePath=$env:PSModulePath
$modules=Join-Path $work 'modules'; $module=Join-Path $modules 'Hyper-V'
New-Item -ItemType Directory -Force -Path $module | Out-Null
Copy-Item "$PSScriptRoot/fixtures/Hyper-V/Hyper-V.psm1" "$module/Hyper-V.psm1"
$env:PSModulePath=$modules+[IO.Path]::PathSeparator+$env:PSModulePath
Remove-Module Hyper-V -ErrorAction SilentlyContinue
Import-Module "$module/Hyper-V.psm1" -Force -DisableNameChecking
$scriptPath=Join-Path $root 'scripts/hyperv.ps1'
$script:caseDir=$null; $script:count=0
function Assert($Condition,$Message) {if(-not $Condition){throw $Message}}
function New-Case([bool]$Prepare=$true) {
  if($script:caseDir){Remove-Item -LiteralPath $script:caseDir -Recurse -Force}
  $script:caseDir=Join-Path $work 'case'
  New-Item -ItemType Directory -Path $script:caseDir | Out-Null
  $script:build=Join-Path $script:caseDir 'build'
  $script:cache=Join-Path $script:caseDir 'cache'
  $script:seed=Join-Path $script:caseDir 'seed.iso'
  [IO.File]::WriteAllText($script:seed,'mock ISO')
  $script:state=@{
    VM=$null
    Calls=[Collections.Generic.List[string]]::new()
    Fail=''
    RemoveFails=$false
    StopFails=$false
    LookupFails=$false
    Free=100GB
    SplitVolumes=$false
    CacheFree=100GB
    BuildFree=100GB
    BaseSize=16GB
    RawCorrupt=$false
    Cache=$script:cache
  }
  Set-PiVmMockState $script:state
  if($Prepare){
    New-Item -ItemType Directory -Path $script:build,$script:cache | Out-Null
    $archive=Join-Path $script:cache 'Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw.xz'
    [IO.File]::WriteAllText($archive,'mock archive')
    $raw=Join-Path $script:cache 'Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw'
    $file=[IO.File]::Open($raw,[IO.FileMode]::Create)
    try {
      $bytes=[Text.Encoding]::ASCII.GetBytes('original')
      $file.Write($bytes,0,$bytes.Length)
      $file.SetLength(5368709120L)
    } finally {
      $file.Dispose()
    }
    # Conversion is mocked; the real fixed-VHD writer has separate content tests.
    [IO.File]::WriteAllText((Join-Path $script:build 'fedora44-base-17179869184.vhd'),'mock fixed VHD')
  }
  $script:options=@{Action='start';Id='test';Build=$script:build;Cache=$script:cache;SeedIso=$script:seed}
  $script:count++
}
function Expect-Failure($Pattern) {
  $caught=$false
  try {& $scriptPath @script:options} catch {
    $caught=$true
    if($_.Exception.Message -notmatch $Pattern){throw}
  }
  Assert $caught "Expected failure matching $Pattern"
}
function Assert-No-Instance {Assert (-not(Test-Path (Join-Path $script:build 'test'))) 'Failed operation left an instance directory'}
try {
  New-Case $false
  $options.DiskSize='1GiB'
  Expect-Failure 'at least 5 GiB'
  Assert (-not(Test-Path $build)) 'Size preflight created build state'

  New-Case $false
  $options.SeedIso='relative.iso'
  Expect-Failure 'absolute path'
  Assert (-not(Test-Path $build)) 'Seed preflight created build state'

  New-Case $false
  $options.SeedIso=Join-Path $caseDir 'missing.iso'
  Expect-Failure 'does not exist'
  Assert (-not(Test-Path $build)) 'Missing seed created build state'

  New-Case $false
  $state.VM=[pscustomobject]@{Name='pi-vm-test';State='Running'}
  Expect-Failure 'not stopped'
  Assert (-not(Test-Path $build)) 'Active VM preflight mutated files'
  $options.Force=$true; Expect-Failure 'Force cannot replace'; Assert ($state.Calls.Count -eq 0) 'Force changed a registered VM'
  New-Case $false; $state.VM=[pscustomobject]@{Name='pi-vm-test';State='Off'}; Expect-Failure 'incomplete'
  New-Case $false; $state.Fail='switch'; Expect-Failure 'switch'; Assert (-not(Test-Path $build)) 'Missing switch created build state'
  New-Case $false; $state.Free=10GB; Expect-Failure '20 GiB'; Assert (-not(Test-Path $build)) 'Space preflight created build state'
  New-Case; $state.SplitVolumes=$true; $state.CacheFree=7GB; Expect-Failure '8 GiB'; Assert-No-Instance
  New-Case; $state.SplitVolumes=$true; $state.BuildFree=11GB; Expect-Failure '12 GiB'; Assert-No-Instance

  # First creation: conversion and resize must precede the differencing child.
  New-Case; & $scriptPath @options
  Assert ($state.VM.Generation -eq 2 -and $state.VM.Memory -eq 2GB) 'Wrong VM generation or memory'
  Assert ($state.Calls.Contains('cpu:2:True')) 'Nested CPU setting missing'
  Assert ($state.Calls.Contains('dynamic:False')) 'Static RAM is not the default'
  Assert ($state.Calls.IndexOf('convert') -lt $state.Calls.IndexOf('resize')) 'Wrong conversion ordering'
  Assert ($state.Calls.IndexOf('resize') -lt $state.Calls.IndexOf('child')) 'Base resize happened after child creation'
  Assert (Test-Path (Join-Path $build 'test/creation-complete')) 'Successful configuration has no marker'
  $state.VM.State='Off'; $state.Calls.Clear(); & $scriptPath @options
  Assert ($state.Calls.Count -eq 1 -and $state.Calls[0] -eq 'start') 'Restart rebuilt or reconfigured a disk'

  New-Case; [IO.File]::WriteAllText((Join-Path $build 'fedora44-base-17179869184.vhdx'),'existing base'); $options.DynamicMemory=$true
  & $scriptPath @options
  Assert (-not $state.Calls.Contains('convert') -and -not $state.Calls.Contains('resize')) 'Reused base was modified'
  Assert ($state.Calls.Contains('dynamic:True')) 'Dynamic RAM opt-in missing'

  foreach($step in 'convert','resize','child','cpu','firmware','memory','dvd','start'){
    New-Case; $state.Fail=$step; Expect-Failure $step
    Assert-No-Instance
    Assert (-not $state.VM) "Rollback retained VM after $step"
    Assert (-not(Test-Path (Join-Path $build 'fedora44-base-17179869184.vhdx.part.vhdx'))) 'Partial base survived failure'
    $state.Fail=''; & $scriptPath @options
    Assert ($state.VM.State -eq 'Running') "Retry failed after $step"
  }
  # Failure after registration, but before New-VM returns, must preserve its disk.
  New-Case; $state.Fail='new-vm'; Expect-Failure 'new-vm'
  Assert ($state.VM -and (Test-Path (Join-Path $build 'test/disk.vhdx'))) 'Ambiguous registration deleted a disk'
  New-Case; $state.Fail='cpu'; $state.RemoveFails=$true; Expect-Failure 'cpu'
  Assert ($state.VM -and (Test-Path (Join-Path $build 'test/disk.vhdx'))) 'Failed VM removal deleted its disk'

  New-Case; $state.Fail='start'; $state.StopFails=$true; Expect-Failure 'start'
  Assert ($state.VM.State -eq 'Running' -and (Test-Path (Join-Path $build 'test/disk.vhdx'))) 'Failed stop deleted a running VM disk'
  New-Case; $state.Fail='cpu'; $state.LookupFails=$true; Expect-Failure 'cpu'
  Assert ($state.VM -and (Test-Path (Join-Path $build 'test/disk.vhdx'))) 'Uncertain VM lookup deleted its disk'

  # Cached raw replacement is staged and must retain the original on hash failure.
  New-Case; $state.RawCorrupt=$true; $state.Fail='raw-hash'; Expect-Failure 'size/SHA-256'
  $raw=Join-Path $cache 'Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw'
  $file=[IO.File]::OpenRead($raw); $bytes=New-Object byte[] 8
  try {$null=$file.Read($bytes,0,8)} finally {$file.Dispose()}
  Assert ([Text.Encoding]::ASCII.GetString($bytes) -eq 'original') 'Failed staged extraction replaced cached raw'
  Assert (-not(Get-ChildItem $cache -Filter '.raw-stage-*')) 'Extraction scratch survived failure'
  $state.Fail=''; & $scriptPath @options
  $file=[IO.File]::OpenRead($raw)
  try {$null=$file.Read($bytes,0,8)} finally {$file.Dispose()}
  Assert ([Text.Encoding]::ASCII.GetString($bytes) -eq 'candidat') 'Validated raw replacement was not published'

  New-Case
  $archive=Join-Path $cache 'Fedora-Cloud-Base-AmazonEC2-44-1.7.x86_64.raw.xz'
  Remove-Item $archive
  $state.Fail='archive-hash'
  Expect-Failure 'Compressed image'
  Assert (-not(Get-ChildItem $cache -Filter '.download-*')) 'Failed download scratch survived'
  $state.Fail=''; & $scriptPath @options
  Assert ($state.Calls.Contains('download')) 'Download mock was not exercised'
  # Status and stop must dispatch without start-only validation or storage work.
  New-Case $false
  $state.VM = [pscustomobject]@{Name='pi-vm-test'; State='Running'; Status='Operating normally'}
  $options.Action = 'status'
  $options.MemoryMB = 1
  $options.DiskSize = 'not a disk size'
  $result = & $scriptPath @options
  Assert ($result.Name -eq 'pi-vm-test' -and $result.State -eq 'Running') 'Status dispatch returned the wrong VM'
  Assert ($state.Calls.Count -eq 0 -and -not(Test-Path $build)) 'Status invoked startup work'

  New-Case $false
  $state.VM = [pscustomobject]@{Name='pi-vm-test'; State='Running'}
  $options.Action = 'stop'
  $options.MemoryMB = 1
  & $scriptPath @options
  Assert ($state.Calls.Count -eq 1 -and $state.Calls[0] -eq 'stop') 'Stop invoked startup work'
  Assert ($state.VM.State -eq 'Off' -and -not(Test-Path $build)) 'Stop dispatch changed storage or failed'

  Write-Output "Hyper-V offline orchestration checks passed ($script:count isolated cases; no real Hyper-V or network)"
} finally {
  Remove-Module Hyper-V -ErrorAction SilentlyContinue
  $env:PSModulePath=$oldModulePath
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
