# Local API

The runner listens on loopback only, `127.0.0.1:8791` by default (see
`runnerPort`), and every request needs the per-boot token from
`%TEMP%\sober-stt.token` in the `X-SOBER-Token` header. Host and Origin are
checked as well, so a web page cannot reach your mic. That is enough to build
your own front end: a Stream Deck, a hotkey script, a different overlay.

| Endpoint | What |
|---|---|
| `POST /start` | Start recording |
| `POST /stop {"pid":1234}` | Stop, transcribe, normalize, paste. Returns `{seq}` at once, and focuses the `pid` window first |
| `GET /result?seq=N` | Poll the pipeline result |
| `GET /last` | Last transcript (`raw`, `text`, `error`, `prompt`) |
| `POST /cancel` | Cancel the recording |
| `POST /kill` | Kill the LLM servers and free VRAM |
| `POST /warm {"enabled":bool}` | Keep models loaded |
| `POST /chunk {"enabled":bool}` | Chunk long dictations |
| `POST /models {"slot","file"}` | Switch the model file for a slot |
| `GET /health` | `{recording, processing, phase, modelsDir, tmpDir, deps}` |

## Example

```powershell
$tok = (Get-Content $env:TEMP\sober-stt.token -Raw).Trim()
(Invoke-WebRequest http://127.0.0.1:8791/health `
  -Headers @{ 'X-SOBER-Token' = $tok } -UseBasicParsing).Content
```

The `deps` field in that response is the quickest way to see what the runner
found: binary paths, model files, and whether PowerShell 7 is present.
