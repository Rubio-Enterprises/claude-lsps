"use strict";

const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");

const HEADER_DELIM = Buffer.from("\r\n\r\n");
const CL_RE = /^content-length:\s*(\d+)\s*$/im;

function requireEnv() {
  const ROOT_DIR = process.env.ROOT_DIR;
  const TMP_DIR = process.env.TMP_DIR;
  const TESTS_DIR = process.env.TESTS_DIR;
  if (!ROOT_DIR || !TMP_DIR || !TESTS_DIR) {
    console.error("ROOT_DIR/TMP_DIR/TESTS_DIR must be exported");
    process.exit(2);
  }
  return { ROOT_DIR, TMP_DIR, TESTS_DIR };
}

function frameOf(obj) {
  const body = Buffer.from(JSON.stringify(obj));
  return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]);
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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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

function newWorkdir(rootTmp, tag) {
  const parent = path.join(rootTmp, "wd");
  fs.mkdirSync(parent, { recursive: true });
  return fs.mkdtempSync(path.join(parent, `${tag}-`));
}

function readJsonLines(file) {
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, "utf8")
    .split("\n")
    .filter(Boolean)
    .map(JSON.parse);
}

function assert(cond, msg) {
  if (!cond) throw new Error(`assertion failed: ${msg}`);
}

function spawnProxy({ proxyJs, config, configPath, stubEnv = {} }) {
  let cfg = configPath;
  if (!cfg) {
    cfg = path.join(fs.mkdtempSync(path.join(process.env.TMP_DIR, "cfg-")), "proxy.json");
  }
  if (config !== undefined) fs.writeFileSync(cfg, JSON.stringify(config));

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

// Run each scenario and exit with non-zero on the first failure. Always kill
// the spawned proxy if it's still running so a hung waitFor doesn't orphan a
// child process.
function dispatch(scenarios, name) {
  if (!name || !scenarios[name]) {
    console.error(`unknown scenario: ${name}`);
    console.error("available:", Object.keys(scenarios).join(", "));
    process.exit(2);
  }
  let activeProxy = null;
  const setProxy = (p) => { activeProxy = p; };
  (async () => {
    try {
      await scenarios[name](setProxy);
      process.exit(0);
    } catch (err) {
      console.error(err && err.stack ? err.stack : String(err));
      process.exit(1);
    } finally {
      if (activeProxy && activeProxy.child && !activeProxy.child.killed) {
        try { activeProxy.child.kill("SIGKILL"); } catch {}
      }
    }
  })();
}

module.exports = {
  HEADER_DELIM,
  CL_RE,
  requireEnv,
  frameOf,
  parseFrames,
  sleep,
  waitFor,
  newWorkdir,
  readJsonLines,
  assert,
  spawnProxy,
  dispatch,
};
