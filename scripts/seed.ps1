[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Id,
    [string]$Hostname = 'pipette',
    [Parameter(Mandatory=$true)]
    [string]$OutputIso
)
$ErrorActionPreference = 'Stop'

if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') {
    throw 'Invalid instance id'
}
if ($Hostname -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$') {
    throw 'Invalid hostname'
}
if ([string]::IsNullOrWhiteSpace($OutputIso)) {
    throw 'OutputIso must be a path'
}

$output = [IO.Path]::GetFullPath($OutputIso)
if (Test-Path -LiteralPath $output) {
    throw "Output ISO already exists: $output"
}
$outputDirectory = [IO.Path]::GetDirectoryName($output)
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    throw "Output directory does not exist: $outputDirectory"
}

function Write-ImageStream($ImageStream, $Path) {
    if (-not ('SeedStream' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class SeedStream {
    public static void Save(IStream source, string path) {
        using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
            var buffer = new byte[1024 * 1024];
            var bytesRead = Marshal.AllocHGlobal(4);
            try {
                while (true) {
                    Marshal.WriteInt32(bytesRead, 0);
                    source.Read(buffer, buffer.Length, bytesRead);
                    int count = Marshal.ReadInt32(bytesRead);
                    if (count <= 0) break;
                    output.Write(buffer, 0, count);
                }
            } finally {
                Marshal.FreeHGlobal(bytesRead);
            }
        }
    }
}
'@ -ErrorAction Stop
    }
    [SeedStream]::Save($ImageStream, $Path)
}

$scratch = Join-Path $outputDirectory ('.seed-' + [Guid]::NewGuid().ToString('N'))
$temporaryIso = $output + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
try {
    New-Item -ItemType Directory -Path $scratch | Out-Null
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) {
        throw 'Python (python command) is required to render the Windows seed'
    }

    $renderer = Join-Path $PSScriptRoot 'render-seed.py'
    & $python.Source $renderer --instance-id $Id --hostname $Hostname --output-dir $scratch
    if ($LASTEXITCODE -ne 0) {
        throw 'Python seed renderer failed'
    }
    foreach ($name in 'user-data', 'meta-data') {
        if (-not (Test-Path -LiteralPath (Join-Path $scratch $name) -PathType Leaf)) {
            throw "Renderer did not produce $name"
        }
    }

    $filesystem = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $filesystem.ChooseImageDefaultsForMediaType(12) # IMAPI_MEDIA_TYPE_DISK
    $filesystem.FileSystemsToCreate = 3
    $filesystem.VolumeName = 'cidata'
    $filesystem.Root.AddTree($scratch, $false)
    $result = $filesystem.CreateResultImage()
    if (-not $result.ImageStream) {
        throw 'IMAPI2FS returned no image stream'
    }

    Write-ImageStream $result.ImageStream $temporaryIso
    if ((Get-Item -LiteralPath $temporaryIso).Length -le 0) {
        throw 'IMAPI2FS produced an empty ISO'
    }
    [IO.File]::Move($temporaryIso, $output)
} finally {
    Remove-Item -LiteralPath $temporaryIso -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
