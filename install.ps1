# install.ps1 — deploy cc-app-bridge into ~/.appbridge and the Claude Code skills dir, then start.
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$dest = Join-Path $env:USERPROFILE '.appbridge'
$skill = Join-Path $env:USERPROFILE '.claude\skills\appbridge'

Write-Host "Installing cc-app-bridge..."
New-Item -ItemType Directory -Force -Path `
  (Join-Path $dest 'bin'), (Join-Path $dest 'daemon'), (Join-Path $dest 'logs'), `
  (Join-Path $skill 'references') | Out-Null

Copy-Item (Join-Path $src 'bin\*')                $dest\bin       -Force
Copy-Item (Join-Path $src 'daemon\*')             $dest\daemon    -Force
Copy-Item (Join-Path $src 'skill\SKILL.md')       $skill          -Force
Copy-Item (Join-Path $src 'skill\references\*')   $skill\references -Force

Write-Host "Files deployed. Checking prerequisites..."
$node = (Get-Command node -ErrorAction SilentlyContinue)
$pwshOk = (Get-Command pwsh -ErrorAction SilentlyContinue)
if (-not $node)  { Write-Warning "Node.js not found on PATH — appbridge needs Node 24+." }
if (-not $pwshOk){ Write-Warning "PowerShell 7 (pwsh) not found — the UIA engine needs it." }

if ($node) {
  Write-Host "Starting daemon..."
  & node (Join-Path $dest 'bin\appbridge.mjs') start
  Write-Host "`nDone. Health check:  node `"$dest\bin\appbridge.mjs`" status"
} else {
  Write-Host "`nInstall Node, then run:  node `"$dest\bin\appbridge.mjs`" start"
}
