# chta Desktop: one-file distribution

The distributable is one file, `chta.exe`. Flutter's runtime, assets, native plugins and Rust helpers are embedded in it. On first launch the Rust bootstrap expands them into `%LOCALAPPDATA%\chta\runtime\<content hash>`, verifies every file and starts the app. Later launches reuse a verified cache. A damaged cache is repaired separately; active versions and identity data are not overwritten.

This is a self-extracting portable app. It still uses runtime files on disk and does not mean Flutter has been statically linked into one executable. No administrator permission is required to launch it. Identity, PIN, contacts, relay settings and history keep their existing storage locations.

Build the ordinary Windows release, then run from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/package-windows.ps1
```

The output is `apps/flutter_app/build/windows/single-file/chta.exe`. That folder is the distribution; the larger `runner/Release` directory remains an intermediate build input. Its legacy `cht.exe` alias and debug symbols are excluded from the archive. Available Microsoft VC143 CRT redistributable DLLs are included from the installed Build Tools. The bootstrap itself uses the static CRT.

Packaging rejects an out-of-date app version, missing runtime files, redirected input paths and an output inside its source folder. The output must be empty or contain only a previous `chta.exe`; unrelated files are preserved and cause packaging to stop. Extraction bounds sizes and filenames, rejects Windows device/stream/traversal paths, validates the embedded archive plus each runtime SHA-256, and commits a staging directory before launch. Startup checks do not replace code signing or protect a machine already controlled by the same Windows user.

Run a noninteractive integrity check without opening an identity:

```powershell
.\apps\flutter_app\build\windows\single-file\chta.exe --check-runtime runtime-check.json
```

The JSON reports runtime verification only. Normal launch opens the actual app. Old runtime versions are retained to avoid deleting loaded files; they can be removed after all app versions are closed, without removing the separate identity/history directories.
