// Standalone OpenCode Voice runner.
//
// Exposes the STT pipeline (reused from the opencode-voice plugin's lib/) over a
// tiny local HTTP API, so the AHK tray app can drive it from any focused window.
//
//   POST /start            start recording
//   POST /stop             stop + transcribe + normalize + paste (async: returns
//                          {started, seq} immediately; poll /result?seq=N)
//   GET  /result?seq=N     pipeline result for a /stop ({done, ok, error, pasted})
//   POST /cancel           cancel the current recording
//   POST /kill             kill local LLM servers (free VRAM/RAM)
//   POST /warm {enabled}   keep s1/qwen loaded, or restore the 1-min idle kill
//   GET  /health           { ok, recording, processing, warm }
//
// Recording uses a persistent PowerShell host (rec-host.ps1) that compiles the
// winmm recorder once. Spawning rec.ps1 per dictation cost ~1.2s and clipped the
// start of speech; the host brings that down to a few ms.
//
// Model lifecycle: servers are spawned on demand by the pipeline. Cold mode kills
// them 1 minute after the last use; warm mode keeps them alive by touching the
// plugin's 120s idle timer every 45s.

import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync, spawn } from "node:child_process";

const ROOT = path.dirname(fileURLToPath(import.meta.url));

// Machine config: config.json (installer layout, relative paths) optionally
// overridden by config.local.json (dev machines, gitignored).
function resolvePath(value) {
  if (!value) return value;
  const expanded = String(value).replace(/%([^%]+)%/g, (_, name) => process.env[name] || `%${name}%`);
  return path.isAbsolute(expanded) ? expanded : path.join(ROOT, expanded);
}

function loadConfig() {
  const base = JSON.parse(fs.readFileSync(path.join(ROOT, "config.json"), "utf8"));
  try {
    const local = JSON.parse(fs.readFileSync(path.join(ROOT, "config.local.json"), "utf8"));
    return { ...base, ...local };
  } catch {
    return base;
  }
}
const CONFIG = loadConfig();

const stt = await import("./lib/stt.js");
const { createClient } = await import("./lib/llm-client.js");
const llmServers = await import("./lib/local-llm-manager.js");

const PORT = CONFIG.runnerPort || 8791;
const IDLE_KILL_MS = 60_000;
const WARM_TOUCH_MS = 45_000;
const REC_HOST = new URL("./rec-host.ps1", import.meta.url).pathname.replace(/^\//, "");
// Mirrors the plugin options currently in cli.json.
const OPTIONS = {
  endpoint: CONFIG.endpoint || "http://127.0.0.1:8081/v1",
  model: CONFIG.model || "qwen3-4b",
  tmpDir: CONFIG.tmpDir || os.tmpdir(),
  parakeetBin: resolvePath(CONFIG.parakeetBin),
  parakeetModel: resolvePath(CONFIG.parakeetModel),
  parakeetThreads: CONFIG.parakeetThreads || 6,
  s1Model: resolvePath(CONFIG.s1Model),
  qwenModel: resolvePath(CONFIG.qwenModel),
  s1Endpoint: `http://127.0.0.1:${CONFIG.s1Port || 8080}/v1`,
  qwenEndpoint: `http://127.0.0.1:${CONFIG.qwenPort || 8081}/v1`,
};
llmServers.configureLocalLlm({
  llamaBin: resolvePath(CONFIG.llamaBin),
  s1Model: OPTIONS.s1Model,
  qwenModel: OPTIONS.qwenModel,
  s1Port: CONFIG.s1Port || 8080,
  qwenPort: CONFIG.qwenPort || 8081,
});

// Mic level file, read by the overlay in voice-tray.ahk.
const LEVEL_PATH = OPTIONS.tmpDir + "/opencode-stt.level";
// Current pipeline phase, read by the overlay to pick label/color.
const PHASE_PATH = OPTIONS.tmpDir + "/opencode-stt.phase";
// Last pipeline results by seq, so the tray app can poll without blocking.
const RESULTS = new Map();
let pipelineSeq = 0;
// Last pipeline I/O, for debugging what was heard vs produced.
const LAST_PATH = OPTIONS.tmpDir + "/opencode-stt.last.json";
function writeLast(payload) {
  try {
    fs.writeFileSync(LAST_PATH, JSON.stringify(payload));
  } catch {}
}

// recording -> transcribing -> normalizing -> idle
let phase = "idle";
function writePhase(value) {
  phase = value;
  try {
    fs.writeFileSync(PHASE_PATH, value);
  } catch {}
}

const logger = {
  log(scope, message, level = "debug") {
    if (level === "debug" && !process.env.VOICE_DEBUG) return;
    console.log(`[${level}] ${scope}: ${message}`);
  },
};

// STT system prompt: canonical copy lives in prompts/stt-system-prompt.md
// (PT + list rules); falls back to the lib default if the file is missing.
// The leading <!-- --> doc block is stripped so it never reaches the model.
function loadPromptFile() {
  try {
    const file = new URL("./prompts/stt-system-prompt.md", import.meta.url).pathname.replace(/^\//, "");
    const stripped = fs
      .readFileSync(file, "utf8")
      .replace(/^<!--[\s\S]*?-->\s*/, "")
      .replace(/\s+$/, "");
    if (stripped.trim()) {
      logger.log("VOICE", "Using prompts/stt-system-prompt.md", "debug");
      return { source: "file", text: stripped };
    }
  } catch (e) {
    logger.log("VOICE", `Prompt file unreadable, using lib default: ${e.message}`, "warn");
  }
  return { source: "lib", text: stt.STT_SYSTEM_PROMPT };
}
const STT_PROMPT = loadPromptFile();
const PROMPT_SOURCE = STT_PROMPT.source;
const STT_TEXT = STT_PROMPT.text;

// The pipeline reads model/mic from a kv store; standalone we keep it in memory.
const kv = {
  store: { "stt.model": "large-v3-turbo-q5_0", "stt.mic": "", "stt.api.model": "" },
  get(key, dflt) {
    return this.store[key] ?? dflt;
  },
  set(key, value) {
    this.store[key] = value;
  },
};

stt.configureSttRuntime(OPTIONS, logger);
const { complete } = createClient(OPTIONS, logger);

let processing = false;
let recording = false;
let warm = false;
let warmTimer = null;
let idleTimer = null;

// ---- Recorder host ---------------------------------------------------------
let hostProc = null;
let hostReady = null;
let hostBuffer = "";
const hostPending = [];

function ensureHost() {
  if (hostProc) return hostReady;
  hostProc = spawn("pwsh", ["-NoProfile", "-NonInteractive", "-File", REC_HOST], {
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });
  hostProc.stdout.setEncoding("utf8");
  hostProc.stderr.setEncoding("utf8");
  hostProc.stdout.on("data", (chunk) => {
    hostBuffer += chunk;
    let idx;
    while ((idx = hostBuffer.indexOf("\n")) >= 0) {
      const line = hostBuffer.slice(0, idx).trim();
      hostBuffer = hostBuffer.slice(idx + 1);
      if (!line) continue;
      const resolve = hostPending.shift();
      if (resolve) resolve(line);
    }
  });
  hostProc.stderr.on("data", (data) => logger.log("REC", String(data).trim(), "warn"));
  hostProc.on("exit", () => {
    hostProc = null;
    hostReady = null;
    recording = false;
  });
  hostReady = new Promise((resolve) => hostPending.push(resolve));
  return hostReady;
}

function hostCmd(line) {
  return new Promise((resolve, reject) => {
    if (!hostProc) return reject(new Error("recorder host not running"));
    const timer = setTimeout(() => reject(new Error("recorder host timeout")), 15000);
    hostPending.push((response) => {
      clearTimeout(timer);
      resolve(response);
    });
    hostProc.stdin.write(line + "\n");
  });
}

// ---- Local LLM lifecycle ---------------------------------------------------
function killServers() {
  try {
    llmServers.killAll(logger);
  } catch (e) {
    logger.log("VOICE", `killAll failed: ${e.message}`, "warn");
  }
}

function clearIdle() {
  if (idleTimer) {
    clearTimeout(idleTimer);
    idleTimer = null;
  }
}

// Cold mode: drop the servers 1 min after the last use. Warm mode: leave them up.
function scheduleIdleKill() {
  clearIdle();
  if (warm) return;
  idleTimer = setTimeout(killServers, IDLE_KILL_MS);
  idleTimer.unref?.();
}

function stopWarmLoop() {
  if (warmTimer) {
    clearInterval(warmTimer);
    warmTimer = null;
  }
}

// Keep s1/qwen loaded: touch the idle timer well under the plugin's 120s window.
function startWarmLoop() {
  stopWarmLoop();
  warmTimer = setInterval(() => {
    for (const key of ["s1", "qwen"]) {
      try {
        llmServers.touchServer(key, logger);
      } catch {}
    }
  }, WARM_TOUCH_MS);
  warmTimer.unref?.();
  for (const key of ["s1", "qwen"]) {
    llmServers
      .ensureServer(key, logger)
      .catch((e) => logger.log("VOICE", `warm ${key} failed: ${e.message}`, "warn"));
  }
}

function pasteText(text) {
  if (process.platform !== "win32") return false;
  try {
    execFileSync("clip", { input: text });
  } catch {
    return false;
  }
  try {
    execFileSync(
      "pwsh",
      ["-NoProfile", "-NonInteractive", "-Command", "(New-Object -ComObject WScript.Shell).SendKeys('^v')"],
      { timeout: 8000 },
    );
  } catch {
    return false;
  }
  return true;
}

// ---- Pipeline --------------------------------------------------------------
// Runs in the background: /stop returns {started, seq} immediately so the AHK
// overlay keeps repainting while the phases change. (A blocking /stop froze the
// AHK thread inside the HTTP call, so transcribing/normalizing never painted.)
async function runPipeline(seq) {
  processing = true;
  const done = (payload) => {
    RESULTS.set(seq, { seq, done: true, ...payload });
    if (RESULTS.size > 5) RESULTS.delete(RESULTS.keys().next().value);
    processing = false;
    writePhase("idle");
    stt.markSttIdle();
    scheduleIdleKill();
  };
  try {
    await hostCmd("stop"); // finalizes the WAV before we transcribe
    recording = false;

    writePhase("transcribing");
    const result = stt.isSttApiConfigured()
      ? await stt.transcribeSttApiCall(kv, logger)
      : await stt.transcribeSttRecording(kv, logger);

    if (result?.error) {
      writeLast({ raw: null, text: null, error: result.error });
      return done({ ok: false, error: result.error });
    }
    if (!result?.text) {
      writeLast({ raw: null, text: null, error: "no-speech" });
      return done({ ok: false, error: "no-speech" });
    }

    writePhase("normalizing");
    const normalized = await stt.normalizeHybrid(complete, result.text, "", STT_TEXT, logger);
    const text = normalized?.text || result.text;
    writeLast({ raw: result.text, text, error: normalized?.error || null, prompt: PROMPT_SOURCE });
    done({ ok: true, text, pasted: pasteText(text) });
  } catch (e) {
    done({ ok: false, error: e.message });
  }
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = "";
    req.on("data", (chunk) => (data += chunk));
    req.on("end", () => {
      try {
        resolve(data ? JSON.parse(data) : {});
      } catch {
        resolve({});
      }
    });
  });
}

function send(res, code, payload) {
  res.writeHead(code, { "Content-Type": "application/json" });
  res.end(JSON.stringify(payload));
}

// First-boot diagnosis: the installer guarantees these files, but a manual
// copy may miss them. Surfaced in /health so the tray app (or a user with
// curl) can say exactly what is missing.
function checkDeps() {
  const files = {
    parakeetBin: OPTIONS.parakeetBin,
    parakeetModel: OPTIONS.parakeetModel,
    llamaBin: llmServers.SERVERS_META?.s1?.bin,
    s1Model: llmServers.SERVERS_META?.s1?.modelFile,
    qwenModel: llmServers.SERVERS_META?.qwen?.modelFile,
  };
  const missing = Object.entries(files)
    .filter(([, p]) => !p || !fs.existsSync(p))
    .map(([k]) => k);
  return { ok: missing.length === 0, missing };
}

const server = http.createServer(async (req, res) => {
  const path = new URL(req.url, "http://127.0.0.1").pathname;
  const method = req.method;

  try {
    if (method === "GET" && path === "/health") {
      return send(res, 200, { ok: true, recording, processing, warm, phase, deps: checkDeps() });
    }
    if (method === "POST" && path === "/start") {
      if (recording || processing) return send(res, 200, { ok: true, recording });
      await ensureHost();
      await hostCmd(`start ${stt.getSttWavPath()} ${LEVEL_PATH}`);
      recording = true;
      writePhase("recording");
      // Pre-warm qwen while parakeet transcribes (~1s): hides the ~1.5s cold
      // load so even cold starts feel warm. Qwen-only: s1+qwen+parakeet peaks
      // would leave no VRAM headroom on 8GB. Fire-and-forget (never await).
      llmServers
        .ensureServer("qwen", logger)
        .catch((e) => logger.log("VOICE", `pre-warm qwen failed: ${e.message}`, "warn"));
      return send(res, 200, { ok: true, recording: true });
    }
    if (method === "POST" && path === "/stop") {
      if (processing) return send(res, 200, { ok: false, error: "busy" });
      if (!recording) return send(res, 200, { ok: false, error: "not-recording" });
      pipelineSeq += 1;
      const seq = pipelineSeq;
      RESULTS.set(seq, { seq, done: false });
      void runPipeline(seq);
      return send(res, 200, { ok: true, started: true, seq });
    }
    if (method === "GET" && path === "/result") {
      const seq = Number(new URL(req.url, "http://127.0.0.1").searchParams.get("seq"));
      const r = RESULTS.get(seq);
      if (!r) return send(res, 404, { ok: false, error: "unknown-seq" });
      return send(res, 200, { ok: true, ...r });
    }
    if (method === "POST" && path === "/cancel") {
      if (recording) {
        await hostCmd("stop");
        recording = false;
      }
      writePhase("idle");
      stt.markSttIdle();
      return send(res, 200, { ok: true, cancelled: true });
    }
    if (method === "POST" && path === "/kill") {
      clearIdle();
      killServers();
      return send(res, 200, { ok: true });
    }
    if (method === "POST" && path === "/warm") {
      const body = await readBody(req);
      warm = Boolean(body.enabled);
      if (warm) {
        startWarmLoop();
      } else {
        stopWarmLoop();
        scheduleIdleKill();
      }
      return send(res, 200, { ok: true, warm });
    }
    return send(res, 404, { ok: false, error: "not-found" });
  } catch (e) {
    return send(res, 500, { ok: false, error: e.message });
  }
});

server.on("error", (e) => {
  console.error(`voice-runner error: ${e.message}`);
  process.exit(1);
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`voice-runner listening on http://127.0.0.1:${PORT}`);
  // Warm the recorder host now so the first dictation doesn't pay the compile cost.
  writePhase("idle");
  ensureHost().catch((e) => logger.log("VOICE", `recorder host failed: ${e.message}`, "warn"));
});

function shutdown() {
  clearIdle();
  stopWarmLoop();
  killServers();
  if (hostProc) {
    try {
      hostProc.stdin.write("quit\n");
    } catch {}
    try {
      hostProc.kill();
    } catch {}
  }
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 1500);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
