param()
# Regenerate installer/generated-downloads.iss from installer/downloads.json,
# then compile installer/sober-stt.iss with Inno Setup 6.
#
#   pwsh tools/build-installer.ps1
#
# Output: dist/SOBER-STT-Setup-<version>.exe
$ErrorActionPreference = "Stop"
$ROOT = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
$INSTALLER = Join-Path $ROOT "installer"

$ISCC = @(
  "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
  (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe")
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (!$ISCC) {
  $ISCC = (Get-Command iscc -ErrorAction SilentlyContinue).Source
}
if (!$ISCC) { throw "ISCC not found (winget install JRSoftware.InnoSetup)" }

$manifest = Get-Content (Join-Path $INSTALLER "downloads.json") -Raw | ConvertFrom-Json
$items = $manifest.items

function Q($s) { return ($s -replace "'", "''") }

$pas = New-Object System.Text.StringBuilder
[void]$pas.AppendLine("{ Generated from downloads.json by tools/build-installer.ps1. Do not edit. }")
[void]$pas.AppendLine("const")
[void]$pas.AppendLine("  DownloadCount = $($items.Count);")
[void]$pas.AppendLine("")
foreach ($fn in @("Label", "Version", "File", "Url", "DestSub", "CheckFile")) {
  [void]$pas.AppendLine("function Download$fn(I: Integer): String;")
  [void]$pas.AppendLine("begin")
  [void]$pas.AppendLine("  case I of")
  for ($i = 0; $i -lt $items.Count; $i++) {
    $v = switch ($fn) {
      "Label" { $items[$i].label }
      "Version" { $items[$i].version }
      "File" { $items[$i].file }
      "Url" { $items[$i].url }
      "DestSub" { $items[$i].dest }
      "CheckFile" { $items[$i].checkFile }
    }
    [void]$pas.AppendLine("    ${i}: Result := '$(Q $v)';")
  }
  [void]$pas.AppendLine("  else Result := '';")
  [void]$pas.AppendLine("  end;")
  [void]$pas.AppendLine("end;")
  [void]$pas.AppendLine("")
}
[void]$pas.AppendLine("function DownloadExtract(I: Integer): Boolean;")
[void]$pas.AppendLine("begin")
[void]$pas.AppendLine("  case I of")
for ($i = 0; $i -lt $items.Count; $i++) {
  if ($items[$i].extract) { [void]$pas.AppendLine("    ${i}: Result := True;") }
}
[void]$pas.AppendLine("  else Result := False;")
[void]$pas.AppendLine("  end;")
[void]$pas.AppendLine("end;")
[void]$pas.AppendLine("")
foreach ($lang in @("En", "Pt", "Fr", "Es")) {
  $key = "label_" + $lang.ToLower()
  [void]$pas.AppendLine("")
  [void]$pas.AppendLine("function DownloadList$lang(): String;")
  [void]$pas.AppendLine("begin")
  $quoted = foreach ($it in $items) { "'$(Q "  - $($it.$key): $($it.version)")'" }
  [void]$pas.AppendLine("  Result := $($quoted -join ' + #13#10 + ');")
  [void]$pas.AppendLine("end;")
}
[void]$pas.AppendLine("")
[void]$pas.AppendLine("function DownloadListText(): String;")
[void]$pas.AppendLine("begin")
[void]$pas.AppendLine("  if ActiveLanguage() = 'fr' then Result := DownloadListFr()")
[void]$pas.AppendLine("  else if ActiveLanguage() = 'es' then Result := DownloadListEs()")
[void]$pas.AppendLine("  else if ActiveLanguage() = 'en' then Result := DownloadListEn()")
[void]$pas.AppendLine("  else Result := DownloadListPt();")
[void]$pas.AppendLine("end;")

$out = Join-Path $INSTALLER "generated-downloads.iss"
[IO.File]::WriteAllText($out, $pas.ToString(), (New-Object Text.UTF8Encoding $true))
Write-Host "wrote generated-downloads.iss ($($items.Count) items)"

$total = ($items | Measure-Object installedBytes -Sum).Sum
$defs = "#define DownloadTotalBytes $total`r`n"
[IO.File]::WriteAllText((Join-Path $INSTALLER "generated-downloads-defs.iss"), $defs, (New-Object Text.UTF8Encoding $true))
Write-Host "total installed bytes: $total"

Write-Host "== compiling installer"
& $ISCC (Join-Path $INSTALLER "sober-stt.iss")
if ($LASTEXITCODE -ne 0) { throw "ISCC failed ($LASTEXITCODE)" }
Write-Host "== OK"
