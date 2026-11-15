param(
    [string]$ReleaseDirectory,
    [string]$OutputDirectory,
    [string]$Version
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $ReleaseDirectory) { $ReleaseDirectory = Join-Path $repo 'apps/flutter_app/build/windows/x64/runner/Release' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo 'apps/flutter_app/build/windows/single-file' }
if (-not $Version) {
    $versionLine = Get-Content (Join-Path $repo 'apps/flutter_app/pubspec.yaml') | Select-String '^version:'
    $Version = ($versionLine.Line -replace '^version:\s*','').Trim()
}
if (-not $Version) { throw 'Missing app version' }
$release = (Resolve-Path -LiteralPath $ReleaseDirectory).Path
$actualVersion = (Get-Item -LiteralPath (Join-Path $release 'chta.exe')).VersionInfo.ProductVersion
if ($actualVersion -ne $Version) { throw "Build the desktop release first: expected $Version, found $actualVersion" }
$output = [System.IO.Path]::GetFullPath($OutputDirectory)
if ($output -eq $release -or $output.StartsWith($release + [System.IO.Path]::DirectorySeparatorChar)) { throw 'Single-file output must be outside the Flutter runtime folder' }
if (Test-Path -LiteralPath $output) {
    $unexpected = @(Get-ChildItem -LiteralPath $output -Force | Where-Object { $_.Name -ne 'chta.exe' -or $_.PSIsContainer })
    if ($unexpected.Count -gt 0) { throw 'Single-file output must be empty or contain only chta.exe. Existing files were preserved.' }
}
New-Item -ItemType Directory -Force -Path $output | Out-Null
$temporary = Join-Path $repo 'target/desktop-launcher/package'
New-Item -ItemType Directory -Force -Path $temporary | Out-Null
$payload = Join-Path $temporary 'runtime.bin'
$python = (Get-Command python.exe -ErrorAction Stop).Source
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$redist = $null
if (Test-Path -LiteralPath $vswhere) {
    $studio = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($studio) {
        $redist = Get-ChildItem (Join-Path $studio 'VC/Redist/MSVC') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'x64/Microsoft.VC143.CRT' } |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
}
$arguments = @((Join-Path $PSScriptRoot 'pack_windows_payload.py'), $release, $payload)
if ($redist) { $arguments += @('--runtime-directory', $redist) }
& $python @arguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$env:CHTA_PAYLOAD_PATH = $payload
$env:CHTA_RELEASE_VERSION = $Version
$env:CARGO_TARGET_DIR = Join-Path $repo 'target/desktop-launcher'
$env:RUSTFLAGS = '-C target-feature=+crt-static'
$cargo = Join-Path $env:USERPROFILE '.cargo/bin/cargo.exe'
& $cargo build --manifest-path (Join-Path $repo 'rust/crates/desktop_launcher/Cargo.toml') --release --locked
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$destination = Join-Path $output 'chta.exe'
Copy-Item -LiteralPath (Join-Path $env:CARGO_TARGET_DIR 'release/chta-launcher.exe') -Destination $destination -Force
Write-Output "Single-file desktop app: $destination"
Write-Output "Runtime extracts to LOCALAPPDATA/chta/runtime; existing identity/history storage stays unchanged."
