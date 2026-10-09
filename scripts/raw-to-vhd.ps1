[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$RawPath,
    [Parameter(Mandatory=$true)]
    [string]$VhdPath
)
$ErrorActionPreference = 'Stop'

function Set-BigEndian(
    [byte[]]$Buffer,
    [int]$Offset,
    [UInt64]$Value,
    [int]$Width
) {
    for ($index = 0; $index -lt $Width; $index++) {
        $Buffer[$Offset + $Width - 1 - $index] =
            [byte](($Value -shr (8 * $index)) -band 0xff)
    }
}

function New-FixedVhdFooter([Int64]$ImageSize) {
    $footer = New-Object byte[] 512
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('conectix'), 0, $footer, 0, 8)
    Set-BigEndian $footer 8 2 4
    Set-BigEndian $footer 12 0x00010000 4
    Set-BigEndian $footer 16 ([UInt64]::MaxValue) 8

    $secondsSince2000 = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 946684800
    Set-BigEndian $footer 24 ([UInt32]$secondsSince2000) 4
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('PIVM'), 0, $footer, 28, 4)
    Set-BigEndian $footer 32 0x00010000 4
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('Wi2k'), 0, $footer, 36, 4)

    Set-BigEndian $footer 40 ([UInt64]$ImageSize) 8
    Set-BigEndian $footer 48 ([UInt64]$ImageSize) 8
    $sectors = [UInt64]($ImageSize / 512)
    $cylinders = [UInt64][Math]::Min(65535, [Math]::Floor($sectors / (16 * 63)))
    Set-BigEndian $footer 56 $cylinders 2
    $footer[58] = 16
    $footer[59] = 63
    Set-BigEndian $footer 60 2 4

    $id = [Guid]::NewGuid().ToByteArray()
    [Array]::Copy($id, 0, $footer, 68, 16)
    $sum = [UInt64]0
    for ($index = 0; $index -lt 512; $index++) {
        if ($index -lt 64 -or $index -gt 67) {
            $sum += $footer[$index]
        }
    }
    $checksum = [UInt64](0xffffffffL - ($sum % 0x100000000L))
    Set-BigEndian $footer 64 $checksum 4
    return ,$footer
}

$RawPath = [IO.Path]::GetFullPath($RawPath)
$VhdPath = [IO.Path]::GetFullPath($VhdPath)
if (-not (Test-Path -LiteralPath $RawPath -PathType Leaf)) {
    throw "Raw image not found: $RawPath"
}
if (Test-Path -LiteralPath $VhdPath) {
    throw "Refusing to overwrite: $VhdPath"
}

$imageSize = (Get-Item -LiteralPath $RawPath).Length
if ($imageSize -lt 512 -or $imageSize % 512) {
    throw 'Raw image length must be a nonzero multiple of 512 bytes'
}

$temporaryPath = "$VhdPath.part"
if (Test-Path -LiteralPath $temporaryPath) {
    throw "Temporary output already exists: $temporaryPath"
}

$output = $null
try {
    $output = [IO.File]::Open(
        $temporaryPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
    $input = [IO.File]::OpenRead($RawPath)
    try {
        $input.CopyTo($output)
    } finally {
        $input.Dispose()
    }

    $footer = New-FixedVhdFooter $imageSize
    $output.Write($footer, 0, $footer.Length)
    $output.Flush($true)
    $output.Dispose()
    $output = $null
    [IO.File]::Move($temporaryPath, $VhdPath)
} catch {
    if ($output) {
        $output.Dispose()
    }
    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    throw
}
