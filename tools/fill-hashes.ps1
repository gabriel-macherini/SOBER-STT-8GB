param(
  # Fill installer/downloads.json "sha256" fields by downloading each item
  # and hashing it. Skips items already pinned. Run once per version bump;
  # the installer verifies these hashes at download time (S2).
  # Requires pwsh 7+ (5.1 mangles UTF-8 manifests on read).
  #
  #   pwsh tools/fill-hashes.ps1
)
$ErrorActionPreference = "Stop"
$ROOT = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
$manifestPath = Join-Path $ROOT "installer/downloads.json"
$manifest = Get-Content $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
$tmp = Join-Path ([IO.Path]::GetTempPath()) "sober-stt-hashes"
New-Item -ItemType Directory -Force $tmp | Out-Null
$changed = $false
foreach ($it in $manifest.items) {
  if ($it.sha256) { Write-Host "pinned $($it.id), skip"; continue }
  $dest = Join-Path $tmp $it.file
  Write-Host "== downloading $($it.id) ($($it.url))"
  Invoke-WebRequest -Uri $it.url -OutFile $dest
  $it.sha256 = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
  Write-Host "   sha256=$($it.sha256)"
  Remove-Item $dest -Force
  $changed = $true
}
if ($changed) {
  # No BOM: Node's JSON.parse chokes on it, and the repo files are BOM-less.
  [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
  Write-Host "wrote $manifestPath (regenerate the installer next)"
} else {
  Write-Host "nothing to do"
}
