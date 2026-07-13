#!/usr/bin/env node
// PROTOTYPE — pyright stale-diagnostics sync proxy.
//
// Problem it solves: pyright is push-only (no diagnosticProvider), so it only
// re-analyzes an OPEN document when the client sends textDocument/didChange.
// Claude Code edits files on disk (Edit/Write tools) without sending didChange,
// so pyright keeps serving the diagnostics from the version it last saw — the
// "stale errors after a fix" symptom. A workspace/didChangeWatchedFiles event
// would NOT help: for an open document the server authoritatively uses the
// client's in-memory buffer, not disk. The only refresh lever is didChange.
//
// What this proxy does: it sits between Claude Code and pyright, forwarding all
// traffic transparently (NO method-blocking, NO server→client auto-ack — pyright
// works direct today, so we preserve that exactly), and adds ONE behavior:
//   - it records every document the client opens (textDocument/didOpen),
//   - polls those files on disk, and
//   - when an open file's content changes on disk, injects a synthetic
//     textDocument/didChange (full-text, version-incremented) to pyright so it
//     re-analyzes and re-publishes.
//
// Client priority: if the client EVER sends its own didChange for a URI (a real
// editor managing a buffer), the proxy backs off for that document and never
// injects — the client is authoritative. So this is inert for buffer-driven
// clients and only activates for disk-edit clients like Claude Code.
//
// Usage: node lsp-proxy.js --config <path-to-proxy.json>
// proxy.json: { "server": ["pyright-langserver","--stdio"], "sync": { "pollMs": 300 } }
//
// Node stdlib only, per repo convention.

"use strict";

const { spawn } = require("child_process");
const { readFileSync, statSync } = require("fs");
const { resolve } = require("path");
const { fileURLToPath } = require("url");

// -- Config ------------------------------------------------------------------

const configIdx = process.argv.indexOf("--config");
if (configIdx === -1 || !process.argv[configIdx + 1]) {
  process.stderr.write("Usage: lsp-proxy --config <path-to-proxy.json>\n");
  process.exit(1);
}
const configPath = resolve(process.argv[configIdx + 1]);
let config;
try {
  config = JSON.parse(readFileSync(configPath, "utf8"));
} catch (err) {
  process.stderr.write(`[pyright-sync] Failed to read config: ${err.message}\n`);
  process.exit(1);
}
if (!Array.isArray(config.server) || config.server.length === 0) {
  process.stderr.write('[pyright-sync] Config "server" must be a non-empty array\n');
  process.exit(1);
}

const SERVER_CMD = config.server[0];
const SERVER_ARGS = config.server.slice(1);
const POLL_MS = Math.max(50, (config.sync && config.sync.pollMs) || 300);

// -- Framing -----------------------------------------------------------------

const HEADER_DELIM = Buffer.from("\r\n\r\n");
const CONTENT_LENGTH_RE = /^content-length:\s*(\d+)\s*$/im;

function writeMessage(stream, obj) {
  if (!stream || !stream.writable) return;
  const buf = Buffer.from(JSON.stringify(obj));
  stream.write(`Content-Length: ${buf.length}\r\n\r\n`);
  stream.write(buf);
}

// -- Open-document tracking --------------------------------------------------

// uri -> { version, text, path, stat: {mtimeMs,size}|null, pending: bool }
const open = new Map();
// URIs where the client sent its own didChange — the proxy defers to it.
const clientDriven = new Set();

function toPath(uri) {
  try {
    return uri.startsWith("file:") ? fileURLToPath(uri) : null;
  } catch {
    return null;
  }
}

function statOf(p) {
  try {
    const s = statSync(p);
    return { mtimeMs: s.mtimeMs, size: s.size };
  } catch {
    return null;
  }
}

function sameStat(a, b) {
  return a && b && a.mtimeMs === b.mtimeMs && a.size === b.size;
}

// -- Spawn pyright; server→client is a transparent raw pipe ------------------

const child = spawn(SERVER_CMD, SERVER_ARGS, { stdio: ["pipe", "pipe", "inherit"] });
child.stdout.pipe(process.stdout);

child.on("error", (err) => {
  process.stderr.write(`[pyright-sync] child error: ${err.message}\n`);
  process.exit(1);
});
child.on("exit", (code) => {
  clearInterval(pollTimer);
  process.exit(code ?? 1);
});

// -- Client→server: observe didOpen/didChange/didClose, forward everything ---

let buffer = Buffer.alloc(0);

process.stdin.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  drainClient();
});
process.stdin.on("end", () => {
  clearInterval(pollTimer);
  child.kill("SIGTERM");
});

function drainClient() {
  while (true) {
    const delimIdx = buffer.indexOf(HEADER_DELIM);
    if (delimIdx === -1) return;
    const header = buffer.subarray(0, delimIdx).toString("ascii");
    const match = CONTENT_LENGTH_RE.exec(header);
    if (!match) {
      // Unrecoverable header: forward what we have and reset (mirrors the
      // sibling proxies' fail-safe).
      child.stdin.write(buffer);
      buffer = Buffer.alloc(0);
      return;
    }
    const contentLength = parseInt(match[1], 10);
    const bodyStart = delimIdx + HEADER_DELIM.length;
    const messageEnd = bodyStart + contentLength;
    if (buffer.length < messageEnd) return;

    const rawMessage = buffer.subarray(0, messageEnd);
    const bodyBytes = buffer.subarray(bodyStart, messageEnd);
    buffer = buffer.subarray(messageEnd);

    let msg = null;
    try { msg = JSON.parse(bodyBytes.toString("utf8")); } catch { /* forward raw */ }
    if (msg) observe(msg);

    // Always forward the client's original bytes unchanged.
    child.stdin.write(rawMessage);
  }
}

function observe(msg) {
  const td = msg.params && msg.params.textDocument;
  switch (msg.method) {
    case "textDocument/didOpen": {
      if (!td || !td.uri) return;
      const p = toPath(td.uri);
      open.set(td.uri, {
        version: typeof td.version === "number" ? td.version : 1,
        text: td.text != null ? td.text : "",
        path: p,
        stat: p ? statOf(p) : null,
        pending: false,
      });
      break;
    }
    case "textDocument/didChange": {
      // The client manages this buffer itself — stop injecting for it.
      if (td && td.uri) {
        clientDriven.add(td.uri);
        const st = open.get(td.uri);
        if (st && typeof td.version === "number") st.version = td.version;
      }
      break;
    }
    case "textDocument/didClose": {
      if (td && td.uri) {
        open.delete(td.uri);
        clientDriven.delete(td.uri);
      }
      break;
    }
    default:
      break;
  }
}

// -- Disk-sync poll: inject didChange when an open file changes on disk -------
//
// Two-tick stability gate: we only inject once a file's (mtime,size) has been
// steady across consecutive polls, so a mid-write partial read never reaches
// pyright. This adds up to one POLL_MS of latency to the refresh.

const pollTimer = setInterval(pollOpenFiles, POLL_MS);
if (pollTimer.unref) pollTimer.unref();

function pollOpenFiles() {
  for (const [uri, st] of open) {
    if (clientDriven.has(uri) || !st.path) continue;
    const cur = statOf(st.path);
    if (!cur) { st.pending = false; continue; }

    if (!sameStat(cur, st.stat)) {
      // Disk changed since last poll — record and wait one tick for it to settle.
      st.stat = cur;
      st.pending = true;
      continue;
    }
    if (!st.pending) continue;

    // Stable for a full tick — safe to read and (maybe) inject.
    st.pending = false;
    let text;
    try { text = readFileSync(st.path, "utf8"); } catch { continue; }
    if (text === st.text) continue; // content-identical (e.g. touch) — no-op

    st.version += 1;
    st.text = text;
    writeMessage(child.stdin, {
      jsonrpc: "2.0",
      method: "textDocument/didChange",
      params: {
        textDocument: { uri, version: st.version },
        contentChanges: [{ text }],
      },
    });
    process.stderr.write(`[pyright-sync] injected didChange ${uri} v${st.version}\n`);
  }
}

// -- Signals -----------------------------------------------------------------

for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, () => {
    clearInterval(pollTimer);
    child.kill(sig);
  });
}
