// Manages local llama-server processes with 2min idle auto-kill.
// Each server is spawned on-demand, kept alive while in use, killed after 120s idle.
//
// Vendored from the opencode-voice plugin repo (lib/local-llm-manager.js) so
// SOBER-STT-8GB installs standalone. SOBER-STT-8GB adaptation: server paths
// and ports are set via configureLocalLlm(opts); defaults preserve the
// original dev-machine behavior.

import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const IDLE_MS = 120_000; // 2 minutos sem uso -> mata server
const STARTUP_TIMEOUT_MS = 30_000;

const SERVERS = {
  s1: {
    port: 8080,
    modelFile: "C:/Users/the_s/models/s1-mini-q4_k_m.gguf",
    bin: "C:/Users/the_s/bin/llama/llama-server.exe",
  },
  qwen: {
    port: 8081,
    modelFile: "C:/Users/the_s/models/Qwen3-4B-Q4_K_M.gguf",
    bin: "C:/Users/the_s/bin/llama/llama-server.exe",
  },
};

// Flag names churn between llama.cpp releases (e.g. b11429 removed
// --no-mmap in favor of --load-mode, and deprecated --chat-template-kwargs
// for --reasoning). Probe each binary once so old and new builds both work.
const helpCache = new Map();
function binSupports(bin, flag) {
  if (!helpCache.has(bin)) {
    try {
      helpCache.set(bin, execFileSync(bin, ["--help"], { encoding: "utf8", timeout: 15000 }));
    } catch {
      helpCache.set(bin, "");
    }
  }
  return helpCache.get(bin).includes(flag);
}

function serverArgs(cfg) {
  const args = [
    "-m",
    cfg.modelFile,
    "--host",
    "127.0.0.1",
    "--port",
    String(cfg.port),
    "-c",
    "2048",
    "--jinja",
    "--temp",
    "0",
    "-ngl",
    "99",
    "--flash-attn",
    "on",
  ];
  // Trailing space: "--reasoning " must not match old "--reasoning-format".
  if (binSupports(cfg.bin, "--reasoning ")) args.push("--reasoning", "off");
  else args.push("--chat-template-kwargs", '{"enable_thinking":false}');
  if (binSupports(cfg.bin, "--load-mode")) args.push("--load-mode", "none");
  else if (binSupports(cfg.bin, "--no-mmap")) args.push("--no-mmap");
  return args;
}

// Point the servers at this machine's binaries, models, and ports.
// Accepts { llamaBin, s1Model, qwenModel, s1Port, qwenPort }; anything
// omitted keeps the default above.
export function configureLocalLlm(opts) {
  if (!opts) return;
  if (opts.llamaBin) {
    SERVERS.s1.bin = opts.llamaBin;
    SERVERS.qwen.bin = opts.llamaBin;
  }
  if (opts.s1Model) SERVERS.s1.modelFile = opts.s1Model;
  if (opts.qwenModel) SERVERS.qwen.modelFile = opts.qwenModel;
  if (opts.s1Port) SERVERS.s1.port = opts.s1Port;
  if (opts.qwenPort) SERVERS.qwen.port = opts.qwenPort;
}

const state = {
  s1: { proc: null, idleTimer: null, starting: null },
  qwen: { proc: null, idleTimer: null, starting: null },
};

function logLine(logger, msg, level = "debug") {
  logger?.log?.("LocalLLM", msg, level);
}

async function isAlive(port, timeoutMs = 800) {
  try {
    const ctrl = AbortSignal.timeout(timeoutMs);
    const r = await fetch(`http://127.0.0.1:${port}/health`, { signal: ctrl });
    return r.ok;
  } catch {
    try {
      const ctrl2 = AbortSignal.timeout(timeoutMs);
      const r2 = await fetch(`http://127.0.0.1:${port}/v1/models`, { signal: ctrl2 });
      return r2.ok;
    } catch {
      return false;
    }
  }
}

function scheduleIdleKill(key, logger) {
  const s = state[key];
  if (s.idleTimer) clearTimeout(s.idleTimer);
  s.idleTimer = setTimeout(() => {
    logLine(
      logger,
      `${key} idle ${IDLE_MS}ms -> killing server on port ${SERVERS[key].port}`,
      "debug",
    );
    killServer(key, logger);
  }, IDLE_MS);
  // don't keep process alive just for timer
  s.idleTimer.unref?.();
}

export function touchServer(key, logger) {
  if (!state[key]) return;
  scheduleIdleKill(key, logger);
}

export function killServer(key, logger) {
  const s = state[key];
  if (s.idleTimer) {
    clearTimeout(s.idleTimer);
    s.idleTimer = null;
  }
  if (s.proc) {
    try {
      s.proc.kill("SIGTERM");
    } catch {}
    // force after 2s
    setTimeout(() => {
      try {
        s.proc?.kill("SIGKILL");
      } catch {}
    }, 2000);
    s.proc = null;
  }
  s.starting = null;
  logLine(logger, `${key} killed`, "debug");
}

export function killAll(logger) {
  for (const k of Object.keys(SERVERS)) killServer(k, logger);
}

export async function ensureServer(key, logger) {
  const cfg = SERVERS[key];
  if (!cfg) throw new Error(`unknown server ${key}`);
  if (!fs.existsSync(cfg.modelFile)) {
    throw new Error(`Model not found: ${cfg.modelFile}`);
  }
  if (!fs.existsSync(cfg.bin)) {
    throw new Error(`llama-server not found: ${cfg.bin}`);
  }

  // already alive externally (manual start)
  if (await isAlive(cfg.port, 600)) {
    logLine(logger, `${key} already alive on :${cfg.port}`, "debug");
    touchServer(key, logger);
    return;
  }
  // already spawning
  if (state[key].starting) {
    logLine(logger, `${key} already starting, waiting...`, "debug");
    await state[key].starting;
    touchServer(key, logger);
    return;
  }
  // if proc exists but not responding, kill stale
  if (state[key].proc && !(await isAlive(cfg.port, 400))) {
    killServer(key, logger);
  }

  const args = serverArgs(cfg);
  logLine(logger, `Spawning ${key} on :${cfg.port} -> ${cfg.bin} ${args.join(" ")}`, "debug");

  const proc = spawn(cfg.bin, args, {
    stdio: ["ignore", "pipe", "pipe"],
    detached: false,
    cwd: path.dirname(cfg.bin),
  });
  state[key].proc = proc;

  proc.stdout.on("data", (d) =>
    logLine(logger, `${key} stdout: ${d.toString().trim().slice(0, 400)}`, "debug"),
  );
  proc.stderr.on("data", (d) =>
    logLine(logger, `${key} stderr: ${d.toString().trim().slice(0, 400)}`, "debug"),
  );
  proc.on("exit", (code) => {
    logLine(logger, `${key} exited code=${code}`, code === 0 ? "debug" : "warn");
    if (state[key].proc === proc) state[key].proc = null;
  });
  proc.on("error", (err) => {
    logLine(logger, `${key} spawn error: ${err.message}`, "error");
    state[key].proc = null;
  });

  // wait until /health or /v1/models responds
  const start = Date.now();
  const promise = (async () => {
    while (Date.now() - start < STARTUP_TIMEOUT_MS) {
      await new Promise((r) => setTimeout(r, 400));
      if (await isAlive(cfg.port, 600)) {
        logLine(logger, `${key} ready on :${cfg.port} after ${Date.now() - start}ms`, "debug");
        return;
      }
    }
    throw new Error(`${key} failed to start within ${STARTUP_TIMEOUT_MS}ms`);
  })();

  state[key].starting = promise;
  try {
    await promise;
  } finally {
    state[key].starting = null;
  }
  touchServer(key, logger);
}

// Touch on every successful LLM call, so idle timer resets
export const SERVERS_META = SERVERS;
