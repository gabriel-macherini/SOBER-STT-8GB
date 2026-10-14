// Speech-to-text: mic recording, parakeet-cli transcription, LLM normalization.
//
// Vendored from the opencode-voice plugin repo (lib/stt.js) so SOBER-STT-8GB
// installs standalone. SOBER-STT-8GB adaptations: every machine-specific path
// below is overridable via configureSttRuntime(opts) (see config.json);
// defaults preserve the original dev-machine behavior.

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { spawn, execSync } from "node:child_process";
import { getActiveSessionTitle } from "./session.js";
import { createClient } from "./llm-client.js";
import { ensureServer, touchServer, killAll as killLocalServers } from "./local-llm-manager.js";

let sttApiEndpoint = null;
let sttApiModel = null;
let sttApiKeyEnv = null;

const WAV_FILENAME = "opencode-stt.wav";
let tmpDir = "/tmp";

// Machine-specific overrides, set via configureSttRuntime(opts). Defaults
// preserve the original dev-machine paths; the standalone runner passes
// absolute paths resolved from config.json.
let parakeetBinOverride = null;
let parakeetModelOverride = null;
let s1ModelPath = "C:/Users/the_s/models/s1-mini-q4_k_m.gguf";
let qwenModelPath = "C:/Users/the_s/models/Qwen3-4B-Q4_K_M.gguf";
let parakeetThreads = 6;
let s1Endpoint = "http://127.0.0.1:8080/v1";
let qwenEndpoint = "http://127.0.0.1:8081/v1";

const MODELS_DIRS = [
  path.join(os.homedir(), ".local", "share", "whisper-cpp"),
  "/opt/homebrew/share/whisper-cpp/models",
  "/usr/local/share/whisper-cpp/models",
];

// Single local engine: Parakeet TDT v3 via parakeet-cli (whisper.cpp build, GPU).
const MODELS = {
  "parakeet-tdt-v3-q8_0": {
    label: "Parakeet TDT v3 Q8",
    file: "ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
  },
};
const DEFAULT_MODEL = "parakeet-tdt-v3-q8_0";

export function isOpenRouterEndpoint(endpoint) {
  return /(^https?:\/\/)?([^/]+\.)?openrouter\.ai(\/|$)/i.test(endpoint || "");
}

function buildMultipartTranscriptionRequest(model, audioBuffer, apiKey) {
  const blob = new Blob([audioBuffer], { type: "audio/wav" });
  const form = new FormData();
  form.append("file", blob, "audio.wav");
  form.append("model", model);
  form.append("response_format", "json");

  const headers = {};
  if (apiKey) headers["Authorization"] = "Bearer " + apiKey;

  return {
    headers,
    body: form,
  };
}

export function buildOpenRouterTranscriptionRequest(model, audioBuffer, apiKey) {
  const headers = { "Content-Type": "application/json" };
  if (apiKey) headers["Authorization"] = "Bearer " + apiKey;

  const payload = {
    model,
    input_audio: {
      data: audioBuffer.toString("base64"),
      format: "wav",
    },
  };

  return {
    headers,
    body: JSON.stringify(payload),
  };
}

function getModelsDir() {
  for (const dir of MODELS_DIRS) {
    if (fs.existsSync(dir)) return dir;
  }
  return MODELS_DIRS[0];
}

function listInputDevices() {
  try {
    const json = execSync("system_profiler SPAudioDataType -json 2>/dev/null", {
      encoding: "utf-8",
      timeout: 5000,
    });
    const data = JSON.parse(json);
    return (data.SPAudioDataType?.[0]?._items || [])
      .filter((d) => d.coreaudio_input_source != null)
      .map((d) => d.coreaudio_device_name || d._name);
  } catch {
    return [];
  }
}

// ---- Recording state and control ----

let soxProc = null;
let soxStderr = "";
let recording = false;
let processing = false;

const IS_WIN = process.platform === "win32";
const REC_SCRIPT = "C:/Users/the_s/bin/rec.ps1"; // ponytail: native winmm recorder, sox -d is broken on Win11

function forceKillSox(logger) {
  if (soxProc) {
    try {
      process.kill(soxProc.pid, "SIGKILL");
      logger?.log("STT", `Killed sox pid=${soxProc.pid}`, "debug");
    } catch {}
    soxProc = null;
  }
  if (IS_WIN) {
    try {
      execSync("taskkill /F /IM sox.exe 2>nul", { stdio: "ignore" });
    } catch {}
    return;
  }
  try {
    execSync("pkill -9 -f 'sox.*opencode-stt'", { stdio: "ignore" });
  } catch {}
}

function startRecording(kv, toast, logger) {
  if (soxProc) {
    logger?.log("STT", "Start recording skipped: sox already running", "debug");
    return;
  }

  const wavFile = path.join(tmpDir, WAV_FILENAME);
  forceKillSox(logger);
  try {
    fs.unlinkSync(wavFile);
  } catch {}

  soxStderr = "";
  const mic = kv.get("stt.mic", "") || null;
  const inputArgs = mic ? ["-t", "coreaudio", mic] : ["-d"];
  logger?.log("STT", `Starting recording mic=${mic || "system default"}`, "debug");

  soxProc = IS_WIN
    ? spawn("pwsh", ["-NoProfile", "-File", REC_SCRIPT, "-Out", wavFile], {
        stdio: ["ignore", "ignore", "pipe"],
        detached: false,
      })
    : spawn(
        "sox",
        [...inputArgs, "-r", "16000", "-c", "1", "-b", "16", wavFile, "silence", "1", "0.1", "1%"],
        {
          stdio: ["ignore", "ignore", "pipe"],
          detached: false,
        },
      );

  soxProc.stderr.on("data", (chunk) => {
    soxStderr += chunk.toString();
  });

  soxProc.on("error", (err) => {
    soxProc = null;
    logger?.log("STT", `Recording failed: ${err.message}`, "error");
    if (recording) {
      recording = false;
      toast(`Recording failed: ${err.message}`, "error");
    }
  });

  soxProc.on("exit", (code) => {
    soxProc = null;
    logger?.log(
      "STT",
      `sox exited code=${code} stderr=${soxStderr.trim()}`,
      code === 0 || code === null ? "debug" : "warn",
    );
    if (recording && code !== 0 && code !== null && !processing) {
      recording = false;
      const errLine = soxStderr.trim().split("\n").pop();
      toast(`Recording error: ${errLine || `sox exited (code=${code})`}`, "error");
    }
  });

  recording = true;
}

function stopRecording(logger) {
  logger?.log("STT", "Stopping recording", "debug");
  if (soxProc) soxProc.kill("SIGINT");
}

async function waitForSoxExit(logger, timeoutMs = 2000) {
  const start = Date.now();
  while (soxProc && Date.now() - start < timeoutMs) {
    await new Promise((r) => setTimeout(r, 100));
  }
  if (soxProc) {
    logger?.log("STT", "sox did not stop before timeout", "warn");
    forceKillSox(logger);
  }
}

function getModelName(kv) {
  const model = kv.get("stt.model", DEFAULT_MODEL);
  return MODELS[model] ? model : DEFAULT_MODEL;
}

function getModelPath(kv) {
  if (parakeetModelOverride) return parakeetModelOverride;
  return path.join(getModelsDir(), MODELS[getModelName(kv)].file);
}

// Absolute CLI path: bare names break CUDA DLL resolution on Windows (DLLs live next to the exe).
function parakeetBin() {
  if (parakeetBinOverride) return parakeetBinOverride;
  return IS_WIN ? "C:/Users/the_s/bin/whisper/parakeet-cli.exe" : "parakeet-cli";
}

export function isSttBusy() {
  return recording || processing;
}

export function isSttApiConfigured() {
  return Boolean(sttApiEndpoint && sttApiModel);
}

// ---- V2 runtime (also reused by the V1 registerSTT below) ----

// Apply plugin options to module state. Extracted so the V2 CLI entrypoint
// (tui.js) configures recording without the V1 `api` object.
export function configureSttRuntime(opts, logger) {
  if (opts?.sttEndpoint) {
    sttApiEndpoint = opts.sttEndpoint;
    sttApiModel = opts.sttModel || "whisper-large-v3-turbo";
    sttApiKeyEnv = opts.sttApiKeyEnv || null;
    logger?.log(
      "STT",
      `Configured STT API endpoint=${sttApiEndpoint} model=${sttApiModel}`,
      "debug",
    );
  }

  tmpDir = opts?.tmpDir || "/tmp";
  if (opts?.parakeetBin) parakeetBinOverride = opts.parakeetBin;
  if (opts?.parakeetModel) parakeetModelOverride = opts.parakeetModel;
  if (opts?.s1Model) s1ModelPath = opts.s1Model;
  if (opts?.qwenModel) qwenModelPath = opts.qwenModel;
  if (opts?.parakeetThreads) parakeetThreads = opts.parakeetThreads;
  if (opts?.s1Endpoint) s1Endpoint = opts.s1Endpoint;
  if (opts?.qwenEndpoint) qwenEndpoint = opts.qwenEndpoint;
  try {
    fs.mkdirSync(tmpDir, { recursive: true });
  } catch (err) {
    logger?.log("STT", `Failed to create tmpDir ${tmpDir}: ${err.message}`, "warn");
  }
  logger?.log("STT", `STT temp dir=${tmpDir}`, "debug");
}

export function isSttRecording() {
  return recording;
}

export function isSttProcessing() {
  return processing;
}

export function setSttProcessing(value) {
  processing = Boolean(value);
}

export function markSttIdle() {
  recording = false;
  processing = false;
}

export function getSttWavPath() {
  return path.join(tmpDir, WAV_FILENAME);
}

export function getSttModel(kv) {
  return getModelName(kv);
}

export function listSttModels() {
  return Object.entries(MODELS).map(([value, v]) => ({ value, label: v.label }));
}

export async function fetchSttApiModels(logger) {
  return getApiModels(logger);
}

export function listSttInputDevices() {
  return listInputDevices();
}

// Start recording; returns true when a recording is in progress.
export function startSttRecording(kv, toast, logger) {
  startRecording(kv, toast, logger);
  return recording;
}

export function stopSttRecording(logger) {
  stopRecording(logger);
}

export async function waitForSttExit(logger, timeoutMs) {
  await waitForSoxExit(logger, timeoutMs);
}

// Cancel an in-progress recording. Returns true when one was cancelled.
export function cancelSttRecording(logger) {
  if (recording) {
    recording = false;
    forceKillSox(logger);
    logger?.log("STT", "Recording cancelled", "debug");
    return true;
  }
  return false;
}

export function transcribeSttRecording(kv, logger) {
  return transcribe(kv, logger);
}

export function transcribeSttApiCall(kv, logger) {
  return transcribeApi(kv, logger);
}

// Timeout scales with file size: 60s base + 60s per 5MB, capped at 5min.
// WhatsApp voice notes are small; longer audios need headroom for parakeet-cli.
export function transcribeTimeoutForSize(bytes) {
  const extra = Math.floor((bytes || 0) / (5 * 1024 * 1024)) * 60000;
  return Math.min(60000 + extra, 300000);
}

function transcribe(kv, logger) {
  return transcribeAudioFile(path.join(tmpDir, WAV_FILENAME), kv, logger);
}

export function transcribeAudioFile(filePath, kv, logger, timeoutMs) {
  const mp = getModelPath(kv);
  logger?.log("STT", `Local file transcription requested model=${mp} file=${filePath}`, "debug");
  if (!fs.existsSync(mp)) {
    logger?.log("STT", `Parakeet model missing: ${mp}`, "error");
    return Promise.resolve({
      error: `Model not found: ${getModelName(kv)}. Download from huggingface.co/ggml-org/parakeet-GGUF`,
    });
  }
  if (!fs.existsSync(filePath)) {
    logger?.log("STT", `Audio file missing: ${filePath}`, "error");
    return Promise.resolve({ error: `Audio file not found: ${filePath}` });
  }
  const size = fs.statSync(filePath).size;
  if (size <= 44) {
    logger?.log("STT", `Audio file empty: ${filePath}`, "warn");
    return Promise.resolve({ error: "Audio file is empty - no audio captured" });
  }
  const timeout = timeoutMs || transcribeTimeoutForSize(size);

  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    // Single engine: parakeet-cli auto-detects language, -np keeps stdout clean.
    // -t matches the physical cores; the encoder is GPU-bound so this barely matters.
    const proc = spawn(parakeetBin(), ["-m", mp, "-f", filePath, "-np", "-t", String(parakeetThreads)], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    logger?.log("STT", `Started parakeet-cli pid=${proc.pid}`, "debug");

    proc.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    proc.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    const timer = setTimeout(() => {
      proc.kill("SIGKILL");
      logger?.log("STT", `parakeet-cli timed out after ${timeout}ms`, "error");
      resolve({ error: `Transcription timed out (${Math.round(timeout / 1000)}s)` });
    }, timeout);

    proc.on("error", (err) => {
      clearTimeout(timer);
      logger?.log("STT", `parakeet-cli error: ${err.message}`, "error");
      resolve({ error: `Transcription failed: ${err.message}` });
    });

    proc.on("exit", (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        logger?.log("STT", `parakeet-cli exited code=${code} stderr=${stderr.trim()}`, "error");
        resolve({
          error: stderr.trim().split("\n").pop() || `parakeet-cli exited (code=${code})`,
        });
        return;
      }
      logger?.log("STT", `Local transcription succeeded stdoutChars=${stdout.length}`, "debug");
      // -np already prints plain text; strip any residual timestamps/parentheticals.
      resolve({
        text: stdout
          .replace(/\[.*?\]/g, "")
          .replace(/\(.*?\)/g, "")
          .replace(/\s+/g, " ")
          .trim(),
      });
    });
  });
}

export const STT_SYSTEM_PROMPT = `You are a speech-to-text normalizer for a coding assistant CLI.

Clean up raw speech-to-text transcription into a clear, well-punctuated prompt. Rules:
- Fix punctuation, capitalization, and grammar
- Remove filler words (um, uh, like, you know, etc.)
- Keep technical terms, file names, and code references exact
- If the user is dictating code, format it appropriately
- Use the session context above to resolve ambiguous references (e.g. "that function", "the file", "it")
- Output ONLY the cleaned text, nothing else
- Do not add any commentary or explanation
- Keep the user's intent and meaning intact
- CRITICAL: Keep the original language (Portuguese, English, or French) - do NOT translate. If input is Portuguese, output Portuguese; if French, output French.

CRITICAL DOMAIN CORRECTIONS - Fix common STT homophone errors in software engineering contexts:
- "locks" -> "logs" (unless explicitly talking about mutexes/concurrency)
- "note" / "no" -> "node"
- "app and" -> "append"
- "sink" -> "sync"
- "a sink" -> "async"
- "doc" / "talker" / "dotter" -> "docker"
- "systray" -> "SystemTray"
- "capslock" -> "Caps Lock"
- "cash" -> "cache"
- "rap" -> "wrap"
- "Jason" -> "JSON"
- "get" -> "Git"
- "react" -> "React"
- "types creep" / "type script" -> "TypeScript"
- "bite" -> "byte"
- "string" -> "String"
- "int" -> "Int"
- "bullion" -> "boolean"

Rely heavily on context to fix words that sound similar to programming terminology.

ENGLISH TECHNICAL TERMS IN PORTUGUESE DICTATION - The user often says English
technical words while speaking Portuguese. Preserve them EXACTLY, never
translate or adapt to Portuguese spelling:
- Key names, always capitalized: Enter, Shift, Tab, Control (Ctrl), Alt, Escape (Esc), Space, Backspace, Delete, Caps Lock
- If the transcription shows a Portuguese homophone where a key or UI term fits
  the context, restore the capitalized English term ("entre" -> "Enter" when
  about the keyboard, "aba" stays "aba" for browser tab unless the user clearly said "tab").

FIDELITY - Remove ONLY filler words (uh, tipo assim, sabe, né? - note: PT "um"
is an article/numeral, keep it). Never drop
articles, nouns, verbs or other content words ("um arquivo" stays "um arquivo",
"eu quero" stays "eu quero"). Fix punctuation and homophones, keep every word.

ENUMERATED LISTS - When the user dictates items in sequence, output a numbered
list, one item per line:
- PT numerals (um, dois, três, quatro, cinco, ...) and ordinals (primeiro,
  segundo, terceiro, ...) are item markers: "texto um texto dois texto três" ->
  "1. texto\n2. texto\n3. texto"
- "um" after an item is the number 1, NOT the article ("texto um" is item 1;
  "um arquivo" with no enumeration is still the article "a file")
- Same for EN ("one, two, three") and FR ("un, deux, trois")
- Only do this for real enumerations; do not invent list structure in plain prose.
- Never break "item N" references onto their own line ("vai para o item 1"
  stays whole; it is a reference, not a new item).
- With a preamble, keep it as an intro line, then break: "quero uma lista:
  um, o menu amarelo. dois, o menu grande" ->
  "Quero uma lista:\n1. o menu amarelo\n2. o menu grande".
- Always render spoken numerals as digits in markers, even mid-sentence:
  "...grande e três, ele suma..." -> break as "3. ele suma...".
- Convert ordinal markers to digits too (Primeiro→1., first→1.),
  keeping the one-item-per-line layout.
- LIST TRIGGERS - the speaker explicitly announcing a list, in any language.
  Cues: "dois pontos", "colon", "deux-points", "lista", "list", "liste",
  "em forma de lista" / "in list form" / "sous forme de liste",
  "enumera(r)" / "enumerate" / "énumérer" forms, or a literal ":"
  followed by content. The cue is a formatting instruction, NOT content:
  keep any preamble as the intro line (with ":"), then break what follows
  into a numbered list, one item per line. Never make the cue an item.
- "deux points" / "deux-points" always means the ":" punctuation announcing
  a list, never a quantity.`;

// S1-mini: fixed system prompt (must be exact, per HF model card)
const S1_SYSTEM =
  "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text.";

// Heuristic lang detect: fast, no deps. Scores PT vs FR markers (accents
// weigh in), tie/quiet defaults to en. "que" stays a PT marker (PT-first
// order); FR wins whenever any other FR marker is present. Deliberately
// excluded: PT "um/uma" (EN filler "um, ..."), PT "mais" (FR "but"),
// FR "est"/"en" (EN "3pm est", "en dash"); FR "non" dropped (EN "non-...").
export function detectLang(text) {
  const t = text.toLowerCase();
  // Accents weigh in; then each side counts its function-word hits.
  let pt = /[áãâàéêíóôõúç]/.test(t) ? 2 : 0;
  let fr = /[àâêèéîïôùûüçœæ]/.test(t) ? 2 : 0;
  pt += (t.match(
    /\b(eu|você|voce|não|nao|sim|obrigado|por favor|com|para|que|isso|vamos|preciso|quero|meu|minha|esse|essa|este|esta|aqui|muito|quando|onde|porque|mostra|coloca|arquivo|aperta|depois|faz|manda|resumo|senha|tela|teste)\b/g,
  ) || []).length;
  fr += (t.match(
    /\b(je|tu|il|elle|nous|vous|ils|elles|fais|fait|font|dans|sans|chez|avec|pour|une|des|les|sont|aussi|quand|comment|pourquoi|merci|oui|bonjour|c'est|très|tres)\b/g,
  ) || []).length;
  if (fr > pt) return "fr";
  if (pt > 0) return "pt";
  return "en";
}

// Explicit list announcements, in any of the three languages. Returns the
// matched cue (for prompt injection) or "". The cue word itself is a
// formatting instruction, never content — callers say so in the prompt.
export function detectListTrigger(text) {
  const t = text.toLowerCase();
  // A literal colon followed by content is the strongest signal (STT often
  // transcribes "lista:" / "list:" with the colon attached).
  const colon = t.match(/:\s*\S/);
  if (colon) return ":";
  const cues = [
    // PT ("quarto"/ordinals excluded: common prose words, covered by the
    // numeral rules instead — triggers must be unambiguous announcements)
    "dois pontos",
    "em forma de lista",
    /\blista\b/,
    /enumer\w+/, // enumera, enumerar, enumeração, enumerados...
    // EN
    /\bcolon\b/,
    /\blist\b/,
    /in (a )?list form/,
    /enumerat\w+/, // enumerate, enumeration, enumerated...
    // FR (transcripts often drop accents, match both)
    /deux[-\s]?points?/,
    /\bliste\b/,
    /sous forme de liste/,
    /[ée]num[ée]r\w*/,
  ];
  for (const cue of cues) {
    if (typeof cue === "string") {
      if (t.includes(cue)) return cue;
    } else {
      const m = t.match(cue);
      if (m) return m[0];
    }
  }
  return "";
}

function detectStructure(text) {
  // S1 is conservative: needs 3+ items. We allow lists always (S1 stays prose if not list).
  // Simple heuristic: if transcript has enumerations, hint lists; else lists still safe.
  const commas = (text.match(/,/g) || []).length;
  const andCount = (text.match(/\be\b|\band\b|\bet\b/gi) || []).length;
  const hasNumbers = /\b(um|dois|tres|one|two|three|1|2|3)\b/i.test(text);
  if (commas >= 2 || andCount >= 2 || hasNumbers) return "lists";
  return "lists"; // always allow - S1 will stay prose if not a real list
}

// Local clients (lazy). No per-request chat_template_kwargs: thinking is
// disabled server-side (--reasoning off on new builds, the equivalent server
// flag on old ones). Sending the deprecated body kwargs makes new builds
// generate garbage ("MOSAOS...") on some inputs.
let s1Client = null;
let qwenClient = null;
function getLocalClients(logger) {
  if (!s1Client) {
    s1Client = createClient(
      {
        endpoint: s1Endpoint,
        model: "s1-mini",
        maxTokens: 512,
        retries: 1,
      },
      logger,
    ).complete;
  }
  if (!qwenClient) {
    qwenClient = createClient(
      {
        endpoint: qwenEndpoint,
        model: "qwen3-4b",
        maxTokens: 1024,
        retries: 1,
      },
      logger,
    ).complete;
  }
  return { s1Complete: s1Client, qwenComplete: qwenClient };
}

async function normalizeWithS1(rawText, logger) {
  await ensureServer("s1", logger);
  const { s1Complete } = getLocalClients(logger);
  const styling = "semi-formal";
  const structure = detectStructure(rawText);
  const context = "general";
  const control = `[Styling: ${styling}] [Structure: ${structure}] [Context: ${context}]`;
  // Explicit list announcement ("lista", "dois pontos", ...): S1_SYSTEM is
  // fixed per the model card, so the bias goes in the user content instead,
  // as an instruction block BEFORE the transcript (trailing text gets read
  // as more transcript).
  const trigger = detectListTrigger(rawText);
  const userContent = trigger
    ? `${control}\nInstruction: the speaker announced a list with "${trigger}". Output a numbered list.\nTranscript:\n${rawText}`
    : `${control}\n${rawText}`;
  // S1 wants greedy, temp 0 already set via server flag, but also ensure per-request kwargs
  const maxTokens = Math.min(512, Math.ceil(rawText.split(/\s+/).length * 1.6) + 32);
  const result = await s1Complete({
    system: S1_SYSTEM,
    prompt: userContent,
    config: { maxTokens },
  });
  touchServer("s1", logger);
  return result;
}

// Spoken numerals by language, for the list safety net in heuristicPostClean.
const NUMBER_WORDS = {  um: 1,
  dois: 2,
  três: 3,
  tres: 3,
  quatro: 4,
  cinco: 5,
  seis: 6,
  sete: 7,
  oito: 8,
  nove: 9,
  dez: 10,
  onze: 11,
  doze: 12,
  one: 1,
  two: 2,
  three: 3,
  four: 4,
  five: 5,
  six: 6,
  seven: 7,
  eight: 8,
  nine: 9,
  ten: 10,
  eleven: 11,
  twelve: 12,
  un: 1,
  deux: 2,
  trois: 3,
  quatre: 4,
  cinq: 5,
  sept: 7,
  huit: 8,
  neuf: 9,
  dix: 10,
  douze: 12,
};

// Ordinal markers by language ("Primeiro, ... Segundo, ..." -> "1. ... 2. ...").
const ORDINAL_WORDS = {
  primeiro: 1,
  segundo: 2,
  terceiro: 3,
  quarto: 4,
  quinto: 5,
  sexto: 6,
  sétimo: 7,
  setimo: 7,
  oitavo: 8,
  nono: 9,
  décimo: 10,
  decimo: 10,
  first: 1,
  second: 2,
  third: 3,
  fourth: 4,
  fifth: 5,
  sixth: 6,
  seventh: 7,
  eighth: 8,
  ninth: 9,
  tenth: 10,
};
const ORDINAL_RE = new RegExp(
  `(^|[.?!]\\s+)(${Object.keys(ORDINAL_WORDS).join("|")})\\s*,\\s*`,
  "gim",
);

export function heuristicPostClean(text, lang = "en") {
  if (!text) return text;
  let out = text;
  // fillers multilíngue - backup para quando LLM não remove.
  // PT "um" is an article/numeral ("um arquivo", item "um"), not filler.
  out = out.replace(/\btipo assim\b/gi, "");
  out = out.replace(lang === "pt" ? /\b(euh|uh)\b/gi : /\b(euh|uh|um)\b/gi, "");
  // "né?" is filler in any language here ("ontem, né? Vamos" -> "ontem. Vamos").
  out = out.replace(/,\s*né\?\s*/gi, ". ");
  out = out.replace(/\bné\?\s*/gi, ". ");
  // Orphan double period left by filler removal ("SCL. . O GET" -> "SCL. O GET").
  // Requires whitespace between dots, so "2.0" and "..." never match.
  out = out.replace(/\.\s+\.(?!\d)/g, ".");
  // remove "so" only at start (filler) - preserve mid-sentence "so"
  out = out.replace(/^\s*so\s+/i, "");
  out = out.replace(/,\s*so\s+/gi, ", ");
  out = out.replace(/\s{2,}/g, " ").trim();
  // homophone backup (case-insensitive, word boundary)
  const fixes = [
    [/\bsink\b/gi, "sync"],
    [/\ba sink\b/gi, "async"],
    [/\blocks\b/gi, "logs"],
    [/\bcash\b/gi, "cache"],
    [/\bJason\b/g, "JSON"],
    [/\brap\b/gi, "wrap"],
    [/\bdotter\b/gi, "docker"],
    // Product/UI names dictated loosely.
    [/\bsystray\b/gi, "SystemTray"],
    [/\bcapslock\b/gi, "Caps Lock"],
    // Key names dictated in PT/FR are unambiguous: no Portuguese or French
    // word collides with these standalone tokens.
    [/\benter\b/g, "Enter"],
    [/\btab\b/g, "Tab"],
    // Transcription misspellings of tech terms (nonsense words otherwise).
    [/\bit scan\b/gi, "I2C scan"],
    [/\bridme\b/gi, "README"],
    [/\bcaps lock\b/gi, "Caps Lock"],
    [/\bumber\b/gi, "amber"],
    [/\bbald\b/gi, "baud"],
    [/\bmilles\b/gi, "millis"],
  ];
  for (const [re, rep] of fixes) out = out.replace(re, rep);
  // ensure first letter capitalized, trim double spaces
  out = out.replace(/\s{2,}/g, " ").trim();
  // Safety net: ordinal markers ("Primeiro, ... Segundo, ...") become digits.
  // 2+ ordinals is a near-certain list signal (unlike bare digits in versions).
  // Requires sentence boundary + comma so "o primeiro item" never matches.
  const ordinalMatches = out.match(ORDINAL_RE) || [];
  if (ordinalMatches.length >= 2) {
    out = out.replace(ORDINAL_RE, (m, pre, word) => {
      const n = ORDINAL_WORDS[word.toLowerCase()];
      return pre ? `${pre.trimEnd()}\n${n}. ` : `${n}. `;
    });
  }
  // Safety net: numbered markers left inline ("1. a. 2. b.") go one per line.
  // Needs 2+ markers so "versão 2.0" and single references never split.
  // "item N" is a reference, not an item: never break before it.
  const inlineMarkers = out.match(/\b\d{1,2}[.)] /g) || [];
  const listMode = inlineMarkers.length >= 2 || ordinalMatches.length >= 2;
  if (listMode) {
    // Split before inline markers, even mid-text: not at line start already,
    // never after an "item N" reference.
    out = out.replace(/(?<!\bitem\s)(?<!\n)\s+(?=\d{1,2}[.)] )/gi, "\n");
  }
  // Same net for number words glued mid-sentence ("...grande e três, ...").
  // Gated on list mode so prose like "café e dois pães" is never touched.
  // Glue word per language: PT "e", EN "and", FR "et". The "1" words
  // (um/one/un) are excluded: mid-sentence they are articles ("e um wrap"
  // = "and a wrap"), not item markers.
  if (listMode) {
    out = out.replace(
      /\s+(e|and|et)\s+(dois|três|tres|quatro|cinco|seis|sete|oito|nove|dez|onze|doze|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|deux|trois|quatre|cinq|sept|huit|neuf|dix|douze)\b,?\s*/gi,
      (m, _glue, word) => `\n${NUMBER_WORDS[word.toLowerCase()]}. `,
    );
  }
  const isList = /^\d+[.)]\s/m.test(out);
  if (out && !/[.!?]$/.test(out) && !isList) {
    // add period if looks like sentence and not list
    if (!out.startsWith("-") && !out.startsWith("•")) out += ".";
  }
  // capitalize first letter
  if (out) out = out.charAt(0).toUpperCase() + out.slice(1);
  return out;
}

async function normalizeWithQwen(
  complete,
  rawText,
  sessionTitle,
  systemPrompt,
  logger,
  lang = "en",
) {
  // ensure qwen server alive first (local)
  try {
    await ensureServer("qwen", logger);
  } catch (e) {
    logger?.log("STT", `qwen ensure failed: ${e.message}, falling back to cloud complete`, "warn");
  }
  // If local qwen is available, prefer it; otherwise use passed complete (cloud/local)
  const { qwenComplete } = getLocalClients(logger);
  const contextLine = sessionTitle ? ` The user is currently working on: "${sessionTitle}"` : "";
  const system = `${systemPrompt}${contextLine}`;
  // try local qwen first
  let result = null;
  try {
    const maxTokens = Math.ceil(rawText.length / 2) + 64;
    result = await qwenComplete({
      system,
      prompt: `Clean up this speech-to-text transcription:\n\n${rawText}`,
      config: { maxTokens },
    });
    touchServer("qwen", logger);
    if (result.text) {
      const cleaned = heuristicPostClean(result.text, lang);
      logger?.log("STT", `qwen raw="${result.text}" heuristic="${cleaned}"`, "debug");
      return { text: cleaned };
    }
    logger?.log("STT", `qwen local empty, trying fallback: ${result.error}`, "warn");
  } catch (e) {
    logger?.log("STT", `qwen local error: ${e.message}`, "warn");
  }
  // fallback to original cloud complete (if configured)
  const fallback = await normalizeTranscription(
    complete,
    rawText,
    sessionTitle,
    systemPrompt,
    logger,
  );
  if (fallback.text) fallback.text = heuristicPostClean(fallback.text, lang);
  return fallback;
}

export async function normalizeHybrid(complete, rawText, sessionTitle, systemPrompt, logger) {
  const lang = detectLang(rawText);
  logger?.log(
    "STT",
    `Hybrid routing lang=${lang} chars=${rawText.length} structure=${detectStructure(rawText)}`,
    "debug",
  );
  // Anchor the output language: small models follow the English-heavy
  // examples otherwise and occasionally translate. S1 keeps its exact prompt.
  const langNames = { pt: "Portuguese", fr: "French", en: "English" };
  let localizedPrompt = `${systemPrompt} Respond in ${langNames[lang] || "the original language"}. Do NOT translate to any other language.`;
  // Explicit list announcement ("lista", "dois pontos", ...): bias every
  // downstream consumer (Qwen and the cloud fallback) toward listing.
  const listTrigger = detectListTrigger(rawText);
  if (listTrigger) {
    localizedPrompt += ` The speaker explicitly announced a list (cue: "${listTrigger}"). Format what follows as a numbered list, one item per line; the cue itself is a formatting instruction, never a list item. "deux points" means ":", never "two points".`;
    const listExamples = {
      pt: 'Example: "quero uma lista dois pontos pão queijo" -> "Quero uma lista:\n1. pão\n2. queijo".',
      en: 'Example: "shopping list colon milk bread" -> "Shopping list:\n1. milk\n2. bread".',
      fr: 'Example: "je veux une liste deux points pain lait" -> "Je veux une liste:\n1. pain\n2. lait".',
    };
    if (listExamples[lang]) localizedPrompt += " " + listExamples[lang];
  }
  // Check if local models exist; if not, use cloud directly
  const s1Exists = fs.existsSync(s1ModelPath);
  const qwenExists = fs.existsSync(qwenModelPath);
  if (!s1Exists && !qwenExists) {
    logger?.log("STT", "No local models found, using cloud LLM", "debug");
    return normalizeTranscription(complete, rawText, sessionTitle, systemPrompt, logger);
  }
  if (lang === "en" && s1Exists) {
    try {
      const r = await normalizeWithS1(rawText, logger);
      // Explicit list cue but S1 stayed prose: fall back to Qwen (slower,
      // but an announced list must come back a list).
      if (r.text && (!listTrigger || /\n\d+[.)]/.test(r.text))) return r;
      if (r.text)
        logger?.log("STT", "S1 ignored list cue, falling back to Qwen", "warn");
      else logger?.log("STT", `S1 failed (${r.error}), falling back to Qwen`, "warn");
    } catch (e) {
      logger?.log("STT", `S1 error: ${e.message}, falling back to Qwen`, "warn");
    }
  }
  // PT/FR or S1 failed -> Qwen (local preferred, cloud fallback inside)
  if (qwenExists) {
    return normalizeWithQwen(complete, rawText, sessionTitle, localizedPrompt, logger, lang);
  }
  return normalizeTranscription(complete, rawText, sessionTitle, localizedPrompt, logger);
}

async function normalizeTranscription(complete, rawText, sessionTitle, systemPrompt, logger) {
  const contextLine = sessionTitle ? ` The user is currently working on: "${sessionTitle}"` : "";
  const system = `${systemPrompt}${contextLine}`;

  logger?.log("STT", `Normalizing transcription chars=${rawText.length}`, "debug");
  const result = await complete({
    system,
    prompt: `Clean up this speech-to-text transcription:\n\n${rawText}`,
  });
  return result;
}

async function getApiModels(logger) {
  if (!sttApiEndpoint) return [];
  try {
    const url = sttApiEndpoint.endsWith("/")
      ? `${sttApiEndpoint}models`
      : `${sttApiEndpoint}/models`;
    const headers = {};
    if (sttApiKeyEnv && process.env[sttApiKeyEnv]) {
      headers["Authorization"] = "Bearer " + process.env[sttApiKeyEnv];
    }
    const resp = await fetch(url, { headers, signal: AbortSignal.timeout(5000) });
    logger?.log("STT", `Fetched STT API models status=${resp.status}`, resp.ok ? "debug" : "warn");
    if (!resp.ok) return [];
    const data = await resp.json();
    return (data.data || [])
      .filter((m) => m.id && /whisper/i.test(m.id))
      .map((m) => ({ value: m.id, label: m.id }));
  } catch (err) {
    logger?.log("STT", `Failed to fetch STT API models: ${err.message}`, "error");
    return [];
  }
}

async function transcribeApi(kv, logger) {
  return transcribeAudioFileApi(path.join(tmpDir, WAV_FILENAME), kv, logger);
}

export async function transcribeAudioFileApi(filePath, kv, logger) {
  if (!sttApiEndpoint || !sttApiModel) {
    logger?.log("STT", "STT API transcription skipped: API not configured", "warn");
    return { error: "STT API not configured" };
  }
  const model = kv.get("stt.api.model") || sttApiModel;
  logger?.log(
    "STT",
    `STT API file transcription requested model=${model} file=${filePath}`,
    "debug",
  );

  if (!fs.existsSync(filePath)) {
    logger?.log("STT", `Audio file missing: ${filePath}`, "error");
    return { error: `Audio file not found: ${filePath}` };
  }
  if (fs.statSync(filePath).size <= 44) {
    logger?.log("STT", `Audio file empty: ${filePath}`, "warn");
    return { error: "Audio file is empty - no audio captured" };
  }

  try {
    const audioBuffer = await fs.promises.readFile(filePath);
    const apiKey = sttApiKeyEnv ? process.env[sttApiKeyEnv] : null;
    const useOpenRouterFormat = isOpenRouterEndpoint(sttApiEndpoint);

    const url = sttApiEndpoint.endsWith("/")
      ? `${sttApiEndpoint}audio/transcriptions`
      : `${sttApiEndpoint}/audio/transcriptions`;

    const request = useOpenRouterFormat
      ? buildOpenRouterTranscriptionRequest(model, audioBuffer, apiKey)
      : buildMultipartTranscriptionRequest(model, audioBuffer, apiKey);

    const resp = await fetch(url, {
      method: "POST",
      headers: request.headers,
      body: request.body,
      signal: AbortSignal.timeout(60000),
    });
    logger?.log("STT", `STT API response status=${resp.status}`, resp.ok ? "debug" : "error");

    if (!resp.ok) {
      const responseBody = await resp.text();
      let msg = `STT API error ${resp.status}`;
      try {
        const err = JSON.parse(responseBody);
        msg = err?.error?.message || msg;
      } catch {}
      return { error: msg };
    }

    let data;
    try {
      data = await resp.json();
    } catch (err) {
      logger?.log("STT", `STT API returned invalid JSON: ${err.message}`, "error");
      return { error: `STT API returned invalid JSON: ${err.message}` };
    }
    logger?.log("STT", `STT API transcription succeeded chars=${data.text?.length || 0}`, "debug");
    return { text: data.text?.trim() || "" };
  } catch (err) {
    logger?.log("STT", `STT API request failed: ${err.message}`, "error");
    if (err.name === "TimeoutError" || err.name === "AbortError") {
      return { error: "STT API request timed out (60s)" };
    }
    return { error: `STT API request failed: ${err.message}` };
  }
}

export async function appendTranscription(client, text, submit) {
  let appendResult = await client.tui.appendPrompt({ body: { text } });

  if (appendResult?.error?.data?.message === "Expected object, got undefined") {
    appendResult = await client.tui.appendPrompt({ text });
  }

  if (appendResult?.error) {
    throw new Error(
      `appendPrompt failed: ${appendResult.error.data?.message || appendResult.error.name}`,
    );
  }

  if (submit) {
    await client.tui.submitPrompt();
  }
}

async function doTranscribePipeline(
  kv,
  complete,
  client,
  toast,
  systemPrompt,
  submit = false,
  logger,
) {
  processing = true;
  try {
    logger?.log("STT", `Pipeline started submit=${submit}`, "debug");
    stopRecording(logger);
    await waitForSoxExit(logger);

    toast("Transcribing...");
    const result = sttApiEndpoint ? await transcribeApi(kv, logger) : await transcribe(kv, logger);

    if (result.error) {
      logger?.log("STT", `Transcription failed: ${result.error}`, "error");
      toast(result.error, "error");
      return;
    }
    if (!result.text) {
      logger?.log("STT", "Transcription produced no text", "warn");
      toast("No speech detected", "warning");
      return;
    }

    toast("Normalizing...");
    const sessionTitle = await getActiveSessionTitle(client);
    const llmResult = await normalizeHybrid(
      complete,
      result.text,
      sessionTitle,
      systemPrompt,
      logger,
    );

    if (!llmResult.text) {
      logger?.log("STT", `Normalization failed, using raw input: ${llmResult.error}`, "warn");
      toast(`Normalization failed, using raw input: ${llmResult.error}`, "warning");
      await appendTranscription(client, result.text, submit);
      return;
    }

    await appendTranscription(client, llmResult.text, submit);
    logger?.log("STT", `Pipeline completed normalizedChars=${llmResult.text.length}`, "debug");
    toast(submit ? "Transcription submitted" : "Transcription added to prompt", "success");
  } catch (err) {
    logger?.log("STT", `Pipeline error: ${err.message}`, "error");
    toast(`STT error: ${err.message}`, "error");
  } finally {
    processing = false;
    recording = false;
  }
}

// ---- Public API for TUI plugin ----

export function registerSTT(api, kv, complete, prompts, opts, logger) {
  const client = api.client;
  const systemPrompt = prompts?.stt || STT_SYSTEM_PROMPT;
  function toast(message, variant = "info") {
    api.ui.toast({ message, variant, duration: 3000 });
  }

  configureSttRuntime(opts, logger);

  return [
    {
      title: sttApiEndpoint ? "STT: record/transcribe (API)" : "STT: record/transcribe",
      value: "stt.record",
      description: sttApiEndpoint
        ? "Toggle recording; press again to stop and transcribe via API"
        : "Toggle recording; press again to stop and transcribe",
      keybind: "alt+q",
      slash: { name: "stt-record" },
      onSelect() {
        if (processing) {
          toast("STT busy, please wait...");
          return;
        }
        if (recording) {
          toast("Stopping, transcribing...");
          doTranscribePipeline(kv, complete, client, toast, systemPrompt, false, logger);
        } else {
          startRecording(kv, toast, logger);
          if (recording) toast("Recording... press again to transcribe");
        }
      },
    },
    {
      title: sttApiEndpoint ? "STT: submit recording (API)" : "STT: submit recording",
      value: "stt.submit",
      description: sttApiEndpoint
        ? "Stop recording, transcribe via API, and submit prompt"
        : "Stop recording, transcribe, and submit prompt",
      slash: { name: "stt-submit" },
      onSelect() {
        if (processing) {
          toast("STT busy, please wait...");
          return;
        }
        if (!recording) {
          toast("No recording in progress", "warning");
          return;
        }
        toast("Stopping, transcribing...");
        doTranscribePipeline(kv, complete, client, toast, systemPrompt, true, logger);
      },
    },
    {
      title: "STT: cancel recording",
      value: "stt.stop",
      description: "Cancel current recording",
      slash: { name: "stt-stop" },
      onSelect() {
        if (cancelSttRecording(logger)) toast("Recording cancelled");
      },
    },
    {
      title: sttApiEndpoint ? "STT: select model (API)" : "STT: select model",
      value: "stt.model",
      description: sttApiEndpoint ? "Choose whisper model via API" : "Choose STT model",
      slash: { name: "stt-model" },
      async onSelect() {
        if (sttApiEndpoint) {
          const current = kv.get("stt.api.model") || sttApiModel;
          const apiModels = await getApiModels(logger);
          const options = apiModels.length > 0 ? apiModels : [{ value: current, label: current }];
          api.ui.dialog.replace(() =>
            api.ui.DialogSelect({
              title: "Select whisper model (API)",
              current,
              options: options.map((m) => ({
                title: m.label,
                value: m.value,
                onSelect() {
                  kv.set("stt.api.model", m.value);
                  toast(`Whisper API model: ${m.label}`);
                  api.ui.dialog.clear();
                },
              })),
            }),
          );
        } else {
          const current = getModelName(kv);
          api.ui.dialog.replace(() =>
            api.ui.DialogSelect({
              title: "Select STT model",
              current,
              options: Object.entries(MODELS).map(([key, v]) => ({
                title: v.label,
                value: key,
                onSelect() {
                  kv.set("stt.model", key);
                  toast(`STT model: ${v.label}`);
                  api.ui.dialog.clear();
                },
              })),
            }),
          );
        }
      },
    },
    {
      title: "STT: select microphone",
      value: "stt.mic",
      description: "Choose audio input device",
      slash: { name: "stt-mic" },
      onSelect() {
        const current = kv.get("stt.mic", "");
        const devices = listInputDevices();
        if (devices.length === 0) {
          toast("No input devices found");
          return;
        }
        api.ui.dialog.replace(() =>
          api.ui.DialogSelect({
            title: "Select microphone",
            current,
            options: [
              {
                title: "System default",
                value: "",
                onSelect() {
                  kv.set("stt.mic", "");
                  toast("Mic: system default");
                  api.ui.dialog.clear();
                },
              },
              ...devices.map((name) => ({
                title: name,
                value: name,
                onSelect() {
                  kv.set("stt.mic", name);
                  toast(`Mic: ${name}`);
                  api.ui.dialog.clear();
                },
              })),
            ],
          }),
        );
      },
    },
    {
      title: "STT: kill local LLM servers",
      value: "stt.kill-local",
      description: "Kill local S1/Qwen servers (they auto-restart on next voice, idle 2min)",
      slash: { name: "stt-kill-local" },
      onSelect() {
        killLocalServers(logger);
        toast("Local LLM servers killed (auto-idle 2min, restart on next voice)");
      },
    },
  ];
}
