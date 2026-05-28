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

// Server-initiated requests Claude Code's real client ignores (replying -32601)
// would otherwise deadlock servers waiting on a reply. We answer with the
// minimum a spec-compliant client would. workspace/configuration's response
// must be an array of length params.items.length — single null breaks pyright.
const SERVER_REQUEST_AUTOACKS = {
  "client/registerCapability":        () => null,
  "client/unregisterCapability":      () => null,
  "window/workDoneProgress/create":   () => null,
  "window/showMessageRequest":        () => null,
  "workspace/configuration":          (p) => (p && p.items ? p.items.map(() => null) : []),
  "workspace/applyEdit":              () => ({ applied: false }),
  "workspace/codeLens/refresh":       () => null,
  "workspace/inlayHint/refresh":      () => null,
  "workspace/semanticTokens/refresh": () => null,
  "workspace/diagnostic/refresh":     () => null,
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
    this.env = { ...process.env, ...env };
    this.captureStderr = captureStderr;
    this.child = null;
    this._buffer = Buffer.alloc(0);
    this._pending = new Map();
    this._nextId = 1;
    this._diagsByUri = new Map();
    this._diagListeners = [];
    this._stderrChunks = [];
    this._serverCaps = null;
    this.exited = null;
  }

  async start() {
    this.child = spawn(this.command, this.args, {
      cwd: this.cwd,
      env: this.env,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child.stdout.on("data", (chunk) => this._onStdoutData(chunk));
    if (this.captureStderr) {
      this.child.stderr.on("data", (chunk) => this._stderrChunks.push(chunk));
    } else {
      this.child.stderr.pipe(process.stderr);
    }
    this.exited = new Promise((resolve) => {
      this.child.on("exit", (code, signal) => resolve({ code, signal }));
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
        this._buffer = this._buffer.subarray(di + HEADER_DELIM.length);
        continue;
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
    if (msg.id !== undefined && msg.method === undefined) {
      const p = this._pending.get(msg.id);
      if (!p) return;
      this._pending.delete(msg.id);
      clearTimeout(p.timer);
      if (msg.error) p.reject(new Error(`LSP error ${msg.error.code}: ${msg.error.message}`));
      else p.resolve(msg.result);
      return;
    }
    if (msg.id !== undefined && msg.method) {
      const handler = SERVER_REQUEST_AUTOACKS[msg.method];
      const result = handler ? handler(msg.params) : null;
      this._send({ jsonrpc: "2.0", id: msg.id, result });
      return;
    }
    if (msg.method === "textDocument/publishDiagnostics") {
      const uri = msg.params.uri;
      this._diagsByUri.set(uri, msg.params.diagnostics || []);
      for (const cb of this._diagListeners) cb(uri);
    }
  }

  _send(obj) {
    const body = Buffer.from(JSON.stringify(obj));
    this.child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
    this.child.stdin.write(body);
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

  didOpen({ uri, languageId, text, version = 1 }) {
    this.notify("textDocument/didOpen", {
      textDocument: { uri, languageId, version, text },
    });
  }

  // mode: "auto" | "pull" | "push"
  async waitForDiagnostics({ uri, mode = "auto", quietMs, timeout }) {
    const resolved = mode === "auto"
      ? (this.hasPullDiagnostics() ? "pull" : "push")
      : mode;
    if (resolved === "pull") {
      const r = await this.request("textDocument/diagnostic",
        { textDocument: { uri } },
        { timeout: timeout || PULL_TIMEOUT_MS });
      if (r && r.kind === "full") return r.items || [];
      return [];
    }
    const t = timeout || PUSH_TIMEOUT_MS;
    const q = quietMs || PUSH_QUIET_MS;
    const start = Date.now();
    let lastUpdate = Date.now();
    let updated = this._diagsByUri.has(uri);
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
        if (total >= t) return this._diagsByUri.get(uri) || [];
      }
    } finally {
      const idx = this._diagListeners.indexOf(listener);
      if (idx >= 0) this._diagListeners.splice(idx, 1);
    }
  }

  async shutdown({ graceMs = 1500 } = {}) {
    try { await this.request("shutdown", null, { timeout: 2000 }); } catch {}
    try { this.notify("exit", null); } catch {}
    try { this.child.stdin.end(); } catch {}
    if (this.exited) await Promise.race([this.exited, sleep(graceMs)]);
  }
}

// Read a plugin's .lsp.json, substitute ${CLAUDE_PLUGIN_ROOT}, and return the
// resolved spawn parameters. Takes the first language entry; multi-entry .lsp.json
// would need explicit selection, but the 02-consistency suite enforces single.
function parseLspJson(pluginDir) {
  const raw = JSON.parse(fs.readFileSync(path.join(pluginDir, ".lsp.json"), "utf8"));
  const keys = Object.keys(raw);
  if (keys.length === 0) throw new Error(`${pluginDir}/.lsp.json has no language entries`);
  const entry = raw[keys[0]];
  const sub = (s) => s.replace(/\$\{CLAUDE_PLUGIN_ROOT\}/g, pluginDir);
  return {
    languageId: keys[0],
    command: sub(entry.command),
    args: (entry.args || []).map(sub),
    extensionToLanguage: entry.extensionToLanguage || {},
  };
}

module.exports = {
  LspClient,
  parseLspJson,
  SERVER_REQUEST_AUTOACKS,
  DEFAULT_CAPS,
  PUSH_QUIET_MS,
  PUSH_TIMEOUT_MS,
  PULL_TIMEOUT_MS,
};
