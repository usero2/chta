param([switch]$DryRun)
$ErrorActionPreference = 'Stop'
$portalDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../apps/web_portal'))
Push-Location -LiteralPath $portalDirectory
try {
  & npm.cmd ci --ignore-scripts
  if ($LASTEXITCODE -ne 0) { throw 'Portal dependency installation failed' }
  & npm.cmd test
  if ($LASTEXITCODE -ne 0) { throw 'Portal tests failed' }
  & npm.cmd run build
  if ($LASTEXITCODE -ne 0) { throw 'Build Flutter with --base-href /chat/ --no-web-resources-cdn first' }
  if ($DryRun) {
    & npm.cmd run dry-run
    if ($LASTEXITCODE -ne 0) { throw 'Wrangler dry run failed' }
  }
} finally { Pop-Location }
