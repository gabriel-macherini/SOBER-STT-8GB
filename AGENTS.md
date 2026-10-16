# AGENTS.md - SOBER-STT-8GB

Guidelines for AI agents working in this repository.

## Architecture

Two processes, each simple:

- `voice-tray.ahk` (AutoHotkey v2) - tray icon, CapsLock gesture
  (double-tap-and-hold, `~` passthrough so CapsLock stays native; short
  double-tap or Esc-while-recording cancels), wave overlay (child-window
  bars, color per phase, centered on the mouse monitor), runner lifecycle,
  token loading (`sober-stt.token`), toggles in `%APPDATA%\SOBER-STT-8GB`.
  Singleton via `#SingleInstance`. Includes `locale.ahk` (never put a
  space before `;` inside a string).
- `runner.mjs` (Node 22, ESM, no deps) - HTTP API on `127.0.0.1:8791`
  (loopback only + per-boot `X-SOBER-Token` + Host/Origin checks),
  spawns `rec-host.ps1`, uses the vendored `lib/` pipeline (see
  `docs/vendor-lib.md`). `/stop` is async: returns `{started, seq}` at
  once, result via `GET /result?seq=N`, so the AHK thread never blocks
  and the overlay keeps repainting through the phases. Endpoints: `/start`,
  `/stop`, `/result`, `/last`, `/cancel`, `/kill`, `/warm`, `/chunk`,
  `/models`, `/health`.
- `rec-host.ps1` - persistent winmm recorder. Compiles the C# once, then
  takes one JSON object per line over stdin
  (`{"cmd":"start","wav":"...","level":"..."}` / `{"cmd":"stop"}` /
  `{"cmd":"quit"}`; legacy plain lines still accepted). Also publishes mic
  peak (0-100) per ~100 ms buffer for the overlay.

## Key invariants

- Machine paths come from `config.json`, optionally overridden by
  `config.local.json` (gitignored, never committed). The tray honors both
  for `runnerPort`. No hardcoded machine paths (the one `C:/Users/the_s`
  left in `lib/stt.js` is dead plugin code).
- Runtime state lives in `%APPDATA%\SOBER-STT-8GB` (warm/chunk/locale/model
  overrides/token), never next to the script. No hardcoded machine paths
  (a stale absolute path left in `lib/stt.js` is dead plugin code). Temp files
  (`sober-stt.wav/.level/.phase/.last.json/.log`) live in `tmpDir`
  (`%TEMP%` by default); the WAV is deleted after every pipeline.
- Never `await` the LLM pre-warm in `/start`, and always `.catch()` it: an
  unhandled rejection kills Node and takes the recorder host down.
- Idle = zero VRAM: 60 s idle kill (cold) or warm loop touching the plugin's
  120 s timer (warm). Pre-warm qwen only; s1 stays on demand (VRAM headroom
  next to Parakeet's peak on 8 GB).
- `version.txt` is the version source of truth; `tools/check-version.mjs`
  enforces installer AppVersion == CHANGELOG == README example == `APPVER`.
- Overlay/label colors and gesture timings are constants at the top of
  `voice-tray.ahk`. `lib/` is vendored: don't hand-edit semantics, and keep
  `STT_SYSTEM_PROMPT` in sync with `prompts/stt-system-prompt.md`
  (`test/units.test.mjs` enforces it).

## Verify

```powershell
npm test            # 20 unit cases (node --test, no deps)
npm run check       # node --check + version drift check
& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut /Validate voice-tray.ahk
$tok = Get-Content $env:TEMP\sober-stt.token -Raw
(Invoke-WebRequest http://127.0.0.1:8791/health -Headers @{'X-SOBER-Token'=$tok.Trim()} -UseBasicParsing).Content
```
