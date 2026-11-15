$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$cargo = Join-Path $env:USERPROFILE ".cargo\bin\cargo.exe"
$wasmBindgen = Join-Path $env:USERPROFILE ".cargo\bin\wasm-bindgen.exe"
$wasmInput = Join-Path $repoRoot "target\wasm32-unknown-unknown\release\cht_core.wasm"
$outputDir = Join-Path $repoRoot "apps\flutter_app\web\wasm"

if (-not (Test-Path -LiteralPath $cargo)) {
    throw "cargo.exe was not found at $cargo"
}
if (-not (Test-Path -LiteralPath $wasmBindgen)) {
    throw "wasm-bindgen.exe was not found at $wasmBindgen"
}

& $cargo build --manifest-path (Join-Path $repoRoot "Cargo.toml") `
    -p cht-core --release --target wasm32-unknown-unknown
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
& $wasmBindgen $wasmInput --out-dir $outputDir --target web --out-name cht_core
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& python.exe (Join-Path $PSScriptRoot 'version_wasm_assets.py') $outputDir
exit $LASTEXITCODE
