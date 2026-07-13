#!/usr/bin/env node
// Unified LSP proxy for Claude Code plugins — the standard wrapper for every
// plugin in this marketplace. All six plugin directories carry a byte-identical
// copy of this file (enforced by tests/cases/02-consistency.sh); behavior is
// driven entirely by each plugin's proxy.json.
//
// Responsibilities (each config-gated where noted):
//
//   1. BLOCKED METHODS ("blocked"): intercept client→server requests for
//      methods the server answers with JSON-RPC -32601, which puts Claude
//      Code's LSP client into an unrecoverable broken state. The proxy
//      synthesizes {result: null} instead and drops blocked notifications.
//
//   2. AUTO-ACK: answer server→client requests Claude Code's client can't
//      handle (client/registerCapability, client/unregisterCapability,
//      workspace/configuration, window/workDoneProgress/create) so the server
//      doesn't deadlock. workspace/configuration gets the spec-correct
//      per-item null array (params.items.length entries), not a bare null.
//
//   3. WARMUP ("warmup"): after the client's `initialized`, walk rootUri for
//      matching files and send synthetic textDocument/didOpen so servers that
//      defer indexing until first-open (Regal) start immediately.
//
//   4. DISK-SYNC ("sync", default ON): Claude Code sends didChange+didSave for
//      its own Edit-tool writes but NOTHING for out-of-band disk edits (Bash
//      sed/git/formatters/other sessions) — validated by wire-tapping real
//      sessions; see experiments/lsp-wiretap/FINDINGS.md. Push-only servers
//      then serve stale diagnostics. The proxy tracks open documents (client
//      didOpens AND warmup opens), polls them on disk with a one-tick
//      stability gate, and injects a synthetic full-text didChange + didSave
//      when disk content diverges from the last known buffer content.
//
//      Reconciliation, not back-off: client didChanges are mirrored into the
//      proxy's buffer/version state (the client stays authoritative for its
//      own edits; a disk write matching the buffer is a no-op) and injected
//      versions continue from max(client, injected)+1. An INCREMENTAL
//      (range-based) client didChange makes the buffer unreconstructable —
//      disk-sync is disabled for that document (logged once).
//
// Usage: node lsp-proxy.js --config <path-to-proxy.json>
//
// proxy.json format:
//   {
//     "server": ["command", "arg1", ...],
//     "blocked": ["method/name", ...],
//     "warmup": { "extensions": [".rego"], "exclude": ["node_modules", ...] },
//     "sync": { "pollMs": 300 }          // or false to disable disk-sync
//   }
//
// Node stdlib only, per repo convention.

"use strict";

const { spawn } = require("child_process");
const { readFileSync, readdirSync, statSync } = require("fs");
const { resolve, join, extname } = require("path");
const { fileURLToPath, pathToFileURL } = require("url");

// ---------------------------------------------------------------------------
// Load configuration
// ---------------------------------------------------------------------------

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
  process.stderr.write(`[lsp-proxy] Failed to read config: ${err.message}\n`);
  process.exit(1);
}

if (!Array.isArray(config.server) || config.server.length === 0) {
  process.stderr.write('[lsp-proxy] Config "server" must be a non-empty array\n');
  process.exit(1);
}

const SERVER_CMD = config.server[0];
const SERVER_ARGS = config.server.slice(1);
const BLOCKED_METHODS = new Set(config.blocked || []);
const WARMUP = config.warmup || null;
const SYNC = config.sync === false
  ? null
  : { pollMs: Math.max(50, (config.sync && config.sync.pollMs) || 300) };
const LOG_PREFIX = `[lsp-proxy:${SERVER_CMD}]`;

// ---------------------------------------------------------------------------
// LSP message framing helpers
// ---------------------------------------------------------------------------

const HEADER_DELIM = Buffer.from("\r\n\r\n");
const CONTENT_LENGTH_RE = /^content-length:\s*(\d+)\s*$/im;

function writeMessage(stream, body) {
  const buf = Buffer.isBuffer(body) ? body : Buffer.from(body);
  stream.write(`Content-Length: ${buf.length}\r\n\r\n`);
  stream.write(buf);
}

// ---------------------------------------------------------------------------
// Spawn the real language server
// ---------------------------------------------------------------------------

const child = spawn(SERVER_CMD, SERVER_ARGS, {
  stdio: ["pipe", "pipe", "inherit"],
});

// ---------------------------------------------------------------------------
// Disk-sync: open-document tracking
// ---------------------------------------------------------------------------

// uri -> { version, text, path, stat: {mtimeMs,size}|null, pending: bool,
//          unsyncable: bool }
// `text` mirrors the last known BUFFER content (didOpen text, client full-text
// didChanges, warmup opens, injected texts).
const openDocs = new Map();

function toPath(uri) {
  try {
    return uri && uri.startsWith("file:") ? fileURLToPath(uri) : null;
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

function trackOpen(uri, text, version) {
  if (!SYNC) return;
  const p = toPath(uri);
  openDocs.set(uri, {
    version: typeof version === "number" ? version : 1,
    text: text != null ? text : "",
    path: p,
    stat: p ? statOf(p) : null,
    pending: false,
    unsyncable: false,
  });
}

// Mirror a client didChange into the buffer model (reconciliation).
function trackChange(uri, version, contentChanges) {
  if (!SYNC) return;
  const st = openDocs.get(uri);
  if (!st) return;
  if (typeof version === "number" && version > st.version) {
    st.version = version;
  }
  if (!Array.isArray(contentChanges)) return;
  for (const c of contentChanges) {
    if (c && c.range === undefined && typeof c.text === "string") {
      st.text = c.text; // full-document replacement
    } else if (!st.unsyncable) {
      st.unsyncable = true;
      process.stderr.write(
        `${LOG_PREFIX} incremental didChange for ${uri}; disk-sync disabled for it\n`
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Disk-sync: poll loop
//
// Two-tick stability gate: only inject once a file's (mtime,size) has been
// steady across consecutive polls, so a mid-write partial read never reaches
// the server. Injects didChange (full text) + didSave, matching what Claude
// Code itself sends for Edit-tool writes.
// ---------------------------------------------------------------------------

function pollOpenDocs() {
  for (const [uri, st] of openDocs) {
    if (st.unsyncable || !st.path) continue;
    const cur = statOf(st.path);
    if (!cur) { st.pending = false; continue; }

    if (!sameStat(cur, st.stat)) {
      // Disk changed since last poll — record and wait one tick to settle.
      st.stat = cur;
      st.pending = true;
      continue;
    }
    if (!st.pending) continue;

    // Stable for a full tick — safe to read and (maybe) inject.
    st.pending = false;
    let text;
    try { text = readFileSync(st.path, "utf8"); } catch { continue; }
    if (text === st.text) continue; // content-identical (touch, client's own write)

    st.version += 1;
    st.text = text;
    writeMessage(child.stdin, JSON.stringify({
      jsonrpc: "2.0",
      method: "textDocument/didChange",
      params: {
        textDocument: { uri, version: st.version },
        contentChanges: [{ text }],
      },
    }));
    writeMessage(child.stdin, JSON.stringify({
      jsonrpc: "2.0",
      method: "textDocument/didSave",
      params: { textDocument: { uri } },
    }));
    process.stderr.write(`${LOG_PREFIX} disk-sync: injected didChange ${uri} v${st.version}\n`);
  }
}

const pollTimer = SYNC ? setInterval(pollOpenDocs, SYNC.pollMs) : null;
if (pollTimer && pollTimer.unref) pollTimer.unref();

// ---------------------------------------------------------------------------
// Warmup: file discovery
// ---------------------------------------------------------------------------

/**
 * Recursively find files matching the given extensions, skipping excluded dirs.
 * Uses a stack to avoid recursion depth issues on large trees.
 */
function findFiles(rootDir, extensions, excludeDirs) {
  const extSet = new Set(extensions);
  const excludeSet = new Set(excludeDirs);
  const results = [];
  const stack = [rootDir];

  while (stack.length > 0) {
    const dir = stack.pop();
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      // Permission denied, symlink loop, etc. — skip silently.
      continue;
    }

    for (const entry of entries) {
      if (excludeSet.has(entry.name)) continue;

      const fullPath = join(dir, entry.name);
      if (entry.isDirectory()) {
        stack.push(fullPath);
      } else if (entry.isFile() && extSet.has(extname(entry.name))) {
        results.push(fullPath);
      }
    }
  }
  return results;
}

/**
 * Send textDocument/didOpen notifications to the server for each file.
 * Uses languageId derived from the file extension. Warmup-opened documents
 * enroll in disk-sync tracking like client-opened ones — a disk edit to a
 * warmup-opened file must refresh its diagnostics too.
 */
function warmupServer(rootDir) {
  if (!WARMUP || !Array.isArray(WARMUP.extensions) || WARMUP.extensions.length === 0) {
    return;
  }

  const exclude = WARMUP.exclude || [];
  const files = findFiles(rootDir, WARMUP.extensions, exclude);

  if (files.length === 0) {
    process.stderr.write(`${LOG_PREFIX} warmup: no files found\n`);
    return;
  }

  process.stderr.write(`${LOG_PREFIX} warmup: opening ${files.length} file(s) for indexing\n`);

  // Map extensions to languageIds
  const extToLang = {
    ".rego": "rego",
    ".py": "python",
    ".ts": "typescript",
    ".js": "javascript",
    ".cue": "cue",
    ".sh": "shellscript",
    ".yml": "yaml",
    ".yaml": "yaml",
    ".swift": "swift",
  };

  let version = 0;
  for (const filePath of files) {
    let content;
    try {
      content = readFileSync(filePath, "utf8");
    } catch {
      continue; // Unreadable file — skip.
    }

    const ext = extname(filePath);
    const languageId = extToLang[ext] || ext.slice(1);
    const uri = pathToFileURL(filePath).href;

    const notification = JSON.stringify({
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: {
        textDocument: {
          uri,
          languageId,
          version: version,
          text: content,
        },
      },
    });

    writeMessage(child.stdin, notification);
    trackOpen(uri, content, version);
    version++;
  }

  process.stderr.write(`${LOG_PREFIX} warmup: sent ${files.length} didOpen notification(s)\n`);
}

// ---------------------------------------------------------------------------
// State tracking for warmup trigger
// ---------------------------------------------------------------------------

let rootUri = null;
let initializeResponseSeen = false;

// ---------------------------------------------------------------------------
// Server→client: parse messages, auto-respond to server-initiated requests
// ---------------------------------------------------------------------------

const SERVER_REQUESTS_AUTO_RESPOND = new Set([
  "client/registerCapability",
  "client/unregisterCapability",
  "workspace/configuration",
  "window/workDoneProgress/create",
]);

// workspace/configuration's spec-correct response is one entry per
// params.items element ("use defaults" = null each). A bare null here breaks
// servers that index into the array (pyright, vtsls).
function autoAckResult(msg) {
  if (msg.method === "workspace/configuration") {
    const items = msg.params && Array.isArray(msg.params.items) ? msg.params.items : [];
    return items.map(() => null);
  }
  return null;
}

let serverBuffer = Buffer.alloc(0);

child.stdout.on("data", (chunk) => {
  serverBuffer = Buffer.concat([serverBuffer, chunk]);
  drainServerBuffer();
});

function drainServerBuffer() {
  while (true) {
    const delimIdx = serverBuffer.indexOf(HEADER_DELIM);
    if (delimIdx === -1) return;

    const header = serverBuffer.subarray(0, delimIdx).toString("ascii");
    const match = CONTENT_LENGTH_RE.exec(header);
    if (!match) {
      process.stdout.write(serverBuffer);
      serverBuffer = Buffer.alloc(0);
      return;
    }

    const contentLength = parseInt(match[1], 10);
    const bodyStart = delimIdx + HEADER_DELIM.length;
    const messageEnd = bodyStart + contentLength;

    if (serverBuffer.length < messageEnd) return;

    const rawMessage = serverBuffer.subarray(0, messageEnd);
    const bodyBytes = serverBuffer.subarray(bodyStart, messageEnd);
    serverBuffer = serverBuffer.subarray(messageEnd);

    let msg;
    try {
      msg = JSON.parse(bodyBytes.toString("utf8"));
    } catch {
      process.stdout.write(rawMessage);
      continue;
    }

    // Auto-respond to server-initiated requests the client can't handle.
    if (
      msg.id !== undefined &&
      msg.method &&
      SERVER_REQUESTS_AUTO_RESPOND.has(msg.method)
    ) {
      const ack = JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: autoAckResult(msg) });
      writeMessage(child.stdin, ack);
      continue;
    }

    // Detect the initialize response (has "capabilities" in result).
    // We use this + the subsequent "initialized" notification to trigger warmup.
    if (msg.result && msg.result.capabilities) {
      initializeResponseSeen = true;
    }

    // Forward everything else to the client.
    process.stdout.write(rawMessage);
  }
}

child.on("error", (err) => {
  process.stderr.write(`${LOG_PREFIX} child error: ${err.message}\n`);
  process.exit(1);
});

child.on("exit", (code) => {
  if (pollTimer) clearInterval(pollTimer);
  process.exit(code ?? 1);
});

// ---------------------------------------------------------------------------
// Client→server: parse messages, intercept blocked methods, trigger warmup,
// observe document lifecycle for disk-sync
// ---------------------------------------------------------------------------

let buffer = Buffer.alloc(0);

process.stdin.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  drainBuffer();
});

process.stdin.on("end", () => {
  if (pollTimer) clearInterval(pollTimer);
  child.kill("SIGTERM");
});

function drainBuffer() {
  while (true) {
    const delimIdx = buffer.indexOf(HEADER_DELIM);
    if (delimIdx === -1) return;

    const header = buffer.subarray(0, delimIdx).toString("ascii");
    const match = CONTENT_LENGTH_RE.exec(header);
    if (!match) {
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

    let msg;
    try {
      msg = JSON.parse(bodyBytes.toString("utf8"));
    } catch {
      child.stdin.write(rawMessage);
      continue;
    }

    // Capture rootUri from the initialize request.
    if (msg.method === "initialize" && msg.params) {
      rootUri = msg.params.rootUri || msg.params.rootPath || null;
      process.stderr.write(`${LOG_PREFIX} rootUri: ${rootUri}\n`);
    }

    // Observe document lifecycle for disk-sync bookkeeping.
    const td = msg.params && msg.params.textDocument;
    if (msg.method === "textDocument/didOpen" && td && td.uri) {
      trackOpen(td.uri, td.text, td.version);
    } else if (msg.method === "textDocument/didChange" && td && td.uri) {
      trackChange(td.uri, td.version, msg.params.contentChanges);
    } else if (msg.method === "textDocument/didClose" && td && td.uri) {
      openDocs.delete(td.uri);
    }

    // After "initialized" notification, trigger warmup.
    if (msg.method === "initialized" && initializeResponseSeen && rootUri && WARMUP) {
      // Forward the initialized notification first.
      child.stdin.write(rawMessage);

      // Then trigger warmup asynchronously (setImmediate lets the event loop
      // flush the initialized notification to the server before we send
      // the didOpen burst).
      const rootDir = rootUri.startsWith("file://")
        ? fileURLToPath(rootUri)
        : rootUri;
      setImmediate(() => warmupServer(rootDir));
      continue;
    }

    // Block unsupported methods.
    if (msg.method && BLOCKED_METHODS.has(msg.method)) {
      if (msg.id !== undefined) {
        const response = JSON.stringify({
          jsonrpc: "2.0",
          id: msg.id,
          result: null,
        });
        writeMessage(process.stdout, response);
      }
      continue;
    }

    // Not blocked — forward the original bytes unchanged.
    child.stdin.write(rawMessage);
  }
}

// ---------------------------------------------------------------------------
// Signal forwarding
// ---------------------------------------------------------------------------

for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, () => {
    if (pollTimer) clearInterval(pollTimer);
    child.kill(sig);
  });
}
