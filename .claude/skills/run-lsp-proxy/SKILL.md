---
name: run-lsp-proxy
description: Launch and drive this repo's LSP proxies (ansible-language-server, regal-lsp) with real JSON-RPC over stdio, and run the marketplace test suite. Use when asked to run, start, exercise, or debug an lsp-proxy.js, observe blocked-method / auto-ack / warmup behavior, reproduce a proxy bug, or run the tests.
---

This is a Claude Code plugin **marketplace** — there is no app to boot. The
only live, protocol-speaking code is the two `lsp-proxy.js` files
(`ansible-language-server/`, `regal-lsp/`). They sit between Claude Code and a
real language server, intercepting JSON-RPC the client can't handle. You drive
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

Drive the bare proxy (ansible) — blocked-method interception + server-request auto-ack:

```bash
node .claude/skills/run-lsp-proxy/driver.mjs --plugin ansible-language-server
```

Drive the warmup proxy (regal) — same, **plus** the `textDocument/didOpen` warmup burst:

```bash
node .claude/skills/run-lsp-proxy/driver.mjs --plugin regal-lsp
```

Each run prints the client↔proxy conversation, then a checklist. Expected tails:
`✅ PASS — 6/6 checks` (ansible) and `✅ PASS — 8/8 checks` (regal). Exit code is
0 only if every check passed. The driver is self-contained — no server to install,
no ports, no cleanup; it creates its own temp workspace and stub log under `/tmp`.

What each run proves against the running proxy:

| check | what it exercises |
|---|---|
| blocked `textDocument/references` → `null` | proxy synthesizes the reply; the server **never sees** the request |
| non-blocked `textDocument/hover` forwarded | ordinary methods round-trip to the server and back |
| server-initiated `workspace/configuration` auto-acked | proxy answers the server so it can't deadlock; client is shielded from it |
| warmup opened all `.rego`, skipped `.txt` (regal only) | `initialized` triggers a recursive `didOpen` burst filtered by extension |

Flags: `--plugin <ansible-language-server|regal-lsp>` (default ansible).
`--live` swaps the stub for the real server from `proxy.json` — see Gotchas; it
is **not** runnable in a clean container (those servers aren't installed).

## Test — the marketplace suite

One bash entry point runs all 78 cases (manifest schema, cross-file invariants,
installer lint/behavior/concurrency, proxy wire tests, warmup, coverage gate):

```bash
bash tests/run.sh
```

Expected tail: `PASS: 78 tests, 0 failures`. Requires `shellcheck` (see
Prerequisites) — without it the runner aborts before any test with
`missing required tools: shellcheck` and exit code 2.

## Gotchas

- **The proxies are the only thing you can "run."** Four of the six plugins
  (`bash-language-server`, `cue-lsp`, `pyright`, `vtsls`) are *direct* — their
  `.lsp.json` invokes the real binary with no proxy, so there's nothing repo-side
  to drive. Only `ansible-language-server` and `regal-lsp` have `lsp-proxy.js`.
- **Regal warmup needs a real `initialize` response first.** Warmup only fires
  after the server's initialize reply (the proxy waits for `result.capabilities`)
  *and* the client's `initialized` notification *and* a `rootUri`. The driver sets
  `STUB_AUTO_INIT=1` so the stub actually answers `initialize`; drop that and
  warmup silently never triggers. This ordering dependency is easy to miss.
- **`--live` can't run here.** The proxied servers (`ansible-language-server`,
  `regal`) are not installed in this container — only `pyright` is, and pyright is
  a *direct* plugin with no proxy. `--live` is wired up but was not exercised;
  use it only where the real server is on `PATH`.
- **shellcheck version skew.** CI pins `shellcheck 0.10.0`; `apt-get` here gives
  `0.9.0`. The suite passes on 0.9.0, but if you hit a lint-only failure that
  reproduces green locally, suspect the version gap before the code.
- **The two proxies share wire logic and drift only by warmup.** If you change
  framing, the auto-ack set, or the blocked-response shape in one `lsp-proxy.js`,
  mirror it to the other and re-run the driver for **both** plugins.

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
