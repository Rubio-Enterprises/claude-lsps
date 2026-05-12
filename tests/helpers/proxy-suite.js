#!/usr/bin/env node
// Proxy framing test suite. Invoked once per scenario:
//
//   node proxy-suite.js <scenario-name>
//
// Exits 0 on success, 1 on assertion failure, prints diagnostics to stderr.

"use strict";

const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const ROOT_DIR = process.env.ROOT_DIR;
const TMP_DIR = process.env.TMP_DIR;
const TESTS_DIR = process.env.TESTS_DIR;
if (!ROOT_DIR || !TMP_DIR || !TESTS_DIR) {
  console.error("ROOT_DIR/TMP_DIR/TESTS_DIR must be exported");
  process.exit(2);
}

const ANSIBLE_PROXY = path.join(ROOT_DIR, "ansible-language-server", "lsp-proxy.js");
const STUB = path.join(TESTS_DIR, "helpers", "stub-server.js");

const HEADER_DELIM = Buffer.from("\r\n\r\n");
const CL_RE = /^content-length:\s*(\d+)\s*$/im;

function frameOf(obj) {
  const body = Buffer.from(JSON.stringify(obj));
  const hdr = Buffer.from(`Content-Length: ${body.length}\r\n\r\n`);
  return Buffer.concat([hdr, body]);
}

function parseFrames(buf) {
  const out = [];
  let i = 0;
  while (i < buf.length) {
    const di = buf.indexOf(HEADER_DELIM, i);
    if (di === -1) break;
    const header = buf.subarray(i, di).toString("ascii");
    const m = CL_RE.exec(header);
    if (!m) break;
    const cl = parseInt(m[1], 10);
    const start = di + HEADER_DELIM.length;
    const end = start + cl;
    if (buf.length < end) break;
    out.push({
      raw: buf.subarray(i, end),
      body: JSON.parse(buf.subarray(start, end).toString("utf8")),
      header,
      contentLength: cl,
    });
    i = end;
  }
  return out;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function waitFor(predicate, { timeout = 4000, interval = 20 } = {}) {
  const start = Date.now();
  while (true) {
    const result = await predicate();
    if (result) return result;
    if (Date.now() - start > timeout) {
      throw new Error(`waitFor timed out after ${timeout}ms`);
    }
    await sleep(interval);
  }
}

let workdirCounter = 0;
function newWorkdir(tag) {
  const dir = path.join(TMP_DIR, "proxy", `${tag}-${workdirCounter++}`);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

function readJsonLines(file) {
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, "utf8")
    .split("\n")
    .filter((l) => l.length > 0)
    .map((l) => JSON.parse(l));
}

function spawnProxy({ proxyJs = ANSIBLE_PROXY, config, stubEnv = {}, configPath }) {
  const cfg = configPath || path.join(newWorkdir("cfg"), "proxy.json");
  if (config !== undefined) {
    fs.writeFileSync(cfg, JSON.stringify(config));
  }
  const env = { ...process.env, ...stubEnv };
  const child = spawn(process.execPath, [proxyJs, "--config", cfg], {
    stdio: ["pipe", "pipe", "pipe"],
    env,
  });
  const stdoutChunks = [];
  const stderrChunks = [];
  child.stdout.on("data", (b) => stdoutChunks.push(b));
  child.stderr.on("data", (b) => stderrChunks.push(b));
  const exited = new Promise((resolve) => {
    child.on("exit", (code, signal) => resolve({ code, signal }));
  });
  return {
    child,
    stdoutBuf: () => Buffer.concat(stdoutChunks),
    stderrBuf: () => Buffer.concat(stderrChunks),
    stdout: () => Buffer.concat(stdoutChunks).toString("utf8"),
    stderr: () => Buffer.concat(stderrChunks).toString("utf8"),
    exited,
  };
}

function assert(cond, msg) {
  if (!cond) throw new Error(`assertion failed: ${msg}`);
}

// ============================================================================
// Scenarios
// ============================================================================

async function passthrough() {
  const wd = newWorkdir("passthrough");
  const proxy = spawnProxy({
    config: {
      server: ["node", STUB],
      blocked: [],
    },
    stubEnv: {
      STUB_LOG_DIR: wd,
      STUB_HOVER_RESULT: "1",
    },
  });
  const hoverReq = {
    jsonrpc: "2.0",
    id: 1,
    method: "textDocument/hover",
    params: { textDocument: { uri: "file:///x.yml" }, position: { line: 0, character: 0 } },
  };
  const sentBytes = frameOf(hoverReq);
  proxy.child.stdin.write(sentBytes);

  // Wait for response frame on proxy stdout.
  await waitFor(() => {
    const frames = parseFrames(proxy.stdoutBuf());
    return frames.some((f) => f.body.id === 1);
  });

  const frames = parseFrames(proxy.stdoutBuf());
  const resp = frames.find((f) => f.body.id === 1);
  assert(resp, "expected response with id=1");
  assert(resp.body.result && resp.body.result.contents === "hover-result",
    `unexpected response body: ${JSON.stringify(resp.body)}`);

  // Stub received the hover request byte-identical.
  const stubReceived = fs.readFileSync(path.join(wd, "recv.log"));
  assert(stubReceived.equals(sentBytes),
    `stub received bytes differ from sent: got ${stubReceived.toString("utf8")}, sent ${sentBytes.toString("utf8")}`);

  proxy.child.stdin.end();
  await proxy.exited;
}

async function blockedRequest() {
  const wd = newWorkdir("blocked-req");
  const proxy = spawnProxy({
    config: {
      server: ["node", STUB],
      blocked: ["textDocument/references"],
    },
    stubEnv: { STUB_LOG_DIR: wd },
  });
  const req = {
    jsonrpc: "2.0",
    id: 42,
    method: "textDocument/references",
    params: { textDocument: { uri: "file:///x" }, position: { line: 0, character: 0 } },
  };
  proxy.child.stdin.write(frameOf(req));

  await waitFor(() => {
    const frames = parseFrames(proxy.stdoutBuf());
    return frames.some((f) => f.body.id === 42);
  });

  const frames = parseFrames(proxy.stdoutBuf());
  const resp = frames.find((f) => f.body.id === 42);
  assert(resp, "expected synthesized response for blocked request");
  assert(resp.body.jsonrpc === "2.0", "missing jsonrpc field");
  assert(resp.body.result === null, `expected result:null, got ${JSON.stringify(resp.body.result)}`);
  assert(resp.contentLength === Buffer.from(JSON.stringify(resp.body)).length,
    "Content-Length mismatch");

  // Stub must NOT have received the blocked request.
  const recvLog = path.join(wd, "recv.log");
  const stubReceived = fs.existsSync(recvLog)
    ? fs.readFileSync(recvLog, "utf8")
    : "";
  assert(!stubReceived.includes("textDocument/references"),
    "stub received the blocked request");

  proxy.child.stdin.end();
  await proxy.exited;
}

async function blockedNotification() {
  const wd = newWorkdir("blocked-notif");
  const proxy = spawnProxy({
    config: {
      server: ["node", STUB],
      blocked: ["textDocument/references"],
    },
    stubEnv: { STUB_LOG_DIR: wd },
  });
  const notif = {
    jsonrpc: "2.0",
    method: "textDocument/references",
    params: { uri: "file:///x" },
  };
  proxy.child.stdin.write(frameOf(notif));

  // After a brief pause, the stub must not have received anything.
  await sleep(200);
  const stubFile = path.join(wd, "recv.log");
  const stubReceived = fs.existsSync(stubFile)
    ? fs.readFileSync(stubFile, "utf8")
    : "";
  assert(!stubReceived.includes("textDocument/references"),
    "stub received the blocked notification");

  // And proxy must not have written any response (since notifications have no id).
  const out = proxy.stdoutBuf();
  assert(out.length === 0,
    `proxy wrote unexpected bytes to client: ${out.toString("utf8")}`);

  proxy.child.stdin.end();
  await proxy.exited;
}

async function autoAckMethod(method) {
  const wd = newWorkdir(`auto-ack-${method.replace(/\//g, "-")}`);
  const serverReq = {
    jsonrpc: "2.0",
    id: 99,
    method,
    params: {},
  };
  const proxy = spawnProxy({
    config: { server: ["node", STUB], blocked: [] },
    stubEnv: {
      STUB_LOG_DIR: wd,
      STUB_EMIT: JSON.stringify([serverReq]),
    },
  });

  // Wait for the stub's recv.jsonl to contain the ack from the proxy.
  await waitFor(() => {
    const msgs = readJsonLines(path.join(wd, "recv.jsonl"));
    return msgs.some((m) => m.id === 99 && m.result === null);
  });

  // Proxy must NOT have forwarded the server request to the client.
  await sleep(150);
  const clientFrames = parseFrames(proxy.stdoutBuf());
  assert(!clientFrames.some((f) => f.body.id === 99 && f.body.method === method),
    `client unexpectedly received server-initiated ${method}`);

  proxy.child.stdin.end();
  await proxy.exited;
}

async function splitBuffer() {
  // Send a hover request one byte at a time; stub responds one byte at a time.
  const wd = newWorkdir("split");
  const proxy = spawnProxy({
    config: { server: ["node", STUB], blocked: [] },
    stubEnv: {
      STUB_LOG_DIR: wd,
      STUB_HOVER_RESULT: "1",
      STUB_RESPONSE_CHUNKED: "1",
    },
  });

  const hover = {
    jsonrpc: "2.0",
    id: 7,
    method: "textDocument/hover",
    params: { textDocument: { uri: "file:///x.yml" }, position: { line: 0, character: 0 } },
  };
  const buf = frameOf(hover);
  for (let i = 0; i < buf.length; i++) {
    proxy.child.stdin.write(Buffer.from([buf[i]]));
    await new Promise((r) => setImmediate(r));
  }

  await waitFor(() => {
    const frames = parseFrames(proxy.stdoutBuf());
    return frames.some((f) => f.body.id === 7);
  }, { timeout: 6000 });

  // Stub received the full request.
  const stubMsgs = readJsonLines(path.join(wd, "recv.jsonl"));
  assert(stubMsgs.some((m) => m.id === 7 && m.method === "textDocument/hover"),
    "stub did not reconstruct hover request from byte-split input");

  const frames = parseFrames(proxy.stdoutBuf());
  const resp = frames.find((f) => f.body.id === 7);
  assert(resp && resp.body.result.contents === "hover-result",
    "client did not reconstruct hover response from byte-split server output");

  proxy.child.stdin.end();
  await proxy.exited;
}

async function signalForwarded(sig) {
  const wd = newWorkdir(`signal-${sig.toLowerCase()}`);
  const sigLog = path.join(wd, "signals.log");
  const proxy = spawnProxy({
    config: { server: ["node", STUB], blocked: [] },
    stubEnv: { STUB_SIGNAL_LOG: sigLog },
  });

  // Give the child time to install signal handlers.
  await sleep(200);
  proxy.child.kill(sig);
  await proxy.exited;

  assert(fs.existsSync(sigLog), `stub did not record any signal (${sig})`);
  const recorded = fs.readFileSync(sigLog, "utf8");
  assert(recorded.includes(sig), `stub did not record ${sig}; got: ${recorded}`);
}

async function childExitCodePropagated() {
  const wd = newWorkdir("exit-code");
  const proxy = spawnProxy({
    config: { server: ["node", STUB], blocked: [] },
    stubEnv: {
      STUB_LOG_DIR: wd,
      STUB_EXIT_ON_METHOD: "$/please-exit",
      STUB_EXIT_CODE: "42",
    },
  });
  proxy.child.stdin.write(frameOf({ jsonrpc: "2.0", method: "$/please-exit", params: {} }));
  const result = await proxy.exited;
  assert(result.code === 42,
    `expected proxy exit code 42, got code=${result.code} signal=${result.signal}`);
}

async function stdinEofTerminatesChild() {
  const wd = newWorkdir("stdin-eof");
  const sigLog = path.join(wd, "signals.log");
  const proxy = spawnProxy({
    config: { server: ["node", STUB], blocked: [] },
    stubEnv: { STUB_SIGNAL_LOG: sigLog },
  });

  await sleep(200);
  proxy.child.stdin.end();
  await proxy.exited;

  assert(fs.existsSync(sigLog),
    "stub did not record any signal on proxy stdin EOF");
  const recorded = fs.readFileSync(sigLog, "utf8");
  assert(recorded.includes("SIGTERM"),
    `expected SIGTERM after stdin EOF; got: ${recorded}`);
}

async function configMissing() {
  const child = spawn(process.execPath, [ANSIBLE_PROXY], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  const stderrChunks = [];
  child.stderr.on("data", (b) => stderrChunks.push(b));
  const result = await new Promise((resolve) => {
    child.on("exit", (code) => resolve(code));
  });
  assert(result !== 0, `expected non-zero exit; got ${result}`);
  const err = Buffer.concat(stderrChunks).toString("utf8");
  assert(/Usage|--config/i.test(err), `expected usage message; got: ${err}`);
}

async function configUnreadable() {
  const child = spawn(process.execPath, [ANSIBLE_PROXY, "--config", "/no/such/file.json"], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  const stderrChunks = [];
  child.stderr.on("data", (b) => stderrChunks.push(b));
  const result = await new Promise((resolve) => {
    child.on("exit", (code) => resolve(code));
  });
  assert(result !== 0, `expected non-zero exit; got ${result}`);
  const err = Buffer.concat(stderrChunks).toString("utf8");
  assert(/Failed to read config/i.test(err), `expected read-failure message; got: ${err}`);
}

async function configEmptyServer() {
  const wd = newWorkdir("empty-server");
  const cfg = path.join(wd, "proxy.json");
  fs.writeFileSync(cfg, JSON.stringify({ server: [], blocked: [] }));
  const child = spawn(process.execPath, [ANSIBLE_PROXY, "--config", cfg], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  const stderrChunks = [];
  child.stderr.on("data", (b) => stderrChunks.push(b));
  const result = await new Promise((resolve) => {
    child.on("exit", (code) => resolve(code));
  });
  assert(result !== 0, `expected non-zero exit; got ${result}`);
  const err = Buffer.concat(stderrChunks).toString("utf8");
  assert(/non-empty array/i.test(err), `expected non-empty-array message; got: ${err}`);
}

// ============================================================================
// Dispatch
// ============================================================================

const SCENARIOS = {
  "passthrough": passthrough,
  "blocked-request": blockedRequest,
  "blocked-notification": blockedNotification,
  "auto-ack-register": () => autoAckMethod("client/registerCapability"),
  "auto-ack-unregister": () => autoAckMethod("client/unregisterCapability"),
  "auto-ack-configuration": () => autoAckMethod("workspace/configuration"),
  "auto-ack-workdone": () => autoAckMethod("window/workDoneProgress/create"),
  "split-buffer": splitBuffer,
  "sigterm": () => signalForwarded("SIGTERM"),
  "sigint": () => signalForwarded("SIGINT"),
  "exit-code-propagated": childExitCodePropagated,
  "stdin-eof": stdinEofTerminatesChild,
  "config-missing": configMissing,
  "config-unreadable": configUnreadable,
  "config-empty-server": configEmptyServer,
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
