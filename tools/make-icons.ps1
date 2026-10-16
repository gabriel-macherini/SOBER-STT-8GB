# Build voice-idle.ico / voice-rec.ico / voice-proc.ico (variant C: mic inside a ring).
# Draw with GDI+ and pack an .ico with PNG frames at 16/20/24/32/48/64/128.
# Run from the repo root:  pwsh tools/make-icons.ps1  (writes next to voice-tray.ahk)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$sizes = @(16, 20, 24, 32, 48, 64, 128)

$states = [ordered]@{
  "idle" = [System.Drawing.Color]::FromArgb(255, 154, 160, 166)  # #9AA0A6
  "rec"  = [System.Drawing.Color]::FromArgb(255, 255, 77, 79)    # #FF4D4F
  "proc" = [System.Drawing.Color]::FromArgb(255, 245, 166, 35)   # #F5A623
}
$light = [System.Drawing.Color]::FromArgb(255, 232, 234, 237)    # #E8EAED

$frameDir = Join-Path $env:TEMP "voice-ico-frames"
New-Item -ItemType Directory -Force -Path $frameDir | Out-Null

# Render one size and save the PNG; return the file path (avoids PowerShell
# unrolling the byte[] on return).
function New-FrameFile([int]$size, [System.Drawing.Color]$ringColor, [string]$outPath) {
  $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)

  $u = $size / 24.0
  $lightBrush = New-Object System.Drawing.SolidBrush($light)
  $ringPen = New-Object System.Drawing.Pen($ringColor, [single][Math]::Max(1.0, 1.6 * $u))
  $lightPen = New-Object System.Drawing.Pen($light, [single][Math]::Max(1.0, 1.6 * $u))
  $lightPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $lightPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round

  # mic body (filled capsule)
  $bx = 9.2 * $u; $by = 4.6 * $u; $bw = 5.6 * $u; $bh = 9.4 * $u; $r = $bw / 2
  $g.FillRectangle($lightBrush, [single]$bx, [single]($by + $r), [single]$bw, [single]($bh - 2 * $r))
  $g.FillEllipse($lightBrush, [single]$bx, [single]$by, [single]$bw, [single]$bw)
  $g.FillEllipse($lightBrush, [single]$bx, [single]($by + $bh - $bw), [single]$bw, [single]$bw)

  # cradle arc (bottom half) and stem
  $g.DrawArc($lightPen, [single](7.4 * $u), [single](7.0 * $u), [single](9.2 * $u), [single](9.2 * $u), 0, 180)
  $g.DrawLine($lightPen, [single](12 * $u), [single](16.4 * $u), [single](12 * $u), [single](19 * $u))

  # state ring
  $g.DrawEllipse($ringPen, [single](1.7 * $u), [single](1.7 * $u), [single](20.6 * $u), [single](20.6 * $u))

  $g.Dispose()
  $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  return $outPath
}

function Write-Ico([string]$path, [System.Drawing.Color]$color) {
  $files = @()
  foreach ($s in $sizes) {
    $files += New-FrameFile -size $s -ringColor $color -outPath (Join-Path $frameDir "$s.png")
  }
  $frames = @()
  foreach ($f in $files) { $frames += ,([System.IO.File]::ReadAllBytes($f)) }

  $count = $frames.Count
  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter($ms)
  $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$count)
  $offset = 6 + 16 * $count
  for ($i = 0; $i -lt $count; $i++) {
    $sz = $sizes[$i]
    $dim = if ($sz -ge 256) { 0 } else { $sz }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim)
    $bw.Write([byte]0); $bw.Write([byte]0)          # color count, reserved
    $bw.Write([uint16]1); $bw.Write([uint16]32)     # planes, bpp
    $bw.Write([uint32]$frames[$i].Length)
    $bw.Write([uint32]$offset)
    $offset += $frames[$i].Length
  }
  foreach ($frame in $frames) { $bw.Write($frame) }
  $bw.Flush()
  [System.IO.File]::WriteAllBytes($path, $ms.ToArray())
  $bw.Dispose(); $ms.Dispose()
}

foreach ($name in $states.Keys) {
  $path = Join-Path (Split-Path $PSScriptRoot -Parent) "voice-$name.ico"
  Write-Ico -path $path -color $states[$name]
  $info = Get-Item $path
  "wrote $($info.Name) ($($info.Length) bytes)"
}
