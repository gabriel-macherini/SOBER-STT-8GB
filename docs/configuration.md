# Configuration

Machine paths live in `config.json`, relative to the install folder. Absolute
paths and `%ENV%` references also work. A `config.local.json` next to it
(gitignored) overrides values on dev machines.

| Key | Default | What |
|---|---|---|
| `parakeetBin` / `parakeetModel` | `bin/whisper/...` / `models/ggml-parakeet-...bin` | Transcriber binary and model |
| `llamaBin` / `s1Model` / `qwenModel` | `bin/llama/...` / `models/...` | LLM server binary and models |
| `parakeetThreads` | `6` | Match your CPU core count |
| `runnerPort` / `s1Port` / `qwenPort` | `8791` / `8080` / `8081` | Local ports. The tray reads `runnerPort` from `config.json` plus `config.local.json` |
| `tmpDir` | empty (`%TEMP%`) | Where the WAV, level, phase, log and last-transcript files live |
| `promptFile` | `prompts/stt-system-prompt.md` | Normalizer prompt. `prompts/stt-system-prompt-v2.md` is there for A/B tests, and `last.json` records which one ran |
| `keepLastJson` | `true` | Keep `%TEMP%\sober-stt.last.json` (raw and pasted text) for debugging. `false` writes nothing |
| `preserveClipboard` | `true` | Restore the clipboard text about 400 ms after pasting |

## Overlay and gesture constants

These are not in `config.json`. They live at the top of `voice-tray.ahk`:

| Constant | Default | What |
|---|---|---|
| `TAP_MAX` / `GAP` / `HOLD_MIN` | 400 / 800 / 200 ms | Gesture timing |
| `BARS` / `BARW` / `BARGAP` / `BARH` | 17 / 4 / 5 / 30 | Overlay bar geometry |
| `COL_REC` / `COL_TRA` / `COL_NOR` | green / orange / blue | Phase colors |
| `VOICE_DEBUG` | `false` | Gesture log in `%TEMP%\sober-tray.log` |

## Tray menu

**Keep models loaded**, **Start with Windows**, **Split long texts (chunks)**
(on by default, persisted in `%APPDATA%\SOBER-STT-8GB\chunk.state`),
**Switch model**, **Open folder**, **Open temp folder**, **Copy last
transcript**, **Help** (shows the app version), **Exit**, plus a **Language**
submenu (English, Português, Français, Español, persisted in
`%APPDATA%\SOBER-STT-8GB\locale`). All choices survive reboots. The app
follows the selected UI language.

## Swapping models

Drop a `.gguf` (LLM) or `.bin` (Parakeet) into `models/` and pick it in
**Switch model**, per slot: transcription, EN normalization, PT/FR
normalization. The runner validates the extension and the `GGUF` magic,
applies it immediately (LLM servers reload on next use), and persists the
choice in `%APPDATA%\SOBER-STT-8GB\models.override.json`. "Installer default"
resets it. Files over 3 GB ask for confirmation, because of the 8 GB VRAM
risk.
