#!/usr/bin/env node
// Coverage gate. Reads V8 coverage produced by NODE_V8_COVERAGE during the
// test run, computes per-file line coverage for the two lsp-proxy.js files,
// and exits non-zero if any file is below the threshold (default 80%).
//
// Usage: node coverage-check.js [--threshold=80]

"use strict";

const fs = require("fs");
const path = require("path");

const ROOT_DIR = process.env.ROOT_DIR;
const COV_DIR = process.env.NODE_V8_COVERAGE;
if (!ROOT_DIR || !COV_DIR) {
  console.error("ROOT_DIR and NODE_V8_COVERAGE must be set");
  process.exit(2);
}

const TARGETS = [
  path.join(ROOT_DIR, "ansible-language-server", "lsp-proxy.js"),
  path.join(ROOT_DIR, "regal-lsp", "lsp-proxy.js"),
];

let threshold = 80;
for (const arg of process.argv.slice(2)) {
  const m = /^--threshold=(\d+(?:\.\d+)?)$/.exec(arg);
  if (m) threshold = parseFloat(m[1]);
}

function loadCoverageFiles() {
  if (!fs.existsSync(COV_DIR)) return [];
  return fs.readdirSync(COV_DIR)
    .filter((f) => f.endsWith(".json"))
    .map((f) => {
      try {
        return JSON.parse(fs.readFileSync(path.join(COV_DIR, f), "utf8"));
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

function urlToPath(url) {
  if (url.startsWith("file://")) {
    return decodeURI(url.slice(7));
  }
  return url;
}

// Compute per-file coverage: bytes/lines covered vs uncovered. The V8 model
// is range-based; we mark each byte's state by walking ranges in order
// (outer ranges first, inner ranges override).
function computeCoverage(sourcePath, entries) {
  const source = fs.readFileSync(sourcePath, "utf8");
  const len = source.length;
  // Final state per byte: 0 = no instrumentation, 1 = covered, 2 = uncovered.
  // Covered-wins across V8 coverage entries from different subprocesses, but
  // within a single entry inner ranges must override their enclosing range
  // (an outer function might be called once while an inner branch never runs).
  const state = new Uint8Array(len);

  for (const entry of entries) {
    const local = new Uint8Array(len);
    for (const fn of entry.functions || []) {
      // V8 emits ranges from outermost to innermost, so applying them in order
      // lets the inner ranges override their parents within this entry.
      for (const r of fn.ranges) {
        const mark = r.count > 0 ? 1 : 2;
        const start = Math.max(0, r.startOffset | 0);
        const end = Math.min(len, r.endOffset | 0);
        for (let i = start; i < end; i++) local[i] = mark;
      }
    }
    // Merge into the global state: covered always wins.
    for (let i = 0; i < len; i++) {
      if (local[i] === 1) state[i] = 1;
      else if (local[i] === 2 && state[i] !== 1) state[i] = 2;
    }
  }

  // Walk lines. A line is "covered" if it contains at least one covered byte
  // (state==1). It's "uncovered" if it has uncovered bytes but no covered
  // bytes. Lines with state==0 across all bytes have no instrumentation
  // (typically blank lines, comments, declarations outside any function) and
  // are excluded from the denominator.
  let covered = 0, uncovered = 0, total = 0;
  let i = 0;
  while (i <= len) {
    let end = i;
    while (end < len && source[end] !== "\n") end++;
    let hasCovered = false, hasUncovered = false;
    for (let j = i; j < end; j++) {
      if (state[j] === 1) hasCovered = true;
      else if (state[j] === 2) hasUncovered = true;
    }
    total++;
    if (hasCovered) covered++;
    else if (hasUncovered) uncovered++;
    i = end + 1;
  }
  const denom = covered + uncovered;
  return {
    sourceLines: total,
    coveredLines: covered,
    uncoveredLines: uncovered,
    percent: denom === 0 ? 100 : (covered / denom) * 100,
  };
}

function main() {
  const all = loadCoverageFiles();
  if (all.length === 0) {
    console.error(`no coverage files in ${COV_DIR}`);
    process.exit(1);
  }

  // Group all V8 script-coverage entries by source file.
  const byFile = new Map();
  for (const cov of all) {
    for (const result of cov.result || []) {
      const p = urlToPath(result.url || "");
      if (!byFile.has(p)) byFile.set(p, []);
      byFile.get(p).push(result);
    }
  }

  let pass = true;
  const lines = [];
  for (const target of TARGETS) {
    const entries = byFile.get(target) || [];
    if (entries.length === 0) {
      lines.push(`  ${path.relative(ROOT_DIR, target)}: NO DATA`);
      pass = false;
      continue;
    }
    const { coveredLines, uncoveredLines, percent } = computeCoverage(target, entries);
    const status = percent >= threshold ? "ok" : "FAIL";
    lines.push(
      `  ${path.relative(ROOT_DIR, target)}: ${percent.toFixed(1)}% ` +
      `(${coveredLines} covered / ${coveredLines + uncoveredLines} executable) [${status}]`
    );
    if (percent < threshold) pass = false;
  }

  console.log(`coverage gate (threshold ${threshold}%):`);
  for (const l of lines) console.log(l);

  if (!pass) {
    console.error(`coverage below threshold ${threshold}%`);
    process.exit(1);
  }
}

main();
