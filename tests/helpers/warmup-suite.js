#!/usr/bin/env node
// Regal warmup tests for regal-lsp/lsp-proxy.js.

"use strict";

const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");

const ROOT_DIR = process.env.ROOT_DIR;
const TMP_DIR = process.env.TMP_DIR;
const TESTS_DIR = process.env.TESTS_DIR;
if (!ROOT_DIR || !TMP_DIR || !TESTS_DIR) {
  console.error("ROOT_DIR/TMP_DIR/TESTS_DIR must be exported");
  process.exit(2);
}

const REGAL_PROXY = path.join(ROOT_DIR, "regal-lsp", "lsp-proxy.js");
const STUB = path.join(TESTS_DIR, "helpers", "stub-server.js");

const HEADER_DELIM = Buffer.from("\r\n\r\n");
const CL_RE = /^content-length:\s*(\d+)\s*$/im;

function frameOf(obj) {
  const body = Buffer.from(JSON.stringify(obj));
  return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]);
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function waitFor(predicate, { timeout = 5000, interval = 25 } = {}) {
  const start = Date.now();
  while (true) {
    const r = await predicate();
    if (r) return r;
    if (Date.now() - start > timeout) {
      throw new Error("waitFor timeout");
    }
    await sleep(interval);
  }
}

let counter = 0;
function newWorkdir(tag) {
  const d = path.join(TMP_DIR, "warmup", `${tag}-${counter++}`);
  fs.mkdirSync(d, { recursive: true });
  return d;
}

function readJsonLines(file) {
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, "utf8").split("\n").filter(Boolean).map(JSON.parse);
}

function writeRegoTree(root, layout) {
  for (const [rel, content] of Object.entries(layout)) {
    const full = path.join(root, rel);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, content);
  }
}

function spawnProxy(stubEnv, cfg) {
  const env = { ...process.env, ...stubEnv };
  const child = spawn(process.execPath, [REGAL_PROXY, "--config", cfg], {
    stdio: ["pipe", "pipe", "pipe"],
    env,
  });
  const outChunks = [];
  const errChunks = [];
  child.stdout.on("data", (b) => outChunks.push(b));
  child.stderr.on("data", (b) => errChunks.push(b));
  const exited = new Promise((resolve) => {
    child.on("exit", (code, signal) => resolve({ code, signal }));
  });
  return {
    child,
    stdout: () => Buffer.concat(outChunks),
    stderr: () => Buffer.concat(errChunks).toString("utf8"),
    exited,
  };
}

function assert(cond, msg) {
  if (!cond) throw new Error(`assertion failed: ${msg}`);
}

async function driveInitialize(proxy, rootDir) {
  // Send initialize, then initialized.
  proxy.child.stdin.write(frameOf({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: { rootUri: pathToFileURL(rootDir).href },
  }));
  // The stub auto-responds with capabilities; we don't need to wait for the
  // response on the client side here, but we do want the proxy to see it
  // before we send "initialized".
  await sleep(150);
  proxy.child.stdin.write(frameOf({
    jsonrpc: "2.0",
    method: "initialized",
    params: {},
  }));
}

async function warmupOpensRegoFiles() {
  const wd = newWorkdir("rego-tree");
  const stubLog = path.join(wd, "stub");
  fs.mkdirSync(stubLog, { recursive: true });
  const tree = path.join(wd, "tree");
  fs.mkdirSync(tree, { recursive: true });

  // Files: two .rego files, plus excluded files.
  writeRegoTree(tree, {
    "policy.rego": "package a",
    "sub/sub.rego": "package b",
    "node_modules/lib.rego": "package skip",
    "vendor/v.rego": "package skip",
    ".git/g.rego": "package skip",
    "other.txt": "skip me",
  });

  const cfg = path.join(wd, "proxy.json");
  fs.writeFileSync(cfg, JSON.stringify({
    server: ["node", STUB],
    blocked: [],
    warmup: {
      extensions: [".rego"],
      exclude: ["node_modules", ".git", "vendor", ".venv", ".claude"],
    },
  }));

  const proxy = spawnProxy({
    STUB_LOG_DIR: stubLog,
    STUB_AUTO_INIT: "1",
  }, cfg);

  await driveInitialize(proxy, tree);

  // Wait for two didOpen notifications to appear.
  await waitFor(() => {
    const msgs = readJsonLines(path.join(stubLog, "recv.jsonl"));
    const opens = msgs.filter((m) => m.method === "textDocument/didOpen");
    return opens.length >= 2;
  });
  // Settle.
  await sleep(150);

  const msgs = readJsonLines(path.join(stubLog, "recv.jsonl"));
  // Initialized must have been forwarded before any didOpen.
  const idxInitialized = msgs.findIndex((m) => m.method === "initialized");
  const opens = msgs.filter((m) => m.method === "textDocument/didOpen");
  assert(idxInitialized !== -1, "stub never saw 'initialized'");
  for (const o of opens) {
    assert(o.params.textDocument.languageId === "rego",
      `didOpen languageId not 'rego': ${JSON.stringify(o.params.textDocument)}`);
    assert(o.params.textDocument.uri.startsWith("file://"),
      `didOpen uri not file://: ${o.params.textDocument.uri}`);
    assert(!o.params.textDocument.uri.includes("/node_modules/"),
      `excluded dir leaked: ${o.params.textDocument.uri}`);
    assert(!o.params.textDocument.uri.includes("/vendor/"),
      `excluded dir leaked: ${o.params.textDocument.uri}`);
    assert(!o.params.textDocument.uri.includes("/.git/"),
      `excluded dir leaked: ${o.params.textDocument.uri}`);
  }

  // Exactly one didOpen per discovered .rego file: we wrote 2 included ones.
  assert(opens.length === 2,
    `expected 2 didOpen, got ${opens.length}: ${opens.map((o) => o.params.textDocument.uri).join(", ")}`);

  // initialized index should be before first didOpen.
  const idxFirstOpen = msgs.findIndex((m) => m.method === "textDocument/didOpen");
  assert(idxInitialized < idxFirstOpen,
    "didOpen burst occurred before 'initialized' was forwarded");

  proxy.child.stdin.end();
  await proxy.exited;
}

async function warmupEmptyTree() {
  const wd = newWorkdir("empty-tree");
  const stubLog = path.join(wd, "stub");
  fs.mkdirSync(stubLog, { recursive: true });
  const tree = path.join(wd, "tree");
  fs.mkdirSync(tree, { recursive: true });
  // Only non-rego files.
  fs.writeFileSync(path.join(tree, "a.txt"), "x");

  const cfg = path.join(wd, "proxy.json");
  fs.writeFileSync(cfg, JSON.stringify({
    server: ["node", STUB],
    blocked: [],
    warmup: {
      extensions: [".rego"],
      exclude: ["node_modules", ".git", "vendor", ".venv", ".claude"],
    },
  }));

  const proxy = spawnProxy({
    STUB_LOG_DIR: stubLog,
    STUB_AUTO_INIT: "1",
  }, cfg);

  await driveInitialize(proxy, tree);

  // Wait for the "warmup: no files found" log line on proxy stderr.
  await waitFor(() => /warmup: no files found/.test(proxy.stderr()));
  // Settle.
  await sleep(200);

  const msgs = readJsonLines(path.join(stubLog, "recv.jsonl"));
  const opens = msgs.filter((m) => m.method === "textDocument/didOpen");
  assert(opens.length === 0,
    `expected zero didOpen on empty tree, got ${opens.length}`);

  proxy.child.stdin.end();
  await proxy.exited;
}

async function warmupAbsentNoOpen() {
  // The regal proxy must also be usable without a warmup section: initialize
  // and initialized are forwarded normally, no didOpen is emitted, and no
  // warmup log line is produced.
  const wd = newWorkdir("no-warmup");
  const stubLog = path.join(wd, "stub");
  fs.mkdirSync(stubLog, { recursive: true });
  const tree = path.join(wd, "tree");
  fs.mkdirSync(tree, { recursive: true });
  // Populate with .rego files that *would* be opened if warmup were enabled.
  writeRegoTree(tree, {
    "policy.rego": "package a",
    "sub/sub.rego": "package b",
  });

  const cfg = path.join(wd, "proxy.json");
  fs.writeFileSync(cfg, JSON.stringify({
    server: ["node", STUB],
    blocked: [],
    // No warmup key.
  }));

  const proxy = spawnProxy({
    STUB_LOG_DIR: stubLog,
    STUB_AUTO_INIT: "1",
  }, cfg);

  await driveInitialize(proxy, tree);
  // Wait until the stub has seen 'initialized'; then settle.
  await waitFor(() => {
    const msgs = readJsonLines(path.join(stubLog, "recv.jsonl"));
    return msgs.some((m) => m.method === "initialized");
  });
  await sleep(250);

  const msgs = readJsonLines(path.join(stubLog, "recv.jsonl"));
  const opens = msgs.filter((m) => m.method === "textDocument/didOpen");
  assert(opens.length === 0,
    `expected zero didOpen with no warmup config; got ${opens.length}`);
  const err = proxy.stderr();
  assert(!/warmup:/.test(err),
    `proxy emitted a warmup log line with no warmup config:\n${err}`);

  proxy.child.stdin.end();
  await proxy.exited;
}

async function warmupMultiExtension() {
  // The proxy's extToLang table maps several extensions to languageIds, with
  // a slice(1) fallback for unknown extensions. Exercise the loop body across
  // multiple languages to keep coverage robust against benign refactors of
  // the warmup walker.
  const wd = newWorkdir("multi-ext");
  const stubLog = path.join(wd, "stub");
  fs.mkdirSync(stubLog, { recursive: true });
  const tree = path.join(wd, "tree");
  fs.mkdirSync(tree, { recursive: true });
  writeRegoTree(tree, {
    "a.rego": "package a",
    "b.py": "x = 1",
    "c.ts": "const x = 1;",
    "d.swift": "let x = 1",
    "e.foo": "bar",          // unknown ext → languageId = "foo" via slice(1)
  });

  const cfg = path.join(wd, "proxy.json");
  fs.writeFileSync(cfg, JSON.stringify({
    server: ["node", STUB],
    blocked: [],
    warmup: {
      extensions: [".rego", ".py", ".ts", ".swift", ".foo"],
      exclude: ["node_modules", ".git", "vendor"],
    },
  }));

  const proxy = spawnProxy({
    STUB_LOG_DIR: stubLog,
    STUB_AUTO_INIT: "1",
  }, cfg);

  await driveInitialize(proxy, tree);
  await waitFor(() => {
    const msgs = readJsonLines(path.join(stubLog, "recv.jsonl"));
    return msgs.filter((m) => m.method === "textDocument/didOpen").length >= 5;
  });
  await sleep(150);

  const msgs = readJsonLines(path.join(stubLog, "recv.jsonl"));
  const opens = msgs.filter((m) => m.method === "textDocument/didOpen");
  // Build a map of filename → languageId so order doesn't matter.
  const langByFile = {};
  for (const o of opens) {
    const uri = o.params.textDocument.uri;
    langByFile[path.basename(uri)] = o.params.textDocument.languageId;
  }
  const expected = {
    "a.rego": "rego",
    "b.py": "python",
    "c.ts": "typescript",
    "d.swift": "swift",
    "e.foo": "foo",
  };
  for (const [file, lang] of Object.entries(expected)) {
    assert(langByFile[file] === lang,
      `expected ${file} languageId='${lang}', got '${langByFile[file]}'`);
  }

  proxy.child.stdin.end();
  await proxy.exited;
}

const SCENARIOS = {
  "files-opened": warmupOpensRegoFiles,
  "empty-tree": warmupEmptyTree,
  "no-warmup-section": warmupAbsentNoOpen,
  "multi-extension": warmupMultiExtension,
};

const name = process.argv[2];
if (!name || !SCENARIOS[name]) {
  console.error(`unknown scenario: ${name}`);
  console.error("available:", Object.keys(SCENARIOS).join(", "));
  process.exit(2);
}

(async () => {
  try {
    await SCENARIOS[name]();
    process.exit(0);
  } catch (err) {
    console.error(err && err.stack ? err.stack : String(err));
    process.exit(1);
  }
})();
