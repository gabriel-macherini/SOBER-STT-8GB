# Machine setup (performance reference)

Everything outside this repo that affects speed or quality, in one place.
Nothing here is a secret: no API keys, tokens, or credentials exist anywhere
in this pipeline (all endpoints are `127.0.0.1`, auth-free).

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
4. Match `parakeetThreads` to your core count; re-measure with the
   table in [README](../README.md#measured-latencies-rtx-3070).
