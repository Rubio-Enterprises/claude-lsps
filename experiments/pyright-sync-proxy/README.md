# pyright sync proxy (prototype)

An **experimental** LSP proxy that fixes pyright's "stale errors after a fix"
behavior. Not wired into the shipped `pyright` plugin — this directory is a
prototype you run by hand or adopt deliberately (see *Adoption path* below).

## The problem

pyright is **push-only**: it advertises no `diagnosticProvider`, so Claude Code
cannot pull fresh diagnostics on demand. pyright only re-analyzes an **open**
document when it receives a `textDocument/didChange`. Claude Code edits files on
disk (the Edit/Write tools) without sending `didChange`, so pyright keeps
serving the diagnostics from the version it last saw — the stale error you see
after the underlying bug is already fixed.

A `workspace/didChangeWatchedFiles` event does **not** help here: for an open
document the server authoritatively uses the client's in-memory buffer, not the
file on disk. The only lever that refreshes an open document is `didChange`.

The behavior is reproducible and measured in the main test suite
(`live/pyright-refresh` in `tests/helpers/live-suite.js`): given a `didChange`,
pyright clears the error in ~250–780ms. So the staleness is a missing
client-side notification, not a pyright bug.

## What the proxy does

It sits between Claude Code and pyright and forwards all traffic transparently
— **no** method-blocking and **no** server→client auto-ack, because pyright
works correctly direct today and we preserve that exactly. It adds one behavior:

1. records every document the client opens (`textDocument/didOpen`);
2. polls those files on disk (`sync.pollMs`, default 300ms) with a one-tick
   stability gate so a mid-write partial read never reaches pyright;
3. when an open file's content changes on disk, injects a synthetic
   `textDocument/didChange` (full text, version-incremented) so pyright
   re-analyzes and re-publishes.

**Client priority:** if the client ever sends its own `didChange` for a URI (a
real editor managing a buffer), the proxy backs off for that document and never
injects — the client stays authoritative. So the proxy is inert for
buffer-driven clients and only activates for disk-edit clients like Claude Code.

## Try it

Requires `pyright-langserver` on `PATH`. From the repo root:

```bash
node experiments/pyright-sync-proxy/demo.js
```

The demo runs an A/B: it opens a broken file, then fixes it **on disk only** (no
`didChange`), against direct pyright (control) and against the proxy
(treatment). Expected output:

```text
CONTROL   (direct pyright): opened→1 error(s); after disk fix → NO re-publish (stale)
TREATMENT (sync proxy): opened→1 error(s); after disk fix → 0 diag(s) CLEARED in ~500ms

DEMO PASSED — the proxy refreshes pyright on a disk-only edit; direct pyright does not.
```

The demo exits non-zero if either expectation fails, so it doubles as a
regression check.

## Limitations / TODO before adoption

- **Polling, not `fs.watch`.** Polling is robust against atomic-rename replaces
  and inode churn, at the cost of up to one `pollMs` of refresh latency. A
  `fs.watch` fast-path (with a poll fallback) is a possible optimization.
- **Client-priority back-off is untested.** The `didChange`-defers logic is
  implemented but has no automated test yet; add one before adopting.
- **No `didClose`/reopen races covered.** Rapid open/close/rename sequences are
  not exercised.

## Adoption path

To ship this as the real `pyright` plugin behavior (flips pyright from a direct
to a proxied plugin):

1. Move `lsp-proxy.js` + `proxy.json` into `pyright/`.
2. Repoint `pyright/.lsp.json` to
   `node ${CLAUDE_PLUGIN_ROOT}/lsp-proxy.js --config ${CLAUDE_PLUGIN_ROOT}/proxy.json`.
3. Satisfy the suite invariants that then apply to `pyright/`:
   - `tests/cases/02-consistency.sh::tc_proxy_consistency` — the direct/proxied
     dichotomy now expects the proxied shape.
   - `tests/cases/99-coverage.sh` — the ≥80% V8 coverage gate globs every
     top-level `*/lsp-proxy.js`; add proxy tests (extend
     `tests/helpers/proxy-suite.js` + `stub-server.js`) to cover it.
4. Add a `live/*` scenario asserting the disk-edit auto-refresh against real
   pyright (the demo here is the blueprint).
