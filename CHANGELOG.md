# Changelog — SOBER-STT

## [1.0.5] - 2026-10-17

([compare with 1.0.4](https://github.com/gabriel-macherini/SOBER-STT-8GB/compare/v1.0.4...v1.0.5))

### Fixed
- Dictation failed on fresh Windows installs whose default execution policy blocks scripts: the runner started the recorder host with `powershell -File rec-host.ps1`, the host died with `cannot be loaded because running scripts is disabled`, and every gesture ended in the generic "Dictation failed" balloon. The host now spawns with `-ExecutionPolicy Bypass`, which applies to that child process only; machines that already allowed scripts never noticed.

## [1.0.4] - 2026-10-17

([compare with 1.0.3](https://github.com/gabriel-macherini/SOBER-STT-8GB/compare/v1.0.3...v1.0.4))

### Fixed
- Pasting dropped the Ctrl modifier in some sessions: `pasteText` now sends raw `keybd_event` with 60 ms gaps instead of WSH `SendKeys("^v")`, which could deliver a bare `v` and paste nothing.
- The tray treated any non-empty reply as success, so the runner's `403 {"ok":false,"error":"bad-token"}` (per-boot token, file deleted on shutdown, so a missing or stale file is normal after a reboot) looked like a started recording: the overlay flashed, nothing was recorded, nothing was pasted and no error was shown. API calls now check the status code, reload the token and retry once.
- The tray read `sober-stt.token` only once, at startup, and only from the state dir; it now falls back to `%TEMP%\sober-stt.token` (the runner writes both) and re-reads on auth failure. A start that the runner refuses is now reported instead of flashing.
- The tray can relink itself: if `/health` does not answer with a valid token it drops the process holding the API port and starts a fresh runner, instead of staying stuck on a runner it cannot authenticate against.
- The installed app now matches the repository byte for byte. A Windows build machine with `core.autocrlf=true` (the GitHub runner default) checked out CRLF text files, and the installer ships them as they are, so `runner.mjs`, `rec-host.ps1`, `config.json`, `lib/` and `prompts/` differed from the source. `.gitattributes` pins LF for the tree and `npm run check` fails if a shipped file comes out CRLF.
- `SOBER-STT.exe` now stamps its own version resource. Windows file properties used to report the AutoHotkey base version (`2.0.30`) instead of the app version, because nothing overrode Ahk2Exe's default.

### Changed
- `%TEMP%\sober-stt.log` lines are timestamped, and every dictation logs one outcome line (`PIPE seq=… ok=… error=… pasted=… chars=…`), so "balloon flashed, nothing pasted" can be diagnosed from the log.

## [1.0.3] - 2026-10-16

([compare with 1.0.2](https://github.com/gabriel-macherini/SOBER-STT-8GB/compare/v1.0.2...v1.0.3))

### Added
- Demo GIFs in the README: dictating with the live overlay, and the tray menu.
- `README.pt-BR.md`, plus `docs/configuration.md`, `docs/api.md`, `docs/troubleshooting.md` and `docs/building.md`.

### Changed
- README is a first-time-user document: pitch, install, use, how it works, privacy, docs index. It states its focus up front (one gesture, plug and play, zero VRAM when idle, NVIDIA and CUDA only for now). Reference material moved into `docs/`, and the two languages are now two files instead of one.
- Installer GPU warnings now say the bundled binaries are CUDA-only, instead of promising a CPU fallback the app does not implement.
- `docs/machine-setup.md` absorbed the dev-machine table and the measured latencies, and no longer claims the API is auth-free (it needs the per-boot token).

### Fixed
- The release workflow locates Ahk2Exe instead of assuming the Chocolatey package layout, which is what broke the first 1.0.2 release build.
- `tools/check-version.mjs` reads the build example from `docs/building.md`, where it now lives.

## [1.0.2] - 2026-10-16

([compare with 1.0.1](https://github.com/gabriel-macherini/SOBER-STT-8GB/compare/v1.0.1...v1.0.2))

### Added
- Loopback API auth: per-boot token (`X-SOBER-Token`) + Host/Origin checks (web pages can no longer drive the mic).
- Tray: temp-folder / copy-last-transcript menu, error balloon, Esc cancels recording, overlay on the mouse monitor, app version in Help/tooltip.
- `GET /last` endpoint; runner log to `sober-stt.log`; 20 unit tests + CI.
- Installer: SHA-256 verification of downloads, settings cleanup on uninstall.
- Docs: requirements/privacy/troubleshooting/API tables, SECURITY.md, vendoring note.

### Fixed
- PT download list empty, spaces in paths, crash without PowerShell 7, `config.local.json` ignored by tray, model-dir mismatch, recorder queue desync, silent failures.

### Changed
- Last WAV deleted after every dictation (`"keepLastJson": false` disables the transcript file); clipboard restored after paste; focused window restored before pasting.

## [1.0.1] - 2026-10-15

([compare with 1.0.0](https://github.com/gabriel-macherini/SOBER-STT-8GB/compare/v1.0.0...v1.0.1))

### Added
- Trilingual list triggers (`lista`/`dois pontos`, `list`/`colon`, `liste`/`deux-points`, literal `:`) with same-language few-shot bias in PT/EN/FR.
- List-aware chunking for long dictations (>60 words, ~40-word pieces, lists never split), with a tray toggle (on by default).
- Per-slot model switching from the tray (Transcription / EN / PT-FR), validated and persisted per machine.
- Tray Help window with usage, normalization check, and clickable GitHub link.
- Four UI languages (English base, Português, Français, Español) in the installer and the app, persisted across reboots.
- Install-time GPU compatibility check (missing NVIDIA / too-old CUDA families / <6 GB VRAM), each with continue-or-cancel.
- `prompts/stt-system-prompt-v2.md` test prompt + `promptFile` switching in `config.json`.
- `installer/downloads.json` versioned manifest (shown verbatim in the wizard) and per-item download resume.
- `GET /health` now reports dependency files and active models.

### Fixed
- Pinned llama.cpp b11429 removed `--no-mmap` and deprecated template kwargs (servers died on spawn → 30 s stalls): flags are now probed per binary (`--load-mode none` / `--reasoning off` vs legacy), old builds keep working.
- Accent-less French misrouted to the EN-only model; language detection now scores PT/FR function words.
- Accent-less PT tech sentences (`mostra os locks…`, `aperta entre…`) misrouted to EN.
- S1 ignoring an explicit list cue now falls back to Qwen instead of returning prose.
- Ready-page download list rendered as one broken line; destination page showed only ~100 MB instead of ~5.9 GB.

### Changed
- Temp files renamed `opencode-stt.*` → `sober-stt.*` (`sober-stt.wav`, `.level`, `.phase`, `.last.json`); tray log is `sober-tray.log`.
- Brand is SOBER-STT everywhere user-visible (tray tips, Help, README); README is English-first with no Portuguese leftovers in the EN section.

### Removed
- All toast notifications (state stays on the tray icon + overlay; failures land in `sober-stt.last.json`).
- The experimental cross-chunk list renumbering toggle.

## [1.0.0] - 2026-10-14

- First one-click installer: folder choice, Desktop/Start icons, Start-with-Windows task, model + CUDA binary downloads, uninstaller with keep-models option.
- Portable zero-dependency build (compiled tray `.exe`, portable Node, no AutoHotkey needed on target).
- `config.json` machine config, vendored `lib/`, `POST /models` groundwork, autostart tray item.
