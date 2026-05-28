#!/usr/bin/env node
// Minimal LSP client for end-to-end tests.
//
// Spawns a language server (or the production lsp-proxy.js wrapping one),
// drives the initialize/initialized handshake, exposes notify/request/didOpen,
// and gathers diagnostics in either pull (LSP 3.17 textDocument/diagnostic) or
// push (publishDiagnostics + quiet-period debounce) mode.
//
// Wire framing lifted from regal-lsp/lsp-proxy.js — same byte-buffer state
// machine, just on the client side.
//
// Hand-rolled with Node stdlib only per repo convention.

"use strict";

const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const HEADER_DELIM = Buffer.from("\r\n\r\n");
const CL_RE = /^content-length:\s*(\d+)\s*$/im;

const PUSH_QUIET_MS = parseInt(process.env.LIVE_QUIET_MS || "500", 10);
const PUSH_TIMEOUT_MS = parseInt(process.env.LIVE_TIMEOUT_MS || "5000", 10);
const PULL_TIMEOUT_MS = parseInt(process.env.LIVE_PULL_TIMEOUT_MS || "10000", 10);

// Server-initiated requests this client handles natively. The set MUST mirror
// the four methods both production proxies (ansible-language-server/lsp-proxy.js,
// regal-lsp/lsp-proxy.js) auto-respond to — these are the requests Claude Code's
// real client handles, so the test must too. Any other server-initiated request
// is replied with JSON-RPC -32601 ("method not found"), matching what Claude
// Code's subset client does in production. Auto-acking *more* than this would
// hide protocol gaps the live suite is supposed to catch.
const SERVER_REQUEST_AUTOACKS = {
  "client/registerCapability":      () => null,
  "client/unregisterCapability":    () => null,
  "window/workDoneProgress/create": () => null,
  // workspace/configuration's spec-correct response is an array of length
  // params.items.length. The production proxies reply with a single null,
  // which is spec-violating but works for the servers they wrap; the test
  // client keeps the spec-compliant shape so pyright/vtsls direct-spawn
  // scenarios don't trip on the proxy bug. (See PR review finding E3.)
  "workspace/configuration":        (p) => (p && p.items ? p.items.map(() => null) : []),
};

const DEFAULT_CAPS = {
  textDocument: {
    publishDiagnostics: { relatedInformation: true, versionSupport: false },
    diagnostic: { dynamicRegistration: false, relatedDocumentSupport: false },
    synchronization: { didSave: true },
  },
  workspace: {
    configuration: true,
    workspaceFolders: true,
    didChangeConfiguration: { dynamicRegistration: false },
  },
  window: {
    workDoneProgress: false,
  },
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

class LspClient {
  constructor({ command, args, cwd, env = {}, captureStderr = true }) {
    this.command = command;
    this.args = args || [];
    this.cwd = cwd;
    // Scrub identity-bearing vars from the inherited env so a server's
    // config-file search (e.g. regal's ~/.regal/config.yaml, eslint's home
    // config) cannot reach into the developer's real $HOME. Point HOME at
    // the per-scenario workdir, which is itself a fresh tmpdir.
    const {
      HOME: _h,
      XDG_CONFIG_HOME: _xc,
      XDG_DATA_HOME: _xd,
      XDG_CACHE_HOME: _xch,
      ...sanitized
    } = process.env;
    this.env = { ...sanitized, HOME: cwd, ...env };
    this.captureStderr = captureStderr;
    this.child = null;
    this._buffer = Buffer.alloc(0);
    this._pending = new Map();
    this._nextId = 1;
    this._diagsByUri = new Map();
    this._lastPublishAt = new Map();
    this._diagListeners = [];
    this._stderrChunks = [];
    this._serverCaps = null;
    this.exited = null;
  }

  async start() {
    // detached:true puts the child in its own process group on POSIX. Lets
    // shutdown() send signals to the negative pid and reap subprocesses
    // (vtsls forks tsserver, pyright forks workers, etc.) atomically.
    this.child = spawn(this.command, this.args, {
      cwd: this.cwd,
      env: this.env,
      stdio: ["pipe", "pipe", "pipe"],
      detached: true,
    });
    this.child.stdout.on("data", (chunk) => this._onStdoutData(chunk));
    // Swallow stdin 'error' events (EPIPE after the child exits) so they
    // don't propagate to the test runner as uncaughtException.
    this.child.stdin.on("error", () => {});
    if (this.captureStderr) {
      this.child.stderr.on("data", (chunk) => this._stderrChunks.push(chunk));
    } else {
      this.child.stderr.pipe(process.stderr);
    }
    this.exited = new Promise((resolve) => {
      this.child.on("exit", (code, signal) => {
        // Reject any in-flight requests so callers see "process died" instead
        // of "request timed out" 15s later.
        for (const p of this._pending.values()) {
          clearTimeout(p.timer);
          p.reject(new Error(
            `LSP process exited (code=${code}, signal=${signal}) ` +
            `with pending request`
          ));
        }
        this._pending.clear();
        resolve({ code, signal });
      });
    });
    this.child.on("error", (err) => {
      for (const p of this._pending.values()) {
        clearTimeout(p.timer);
        p.reject(err);
      }
      this._pending.clear();
    });
  }

  stderr() { return Buffer.concat(this._stderrChunks).toString("utf8"); }

  _onStdoutData(chunk) {
    this._buffer = Buffer.concat([this._buffer, chunk]);
    while (true) {
      const di = this._buffer.indexOf(HEADER_DELIM);
      if (di === -1) return;
      const header = this._buffer.subarray(0, di).toString("ascii");
      const m = CL_RE.exec(header);
      if (!m) {
        // Protocol violation: header block without Content-Length. We can't
        // know where the body ends, so trying to "skip just the delimiter"
        // would misparse subsequent body bytes as headers and corrupt every
        // frame after. Drop the entire buffer instead so the next valid
        // frame's header re-syncs cleanly.
        process.stderr.write(
          `[lsp-client] dropping ${this._buffer.length} buffered bytes: ` +
          `header without Content-Length\n`
        );
        this._buffer = Buffer.alloc(0);
        return;
      }
      const cl = parseInt(m[1], 10);
      const bodyStart = di + HEADER_DELIM.length;
      const messageEnd = bodyStart + cl;
      if (this._buffer.length < messageEnd) return;
      const body = this._buffer.subarray(bodyStart, messageEnd);
      this._buffer = this._buffer.subarray(messageEnd);
      let msg;
      try { msg = JSON.parse(body.toString("utf8")); } catch { continue; }
      this._handle(msg);
    }
  }

  _handle(msg) {
    try {
      // Response to one of our requests.
      if (msg.id !== undefined && msg.method === undefined) {
        const p = this._pending.get(msg.id);
        if (!p) return;
        this._pending.delete(msg.id);
        clearTimeout(p.timer);
        if (msg.error) p.reject(new Error(`LSP error ${msg.error.code}: ${msg.error.message}`));
        else p.resolve(msg.result);
        return;
      }
      // Server-initiated request: handle the small allow-list, reply -32601
      // to everything else — matching Claude Code's subset client.
      if (msg.id !== undefined && msg.method) {
        const handler = SERVER_REQUEST_AUTOACKS[msg.method];
        if (handler) {
          this._send({ jsonrpc: "2.0", id: msg.id, result: handler(msg.params) });
        } else {
          this._send({
            jsonrpc: "2.0",
            id: msg.id,
            error: { code: -32601, message: `Method not found: ${msg.method}` },
          });
        }
        return;
      }
      // Server-initiated notification.
      if (msg.method === "textDocument/publishDiagnostics") {
        const uri = msg.params && msg.params.uri;
        if (!uri) return;
        this._diagsByUri.set(uri, (msg.params && msg.params.diagnostics) || []);
        this._lastPublishAt.set(uri, Date.now());
        for (const cb of this._diagListeners) cb(uri);
      }
    } catch (err) {
      // A bug in this handler (or a malformed message that slipped past the
      // guards above) must not abort the test process. Log + drop.
      process.stderr.write(`[lsp-client] _handle error: ${err && err.stack || err}\n`);
    }
  }

  _send(obj) {
    if (!this.child || !this.child.stdin || !this.child.stdin.writable) return;
    const body = Buffer.from(JSON.stringify(obj));
    try {
      this.child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
      this.child.stdin.write(body);
    } catch {
      // Child stdin closed mid-write (EPIPE). The 'exit' handler will reject
      // any pending request derived from this _send; nothing to do here.
    }
  }

  notify(method, params) {
    this._send({ jsonrpc: "2.0", method, params });
  }

  request(method, params, { timeout = PULL_TIMEOUT_MS } = {}) {
    const id = this._nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this._pending.delete(id);
        reject(new Error(`request timed out: ${method} (id=${id}, ${timeout}ms)`));
      }, timeout);
      this._pending.set(id, { resolve, reject, timer });
      this._send({ jsonrpc: "2.0", id, method, params });
    });
  }

  async initialize({ rootUri, capabilities = DEFAULT_CAPS, workspaceFolders,
                     initializationOptions, settings = {} }) {
    const wf = workspaceFolders
      || (rootUri ? [{ uri: rootUri, name: "fixture" }] : null);
    const result = await this.request("initialize", {
      processId: process.pid,
      rootUri: rootUri || null,
      capabilities,
      clientInfo: { name: "claude-lsps-live-test", version: "0" },
      workspaceFolders: wf,
      initializationOptions,
    }, { timeout: 15000 });
    this._serverCaps = result.capabilities || {};
    this.notify("initialized", {});
    // Pyright (and many others) sit idle after `initialized` until they see
    // workspace/didChangeConfiguration. Sending an empty settings object is
    // harmless for servers that don't care and unblocks the ones that do.
    this.notify("workspace/didChangeConfiguration", { settings });
    return result;
  }

  hasPullDiagnostics() {
    return !!(this._serverCaps && this._serverCaps.diagnosticProvider);
  }

  isAlive() {
    return !!(this.child && this.child.exitCode === null
      && this.child.signalCode === null && !this.child.killed);
  }

  didOpen({ uri, languageId, text, version = 1 }) {
    this.notify("textDocument/didOpen", {
      textDocument: { uri, languageId, version, text },
    });
  }

  // mode: "auto" | "pull" | "push"
  // requirePublish: when true (default), push-mode timeout without ever
  //   receiving a publishDiagnostics throws — distinguishing "server is silent"
  //   from "server published 0 diagnostics". Set false only for servers known
  //   not to publish (e.g. cue lsp v0.16, which exposes the LSP transport but
  //   no diagnostic provider yet).
  async waitForDiagnostics({ uri, mode = "auto", quietMs, timeout, requirePublish = true } = {}) {
    const resolved = mode === "auto"
      ? (this.hasPullDiagnostics() ? "pull" : "push")
      : mode;
    if (resolved === "pull") {
      const r = await this.request("textDocument/diagnostic",
        { textDocument: { uri } },
        { timeout: timeout ?? PULL_TIMEOUT_MS });
      if (!r) return [];
      if (r.kind === "full") return r.items || [];
      // "unchanged" on a first-ever pull (we didn't send previousResultId)
      // means the server isn't actually answering — fail loud rather than
      // silently treating it as "no diagnostics".
      throw new Error(
        `pull diagnostic for ${uri} returned kind=${JSON.stringify(r.kind)}; ` +
        `expected "full"`
      );
    }
    const t = timeout ?? PUSH_TIMEOUT_MS;
    const q = quietMs ?? PUSH_QUIET_MS;
    const start = Date.now();
    // Initialize lastUpdate from the actual publish timestamp if a publish
    // already arrived (e.g. during initialize). Otherwise -Infinity so the
    // quiet-period check can't fire until a real publish lands.
    let lastUpdate = this._lastPublishAt.get(uri) ?? -Infinity;
    let updated = this._lastPublishAt.has(uri);
    const listener = (u) => {
      if (u !== uri) return;
      lastUpdate = Date.now();
      updated = true;
    };
    this._diagListeners.push(listener);
    try {
      while (true) {
        await sleep(50);
        const sinceUpdate = Date.now() - lastUpdate;
        const total = Date.now() - start;
        if (updated && sinceUpdate >= q) return this._diagsByUri.get(uri) || [];
        if (total >= t) {
          if (!updated && requirePublish) {
            throw new Error(
              `no publishDiagnostics received for ${uri} within ${t}ms ` +
              `(server may have crashed or never started analysis)`
            );
          }
          return this._diagsByUri.get(uri) || [];
        }
      }
    } finally {
      const idx = this._diagListeners.indexOf(listener);
      if (idx >= 0) this._diagListeners.splice(idx, 1);
    }
  }

  // Drive the LSP shutdown handshake, then ensure the process group is dead.
  // We use process.kill(-pid) so subprocesses the LSP forked (tsserver,
  // pyright workers) are reaped along with the parent — otherwise repeat CI
  // runs orphan worker processes. graceMs gives the server time to flush
  // NODE_V8_COVERAGE on clean exit (the 99-coverage gate depends on this).
  async shutdown({ graceMs = 3000 } = {}) {
    try { await this.request("shutdown", null, { timeout: 2000 }); } catch {}
    try { this.notify("exit", null); } catch {}
    try { this.child.stdin.end(); } catch {}
    if (this.exited) await Promise.race([this.exited, sleep(graceMs)]);

    if (!this.child || this.child.exitCode !== null) return;

    // Server didn't exit cleanly. Escalate to SIGTERM on the whole process
    // group, then SIGKILL after another short grace.
    const pgKill = (signal) => {
      try { process.kill(-this.child.pid, signal); return true; } catch {}
      try { this.child.kill(signal); return true; } catch {}
      return false;
    };
    pgKill("SIGTERM");
    await Promise.race([this.exited, sleep(500)]);
    if (this.child.exitCode === null) pgKill("SIGKILL");
  }
}

// Read a plugin's .lsp.json, substitute ${CLAUDE_PLUGIN_ROOT}, and return the
// resolved spawn parameters. Takes the first language entry; multi-entry
// .lsp.json would need explicit selection.
function parseLspJson(pluginDir) {
  const raw = JSON.parse(fs.readFileSync(path.join(pluginDir, ".lsp.json"), "utf8"));
  const keys = Object.keys(raw);
  if (keys.length === 0) throw new Error(`${pluginDir}/.lsp.json has no language entries`);
  if (keys.length > 1) {
    throw new Error(
      `${pluginDir}/.lsp.json has multiple language entries (${keys.join(", ")}); ` +
      `live-suite needs explicit selection`
    );
  }
  const entry = raw[keys[0]];
  const sub = (s) => s.replace(/\$\{CLAUDE_PLUGIN_ROOT\}/g, pluginDir);
  return {
    pluginKey: keys[0],
    command: sub(entry.command),
    args: (entry.args || []).map(sub),
    extensionToLanguage: entry.extensionToLanguage || {},
  };
}

// Resolve the wire-level LSP languageId for a file. The .lsp.json top-level
// key is the Claude-Code-internal language tag (e.g. "bash" for the bash
// plugin); the value Claude Code actually puts in didOpen.textDocument
// .languageId comes from extensionToLanguage (e.g. ".sh" -> "shellscript").
// Falls back to the top-level key only if no extension match exists.
function wireLanguageIdFor(parsed, filePath) {
  const ext = path.extname(filePath);
  return parsed.extensionToLanguage[ext] || parsed.pluginKey;
}

module.exports = {
  LspClient,
  parseLspJson,
  wireLanguageIdFor,
  SERVER_REQUEST_AUTOACKS,
  DEFAULT_CAPS,
  PUSH_QUIET_MS,
  PUSH_TIMEOUT_MS,
  PULL_TIMEOUT_MS,
};
