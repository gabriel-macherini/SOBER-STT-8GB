# Troubleshooting

| Symptom | Fix |
|---|---|
| SmartScreen blocks the installer | It is unsigned. More info, then Run anyway |
| Nothing records | Settings > Privacy > Microphone: allow desktop apps. Check the Windows default input |
| AMD GPU | The bundled binaries are CUDA only. See the design note in [the README](../README.md#design) |
| Port conflict | Change `runnerPort` in `config.json` or `config.local.json`, then check `/health` |
| Text did not paste | Open `%TEMP%\sober-stt.last.json`: `raw` is what was heard, `text` what was pasted, `error` why it failed. The tray menu has Copy last transcript |

## Logs

| What | Where |
|---|---|
| Runner | `<tmpDir>\sober-stt.log`, `%TEMP%` by default |
| Gestures | `%TEMP%\sober-tray.log`, only with `VOICE_DEBUG` on |
| Last dictation | `%TEMP%\sober-stt.last.json` |

## Checking the runner

```powershell
$tok = (Get-Content $env:TEMP\sober-stt.token -Raw).Trim()
(Invoke-WebRequest http://127.0.0.1:8791/health `
  -Headers @{ 'X-SOBER-Token' = $tok } -UseBasicParsing).Content
```

Status 403 means the token is wrong or missing, which is usually a stale file
from an earlier boot. Restart the tray app and the runner writes a new one.
