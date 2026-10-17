# Machine setup (performance reference)

Everything outside this repo that affects speed or quality, in one place.
Nothing here is a secret: no API keys or credentials exist anywhere in this
pipeline. Every endpoint is loopback, and the runner asks for a per-boot token
that lives in `%TEMP%\sober-stt.token`.

## The machine this was tuned on

| Piece | What | Notes |
|---|---|---|
| OS | Windows 11, RTX 3070 8 GB, Ryzen 5 5600 | The VRAM policy is tuned for 8 GB |
| Node | 22, on `PATH` | ESM, zero npm dependencies |
| AutoHotkey | v2 (`AutoHotkey64.exe`) | Runs `voice-tray.ahk` |
| Mic | Fifine Hub as the Windows default input | Native winmm through `rec-host.ps1`, because `sox -d` is broken on Win11 |
| Transcriber | `bin\whisper\parakeet-cli.exe` (whisper.cpp CUDA build) plus `ggml-parakeet-tdt-0.6b-v3-q8_0.bin` (669 MB) | About 950 ms per dictation |
| LLM servers | `bin\llama\llama-server.exe` plus `s1-mini` (484 MB, EN) and `Qwen3-4B` (2.5 GB, PT/FR) | Spawned on demand. Vendored from [opencode-voice](https://github.com/gabriel-macherini/opencode-voice) |
| Pipeline code | `lib/`, vendored from opencode-voice, paths from `config.json` | STT and normalization logic live here |

## Audio input

- Windows default input: Fifine Hub (USB). The recorder (`rec-host.ps1`)
  opens winmm at **16 kHz / mono / 16-bit**; if the device runs at 48 kHz,
  Windows resamples transparently (negligible CPU).
- Quality lever that matters most: mic gain + room noise, not software.
  Keep the Fifine as default; `stt.mic` selection only matters with
  multiple mics.

## Transcriber (Parakeet, lives in opencode-voice `lib/stt.js`)

- Binary: whisper.cpp CUDA 12.4 build with parakeet support.
- Model: `ggml-parakeet-tdt-0.6b-v3-q8_0.bin` (~640 MB), 25 languages.
- Flags: `-np -t 6` — 6 threads = the 6 cores of the dev Ryzen 5600.
  Scale `-t` to your core count on another machine.
- Measured: ~950 ms per dictation including process spawn + model load,
  so no persistent STT server is worth the complexity.

## LLM servers (llama.cpp, lives in opencode-voice `lib/local-llm-manager.js`)

Source of truth is the plugin repo; copied here for reference:

| Flag | Value | Why |
|---|---|---|
| `-c` | 2048 | Short normalization prompts never need more |
| `--temp` | 0 | Deterministic cleanup output |
| `-ngl` | 99 | Full GPU offload (8 GB card) |
| `--no-mmap` / `--load-mode none` | — | Full load each start (~1–1.5 s, hidden by pre-warm); avoids mmap page-fault stutter. `--no-mmap` on old builds, `--load-mode none` on new ones (`local-llm-manager.js` probes the binary and picks) |
| `--reasoning off` (new) / `--chat-template-kwargs '{"enable_thinking":false}'` (old) | — | Thinking disabled: deterministic cleanup output (also probed per binary) |
| `--flash-attn` | on | Faster attention on RTX |
| threads | default (all cores) | Matches the 6-core CPU |

This repo's policy on top: pre-warm **qwen only** at record start
(s1 stays on demand — s1+qwen+Parakeet peaks would leave no 8 GB headroom),
60 s idle kill when cold, persisted warm toggle otherwise.

## Measured latencies (RTX 3070)

Numbers from the machine above; yours will differ.

| Step | Cold | Warm |
|---|---|---|
| Record start | ~80 ms | ~80 ms |
| Transcribe | ~950 ms | ~950 ms |
| Qwen normalize | ~1550 ms | ~95 ms |
| s1 normalize | ~900 ms | ~65 ms |

## Deliberately NOT touched

- **Defender exclusions** for models/binaries: would shave milliseconds off
  loads at the cost of protection. Not worth it, not documented as a step.
- **GPU clocks / power plan**: out of scope for a dictation app.
- **`--no-mmap` / thread counts**: measured good, changing them risks the
  working setup for no proven gain.

## Fresh-machine checklist

1. Windows 10/11, NVIDIA CUDA-capable GPU.
2. Run the installer (`dist/SOBER-STT-Setup-<version>.exe`, built by `pwsh tools/build-installer.ps1`; latest under [Releases](https://github.com/gabriel-macherini/SOBER-STT-8GB/releases/latest)) — models + CUDA binaries come from `installer/downloads.json`).
3. Only for source runs: Node 22+, AutoHotkey v2, and a `config.local.json`
   with your paths (see `config.json`); never commit it.
4. Match `parakeetThreads` to your core count, then re-measure with the
   table in [Measured latencies](#measured-latencies-rtx-3070).
