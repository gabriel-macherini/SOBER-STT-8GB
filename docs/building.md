# Building and releasing

## Running from source

You need Node 22+ and AutoHotkey v2, plus the binaries and models laid out as in
`config.json`. A fresh clone alone will not dictate, because the installer is
what normally brings the binaries:

```powershell
& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" "C:\path\to\SOBER-STT-8GB\voice-tray.ahk"
```

Double-tap and hold CapsLock and it should record. Per-machine paths go in
`config.local.json` (gitignored, never commit it).

## Manual binary layout

Mirrors `installer/downloads.json`: URL to destination under the install
folder.

| File | Destination |
|---|---|
| `https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/ggml-parakeet-tdt-0.6b-v3-q8_0.bin` | `models/` |
| `https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/main/s1-mini-q4_k_m.gguf` | `models/` |
| `https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf` | `models/` |
| llama.cpp `b11429` `llama-b11429-bin-win-cuda-12.4-x64.zip` (extract) | `bin/llama/` |
| llama.cpp `b11429` `cudart-llama-bin-win-cuda-12.4-x64.zip` (extract) | `bin/llama/` |
| whisper.cpp `b5454` `whisper-bin-win-cuda-12.4.0-x64.zip` (extract) | `bin/whisper/` |

All three are CUDA builds. On an AMD card there is nothing to download here
that will work, see the design note in [the README](../README.md#design).

## Building the installer

Prerequisites: AutoHotkey v2 for Ahk2Exe, and Inno Setup 6
(`winget install JRSoftware.InnoSetup`).

```powershell
pwsh tools/build-portable.ps1   # dist/SOBER-STT: exe + portable Node + app files
pwsh tools/build-installer.ps1  # dist/SOBER-STT-Setup-1.0.3.exe
```

`build-portable.ps1` locates AutoHotkey on its own. Set `AHK_DIR` to a folder
holding `Compiler\Ahk2Exe.exe` and `v2\AutoHotkey64.exe` to override that.

## Versions

`version.txt` is the source of truth. `tools/check-version.mjs` fails when the
installer `AppVersion`, the CHANGELOG header, the build example above, or the
tray `APPVER` drift from it. Download versions and their SHA-256 pins live in
`installer/downloads.json`, which the wizard lists verbatim; bump a version
there and rebuild.

## Releasing

1. Bump `version.txt`.
2. Add a `CHANGELOG.md` section for the version.
3. Rebuild, commit, then tag and push:

```powershell
git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin main
git push origin vX.Y.Z
```

Pushing a `v*` tag runs the `release` workflow: tests, portable build,
installer build, then a published GitHub release whose notes are that
version's CHANGELOG section plus the installer SHA-256. To do it by hand
instead:

```powershell
gh release create vX.Y.Z --notes-file - dist/SOBER-STT-Setup-X.Y.Z.exe
```

## CI

| Workflow | Trigger | What |
|---|---|---|
| `ci` | push to `main`, pull requests | `npm test` (20 cases) and `npm run check` (version drift) |
| `release` | `v*` tags | tests, portable build, installer build, GitHub release |
