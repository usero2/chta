param([string]$NdkVersion = '30.0.14904198')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$sdk = $env:ANDROID_SDK_ROOT
if (-not $sdk) { $sdk = Join-Path $env:LOCALAPPDATA 'Android\sdk' }
$linker = Join-Path $sdk "ndk\$NdkVersion\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android24-clang.cmd"
if (-not (Test-Path -LiteralPath $linker)) { throw "Android NDK linker not found: $linker" }
$cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
$env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = $linker
$env:CARGO_TARGET_DIR = Join-Path $repo 'target\android'
& $cargo build --manifest-path (Join-Path $repo 'Cargo.toml') -p cht-core --release --target aarch64-linux-android
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$destination = Join-Path $repo 'apps\flutter_app\android\app\src\main\jniLibs\arm64-v8a'
New-Item -ItemType Directory -Force -Path $destination | Out-Null
Copy-Item -LiteralPath (Join-Path $env:CARGO_TARGET_DIR 'aarch64-linux-android\release\libcht_core.so') -Destination (Join-Path $destination 'libcht_core.so') -Force
Write-Output "Built native Android Rust core: $destination\libcht_core.so"
