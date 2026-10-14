# 🎙️ SOBER-STT-8GB

Push-to-talk voice dictation for Windows, tuned for an 8 GB VRAM card.

![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D4?logo=windows&logoColor=white)
![Node](https://img.shields.io/badge/Node-22+-339933?logo=node.js&logoColor=white)
![AutoHotkey](https://img.shields.io/badge/AutoHotkey-v2-334455?logo=autohotkey&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green)
![Local](https://img.shields.io/badge/100%25%20local-no%20cloud-blue)

Push-to-talk voice dictation for Windows. Double-tap and hold **CapsLock**, speak, release — your words are transcribed locally, cleaned up by a local LLM, and pasted into whatever window has focus. No cloud, no subscription, no typing.

> 🇧🇷 Versão em português abaixo: [Português](#-opencode-voice-em-português)

## ✨ Features

- **🎤 CapsLock push-to-talk** — double-tap and hold to record, release to paste. CapsLock keeps working normally otherwise.
- **🧠 LLM normalization** — fixes punctuation, filler words, and code homophones (`Jason` → `JSON`, `sink` → `sync`), formats dictated lists, keeps PT/EN/FR in the original language.
- **🌊 Live overlay** — pill-style wave bars at the bottom of the screen, colored by phase: 🟢 recording → 🟠 transcribing → 🔵 normalizing.
- **🎮 Gamer-friendly VRAM policy** — idle means zero VRAM. Models load on demand and die 60 s after last use (or instantly on quit).
- **💾 It remembers** — the "keep models loaded" toggle persists across restarts.
- **🪟 Works everywhere** — pastes into any focused window: Zed, VS Code, browser, Obsidian.

## 📦 Install (end user)

Download `SOBER-STT-Setup-*.exe` from Releases and run it. One click:

1. Pick a folder (default `%LocalAppData%\SOBER-STT-8GB`, no admin needed).
2. Pick a language (English / Português / Français / Español) — it seeds the app's UI language.
3. Check Desktop / Start Menu icons and **Start with Windows** if you want them.
4. The wizard checks your GPU (NVIDIA + 6+ GB VRAM recommended; warns on old/small/absent cards) and shows exactly what it downloads (name + version + size, see `installer/downloads.json`) — ~4.5 GB of models and GPU binaries, skipped if already present — then leaves the app ready to dictate.

No Node, no AutoHotkey, no repo clone needed on the target machine.
Requires Windows 10/11 x64 and (for good speed) an NVIDIA GPU with a CUDA driver.

## 🚀 Quick start (from source)

```powershell
# 1. Requirements: Windows, Node 22+, AutoHotkey v2
# 2. Set up the voice toolchain once (see "Setup this was built for" below)
# 3. Run the tray app (or double-click the desktop shortcut):
& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" "C:\path\to\SOBER-STT-8GB\voice-tray.ahk"
```

1. Double-tap **CapsLock** and hold the second tap.
2. Speak. The overlay shows live mic bars.
3. Release. The cleaned text is pasted where your cursor is.

Right-click the tray icon → **Sair** to quit (frees VRAM immediately).

## 🖥️ Setup this was developed for

This project was built for and tested on exactly this machine. Porting it elsewhere means adapting these paths (constants at the top of `runner.mjs` / `rec-host.ps1`):

| Piece | Path on the dev machine | Notes |
|---|---|---|
| OS | Windows 11, RTX 3070 8 GB, Ryzen 5 5600 | VRAM policy tuned for 8 GB |
| Node | 22 (`node` on `PATH`) | ESM, zero npm dependencies |
| AutoHotkey | v2 (`AutoHotkey64.exe`) | Runs `voice-tray.ahk` |
| Mic | Fifine Hub as Windows default input | Native winmm via `rec.ps1` (`sox -d` is broken on Win11) |
| Transcriber | `bin\whisper\parakeet-cli.exe` (whisper.cpp CUDA build) + `ggml-parakeet-tdt-0.6b-v3-q8_0.bin` (~640 MB) | ~950 ms per dictation |
| LLM servers | `bin\llama\llama-server.exe` + `s1-mini` (462 MB, EN) + `Qwen3-4B` (2.3 GB, PT/FR) | Spawned on demand, see [opencode-voice](https://github.com/gabriel-macherini/opencode-voice) |
| Pipeline code | `lib/` (vendored from opencode-voice, paths via `config.json`) | STT + normalization logic lives here |

## 📥 Will a fresh clone work first try?

End users should use the installer above. From source, you need the toolchain first: Windows 10/11 with Node 22+ and AutoHotkey v2, plus binaries + models laid out as in `config.json` (or override paths in `config.local.json`). Then run `voice-tray.ahk`, double-tap-hold CapsLock, speak.

## ⚙️ Configuration

Machine paths live in `config.json` (relative to the install folder; absolute paths and `%ENV%` also work). A `config.local.json` next to it (gitignored) overrides values on dev machines.

| Key | Default | What |
|---|---|---|
| `parakeetBin` / `parakeetModel` | `bin/whisper/...` / `models/ggml-parakeet-...bin` | Transcriber binary + model |
| `llamaBin` / `s1Model` / `qwenModel` | `bin/llama/...` / `models/...` | LLM server binary + models |
| `parakeetThreads` | `6` | Match your CPU cores |
| `runnerPort` / `s1Port` / `qwenPort` | `8791` / `8080` / `8081` | Local ports (tray app reads `runnerPort` too) |

Gesture/overlay knobs still live at the top of `voice-tray.ahk`:

| Constant | Default | What |
|---|---|---|
| `TAP_MAX` / `GAP` / `HOLD_MIN` | 400 / 800 / 200 ms | Gesture timing |
| `BARS` / `BARW` / `BARGAP` / `BARH` | 17 / 4 / 5 / 30 | Overlay bar geometry |
| `COL_REC` / `COL_TRA` / `COL_NOR` | green / orange / blue | Phase colors |
| `VOICE_DEBUG` | `false` | Gesture log in `%TEMP%\voice-tray.log` |

Tray menu: **Manter modelos carregados** + **Iniciar com o Windows** (persisted in `%APPDATA%\SOBER-STT-8GB\` / `HKCU\...\Run`), **Trocar modelo**, **Abrir pasta**, **Ajuda**, **Sair** — plus a **Language** submenu (English / Português / Français / Español, persisted in `%APPDATA%\SOBER-STT-8GB\locale`). All three choices (warm, autostart, language) survive reboots.

### 🔀 Swapping models

Drop a `.gguf` (LLM) or `.bin` (Parakeet) into `models/` and pick it in **Trocar modelo** (per slot: transcription, EN normalization, PT/FR normalization). The runner validates extension + `GGUF` magic, applies immediately (LLM servers reload on next use), and persists in `%APPDATA%\SOBER-STT-8GB\models.override.json` ("Padrão do instalador" resets). Files over 3 GB ask for confirmation (8 GB VRAM risk).

## 🏗️ How it works

```
CapsLock (AHK tray app)
   │  double-tap-and-hold → POST /start
   ▼
rec-host.ps1 ── mic ──► opencode-stt.wav (+ live level 0-100)
   │  release → POST /stop (async, returns {seq} at once)
   ▼
parakeet-cli ──► raw text ──► s1 (EN) / Qwen (PT/FR) ──► cleaned text
   │  GET /result?seq=N
   ▼
clipboard + Ctrl+V ──► focused window
```

- `/stop` never blocks: the overlay keeps repainting through `transcribing → normalizing → idle` (a blocking call used to freeze it).
- Recording pre-warms Qwen in the background, so cold starts feel warm. s1 stays on demand to protect VRAM headroom.
- Quitting calls `/kill`: LLM servers die on the spot.

## 📊 Measured latencies (RTX 3070)

| Step | Cold | Warm |
|---|---|---|
| Record start | ~80 ms | ~80 ms |
| Transcribe | ~950 ms | ~950 ms |
| Qwen normalize | ~1550 ms | ~95 ms |
| s1 normalize | ~900 ms | ~65 ms |

## 🗺️ Roadmap

- [x] Single `config.json` for all machine paths (portability)
- [ ] Optional TTS read-back (the sibling plugin already has the engine)
- [x] Packaged `.exe` via Ahk2Exe (no AutoHotkey install needed)

## 🔨 Building the installer

Prerequisites: AutoHotkey v2 (for Ahk2Exe) and Inno Setup 6 (`winget install JRSoftware.InnoSetup`).

```powershell
pwsh tools/build-portable.ps1   # dist/SOBER-STT: exe + Node portable + app files
pwsh tools/build-installer.ps1  # dist/SOBER-STT-Setup-1.0.0.exe
```

Download versions are pinned in `installer/downloads.json` (single source of truth — the wizard lists them verbatim). Bump a version there and rebuild.

## 📄 License

MIT — see [LICENSE](LICENSE).

---

## 🇧🇷 OpenCode Voice em português

Ditada por voz push-to-talk para Windows. Toque duas vezes no **CapsLock** e segure, fale, solte — a fala é transcrita localmente, normalizada por um LLM local e colada na janela em foco. Sem nuvem, sem assinatura.

### ✨ Recursos

- **🎤 CapsLock push-to-talk** — dois toques + segurar para gravar, soltar para colar. O CapsLock continua funcionando normal no resto do tempo.
- **🧠 Normalização por LLM** — pontuação, vícios de linguagem, homófonos de código (`Jason` → `JSON`), formata listas ditadas, mantém PT/EN/FR no idioma original.
- **🌊 Overlay ao vivo** — barrinhas em pílula no rodapé da tela, com cor por fase: 🟢 gravando → 🟠 transcrevendo → 🔵 normalizando.
- **🎮 VRAM amiga de quem joga** — parado = zero VRAM. Modelos sobem sob demanda e morrem 60 s após o uso (ou na hora ao sair).
- **💾 Lembra de você** — o toggle "manter modelos carregados" sobrevive a reinicializações.
- **🪟 Funciona em tudo** — cola em qualquer janela em foco: Zed, VS Code, navegador, Obsidian.

### 📦 Instalação

Baixe o `SOBER-STT-Setup-*.exe` em Releases e execute. Escolha a pasta, o idioma (English / Português / Français / Español), marque ícone na Área de Trabalho / Menu Iniciar e **Iniciar com o Windows** se quiser; o assistente checa sua GPU (NVIDIA com 6+ GB de VRAM recomendado, avisa se for antiga/fraca/ausente), baixa os modelos e binários (lista com versões em `installer/downloads.json`, ~4,5 GB) e deixa pronto para ditar. Sem Node, AutoHotkey ou clone na máquina alvo.

### 🚀 Início rápido (do código-fonte)

```powershell
# 1. Requisitos: Windows, Node 22+, AutoHotkey v2
# 2. Monte o toolchain de voz uma vez (seção "Setup" acima)
# 3. Rode o app de bandeja (ou o atalho do desktop):
& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" "C:\caminho\para\SOBER-STT-8GB\voice-tray.ahk"
```

1. Toque duas vezes no **CapsLock** e segure o segundo toque.
2. Fale. O overlay mostra as barrinhas do microfone ao vivo.
3. Solte. O texto limpo é colado onde está o cursor.

Botão direito no ícone da bandeja → **Sair** para encerrar (libera a VRAM na hora).

### 📥 Um clone fresco funciona de primeira?

Para uso normal, prefira o instalador acima. Do código-fonte, monte o toolchain antes: Windows 10/11 com Node 22+ e AutoHotkey v2, mais binários + modelos no layout do `config.json` (ou sobrescreva em `config.local.json`). Aí rode o `voice-tray.ahk`, dois toques + segurar o CapsLock, falar.

Menu da bandeja: **Manter modelos carregados** + **Iniciar com o Windows**, **Trocar modelo** (solte um `.gguf`/`.bin` em `models/` e selecione por função), **Abrir pasta**, **Ajuda**, **Sair** — mais o submenu **Idioma** (English / Português / Français / Español, lembrado entre reinicializações como os outros toggles).

### 📄 Licença

MIT — ver [LICENSE](LICENSE).
