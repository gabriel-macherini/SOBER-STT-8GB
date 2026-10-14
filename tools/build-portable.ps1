param([switch]$NoNode)
# Build the portable app folder staged for the installer.
#
#   pwsh tools/build-portable.ps1 [-NoNode]
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

$AHK2EXE = "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe"
$AHK_BASE = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
if (!(Test-Path $AHK2EXE)) { throw "Ahk2Exe not found: $AHK2EXE (install AutoHotkey v2)" }
if (!(Test-Path $AHK_BASE)) { throw "AHK base not found: $AHK_BASE" }

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
