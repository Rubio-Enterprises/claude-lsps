---
name: run-lsp-proxy
description: Launch and drive this repo's LSP proxies (regal-lsp, and the byte-identical copy every plugin ships) with real JSON-RPC over stdio, and run the marketplace test suite. Use when asked to run, start, exercise, or debug an lsp-proxy.js, observe blocked-method / auto-ack / warmup behavior, reproduce a proxy bug, or run the tests.
---

This is a Claude Code plugin **marketplace** — there is no app to boot. The
only live, protocol-speaking code is `lsp-proxy.js`, shipped as a
byte-identical copy in every plugin (drive `regal-lsp/`). It sits between Claude
Code and a real language server, intercepting JSON-RPC the client can't handle. You drive
a proxy with **`.claude/skills/run-lsp-proxy/driver.mjs`**: it spawns the proxy,
speaks a real `initialize → initialized → …` conversation at it over stdio, and
asserts the wire behavior. On a clean machine the real servers are absent, so
the driver points the proxy at the repo's bundled `tests/helpers/stub-server.js`
— **zero external installs, always runnable.**

All paths below are relative to the repo root.

## Prerequisites

Node ≥18 (repo runs on `v22.22.2`) — already present. The **test suite** additionally
needs `shellcheck`, `jq`, and `bash`; `jq`/`bash` are present, `shellcheck` is not:

```bash
apt-get install -y shellcheck
```

The **driver alone needs nothing but Node** — it does not use shellcheck.

## Run (agent path) — drive a proxy

Drive the proxy (regal) — blocked-method interception, server-request auto-ack,
**plus** the `textDocument/didOpen` warmup burst:

```bash
node .claude/skills/run-lsp-proxy/driver.mjs --plugin regal-lsp
```

Each run prints the client↔proxy conversation, then a checklist. Exit code is
0 only if every check passed.

**Known failing check (pre-existing, not a regression):** `server-initiated
workspace/configuration auto-acked` fails, so the current tail is
`❌ FAIL — 7/8 checks` (regal). This reproduces on an unmodified checkout and
predates the removal of the ansible plugin — it is a real gap between the
driver's expectation and the proxy's auto-ack behavior, not a broken setup.
Treat 7/8 as the current baseline; investigate the auto-ack path (not your
environment) if you intend to fix it. The driver is self-contained — no server to install,
no ports, no cleanup; it creates its own temp workspace and stub log under `/tmp`.

What each run proves against the running proxy:

| check | what it exercises |
|---|---|
| blocked `textDocument/references` → `null` | proxy synthesizes the reply; the server **never sees** the request |
| non-blocked `textDocument/hover` forwarded | ordinary methods round-trip to the server and back |
| server-initiated `workspace/configuration` auto-acked | proxy answers the server so it can't deadlock; client is shielded from it |
| warmup opened all `.rego`, skipped `.txt` (regal only) | `initialized` triggers a recursive `didOpen` burst filtered by extension |

Flags: `--plugin <plugin-dir>` (default `regal-lsp`). `regal-lsp` is the only
plugin whose `proxy.json` declares `blocked` methods and `warmup`, so it is the
only target that satisfies the full checklist.
`--live` swaps the stub for the real server from `proxy.json` — see Gotchas; it
is **not** runnable in a clean container (those servers aren't installed).

## Test — the marketplace suite

One bash entry point runs every case (manifest schema, cross-file invariants,
installer lint/behavior/concurrency, proxy wire tests, warmup, coverage gate):

```bash
bash tests/run.sh
```

Expected tail: `PASS: <n> tests, 0 failures` — the total varies by machine
because `live/*` cases register only when that server's binary is on `PATH`.
Requires `shellcheck` (see
Prerequisites) — without it the runner aborts before any test with
`missing required tools: shellcheck` and exit code 2.

## Gotchas

- **The proxies are the only thing you can "run."** Every plugin ships a
  byte-identical `lsp-proxy.js`, but only `regal-lsp` configures `blocked`
  methods and warmup — so it is the target that exercises the full checklist.
- **Regal warmup needs a real `initialize` response first.** Warmup only fires
  after the server's initialize reply (the proxy waits for `result.capabilities`)
  *and* the client's `initialized` notification *and* a `rootUri`. The driver sets
  `STUB_AUTO_INIT=1` so the stub actually answers `initialize`; drop that and
  warmup silently never triggers. This ordering dependency is easy to miss.
- **`--live` can't run here.** The proxied server (`regal`) is not installed in
  this container. `--live` is wired up but was not exercised; use it only where
  the real server is on `PATH`.
- **shellcheck version skew.** CI pins `shellcheck 0.10.0`; `apt-get` here gives
  `0.9.0`. The suite passes on 0.9.0, but if you hit a lint-only failure that
  reproduces green locally, suspect the version gap before the code.
- **All proxy copies share wire logic and must stay byte-identical.** If you
  change framing, the auto-ack set, or the blocked-response shape in one
  `lsp-proxy.js`, fan the edit out to every copy and re-run the driver.

## Troubleshooting

- **`missing required tools: shellcheck` (exit 2) from `bash tests/run.sh`**:
  shellcheck isn't installed. `apt-get install -y shellcheck`.
- **Driver hangs / `hard timeout — proxy did not complete the conversation`**:
  the proxy's child server never answered `initialize`. In stub mode that means
  `STUB_AUTO_INIT` didn't take effect; in `--live` mode it means the real server
  isn't on `PATH` or crashed (check the proxy's stderr, which is inherited).
- **`warmup opened all .rego files` fails with `0 didOpen`**: warmup didn't fire.
  Confirm the `initialize` you send carries a `rootUri` and that the stub answered
  with `capabilities` before you send `initialized`.
