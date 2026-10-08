[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Id,
  [string]$Hostname='pipette',
  [Parameter(Mandatory=$true)][string]$OutputIso
)
$ErrorActionPreference='Stop'
if($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$'){throw 'Invalid instance id'}
if($Hostname -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'){throw 'Invalid hostname'}
if([string]::IsNullOrWhiteSpace($OutputIso)){throw 'OutputIso must be a path'}
$out=[IO.Path]::GetFullPath($OutputIso)
if(Test-Path -LiteralPath $out){throw "Output ISO already exists: $out"}
$parent=[IO.Path]::GetDirectoryName($out)
if(-not(Test-Path -LiteralPath $parent -PathType Container)){throw "Output directory does not exist: $parent"}
$scratch=Join-Path $parent ('.seed-'+[Guid]::NewGuid().ToString('N'))
$tmp=$out+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
try {
  New-Item -ItemType Directory -Path $scratch | Out-Null
  $renderer=Join-Path $PSScriptRoot 'render-seed.py'
  $python=Get-Command python -ErrorAction SilentlyContinue
  if(-not $python){throw 'Python (python command) is required to render the Windows seed'}
  & $python.Source $renderer --instance-id $Id --hostname $Hostname --output-dir $scratch
  if($LASTEXITCODE -ne 0){throw 'Python seed renderer failed'}
  foreach($f in 'user-data','meta-data'){if(-not(Test-Path -LiteralPath (Join-Path $scratch $f) -PathType Leaf)){throw "Renderer did not produce $f"}}
  $fs=New-Object -ComObject IMAPI2FS.MsftFileSystemImage
  $fs.ChooseImageDefaultsForMediaType(12) # IMAPI_MEDIA_TYPE_DISK
  $fs.FileSystemsToCreate=3
  $fs.VolumeName='cidata'
  $fs.Root.AddTree($scratch,$false)
  $result=$fs.CreateResultImage()
  if(-not $result.ImageStream){throw 'IMAPI2FS returned no image stream'}
  if (-not ('SeedStream' -as [type])) { Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class SeedStream {
 public static void Save(IStream source, string path) {
  using(var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
   byte[] buffer=new byte[1024*1024];
   IntPtr readPtr=Marshal.AllocHGlobal(4);
   try { while(true) { Marshal.WriteInt32(readPtr,0); source.Read(buffer,buffer.Length,readPtr); int n=Marshal.ReadInt32(readPtr); if(n<=0) break; output.Write(buffer,0,n); } }
   finally { Marshal.FreeHGlobal(readPtr); }
  }
 }
}
'@ -ErrorAction Stop
  }
  [SeedStream]::Save($result.ImageStream,$tmp)
  if((Get-Item -LiteralPath $tmp).Length -le 0){throw 'IMAPI2FS produced an empty ISO'}
  [IO.File]::Move($tmp,$out)
} finally {
  if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
  if(Test-Path -LiteralPath $scratch){Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue}
}
