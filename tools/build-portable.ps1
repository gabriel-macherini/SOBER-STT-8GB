param([switch]$NoNode)
# Build the portable app folder staged for the installer.
#
#   pwsh tools/build-portable.ps1 [-NoNode]
#
# AutoHotkey is located automatically; set AHK_DIR to override (CI points it
# at a freshly unpacked ahk-v2.zip + Ahk2Exe.exe).
#
# Output: dist/SOBER-STT/ with SOBER-STT.exe (compiled tray app, no AutoHotkey
# needed on target), runner.mjs, lib/, rec-host.ps1, config.json, prompts/,
# node/ (portable Node, skipped with -NoNode), and empty models/ + bin/ dirs
# (filled by the installer at install time from installer/downloads.json).
$ErrorActionPreference = "Stop"

$ROOT = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
$DIST = Join-Path $ROOT "dist\SOBER-STT"
$NODE_VERSION = "v22.23.2"
$NODE_ZIP_URL = "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-win-x64.zip"
$CACHE = Join-Path $ROOT ".cache"

# Ahk2Exe + the v2 base it compiles against. AHK_DIR (optional) points at a
# folder laid out like the standard install: Compiler\Ahk2Exe.exe plus a v2
# base (v2\AutoHotkey64.exe). Falls back to the usual install locations.
function Find-Ahk {
  $roots = @()
  if ($env:AHK_DIR) { $roots += $env:AHK_DIR }
  $roots += "$env:ProgramFiles\AutoHotkey"
  if (${env:ProgramFiles(x86)}) { $roots += "${env:ProgramFiles(x86)}\AutoHotkey" }
  if ($env:LOCALAPPDATA) { $roots += "$env:LOCALAPPDATA\Programs\AutoHotkey" }
  if ($env:ChocolateyInstall) { $roots += "$env:ChocolateyInstall\lib\autohotkey.portable\tools" }
  foreach ($root in $roots) {
    if (!$root -or !(Test-Path $root)) { continue }
    $compiler = @("$root\Compiler\Ahk2Exe.exe", "$root\Ahk2Exe.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    $base = @("$root\v2\AutoHotkey64.exe", "$root\AutoHotkey64.exe", "$root\AutoHotkey.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($compiler -and $base) { return , @($compiler, $base) }
  }
  return $null
}

$ahk = Find-Ahk
if (!$ahk) {
  throw "AutoHotkey v2 not found. Install it, or set AHK_DIR to a folder holding Compiler\Ahk2Exe.exe and v2\AutoHotkey64.exe"
}
$AHK2EXE = $ahk[0]
$AHK_BASE = $ahk[1]
Write-Host "== ahk: $AHK2EXE / $AHK_BASE"

Write-Host "== staging $DIST"
Remove-Item -Recurse -Force $DIST -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $DIST | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $DIST "models") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $DIST "bin\whisper") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $DIST "bin\llama") | Out-Null

Write-Host "== compiling tray app"
& $AHK2EXE /in (Join-Path $ROOT "voice-tray.ahk") `
  /out (Join-Path $DIST "SOBER-STT.exe") `
  /icon (Join-Path $ROOT "voice-idle.ico") `
  /base $AHK_BASE
# Note: Ahk2Exe returns before the exe lands on disk (async GUI tool) and
# does not set $LASTEXITCODE reliably; poll for the artifact instead.
$exe = Join-Path $DIST "SOBER-STT.exe"
$deadline = (Get-Date).AddSeconds(60)
while (!(Test-Path $exe) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
if (!(Test-Path $exe)) { throw "Ahk2Exe failed (no exe produced within 60s)" }

Write-Host "== copying app files"
Copy-Item (Join-Path $ROOT "runner.mjs") $DIST
Copy-Item (Join-Path $ROOT "rec-host.ps1") $DIST
Copy-Item (Join-Path $ROOT "config.json") $DIST
Copy-Item (Join-Path $ROOT "voice-idle.ico") $DIST
Copy-Item (Join-Path $ROOT "voice-rec.ico") $DIST
Copy-Item (Join-Path $ROOT "voice-proc.ico") $DIST
Copy-Item (Join-Path $ROOT "lib") (Join-Path $DIST "lib") -Recurse
Copy-Item (Join-Path $ROOT "prompts") (Join-Path $DIST "prompts") -Recurse

if (!$NoNode) {
  New-Item -ItemType Directory -Force -Path $CACHE | Out-Null
  $zip = Join-Path $CACHE "node-$NODE_VERSION-win-x64.zip"
  if (!(Test-Path $zip)) {
    Write-Host "== downloading portable Node $NODE_VERSION"
    Invoke-WebRequest -Uri $NODE_ZIP_URL -OutFile $zip
  }
  Write-Host "== extracting portable Node"
  $tmp = Join-Path $CACHE "node-extract"
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  Expand-Archive -Path $zip -DestinationPath $tmp
  Copy-Item (Join-Path $tmp "node-$NODE_VERSION-win-x64") (Join-Path $DIST "node") -Recurse
  Remove-Item -Recurse -Force $tmp
  & (Join-Path $DIST "node\node.exe") --version
}

Write-Host "== OK: $DIST"
Get-ChildItem $DIST | Format-Table Name -AutoSize | Out-String -Width 120 | Write-Host
