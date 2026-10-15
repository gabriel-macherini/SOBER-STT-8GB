# Changelog — SOBER-STT

## [1.0.1]

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

## [1.0.0]

- First one-click installer: folder choice, Desktop/Start icons, Start-with-Windows task, model + CUDA binary downloads, uninstaller with keep-models option.
- Portable zero-dependency build (compiled tray `.exe`, portable Node, no AutoHotkey needed on target).
- `config.json` machine config, vendored `lib/`, `POST /models` groundwork, autostart tray item.
