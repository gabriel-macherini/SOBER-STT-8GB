# SOBER-STT-8GB

Local voice dictation for Windows. Small by design: one gesture, nothing to configure, zero VRAM when idle. Tuned for an 8 GB card.

![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D4?logo=windows&logoColor=white)
![Node](https://img.shields.io/badge/Node-22+-339933?logo=node.js&logoColor=white)
![AutoHotkey](https://img.shields.io/badge/AutoHotkey-v2-334455?logo=autohotkey&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green)
![Local](https://img.shields.io/badge/100%25%20local-no%20cloud-blue)

[Português](README.pt-BR.md)

![Dictating into OpenCode: the overlay shows Recording with live mic bars while the text lands in the prompt](docs/media/dictation-overlay.gif)

Double-tap and hold **CapsLock**, speak, release. Your words are transcribed locally, cleaned up by a local LLM, and pasted into the window with focus. Warm dictation lands in about a second on an RTX 3070.

## Design

Four constraints shape everything here.

- One gesture. Double-tap and hold CapsLock, nothing to bind, nothing to open before the first dictation. CapsLock keeps its normal job the rest of the time, and the gesture timings are constants at the top of `voice-tray.ahk` if you want to tune them.
- Plug and play. The installer brings the runtime, the models, and the CUDA binaries, asks for no admin rights, and writes every machine path into `config.json` so the folder can move to another PC.
- Zero VRAM when idle. Models load on demand and die 60 s after the last dictation, or immediately on Exit. That is what makes an 8 GB card enough. The trade is disk: about 5 GB of models.
- Few moving parts. The runner is one Node file with no npm dependencies, recording is a single persistent PowerShell host, and the pipeline lives in a vendored `lib/` folder.

NVIDIA only, for now. Both engines ship as CUDA builds, and that is where the 8 GB target comes from. On AMD it is not plug and play: llama.cpp publishes Windows Vulkan builds, whisper.cpp does not, so transcription there would need a build from source or would run at CPU speed.

## Install

Download `SOBER-STT-Setup-*.exe` from [Releases](https://github.com/gabriel-macherini/SOBER-STT-8GB/releases/latest) and run it. The wizard asks for a folder (default `%LocalAppData%\SOBER-STT-8GB`, no admin rights needed) and a UI language, then checks your GPU. It lists exactly what it will download: about 5 GB of models and CUDA binaries, skipped when already present. Nothing else is needed on the target machine, no Node, no AutoHotkey, no clone.

| Need | Minimum | Notes |
|---|---|---|
| OS | Windows 10/11 x64 | The recorder and the paste step are Windows-only |
| GPU | NVIDIA, 6+ GB VRAM | Everything the installer ships is CUDA; AMD would need a manual Vulkan build |
| Disk | ~6 GB free | About 5 GB downloaded, plus staging during install |
| Mic | Any default Windows input | Check Settings > Privacy > Microphone if nothing records |
| Shell | PowerShell 7 | Falls back to `powershell.exe` 5.1 on its own |

## Use

1. Double-tap **CapsLock** and hold the second tap. The overlay shows live mic bars.
2. Speak.
3. Release. The cleaned text is pasted where your cursor is.

The bars carry the phase color: green while recording, orange while transcribing, blue while normalizing. Esc cancels a recording. The tray menu holds the toggles, model switching, folder shortcuts, and Exit, which frees VRAM on the spot.

![The tray menu: toggles, Switch model and Language submenus, folder shortcuts, Exit](docs/media/tray-menu.gif)

## How it works

```
CapsLock (AutoHotkey tray app)
   │  double-tap-and-hold → POST /start
   ▼
rec-host.ps1 ── mic ──► sober-stt.wav (+ live level 0-100)
   │  release → POST /stop (async, returns {seq} at once)
   ▼
parakeet-cli ──► raw text ──► s1 (EN) / Qwen (PT/FR) ──► cleaned text
   │  GET /result?seq=N
   ▼
clipboard + Ctrl+V ──► focused window
```

The tray app and the Node runner talk over loopback only, behind a per-boot token, so a web page cannot reach your mic.

- `/stop` returns at once and the tray polls for the result, so the overlay keeps repainting through transcribing and normalizing.
- Recording pre-warms Qwen in the background. s1 stays on demand to leave VRAM headroom.
- The normalizer prompt ships with the app and fixes punctuation, filler words, and code homophones (`Jason` to `JSON`), while keeping the language you dictated in.

## Privacy

Audio never leaves the machine. Transcription and normalization run locally, and the only network access is the installer fetching models and GPU binaries once, from Hugging Face and GitHub. The WAV is deleted after every dictation. The last transcript stays in `%TEMP%\sober-stt.last.json` unless you set `keepLastJson` to false.

## Docs

| Doc | What is in it |
|---|---|
| [configuration](docs/configuration.md) | `config.json` keys, overlay constants, swapping models |
| [api](docs/api.md) | Loopback endpoints, the token, a PowerShell example |
| [troubleshooting](docs/troubleshooting.md) | Nothing records or pastes, logs, port conflicts |
| [building](docs/building.md) | Running from source, portable + installer builds, release flow, CI |
| [machine setup](docs/machine-setup.md) | The machine this was tuned on, measured latencies |
| [vendored lib](docs/vendor-lib.md) | Where `lib/` comes from and how to update it |

## Credits and licenses

MIT for this repo. The installer fetches third-party weights and binaries: Parakeet TDT v3 (NVIDIA, CC-BY-4.0), Qwen3 (Apache-2.0), llama.cpp and whisper.cpp builds (MIT), s1-mini (see its model card). Check each upstream for its terms.

## License

MIT, see [LICENSE](LICENSE).
