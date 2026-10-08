[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RawPath,[Parameter(Mandatory=$true)][string]$VhdPath)
$ErrorActionPreference = 'Stop'
$RawPath = [IO.Path]::GetFullPath($RawPath); $VhdPath = [IO.Path]::GetFullPath($VhdPath)
if (-not (Test-Path -LiteralPath $RawPath -PathType Leaf)) { throw "Raw image not found: $RawPath" }
if (Test-Path -LiteralPath $VhdPath) { throw "Refusing to overwrite: $VhdPath" }
$length = (Get-Item -LiteralPath $RawPath).Length
if ($length -lt 512 -or $length % 512) { throw 'Raw image length must be a nonzero multiple of 512 bytes' }
function Set-BigEndian([byte[]]$Buffer, [int]$Offset, [UInt64]$Value, [int]$Width) {
  for ($i = 0; $i -lt $Width; $i++) { $Buffer[$Offset + $Width - 1 - $i] = [byte](($Value -shr (8 * $i)) -band 0xff) }
}
$part = "$VhdPath.part"
if (Test-Path -LiteralPath $part) { throw "Temporary output already exists: $part" }
$stream = $null
try {
  $stream = [IO.File]::Open($part, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  $input = [IO.File]::OpenRead($RawPath)
  try { $input.CopyTo($stream) } finally { $input.Dispose() }
  $footer = New-Object byte[] 512
  [Array]::Copy([Text.Encoding]::ASCII.GetBytes('conectix'), 0, $footer, 0, 8)
  Set-BigEndian $footer 8 2 4 # features: temporary + reserved
  Set-BigEndian $footer 12 0x00010000 4 # VHD format version 1.0
  Set-BigEndian $footer 16 ([UInt64]::MaxValue) 8 # fixed disk data offset sentinel
  $timestamp = [UInt32]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 946684800)
  Set-BigEndian $footer 24 $timestamp 4
  [Array]::Copy([Text.Encoding]::ASCII.GetBytes('PIVM'), 0, $footer, 28, 4)
  Set-BigEndian $footer 32 0x00010000 4
  [Array]::Copy([Text.Encoding]::ASCII.GetBytes('Wi2k'), 0, $footer, 36, 4)
  $sectors = [UInt64]($length / 512); $cylinders = [UInt64][Math]::Min(65535, [Math]::Floor($sectors / (16 * 63)))
  Set-BigEndian $footer 56 $cylinders 2; $footer[58]=16; $footer[59]=63
  Set-BigEndian $footer 60 2 4
  $guid = [Guid]::NewGuid().ToByteArray(); [Array]::Copy($guid, 0, $footer, 68, 16)
  Set-BigEndian $footer 40 ([UInt64]$length) 8
  Set-BigEndian $footer 48 ([UInt64]$length) 8
  $sum = [UInt64]0; for ($i=0; $i -lt 512; $i++) { if ($i -lt 64 -or $i -gt 67) { $sum += $footer[$i] } }
  $checksum = [UInt64](0xffffffffL - ($sum % 0x100000000L))
  Set-BigEndian $footer 64 $checksum 4
  $stream.Write($footer,0,512); $stream.Flush($true); $stream.Dispose(); $stream=$null
  [IO.File]::Move($part, $VhdPath)
} catch {
  if ($stream) { $stream.Dispose() }
  Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
  throw
}
