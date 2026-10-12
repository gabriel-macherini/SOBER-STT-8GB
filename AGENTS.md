# AGENTS.md - voice-cli

Guidelines for AI agents working in this repository.

## Architecture

Two processes, each simple:

- `voice-tray.ahk` (AutoHotkey v2) - tray icon, CapsLock gesture
  (double-tap-and-hold, `~` passthrough so CapsLock stays native), wave
  overlay (child-window bars, color per phase), runner lifecycle, warm-toggle
  persistence (`warm.state`). Singleton via `#SingleInstance`.
- `runner.mjs` (Node 22, ESM, no deps) - HTTP API on `127.0.0.1:8791`,
  spawns `rec-host.ps1`, reuses the opencode-voice `lib/` pipeline by absolute
  `file://` import. `/stop` is async: returns `{started, seq}` at once, result
  via `GET /result?seq=N`, so the AHK thread never blocks and the overlay keeps
  repainting through the phases.
- `rec-host.ps1` - persistent winmm recorder. Compiles the C# once, then
  `start <wav> <levelFile>` / `stop` / `quit` over stdin. Also publishes mic
  peak (0-100) per ~100 ms buffer for the overlay.

## Key invariants

- Absolute paths to the author's machine (`C:/Users/the_s/...`) at the top of
  `runner.mjs` / `rec-host.ps1` and the `LIB` import. Port to a new machine by
  editing those constants, not the logic.
- Never `await` the LLM pre-warm in `/start`, and always `.catch()` it: an
  unhandled rejection kills Node and takes the recorder host down.
- Idle = zero VRAM: 60 s idle kill (cold) or warm loop touching the plugin's
  120 s timer (warm). Pre-warm qwen only; s1 stays on demand (VRAM headroom
  next to Parakeet's peak on 8 GB).
- `warm.state` is local state (gitignored). Overlay/label colors and gesture
  timings are constants at the top of `voice-tray.ahk`.

## Verify

```powershell
node --check runner.mjs
& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut /Validate voice-tray.ahk
(Invoke-WebRequest http://127.0.0.1:8791/health -UseBasicParsing).Content
```
