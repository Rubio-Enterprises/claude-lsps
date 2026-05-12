#!/usr/bin/env node
"use strict";

const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const {
  requireEnv, frameOf, parseFrames, sleep, waitFor, newWorkdir,
  readJsonLines, assert, spawnProxy, dispatch,
} = require("./lsp-test-utils.js");

const { ROOT_DIR, TMP_DIR, TESTS_DIR } = requireEnv();
const ANSIBLE_PROXY = path.join(ROOT_DIR, "ansible-language-server", "lsp-proxy.js");
const STUB = path.join(TESTS_DIR, "helpers", "stub-server.js");

const wd = (tag) => newWorkdir(TMP_DIR, tag);
const proxyConfig = (extra = {}) => ({ server: ["node", STUB], blocked: [], ...extra });

// Round-trip a no-op notification through the proxy: by the time the stub has
// logged it, both processes have finished synchronous setup (including signal
// handler registration in lsp-proxy.js). Replaces brittle fixed sleeps.
async function waitForHandshake(proxy, logDir) {
  const ping = { jsonrpc: "2.0", method: "$/test-ready-ping", params: {} };
  proxy.child.stdin.write(frameOf(ping));
  const log = path.join(logDir, "recv.jsonl");
  await waitFor(() => {
    if (!fs.existsSync(log)) return false;
    return readJsonLines(log).some((m) => m.method === "$/test-ready-ping");
  }, { timeout: 8000 });
}

async function passthrough(setProxy) {
  const dir = wd("passthrough");
  const proxy = spawnProxy({
    proxyJs: ANSIBLE_PROXY,
    config: proxyConfig(),
    stubEnv: { STUB_LOG_DIR: dir, STUB_HOVER_RESULT: "1" },
  });
  setProxy(proxy);

  const hover = {
    jsonrpc: "2.0",
    id: 1,
    method: "textDocument/hover",
    params: { textDocument: { uri: "file:///x.yml" }, position: { line: 0, character: 0 } },
  };
  const sentBytes = frameOf(hover);
  proxy.child.stdin.write(sentBytes);

  await waitFor(() => parseFrames(proxy.stdoutBuf()).some((f) => f.body.id === 1));

  const resp = parseFrames(proxy.stdoutBuf()).find((f) => f.body.id === 1);
  assert(resp, "expected response with id=1");
  assert(resp.body.result && resp.body.result.contents === "hover-result",
    `unexpected response body: ${JSON.stringify(resp.body)}`);

  const stubReceived = fs.readFileSync(path.join(dir, "recv.log"));
  assert(stubReceived.equals(sentBytes),
    `stub bytes differ from client bytes; got ${stubReceived.length}B, sent ${sentBytes.length}B`);

  proxy.child.stdin.end();
  await proxy.exited;
}

async function blockedRequest(setProxy) {
  const dir = wd("blocked-req");
  const proxy = spawnProxy({
    proxyJs: ANSIBLE_PROXY,
    config: proxyConfig({ blocked: ["textDocument/references"] }),
    stubEnv: { STUB_LOG_DIR: dir },
  });
  setProxy(proxy);

  const req = {
    jsonrpc: "2.0",
    id: 42,
    method: "textDocument/references",
    params: { textDocument: { uri: "file:///x" }, position: { line: 0, character: 0 } },
  };
  proxy.child.stdin.write(frameOf(req));

  await waitFor(() => parseFrames(proxy.stdoutBuf()).some((f) => f.body.id === 42));

  const resp = parseFrames(proxy.stdoutBuf()).find((f) => f.body.id === 42);
  assert(resp, "expected synthesized response for blocked request");
  assert(resp.body.jsonrpc === "2.0", "missing jsonrpc field");
  assert(resp.body.result === null, `expected result:null, got ${JSON.stringify(resp.body.result)}`);
  assert(resp.contentLength === Buffer.from(JSON.stringify(resp.body)).length,
    "Content-Length mismatch");

  const recvLog = path.join(dir, "recv.log");
  const stubReceived = fs.existsSync(recvLog) ? fs.readFileSync(recvLog, "utf8") : "";
  assert(!stubReceived.includes("textDocument/references"),
    "stub received the blocked request");

  proxy.child.stdin.end();
  await proxy.exited;
}

async function blockedNotification(setProxy) {
  const dir = wd("blocked-notif");
  const proxy = spawnProxy({
    proxyJs: ANSIBLE_PROXY,
    config: proxyConfig({ blocked: ["textDocument/references"] }),
    stubEnv: { STUB_LOG_DIR: dir },
  });
  setProxy(proxy);

  proxy.child.stdin.write(frameOf({
    jsonrpc: "2.0",
    method: "textDocument/references",
    params: { uri: "file:///x" },
  }));

  await sleep(200);
  const stubFile = path.join(dir, "recv.log");
  const stubReceived = fs.existsSync(stubFile) ? fs.readFileSync(stubFile, "utf8") : "";
  assert(!stubReceived.includes("textDocument/references"),
    "stub received the blocked notification");

  const out = proxy.stdoutBuf();
  assert(out.length === 0,
    `proxy wrote unexpected bytes to client: ${out.toString("utf8")}`);

  proxy.child.stdin.end();
  await proxy.exited;
}

async function autoAckMethod(method, setProxy) {
  const dir = wd(`auto-ack-${method.replace(/\//g, "-")}`);
  const serverReq = { jsonrpc: "2.0", id: 99, method, params: {} };
  const proxy = spawnProxy({
    proxyJs: ANSIBLE_PROXY,
    config: proxyConfig(),
    stubEnv: { STUB_LOG_DIR: dir, STUB_EMIT: JSON.stringify([serverReq]) },
  });
  setProxy(proxy);

  await waitFor(() => readJsonLines(path.join(dir, "recv.jsonl"))
    .some((m) => m.id === 99 && m.result === null));

  await sleep(150);
  const clientFrames = parseFrames(proxy.stdoutBuf());
  assert(!clientFrames.some((f) => f.body.id === 99 && f.body.method === method),
    `client unexpectedly received server-initiated ${method}`);

  proxy.child.stdin.end();
  await proxy.exited;
}

async function splitBuffer(setProxy) {
  const dir = wd("split");
  const proxy = spawnProxy({
    proxyJs: ANSIBLE_PROXY,
    config: proxyConfig(),
    stubEnv: { STUB_LOG_DIR: dir, STUB_HOVER_RESULT: "1", STUB_RESPONSE_CHUNKED: "1" },
  });
  setProxy(proxy);

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

  await waitFor(() => parseFrames(proxy.stdoutBuf()).some((f) => f.body.id === 7),
    { timeout: 6000 });

  const stubMsgs = readJsonLines(path.join(dir, "recv.jsonl"));
  assert(stubMsgs.some((m) => m.id === 7 && m.method === "textDocument/hover"),
    "stub did not reconstruct hover request from byte-split input");

  const resp = parseFrames(proxy.stdoutBuf()).find((f) => f.body.id === 7);
  assert(resp && resp.body.result.contents === "hover-result",
    "client did not reconstruct hover response from byte-split server output");

  proxy.child.stdin.end();
  await proxy.exited;
}

async function malformedHeaderForwarded(setProxy) {
  const dir = wd("malformed-header");
  const proxy = spawnProxy({
    proxyJs: ANSIBLE_PROXY,
    config: proxyConfig(),
    stubEnv: { STUB_LOG_DIR: dir },
  });
  setProxy(proxy);

  const bytes = Buffer.from("X-Header: foo\r\n\r\nopaque-body-bytes");
  proxy.child.stdin.write(bytes);
  await waitFor(() => {
    const f = path.join(dir, "recv.log");
    return fs.existsSync(f) && fs.statSync(f).size >= bytes.length;
  });
  const received = fs.readFileSync(path.join(dir, "recv.log"));
  assert(received.equals(bytes),
    `stub did not receive malformed bytes verbatim; got ${received.length}B, sent ${bytes.length}B`);
  proxy.child.stdin.end();
  await proxy.exited;
}

async function unparseableBodyForwarded(setProxy) {
  const dir = wd("unparseable-body");
  const proxy = spawnProxy({
    proxyJs: ANSIBLE_PROXY,
    config: proxyConfig({ blocked: ["textDocument/references"] }),
    stubEnv: { STUB_LOG_DIR: dir },
  });
  setProxy(proxy);

  const body = Buffer.from("{not-json");
  const wire = Buffer.concat([
    Buffer.from(`Content-Length: ${body.length}\r\n\r\n`),
    body,
  ]);
  proxy.child.stdin.write(wire);
  await waitFor(() => {
    const f = path.join(dir, "recv.log");
    return fs.existsSync(f) && fs.statSync(f).size >= wire.length;
  });
  const received = fs.readFileSync(path.join(dir, "recv.log"));
  assert(received.equals(wire),
    `stub did not receive raw frame; got ${received.length}B, sent ${wire.length}B`);
  proxy.child.stdin.end();
  await proxy.exited;
}

async function serverToClientByteIdentical(setProxy) {
  const notif = {
    jsonrpc: "2.0",
    method: "window/showMessage",
    params: { type: 3, message: "hello-from-server" },
  };
  const body = Buffer.from(JSON.stringify(notif));
  const expected = Buffer.concat([
    Buffer.from(`Content-Length: ${body.length}\r\n\r\n`),
    body,
  ]);
  const proxy = spawnProxy({
    proxyJs: ANSIBLE_PROXY,
    config: proxyConfig(),
    stubEnv: { STUB_EMIT: JSON.stringify([notif]) },
  });
  setProxy(proxy);

  await waitFor(() => proxy.stdoutBuf().length >= expected.length);
  await sleep(80);
  const got = proxy.stdoutBuf();
  assert(got.equals(expected),
    `server->client bytes differ; got ${got.length}B '${got.toString("utf8")}', expected '${expected.toString("utf8")}'`);
  proxy.child.stdin.end();
  await proxy.exited;
}

async function signalForwarded(sig, setProxy) {
  const dir = wd(`signal-${sig.toLowerCase()}`);
  const sigLog = path.join(dir, "signals.log");
  const proxy = spawnProxy({
    proxyJs: ANSIBLE_PROXY,
    config: proxyConfig(),
    stubEnv: { STUB_LOG_DIR: dir, STUB_SIGNAL_LOG: sigLog },
  });
  setProxy(proxy);

  await waitForHandshake(proxy, dir);
  proxy.child.kill(sig);
  await proxy.exited;

  assert(fs.existsSync(sigLog), `stub did not record any signal (${sig})`);
  const recorded = fs.readFileSync(sigLog, "utf8");
  assert(recorded.includes(sig), `stub did not record ${sig}; got: ${recorded}`);
}

async function childExitCodePropagated(setProxy) {
  const proxy = spawnProxy({
    proxyJs: ANSIBLE_PROXY,
    config: proxyConfig(),
    stubEnv: { STUB_EXIT_ON_METHOD: "$/please-exit", STUB_EXIT_CODE: "42" },
  });
  setProxy(proxy);
  proxy.child.stdin.write(frameOf({ jsonrpc: "2.0", method: "$/please-exit", params: {} }));
  const result = await proxy.exited;
  assert(result.code === 42,
    `expected proxy exit code 42, got code=${result.code} signal=${result.signal}`);
}

async function stdinEofTerminatesChild(setProxy) {
  const dir = wd("stdin-eof");
  const sigLog = path.join(dir, "signals.log");
  const proxy = spawnProxy({
    proxyJs: ANSIBLE_PROXY,
    config: proxyConfig(),
    stubEnv: { STUB_LOG_DIR: dir, STUB_SIGNAL_LOG: sigLog },
  });
  setProxy(proxy);

  await waitForHandshake(proxy, dir);
  proxy.child.stdin.end();
  await proxy.exited;

  assert(fs.existsSync(sigLog), "stub did not record any signal on proxy stdin EOF");
  const recorded = fs.readFileSync(sigLog, "utf8");
  assert(recorded.includes("SIGTERM"), `expected SIGTERM after stdin EOF; got: ${recorded}`);
}

async function runProxyExpectFailure(args, { stdin = "ignore" } = {}) {
  const child = spawn(process.execPath, args, { stdio: [stdin, "pipe", "pipe"] });
  const stderrChunks = [];
  child.stderr.on("data", (b) => stderrChunks.push(b));
  const code = await new Promise((resolve) => child.on("exit", resolve));
  return { code, stderr: Buffer.concat(stderrChunks).toString("utf8") };
}

async function configMissing() {
  const { code, stderr } = await runProxyExpectFailure([ANSIBLE_PROXY]);
  assert(code !== 0, `expected non-zero exit; got ${code}`);
  assert(/Usage:/.test(stderr) && /--config/.test(stderr),
    `expected 'Usage:' with --config in stderr; got: ${stderr}`);
}

async function configUnreadable() {
  const { code, stderr } = await runProxyExpectFailure(
    [ANSIBLE_PROXY, "--config", "/no/such/file.json"]
  );
  assert(code !== 0, `expected non-zero exit; got ${code}`);
  assert(/Failed to read config/i.test(stderr),
    `expected read-failure message; got: ${stderr}`);
}

async function configEmptyServer() {
  const dir = wd("empty-server");
  const cfg = path.join(dir, "proxy.json");
  fs.writeFileSync(cfg, JSON.stringify({ server: [], blocked: [] }));
  const { code, stderr } = await runProxyExpectFailure([ANSIBLE_PROXY, "--config", cfg]);
  assert(code !== 0, `expected non-zero exit; got ${code}`);
  assert(/non-empty array/i.test(stderr),
    `expected non-empty-array message; got: ${stderr}`);
}

async function childSpawnError() {
  const dir = wd("spawn-error");
  const cfg = path.join(dir, "proxy.json");
  fs.writeFileSync(cfg, JSON.stringify({
    server: ["/no/such/binary/__definitely_not_there__", "--stdio"],
    blocked: [],
  }));
  const { code, stderr } = await runProxyExpectFailure(
    [ANSIBLE_PROXY, "--config", cfg], { stdin: "pipe" }
  );
  assert(code !== 0, `expected non-zero exit on spawn ENOENT; got ${code}`);
  assert(/child error/i.test(stderr) || /ENOENT/.test(stderr),
    `expected child-error message in stderr; got: ${stderr}`);
}

const SCENARIOS = {
  "passthrough": passthrough,
  "passthrough-server-to-client": serverToClientByteIdentical,
  "blocked-request": blockedRequest,
  "blocked-notification": blockedNotification,
  "auto-ack-register": (setProxy) => autoAckMethod("client/registerCapability", setProxy),
  "auto-ack-unregister": (setProxy) => autoAckMethod("client/unregisterCapability", setProxy),
  "auto-ack-configuration": (setProxy) => autoAckMethod("workspace/configuration", setProxy),
  "auto-ack-workdone": (setProxy) => autoAckMethod("window/workDoneProgress/create", setProxy),
  "split-buffer": splitBuffer,
  "malformed-header-forwarded": malformedHeaderForwarded,
  "unparseable-body-forwarded": unparseableBodyForwarded,
  "sigterm": (setProxy) => signalForwarded("SIGTERM", setProxy),
  "sigint": (setProxy) => signalForwarded("SIGINT", setProxy),
  "exit-code-propagated": childExitCodePropagated,
  "stdin-eof": stdinEofTerminatesChild,
  "config-missing": configMissing,
  "config-unreadable": configUnreadable,
  "config-empty-server": configEmptyServer,
  "child-spawn-error": childSpawnError,
};

dispatch(SCENARIOS, process.argv[2]);
