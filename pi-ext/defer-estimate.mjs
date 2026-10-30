#!/usr/bin/env node
// Best-effort size estimator for PI_DEFER=auto (see pi-ctf).
//
// Connects to each stdio MCP server listed in the source mcp.json, lists its
// tools over raw newline-delimited JSON-RPC (no SDK, no deps), and reports the
// combined size of all MCP tool definitions as a percentage of the model
// context window, using chars / 4 ~= tokens. HTTP servers, disabled servers,
// and servers that don't answer in time count as 0.
//
//   node defer-estimate.mjs --pct     -> prints just the percentage (e.g. 42.7)
//   node defer-estimate.mjs           -> prints a JSON breakdown
//
// Env: PI_MCP_SRC (source mcp.json), PI_MODELS (models.json for contextWindow),
//      PI_CONTEXT_WINDOW (fallback window), PI_DEFER_PROBE_TIMEOUT_MS.
import { readFileSync } from "node:fs";
import { spawn } from "node:child_process";

const SRC = process.env.PI_MCP_SRC || "/opt/pi/mcp.json";
const MODELS = process.env.PI_MODELS || `${process.env.HOME || ""}/.pi/agent/models.json`;
const TIMEOUT_MS = Number(process.env.PI_DEFER_PROBE_TIMEOUT_MS || 6000);

function readJson(path) {
  try { return JSON.parse(readFileSync(path, "utf8")); } catch { return null; }
}

function contextWindow() {
  const m = readJson(MODELS);
  try {
    for (const prov of Object.values(m?.providers || {}))
      for (const mod of prov?.models || [])
        if (mod?.contextWindow) return mod.contextWindow;
  } catch { /* fall through */ }
  return Number(process.env.PI_CONTEXT_WINDOW || 32768);
}

// Resolve a server's tool-definition size in characters. Stdio only.
function listToolsChars(cfg) {
  return new Promise((resolve) => {
    if (!cfg?.command) return resolve(0); // http / unknown transport: skip
    let done = false;
    let buf = "";
    let child;
    try {
      child = spawn(cfg.command, cfg.args || [], {
        stdio: ["pipe", "pipe", "ignore"],
        env: { ...process.env, ...(cfg.env || {}) },
      });
    } catch { return resolve(0); }

    const finish = (n) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try { child.kill("SIGKILL"); } catch { /* already gone */ }
      resolve(n);
    };
    const timer = setTimeout(() => finish(0), TIMEOUT_MS);
    child.on("error", () => finish(0));
    child.on("exit", () => finish(0));

    const send = (obj) => { try { child.stdin.write(JSON.stringify(obj) + "\n"); } catch { /* closed */ } };

    let asked = false;
    child.stdout.on("data", (d) => {
      buf += d.toString();
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        if (!line.trim()) continue;
        let msg;
        try { msg = JSON.parse(line); } catch { continue; }
        if (msg.id === 1 && !asked) {
          // initialize answered -> complete the handshake and ask for tools
          asked = true;
          send({ jsonrpc: "2.0", method: "notifications/initialized" });
          send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
        } else if (msg.id === 2) {
          const tools = msg.result?.tools || [];
          finish(tools.reduce((a, t) => a + JSON.stringify(t).length, 0));
        }
      }
    });

    send({
      jsonrpc: "2.0", id: 1, method: "initialize",
      params: {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "pi-defer-estimate", version: "1.0.0" },
      },
    });
  });
}

const cfg = readJson(SRC) || { mcpServers: {} };
const servers = Object.entries(cfg.mcpServers || {}).filter(([, c]) => c?.enabled !== false);

const perServer = {};
let totalChars = 0;
for (const [name, c] of servers) {
  const chars = await listToolsChars(c);
  perServer[name] = chars;
  totalChars += chars;
}

const ctx = contextWindow();
const tokens = totalChars / 4;
const pct = ctx > 0 ? (tokens / ctx) * 100 : 100;

if (process.argv.includes("--pct")) {
  console.log(pct.toFixed(1));
} else {
  console.log(JSON.stringify({
    perServerChars: perServer,
    totalChars,
    estTokens: Math.round(tokens),
    contextWindow: ctx,
    pct: Number(pct.toFixed(1)),
  }, null, 2));
}
