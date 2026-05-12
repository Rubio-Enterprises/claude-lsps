#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");

const {
  requireEnv, frameOf, parseFrames, sleep, waitFor, newWorkdir,
  readJsonLines, assert, spawnProxy, dispatch,
} = require("./lsp-test-utils.js");

const { ROOT_DIR, TMP_DIR, TESTS_DIR } = requireEnv();
const REGAL_PROXY = path.join(ROOT_DIR, "regal-lsp", "lsp-proxy.js");
const STUB = path.join(TESTS_DIR, "helpers", "stub-server.js");

const wd = (tag) => newWorkdir(TMP_DIR, tag);

function writeRegoTree(root, layout) {
  for (const [rel, content] of Object.entries(layout)) {
    const full = path.join(root, rel);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, content);
  }
}

// Wait for the proxy to forward the initialize *response* before sending
// 'initialized'. That's the same event that flips initializeResponseSeen=true
// inside the proxy, which gates the warmup trigger.
async function driveInitialize(proxy, rootDir) {
  proxy.child.stdin.write(frameOf({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: { rootUri: pathToFileURL(rootDir).href },
  }));
  await waitFor(() => parseFrames(proxy.stdoutBuf()).some((f) => f.body.id === 1));
  proxy.child.stdin.write(frameOf({
    jsonrpc: "2.0",
    method: "initialized",
    params: {},
  }));
}

function regalConfig(extra = {}) {
  return { server: ["node", STUB], blocked: [], ...extra };
}

function setupTree(tag, layout) {
  const dir = wd(tag);
  const stubLog = path.join(dir, "stub");
  fs.mkdirSync(stubLog, { recursive: true });
  const tree = path.join(dir, "tree");
  fs.mkdirSync(tree, { recursive: true });
  writeRegoTree(tree, layout);
  return { dir, stubLog, tree };
}

async function warmupOpensRegoFiles(setProxy) {
  const { dir, stubLog, tree } = setupTree("rego-tree", {
    "policy.rego": "package a",
    "sub/sub.rego": "package b",
    "node_modules/lib.rego": "package skip",
    "vendor/v.rego": "package skip",
    ".git/g.rego": "package skip",
    "other.txt": "skip me",
  });
  const cfg = path.join(dir, "proxy.json");
  fs.writeFileSync(cfg, JSON.stringify(regalConfig({
    warmup: {
      extensions: [".rego"],
      exclude: ["node_modules", ".git", "vendor", ".venv", ".claude"],
    },
  })));

  const proxy = spawnProxy({
    proxyJs: REGAL_PROXY,
    configPath: cfg,
    stubEnv: { STUB_LOG_DIR: stubLog, STUB_AUTO_INIT: "1" },
  });
  setProxy(proxy);

  await driveInitialize(proxy, tree);
  await waitFor(() => readJsonLines(path.join(stubLog, "recv.jsonl"))
    .filter((m) => m.method === "textDocument/didOpen").length >= 2);
  await sleep(150);

  const msgs = readJsonLines(path.join(stubLog, "recv.jsonl"));
  const idxInitialized = msgs.findIndex((m) => m.method === "initialized");
  const opens = msgs.filter((m) => m.method === "textDocument/didOpen");
  assert(idxInitialized !== -1, "stub never saw 'initialized'");
  for (const o of opens) {
    assert(o.params.textDocument.languageId === "rego",
      `didOpen languageId not 'rego': ${JSON.stringify(o.params.textDocument)}`);
    assert(o.params.textDocument.uri.startsWith("file://"),
      `didOpen uri not file://: ${o.params.textDocument.uri}`);
    for (const excluded of ["/node_modules/", "/vendor/", "/.git/"]) {
      assert(!o.params.textDocument.uri.includes(excluded),
        `excluded dir leaked: ${o.params.textDocument.uri}`);
    }
  }
  assert(opens.length === 2,
    `expected 2 didOpen, got ${opens.length}: ${opens.map((o) => o.params.textDocument.uri).join(", ")}`);
  const idxFirstOpen = msgs.findIndex((m) => m.method === "textDocument/didOpen");
  assert(idxInitialized < idxFirstOpen,
    "didOpen burst occurred before 'initialized' was forwarded");

  proxy.child.stdin.end();
  await proxy.exited;
}

async function warmupEmptyTree(setProxy) {
  const { dir, stubLog, tree } = setupTree("empty-tree", {
    "a.txt": "x",
  });
  const cfg = path.join(dir, "proxy.json");
  fs.writeFileSync(cfg, JSON.stringify(regalConfig({
    warmup: {
      extensions: [".rego"],
      exclude: ["node_modules", ".git", "vendor", ".venv", ".claude"],
    },
  })));

  const proxy = spawnProxy({
    proxyJs: REGAL_PROXY,
    configPath: cfg,
    stubEnv: { STUB_LOG_DIR: stubLog, STUB_AUTO_INIT: "1" },
  });
  setProxy(proxy);

  await driveInitialize(proxy, tree);
  await waitFor(() => /warmup: no files found/.test(proxy.stderr()));
  await sleep(200);

  const opens = readJsonLines(path.join(stubLog, "recv.jsonl"))
    .filter((m) => m.method === "textDocument/didOpen");
  assert(opens.length === 0,
    `expected zero didOpen on empty tree, got ${opens.length}`);

  proxy.child.stdin.end();
  await proxy.exited;
}

async function warmupAbsentNoOpen(setProxy) {
  const { dir, stubLog, tree } = setupTree("no-warmup", {
    "policy.rego": "package a",
    "sub/sub.rego": "package b",
  });
  const cfg = path.join(dir, "proxy.json");
  fs.writeFileSync(cfg, JSON.stringify(regalConfig()));

  const proxy = spawnProxy({
    proxyJs: REGAL_PROXY,
    configPath: cfg,
    stubEnv: { STUB_LOG_DIR: stubLog, STUB_AUTO_INIT: "1" },
  });
  setProxy(proxy);

  await driveInitialize(proxy, tree);
  await waitFor(() => readJsonLines(path.join(stubLog, "recv.jsonl"))
    .some((m) => m.method === "initialized"));
  await sleep(250);

  const msgs = readJsonLines(path.join(stubLog, "recv.jsonl"));
  const opens = msgs.filter((m) => m.method === "textDocument/didOpen");
  assert(opens.length === 0,
    `expected zero didOpen with no warmup config; got ${opens.length}`);
  assert(!/warmup:/.test(proxy.stderr()),
    `proxy emitted a warmup log line with no warmup config:\n${proxy.stderr()}`);

  proxy.child.stdin.end();
  await proxy.exited;
}

async function warmupMultiExtension(setProxy) {
  const { dir, stubLog, tree } = setupTree("multi-ext", {
    "a.rego": "package a",
    "b.py": "x = 1",
    "c.ts": "const x = 1;",
    "d.swift": "let x = 1",
    "e.foo": "bar",
  });
  const cfg = path.join(dir, "proxy.json");
  fs.writeFileSync(cfg, JSON.stringify(regalConfig({
    warmup: {
      extensions: [".rego", ".py", ".ts", ".swift", ".foo"],
      exclude: ["node_modules", ".git", "vendor"],
    },
  })));

  const proxy = spawnProxy({
    proxyJs: REGAL_PROXY,
    configPath: cfg,
    stubEnv: { STUB_LOG_DIR: stubLog, STUB_AUTO_INIT: "1" },
  });
  setProxy(proxy);

  await driveInitialize(proxy, tree);
  await waitFor(() => readJsonLines(path.join(stubLog, "recv.jsonl"))
    .filter((m) => m.method === "textDocument/didOpen").length >= 5);
  await sleep(150);

  const opens = readJsonLines(path.join(stubLog, "recv.jsonl"))
    .filter((m) => m.method === "textDocument/didOpen");
  const langByFile = {};
  for (const o of opens) {
    langByFile[path.basename(o.params.textDocument.uri)] = o.params.textDocument.languageId;
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

dispatch({
  "files-opened": warmupOpensRegoFiles,
  "empty-tree": warmupEmptyTree,
  "no-warmup-section": warmupAbsentNoOpen,
  "multi-extension": warmupMultiExtension,
}, process.argv[2]);
