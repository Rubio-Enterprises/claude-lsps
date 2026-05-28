#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");

const { requireEnv, newWorkdir, dispatch } = require("./lsp-test-utils.js");
const { LspClient, parseLspJson, wireLanguageIdFor } = require("./lsp-client.js");

const { ROOT_DIR, TMP_DIR, TESTS_DIR } = requireEnv();
const FIXTURES = path.join(TESTS_DIR, "fixtures");

// Copy a curated subset of a fixture directory into a fresh workdir, so each
// scenario gets an isolated workspace. We never use tests/fixtures/ as the
// workspace root — LSPs write caches and walk parents, which would pollute the
// repo or leak between scenarios.
function prepWorkdir(tag, srcDir, includes) {
  const dir = newWorkdir(TMP_DIR, tag);
  for (const name of includes) {
    fs.cpSync(path.join(srcDir, name), path.join(dir, name), { recursive: true });
  }
  return dir;
}

// Standard "open one file, expect N diagnostics" scenario.
// `viaWarmup: true` skips the explicit didOpen — used for proxied plugins
// where the proxy's warmup walk already sends didOpen for matching files.
// Per LSP spec, didOpen for an already-open URI is undefined behavior;
// Regal in particular drops the diagnostics from the warmup pass when this
// happens.
async function runStandard(spec, setProxy) {
  const {
    pluginName, fixturesSubdir, includes, primaryFile,
    expectZero, expectMatch, scenarioTag, extraEnv,
    diagMode, diagTimeoutMs, diagQuietMs, viaWarmup, requirePublish,
  } = spec;

  const dir = prepWorkdir(scenarioTag, path.join(FIXTURES, fixturesSubdir), includes);
  const fileUri = pathToFileURL(path.join(dir, primaryFile)).href;
  const rootUri = pathToFileURL(dir).href;

  const pluginDir = path.join(ROOT_DIR, pluginName);
  const parsed = parseLspJson(pluginDir);
  const client = new LspClient({
    command: parsed.command, args: parsed.args, cwd: dir, env: extraEnv || {},
  });
  await client.start();
  setProxy(client);  // dispatch() reads .child for SIGTERM-with-grace cleanup

  let diags = [];
  let aliveAfterWait = false;
  let stderrSnapshot = "";
  try {
    await client.initialize({ rootUri });
    if (!viaWarmup) {
      const text = fs.readFileSync(path.join(dir, primaryFile), "utf8");
      client.didOpen({ uri: fileUri, languageId: wireLanguageIdFor(parsed, primaryFile), text });
    }
    diags = await client.waitForDiagnostics({
      uri: fileUri,
      mode: diagMode || "auto",
      timeout: diagTimeoutMs,
      quietMs: diagQuietMs,
      requirePublish: requirePublish !== false,
    });
    aliveAfterWait = client.isAlive();
    stderrSnapshot = client.stderr();
  } finally {
    try { await client.shutdown(); } catch {}
  }

  // Servers that never publish for clean files (cue lsp, vtsls/tsserver) use
  // requirePublish: false, so a silent crash would otherwise sail through the
  // expectZero check as "0 diagnostics". Assert the server actually survived
  // the analysis window to keep the no-publish path honest.
  if (requirePublish === false && !aliveAfterWait) {
    throw new Error(
      `server exited before the diagnostics window elapsed (crash?)` +
      (stderrSnapshot ? `\n--- server stderr ---\n${stderrSnapshot.slice(-1500)}` : "")
    );
  }

  if (expectZero) {
    if (diags.length !== 0) {
      throw new Error(
        `expected 0 diagnostics, got ${diags.length}:\n` +
        diags.slice(0, 5).map((d) => `  - ${d.message}`).join("\n") +
        (stderrSnapshot ? `\n--- server stderr ---\n${stderrSnapshot.slice(-1500)}` : "")
      );
    }
  }
  if (expectMatch) {
    if (diags.length === 0) {
      throw new Error(
        `expected ≥1 diagnostic matching ${expectMatch}, got 0` +
        (stderrSnapshot ? `\n--- server stderr ---\n${stderrSnapshot.slice(-1500)}` : "")
      );
    }
    const messages = diags.map((d) => d.message || "").join(" | ");
    if (!expectMatch.test(messages)) {
      throw new Error(
        `expected diagnostic to match ${expectMatch}, got:\n` +
        diags.slice(0, 5).map((d) => `  - ${d.message}`).join("\n")
      );
    }
  }
}

// -- Scenarios ---------------------------------------------------------------

const scenarios = {
  // bash-language-server uses tree-sitter + shellcheck. Syntax errors are
  // surfaced via push diagnostics.
  "bash-clean": (sp) => runStandard({
    pluginName: "bash-language-server",
    fixturesSubdir: "bash",
    includes: ["clean.sh"],
    primaryFile: "clean.sh",
    expectZero: true,
    scenarioTag: "bash-clean",
  }, sp),
  "bash-broken": (sp) => runStandard({
    pluginName: "bash-language-server",
    fixturesSubdir: "bash",
    includes: ["broken.sh"],
    primaryFile: "broken.sh",
    expectMatch: /syntax|expected|parse|unexpected/i,
    scenarioTag: "bash-broken",
  }, sp),

  // pyright does NOT advertise diagnosticProvider (no pull support); it pushes
  // publishDiagnostics, including an empty array for clean files — so
  // pyright-clean is a real assertion (waits for the empty publish).
  "pyright-clean": (sp) => runStandard({
    pluginName: "pyright",
    fixturesSubdir: "pyright",
    includes: ["clean.py", "pyrightconfig.json"],
    primaryFile: "clean.py",
    expectZero: true,
    scenarioTag: "pyright-clean",
    diagTimeoutMs: 15000,
  }, sp),
  "pyright-broken": (sp) => runStandard({
    pluginName: "pyright",
    fixturesSubdir: "pyright",
    includes: ["broken.py", "pyrightconfig.json"],
    primaryFile: "broken.py",
    expectMatch: /not assignable|incompatible|assignment/i,
    scenarioTag: "pyright-broken",
    diagTimeoutMs: 15000,
  }, sp),

  // vtsls (tsserver) does NOT advertise diagnosticProvider and, unlike pyright,
  // does NOT publish an empty diagnostic set for clean .ts files — it only
  // publishes when a file has diagnostics. So vtsls-clean uses
  // requirePublish: false (no publish is expected) and relies on the
  // runStandard liveness check + the vtsls-broken scenario to prove the server
  // is actually analyzing. Needs tsconfig.json for the project to load.
  "vtsls-clean": (sp) => runStandard({
    pluginName: "vtsls",
    fixturesSubdir: "vtsls",
    includes: ["clean.ts", "tsconfig.json"],
    primaryFile: "clean.ts",
    expectZero: true,
    scenarioTag: "vtsls-clean",
    requirePublish: false,
    diagTimeoutMs: 8000,
  }, sp),
  "vtsls-broken": (sp) => runStandard({
    pluginName: "vtsls",
    fixturesSubdir: "vtsls",
    includes: ["broken.ts", "tsconfig.json"],
    primaryFile: "broken.ts",
    expectMatch: /not assignable|Type 'string'/i,
    scenarioTag: "vtsls-broken",
    diagTimeoutMs: 15000,
  }, sp),

  // cue-lsp: validates that `cue lsp serve` spawns, accepts the handshake,
  // accepts didOpen, and doesn't crash. As of cue v0.16.0, `cue lsp serve`
  // does not publish diagnostics (textDocument/diagnostic also unsupported),
  // so we set requirePublish: false to let waitForDiagnostics return [] on
  // timeout without throwing. Re-add a `cue-broken` scenario (and drop the
  // requirePublish override) when upstream gains diagnostic support.
  "cue-clean": (sp) => runStandard({
    pluginName: "cue-lsp",
    fixturesSubdir: "cue",
    includes: ["clean.cue", "cue.mod"],
    primaryFile: "clean.cue",
    expectZero: true,
    scenarioTag: "cue-clean",
    requirePublish: false,
  }, sp),

  // ansible-language-server: through the proxy. Push diagnostics.
  "ansible-clean": (sp) => runStandard({
    pluginName: "ansible-language-server",
    fixturesSubdir: "ansible",
    includes: ["clean.yml", "ansible.cfg"],
    primaryFile: "clean.yml",
    expectZero: true,
    scenarioTag: "ansible-clean",
    extraEnv: { ANSIBLE_NOCOWS: "1" },
    diagTimeoutMs: 15000,
  }, sp),
  // ansible-language-server flags semantic errors only when ansible-lint is
  // installed; without it, the LS still catches raw YAML syntax errors via
  // yaml-language-server integration. broken.yml has an unclosed flow seq.
  "ansible-broken": (sp) => runStandard({
    pluginName: "ansible-language-server",
    fixturesSubdir: "ansible",
    includes: ["broken.yml", "ansible.cfg"],
    primaryFile: "broken.yml",
    expectMatch: /flow|sequence|indent|expected|sufficiently/i,
    scenarioTag: "ansible-broken",
    extraEnv: { ANSIBLE_NOCOWS: "1" },
    diagTimeoutMs: 15000,
  }, sp),

  // regal-lsp: through the proxy. The proxy's warmup walks the workspace and
  // sends didOpen for every .rego file, so we MUST NOT send our own didOpen
  // (would be a spec violation — open-after-open is undefined) — pass
  // viaWarmup: true and let the proxy drive indexing.
  //
  // Regal publishes diagnostics twice on cold start: once before reading
  // .regal/config.yaml (with all default rules firing), then again ~700ms
  // later with the configured rule levels applied. We need a quiet period
  // ≥ that gap so the second publish overwrites the first; 2000ms gives
  // comfortable headroom.
  "regal-clean": (sp) => runStandard({
    pluginName: "regal-lsp",
    fixturesSubdir: "regal",
    includes: ["clean.rego", ".regal"],
    primaryFile: "clean.rego",
    expectZero: true,
    scenarioTag: "regal-clean",
    viaWarmup: true,
    diagMode: "push",
    diagQuietMs: 2000,
    diagTimeoutMs: 12000,
  }, sp),
  "regal-broken": (sp) => runStandard({
    pluginName: "regal-lsp",
    fixturesSubdir: "regal",
    includes: ["broken.rego", ".regal"],
    primaryFile: "broken.rego",
    expectMatch: /prefer.*==|equality|assignment|deprecated/i,
    scenarioTag: "regal-broken",
    viaWarmup: true,
    diagMode: "push",
    diagQuietMs: 2000,
    diagTimeoutMs: 12000,
  }, sp),

  // regal warmup: workspace contains BOTH files, but the client never sends
  // didOpen. If diagnostics arrive for broken.rego, it can only be because the
  // proxy's warmup walked the workspace and sent didOpen on our behalf.
  "regal-warmup": async (setProxy) => {
    const dir = prepWorkdir(
      "regal-warmup",
      path.join(FIXTURES, "regal"),
      ["clean.rego", "broken.rego", ".regal"]
    );
    const brokenUri = pathToFileURL(path.join(dir, "broken.rego")).href;
    const rootUri = pathToFileURL(dir).href;

    const pluginDir = path.join(ROOT_DIR, "regal-lsp");
    const { command, args } = parseLspJson(pluginDir);
    const client = new LspClient({ command, args, cwd: dir });
    await client.start();
    setProxy(client);

    let diags = [];
    let stderrSnapshot = "";
    try {
      await client.initialize({ rootUri });
      // Critical: do NOT call client.didOpen. Warmup must drive indexing.
      diags = await client.waitForDiagnostics({
        uri: brokenUri,
        mode: "push",
        quietMs: 2000,
        timeout: 12000,
      });
      stderrSnapshot = client.stderr();
    } finally {
      try { await client.shutdown(); } catch {}
    }

    if (diags.length === 0) {
      throw new Error(
        "warmup did not produce diagnostics for broken.rego;\n" +
        "proxy stderr (last 1500 chars):\n" + stderrSnapshot.slice(-1500)
      );
    }
    const messages = diags.map((d) => d.message || "").join(" | ");
    if (!/prefer.*==|equality|use-assignment|deprecated/i.test(messages)) {
      throw new Error(
        `warmup produced diagnostics but none matched expected pattern; got:\n` +
        diags.slice(0, 5).map((d) => `  - ${d.message}`).join("\n")
      );
    }
  },
};

dispatch(scenarios, process.argv[2]);
