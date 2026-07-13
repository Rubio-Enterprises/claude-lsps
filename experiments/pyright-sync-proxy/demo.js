#!/usr/bin/env node
// Self-verifying A/B demonstration of the pyright sync proxy.
//
//   CONTROL   direct pyright: open a broken file, fix it ON DISK without sending
//             didChange -> pyright keeps reporting the stale error (the bug).
//   TREATMENT pyright behind lsp-proxy.js: same disk-only fix -> the proxy
//             injects a didChange and pyright re-publishes an empty set (fixed).
//
// Exits non-zero if either expectation fails, so it doubles as a regression
// check. Requires pyright-langserver on PATH. Run: node demo.js
//
// Node stdlib only; reuses the repo's test LspClient for the wire handshake.

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { pathToFileURL } = require("url");

const { LspClient } = require("../../tests/helpers/lsp-client.js");

const PROXY_JS = path.join(__dirname, "lsp-proxy.js");
const PROXY_JSON = path.join(__dirname, "proxy.json");
const BROKEN = 'x: int = "not an int"\nprint(x)\n';
const FIXED = "x: int = 5\nprint(x)\n";
const PYRIGHTCONFIG = JSON.stringify(
  { include: ["."], pythonVersion: "3.11", reportGeneralTypeIssues: "error" },
  null, 2,
);

function makeWorkdir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pyright-sync-demo-"));
  fs.writeFileSync(path.join(dir, "broken.py"), BROKEN);
  fs.writeFileSync(path.join(dir, "pyrightconfig.json"), PYRIGHTCONFIG);
  return dir;
}

// Open broken.py, wait for the error, then rewrite the file to the fixed
// content ON DISK only (no didChange from the client) — exactly what Claude
// Code's Edit tool does. `command`/`args` select direct pyright vs. the proxy.
async function run({ label, command, args }) {
  const dir = makeWorkdir();
  const fileUri = pathToFileURL(path.join(dir, "broken.py")).href;
  const rootUri = pathToFileURL(dir).href;
  const client = new LspClient({ command, args, cwd: dir });

  const result = { label, opened: null, afterDiskFix: null, refreshMs: null, ok: false };
  await client.start();
  try {
    await client.initialize({ rootUri });

    client.didOpen({ uri: fileUri, languageId: "python", text: BROKEN });
    const errDiags = await client.waitForDiagnostics({ uri: fileUri, mode: "push", timeout: 15000 });
    result.opened = errDiags.map((d) => d.message);
    if (errDiags.length === 0) throw new Error("expected an error on open, got none");

    // The fix: disk write, NO didChange.
    const baseSeq = client.publishSeq(fileUri);
    const changeAt = Date.now();
    fs.writeFileSync(path.join(dir, "broken.py"), FIXED);

    // Wait for a refresh publish; if none comes within the window, pyright
    // stayed stale (the control's expected outcome).
    const refreshed = await client.waitForPublish({ uri: fileUri, afterSeq: baseSeq, timeout: 4000 });
    if (refreshed) {
      result.afterDiskFix = refreshed.diagnostics.map((d) => d.message);
      result.refreshMs = refreshed.at - changeAt;
    } else {
      result.afterDiskFix = null; // no new publish — diagnostics frozen at the error
    }
  } finally {
    try { await client.shutdown(); } catch {}
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch {}
  }
  return result;
}

async function main() {
  const control = await run({
    label: "CONTROL   (direct pyright)",
    command: "pyright-langserver",
    args: ["--stdio"],
  });
  const treatment = await run({
    label: "TREATMENT (sync proxy)",
    command: "node",
    args: [PROXY_JS, "--config", PROXY_JSON],
  });

  const line = (r) => {
    const err = r.opened.length;
    if (r.afterDiskFix === null) return `${r.label}: opened→${err} error(s); after disk fix → NO re-publish (stale)`;
    const n = r.afterDiskFix.length;
    return `${r.label}: opened→${err} error(s); after disk fix → ${n} diag(s)` +
      (n === 0 ? ` CLEARED in ${r.refreshMs}ms` : " (still present)");
  };

  console.log("");
  console.log(line(control));
  console.log(line(treatment));
  console.log("");

  // Expectations: control stays stale (no re-publish), treatment clears.
  const controlStale = control.afterDiskFix === null;
  const treatmentFixed = Array.isArray(treatment.afterDiskFix) && treatment.afterDiskFix.length === 0;

  const problems = [];
  if (!controlStale) problems.push("control unexpectedly refreshed (pyright watched disk on its own?)");
  if (!treatmentFixed) problems.push("treatment did NOT clear the error via the proxy");

  if (problems.length) {
    console.log("DEMO FAILED:");
    for (const p of problems) console.log(`  - ${p}`);
    process.exit(1);
  }
  console.log("DEMO PASSED — the proxy refreshes pyright on a disk-only edit; direct pyright does not.");
  process.exit(0);
}

main().catch((e) => {
  console.error(e && e.stack ? e.stack : String(e));
  process.exit(1);
});
