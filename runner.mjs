// Standalone SOBER-STT runner.
//
// Exposes the STT pipeline (reused from the opencode-voice plugin's lib/) over a
// tiny local HTTP API, so the AHK tray app can drive it from any focused window.
//
//   POST /start            start recording
//   POST /stop             stop + transcribe + normalize + paste (async: returns
//                          {started, seq} immediately; poll /result?seq=N)
//   GET  /result?seq=N     pipeline result for a /stop ({done, ok, error, pasted})
//   GET  /last             last pipeline I/O ({raw, text, error, prompt})
//   POST /cancel           cancel the current recording
//   POST /kill             kill local LLM servers (free VRAM/RAM)
//   POST /warm {enabled}   keep s1/qwen loaded, or restore the 1-min idle kill
//   POST /models {slot, file} switch the model file for a slot
//                          (slot: parakeet|s1|qwen, file: basename in models/
//                          or "" for the installer default; persists per machine)
//   POST /chunk {enabled}   chunk long dictations before normalizing
//   GET  /health           { ok, recording, processing, warm, deps }
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
import crypto from "node:crypto";
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
const REC_HOST = fileURLToPath(new URL("./rec-host.ps1", import.meta.url));
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
  chunking: true,
};
llmServers.configureLocalLlm({
  llamaBin: resolvePath(CONFIG.llamaBin),
  s1Model: OPTIONS.s1Model,
  qwenModel: OPTIONS.qwenModel,
  s1Port: CONFIG.s1Port || 8080,
  qwenPort: CONFIG.qwenPort || 8081,
});

// Swappable model files: the tray "Trocar modelo" menu drops a file in
// models/ and POSTs it here. Overrides persist per machine in the state dir
// (next to warm.state) and win over config.json until reset to "".
const MODELS_DIR = resolvePath(CONFIG.modelsDir || "models");
function stateDir() {
  const base = process.env.APPDATA || path.join(os.homedir(), ".config");
  return path.join(base, "SOBER-STT-8GB");
}
function loadModelOverrides() {
  try {
    return JSON.parse(fs.readFileSync(path.join(stateDir(), "models.override.json"), "utf8"));
  } catch {
    return {};
  }
}
const MODEL_OVERRIDES = loadModelOverrides();

// Loopback API auth: per-boot token so a web page can't drive the mic. The tray
// app reads it from the state dir (or tmpDir) and sends it as X-SOBER-Token on
// every request (a custom header forces a CORS preflight, which a simple
// <form>/fetch from a page can't pass). The file is written only once the port
// is ours and removed only when it still holds our token: a runner that lost
// the bind race must never clobber (or delete) the token of the runner that
// owns the port, or the tray would be locked out of a live runner.
const TOKEN = crypto.randomBytes(24).toString("hex");
function tokenPaths() {
  return [...new Set([OPTIONS.tmpDir, stateDir()])].map((dir) => path.join(dir, "sober-stt.token"));
}
function writeTokenFile() {
  for (const p of tokenPaths()) {
    try {
      fs.mkdirSync(path.dirname(p), { recursive: true });
      fs.writeFileSync(p, TOKEN);
    } catch {}
  }
}
function removeTokenFile() {
  for (const p of tokenPaths()) {
    try {
      if (fs.readFileSync(p, "utf8") === TOKEN) fs.unlinkSync(p);
    } catch {}
  }
}

function activeModels() {
  return {
    parakeet: path.basename(OPTIONS.parakeetModel),
    s1: path.basename(llmServers.SERVERS_META?.s1?.modelFile || ""),
    qwen: path.basename(llmServers.SERVERS_META?.qwen?.modelFile || ""),
  };
}

// Re-resolve model paths (config + overrides) and push them into the lib.
// Called once at boot and on every POST /models. killSlot drops the running
// server for that slot so the new file loads on next use (parakeet is
// stateless: each dictation spawns it, so nothing to kill there).
function applyModelOverrides(killSlot) {
  OPTIONS.parakeetModel = MODEL_OVERRIDES.parakeet
    ? path.join(MODELS_DIR, MODEL_OVERRIDES.parakeet)
    : resolvePath(CONFIG.parakeetModel);
  OPTIONS.s1Model = MODEL_OVERRIDES.s1
    ? path.join(MODELS_DIR, MODEL_OVERRIDES.s1)
    : resolvePath(CONFIG.s1Model);
  OPTIONS.qwenModel = MODEL_OVERRIDES.qwen
    ? path.join(MODELS_DIR, MODEL_OVERRIDES.qwen)
    : resolvePath(CONFIG.qwenModel);
  stt.configureSttRuntime(OPTIONS, logger);
  llmServers.configureLocalLlm({ s1Model: OPTIONS.s1Model, qwenModel: OPTIONS.qwenModel });
  if (killSlot === "s1" || killSlot === "qwen") {
    try {
      llmServers.killServer(killSlot, logger);
    } catch {}
  }
}

// Mic level file, read by the overlay in voice-tray.ahk.
const LEVEL_PATH = OPTIONS.tmpDir + "/sober-stt.level";
// Current pipeline phase, read by the overlay to pick label/color.
const PHASE_PATH = OPTIONS.tmpDir + "/sober-stt.phase";
// Last pipeline results by seq, so the tray app can poll without blocking.
const RESULTS = new Map();
let pipelineSeq = 0;
// Last pipeline I/O, for debugging what was heard vs produced.
// Disabled with "keepLastJson": false in config (privacy).
const LAST_PATH = OPTIONS.tmpDir + "/sober-stt.last.json";
function writeLast(payload) {
  if (CONFIG.keepLastJson === false) return;
  try {
    fs.writeFileSync(LAST_PATH, JSON.stringify(payload));
  } catch {}
}

// The last dictation WAV is useless once transcribed: delete it so the
// microphone's latest audio never sits in %TEMP% (S3).
function dropWav() {
  try {
    fs.unlinkSync(stt.getSttWavPath());
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

// The packaged tray starts the runner hidden, so stdout is lost. Mirror it
// to %TEMP%/sober-stt.log for bug reports (fresh file past 512 KB).
const LOG_PATH = OPTIONS.tmpDir + "/sober-stt.log";
try {
  if (fs.existsSync(LOG_PATH) && fs.statSync(LOG_PATH).size > 512 * 1024) fs.unlinkSync(LOG_PATH);
} catch {}
for (const m of ["log", "warn", "error"]) {
  const orig = console[m].bind(console);
  console[m] = (...a) => {
    orig(...a);
    try {
      const ts = new Date().toISOString().slice(11, 23);
      fs.appendFileSync(LOG_PATH, `${ts} ` + a.map((x) => String(x)).join(" ") + "\n");
    } catch {}
  };
}

// STT system prompt: canonical copy lives in prompts/ (configurable via
// promptFile, so prompt variants can be A/B tested). Falls back to the lib
// default if the file is missing. The leading <!-- --> doc block is stripped
// so it never reaches the model.
function loadPromptFile() {
  const rel = CONFIG.promptFile || "prompts/stt-system-prompt.md";
  const name = String(rel).replace(/\\/g, "/").split("/").pop();
  try {
    const file = resolvePath(rel);
    const stripped = fs
      .readFileSync(file, "utf8")
      .replace(/^<!--[\s\S]*?-->\s*/, "")
      .replace(/\s+$/, "");
    if (stripped.trim()) {
      logger.log("VOICE", `Using ${rel}`, "debug");
      return { source: name, text: stripped };
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

applyModelOverrides();
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

// PowerShell 7 (pwsh) is not inbox on Win10/11; fall back to Windows
// PowerShell 5.1 (powershell.exe), which covers both uses (host + SendKeys).
let _psBin = null;
function psBin() {
  if (_psBin) return _psBin;
  if (process.platform !== "win32") {
    _psBin = "pwsh";
    return _psBin;
  }
  try {
    execFileSync("where", ["pwsh"], { stdio: "ignore" });
    _psBin = "pwsh";
  } catch {
    _psBin = "powershell.exe";
  }
  return _psBin;
}

function dropHost(e) {
  if (e) logger.log("VOICE", `recorder host error: ${e.message}`, "warn");
  try {
    hostProc?.kill();
  } catch {}
  hostProc = null;
  hostReady = null;
  recording = false;
  while (hostPending.length) {
    const resolve = hostPending.shift();
    try {
      resolve("err host-error");
    } catch {}
  }
}

function ensureHost() {
  if (hostProc) return hostReady;
  // Fresh Windows clients block .ps1 execution by default (Restricted policy),
  // which killed the recorder host on first install. Bypass applies to this
  // child process only; it changes nothing machine-wide.
  hostProc = spawn(psBin(), ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", REC_HOST], {
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
  hostProc.on("error", dropHost);
  // P9: a dead host must not leave commands hanging until the 15 s timeout.
  hostProc.on("exit", () => dropHost());
  hostReady = new Promise((resolve) => hostPending.push(resolve));
  return hostReady;
}

function hostCmd(line) {
  return new Promise((resolve, reject) => {
    if (!hostProc) return reject(new Error("recorder host not running"));
    const entry = (response) => {
      clearTimeout(timer);
      resolve(response);
    };
    const timer = setTimeout(() => {
      const i = hostPending.indexOf(entry);
      if (i >= 0) hostPending.splice(i, 1);
      reject(new Error("recorder host timeout"));
    }, 15000);
    hostPending.push(entry);
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

function pasteText(text, pid) {
  if (process.platform !== "win32") return false;
  // U3: don't eat the user's clipboard. Save text content, restore ~400 ms
  // after pasting (best effort; non-text clipboard content can't be saved
  // via clip). Disable with "preserveClipboard": false.
  let prev = null;
  if (CONFIG.preserveClipboard !== false) {
    try {
      prev = execFileSync(psBin(), ["-NoProfile", "-NonInteractive", "-Command", "Get-Clipboard -Raw"], {
        timeout: 5000,
      }).toString();
    } catch {
      prev = null;
    }
  }
  try {
    execFileSync("clip", { input: text });
  } catch {
    return false;
  }
  try {
    // U2: the user may have switched windows mid-pipeline; put the window
    // that was focused at /stop back on top before Ctrl+V (best effort).
    const focus = Number(pid) > 0 ? `$null = (New-Object -ComObject WScript.Shell).AppActivate(${Number(pid)}); Start-Sleep -Milliseconds 150; ` : "";
    // Ctrl+V by hand: WSH's SendKeys('^v') loses the Ctrl modifier on some
    // machines and the target receives a literal "v", so inject the four events
    // with keybd_event (VK_CONTROL 0x11, VK_V 0x56, KEYEVENTF_KEYUP 2) spaced by
    // 60 ms. Add-Type is slow, so it runs after the window is back on top.
    const ctrlV =
      `Add-Type -Namespace SttKeys -Name Vk -MemberDefinition '[DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);'; ` +
      `[SttKeys.Vk]::keybd_event(0x11,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; ` +
      `[SttKeys.Vk]::keybd_event(0x56,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; ` +
      `[SttKeys.Vk]::keybd_event(0x56,0,2,[UIntPtr]::Zero); Start-Sleep -Milliseconds 60; ` +
      `[SttKeys.Vk]::keybd_event(0x11,0,2,[UIntPtr]::Zero)`;
    execFileSync(
      psBin(),
      ["-NoProfile", "-NonInteractive", "-Command", `${focus}${ctrlV}`],
      { timeout: 8000 },
    );
  } catch {
    return false;
  }
  if (prev !== null) {
    const t = setTimeout(() => {
      try {
        execFileSync(psBin(), ["-NoProfile", "-NonInteractive", "-Command", "Set-Clipboard -Value $input"], {
          input: prev,
          timeout: 5000,
        });
      } catch {}
    }, 400);
    t.unref?.();
  }
  return true;
}

// ---- Pipeline --------------------------------------------------------------
// Runs in the background: /stop returns {started, seq} immediately so the AHK
// overlay keeps repainting while the phases change. (A blocking /stop froze the
// AHK thread inside the HTTP call, so transcribing/normalizing never painted.)
async function runPipeline(seq, pid) {
  processing = true;
  const done = (payload) => {
    RESULTS.set(seq, { seq, done: true, ...payload });
    if (RESULTS.size > 5) RESULTS.delete(RESULTS.keys().next().value);
    // One line per dictation in %TEMP%/sober-stt.log: the cause of a failure
    // (no-speech, STT error, paste failure) is what bug reports need.
    logger.log(
      "PIPE",
      `seq=${seq} ok=${payload.ok} error=${payload.error || "-"} pasted=${payload.pasted ?? "-"} chars=${(payload.text || "").length}`,
      "info",
    );
    processing = false;
    writePhase("idle");
    stt.markSttIdle();
    dropWav();
    scheduleIdleKill();
  };
  try {
    await hostCmd(JSON.stringify({ cmd: "stop" })); // finalizes the WAV before we transcribe
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
    done({ ok: true, text, pasted: pasteText(text, pid) });
  } catch (e) {
    done({ ok: false, error: e.message });
  }
}

function readBody(req, limit = 100 * 1024) {
  return new Promise((resolve) => {
    let data = "";
    let size = 0;
    let tooBig = false;
    req.on("data", (chunk) => {
      size += chunk.length;
      // Over the cap: drain without accumulating (bounded memory) and
      // answer 413 on end. No destroy(): the socket must stay open to
      // deliver the response.
      if (size > limit) {
        tooBig = true;
        return;
      }
      if (!tooBig) data += chunk;
    });
    req.on("end", () => {
      if (tooBig) return resolve({ __tooBig: true });
      try {
        resolve(data ? JSON.parse(data) : {});
      } catch {
        resolve({});
      }
    });
    req.on("error", () => resolve({}));
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
  return { ok: missing.length === 0, missing, active: activeModels() };
}

const server = http.createServer(async (req, res) => {
  const reqPath = new URL(req.url, "http://127.0.0.1").pathname;
  const method = req.method;

  try {
    // S1: loopback alone doesn't stop a web page (CORS blocks reading, not
    // sending). Require the loopback host, no Origin, and the per-boot token.
    // Brackets first: splitting "[::1]:8791" on ":" would leave "[".
    let host = String(req.headers.host || "").toLowerCase();
    const br = host.match(/^\[(.+)\](?::\d+)?$/);
    host = (br ? br[1] : host.split(":")[0]).replace(/^\[|\]$/g, "");
    if (!["127.0.0.1", "localhost", "::1"].includes(host))
      return send(res, 403, { ok: false, error: "bad-host" });
    if (req.headers.origin) return send(res, 403, { ok: false, error: "origin-denied" });
    if (req.headers["x-sober-token"] !== TOKEN)
      return send(res, 403, { ok: false, error: "bad-token" });

    if (method === "GET" && reqPath === "/health") {
      return send(res, 200, { ok: true, recording, processing, warm, phase, modelsDir: MODELS_DIR, tmpDir: OPTIONS.tmpDir, deps: checkDeps() });
    }
    if (method === "GET" && reqPath === "/last") {
      try {
        return send(res, 200, { ok: true, ...JSON.parse(fs.readFileSync(LAST_PATH, "utf8")) });
      } catch {
        return send(res, 404, { ok: false, error: "no-last" });
      }
    }
    if (method === "POST" && reqPath === "/start") {
      if (recording || processing) return send(res, 200, { ok: true, recording });
      await ensureHost();
      // P9: a host "err ..." reply is a failed start, not a recording.
      const started = await hostCmd(JSON.stringify({ cmd: "start", wav: stt.getSttWavPath(), level: LEVEL_PATH }));
      if (!String(started).startsWith("ok")) return send(res, 500, { ok: false, error: String(started) });
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
    if (method === "POST" && reqPath === "/stop") {
      if (processing) return send(res, 200, { ok: false, error: "busy" });
      if (!recording) return send(res, 200, { ok: false, error: "not-recording" });
      const stopBody = await readBody(req);
      if (stopBody.__tooBig) return send(res, 413, { ok: false, error: "body-too-big" });
      pipelineSeq += 1;
      const seq = pipelineSeq;
      RESULTS.set(seq, { seq, done: false });
      void runPipeline(seq, Number(stopBody.pid) || 0);
      return send(res, 200, { ok: true, started: true, seq });
    }
    if (method === "GET" && reqPath === "/result") {
      const seq = Number(new URL(req.url, "http://127.0.0.1").searchParams.get("seq"));
      const r = RESULTS.get(seq);
      if (!r) return send(res, 404, { ok: false, error: "unknown-seq" });
      return send(res, 200, { ok: true, ...r });
    }
    if (method === "POST" && reqPath === "/cancel") {
      if (recording) {
        await hostCmd(JSON.stringify({ cmd: "stop" }));
        recording = false;
        dropWav();
      }
      writePhase("idle");
      stt.markSttIdle();
      return send(res, 200, { ok: true, cancelled: true });
    }
    if (method === "POST" && reqPath === "/kill") {
      clearIdle();
      killServers();
      return send(res, 200, { ok: true });
    }
    if (method === "POST" && reqPath === "/warm") {
      const body = await readBody(req);
      if (body.__tooBig) return send(res, 413, { ok: false, error: "body-too-big" });
      warm = Boolean(body.enabled);
      if (warm) {
        startWarmLoop();
      } else {
        stopWarmLoop();
        scheduleIdleKill();
      }
      return send(res, 200, { ok: true, warm });
    }
    if (method === "POST" && reqPath === "/chunk") {
      const body = await readBody(req);
      if (body.__tooBig) return send(res, 413, { ok: false, error: "body-too-big" });
      OPTIONS.chunking = body.enabled !== false;
      stt.configureSttRuntime(OPTIONS, logger);
      return send(res, 200, { ok: true, chunking: OPTIONS.chunking });
    }
    if (method === "POST" && reqPath === "/models") {
      const body = await readBody(req);
      if (body.__tooBig) return send(res, 413, { ok: false, error: "body-too-big" });
      const slot = String(body.slot || "");
      const file = String(body.file || "");
      const known = ["parakeet", "s1", "qwen"];
      if (!known.includes(slot)) return send(res, 400, { ok: false, error: "unknown-slot" });
      if (!file) {
        delete MODEL_OVERRIDES[slot]; // back to the installer default
      } else {
        if (file.includes("/") || file.includes("\\") || file.includes(".."))
          return send(res, 400, { ok: false, error: "bad-filename" });
        const wantExt = slot === "parakeet" ? ".bin" : ".gguf";
        if (!file.toLowerCase().endsWith(wantExt))
          return send(res, 400, { ok: false, error: `expected-${wantExt}` });
        const full = path.join(MODELS_DIR, file);
        let st;
        try {
          st = fs.statSync(full);
        } catch {
          return send(res, 404, { ok: false, error: "not-found" });
        }
        if (!st.isFile() || st.size < 1024 * 1024)
          return send(res, 400, { ok: false, error: "bad-file" });
        if (wantExt === ".gguf") {
          const fd = fs.openSync(full, "r");
          const head = Buffer.alloc(4);
          fs.readSync(fd, head, 0, 4, 0);
          fs.closeSync(fd);
          if (head.toString("ascii") !== "GGUF")
            return send(res, 400, { ok: false, error: "not-gguf" });
        }
        if (st.size > 3 * 1024 * 1024 * 1024 && body.confirmed !== true)
          return send(res, 400, { ok: false, error: "too-big-confirm", size: st.size });
        MODEL_OVERRIDES[slot] = file;
      }
      try {
        fs.mkdirSync(stateDir(), { recursive: true });
        fs.writeFileSync(path.join(stateDir(), "models.override.json"), JSON.stringify(MODEL_OVERRIDES, null, 2));
      } catch (e) {
        return send(res, 500, { ok: false, error: e.message });
      }
      applyModelOverrides(slot);
      return send(res, 200, { ok: true, active: activeModels() });
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
  writeTokenFile(); // we own the port now, so this token is the live one
  console.log(`voice-runner listening on http://127.0.0.1:${PORT}`);
  // Warm the recorder host now so the first dictation doesn't pay the compile cost.
  writePhase("idle");
  ensureHost().catch((e) => logger.log("VOICE", `recorder host failed: ${e.message}`, "warn"));
});

function shutdown() {
  clearIdle();
  stopWarmLoop();
  killServers();
  removeTokenFile();
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
