# pyright sync proxy (prototype)

> **Status: PRODUCTIZED.** Disk-sync shipped as part of the unified proxy that
> every plugin in this marketplace now runs (`<plugin>/lsp-proxy.js`, the
> `"sync"` key in `proxy.json`) — with the reconciliation design this prototype
> converged on. This directory remains as design history plus a standalone A/B
> demo against direct pyright; the adoption-path notes below describe the step
> that has since been taken (generalized to all plugins, not just pyright/).

An **experimental** LSP proxy that fixes pyright's "stale errors after a fix"
behavior. Not wired into the shipped `pyright` plugin — this directory is a
prototype you run by hand or adopt deliberately (see *Adoption path* below).

## The problem

pyright is **push-only**: it advertises no `diagnosticProvider`, so Claude Code
cannot pull fresh diagnostics on demand. pyright only re-analyzes an **open**
document when it receives a `textDocument/didChange`.

Wire-tapping real Claude Code v2.1.207 sessions (see
`../lsp-wiretap/FINDINGS.md` for the full evidence) established exactly which
edits get synced:

- **Edit-tool edits ARE synced** — first touch spawns the server lazily and
  sends `didOpen` with the post-edit content; subsequent edits send a full-text
  `didChange` + `didSave`. Pyright refreshes correctly for these.
- **Out-of-band disk edits are NEVER synced** — `sed`/`git`/formatter edits via
  the Bash tool, lefthook `stage_fixed` rewrites, other sessions, external
  editors. Nothing is sent; diagnostics freeze at the last Edit-tool sync.

That unsynced path is the "stale errors after a fix" symptom: the fix reached
the file via git / a formatter / another session, and pyright was never told.

A `workspace/didChangeWatchedFiles` event does **not** help here: for an open
document the server authoritatively uses the client's in-memory buffer, not the
file on disk. The only lever that refreshes an open document is `didChange`.

The refresh itself is fast (measured in `live/pyright-refresh`: ~250–780ms
after a `didChange`), so bridging the gap client-side is viable.

## What the proxy does

It sits between Claude Code and pyright and forwards all traffic transparently
— **no** method-blocking and **no** server→client auto-ack, because pyright
works correctly direct today and we preserve that exactly. It adds one behavior:

1. records every document the client opens (`textDocument/didOpen`);
2. polls those files on disk (`sync.pollMs`, default 300ms) with a one-tick
   stability gate so a mid-write partial read never reaches pyright;
3. when an open file's disk content diverges from the last known **buffer**
   content, injects a synthetic `textDocument/didChange` (full text) so pyright
   re-analyzes and re-publishes.

**Reconciliation, not back-off:** the real client is a hybrid — it didChanges
its own Edit-tool writes but never syncs Bash edits — so the proxy keeps
tracking through client didChanges instead of deferring permanently. It mirrors
the client's full-text `didChange`s into its buffer/version state (the client
stays authoritative for its own edits; a disk write that matches the buffer is
a no-op) and injects with `max(client version, injected version) + 1`. Pyright
applies didChange content regardless of version ordering (verified
empirically), so a lagging client version arriving after an injected one is
harmless. If a client ever sends an *incremental* (range-based) `didChange`,
the buffer becomes unreconstructable and disk-sync is disabled for that
document (logged once) — Claude Code sends full-text changes only.

## Try it

Requires `pyright-langserver` on `PATH`. From the repo root:

```bash
node experiments/pyright-sync-proxy/demo.js
```

The demo runs an A/B plus a hybrid phase modeled on validated Claude Code
behavior: open a broken file, fix it **on disk only** (control stays stale,
treatment clears), then a client-driven `didChange` followed by another
disk-only fix (the proxy must keep syncing — a back-off design goes deaf here).
Expected output:

```text
CONTROL   (direct pyright): opened→1 error(s); after disk fix → NO re-publish (stale)
TREATMENT (sync proxy): opened→1 error(s); after disk fix → 0 diag(s) CLEARED in ~500ms

HYBRID    (sync proxy): client didChange → 1 diag(s); then disk-only fix → 0 diag(s)

DEMO PASSED — disk-only edits sync through the proxy, including after client didChanges.
```

The demo exits non-zero if any expectation fails, so it doubles as a regression
check.

## Limitations / TODO before adoption

- **Polling, not `fs.watch`.** Polling is robust against atomic-rename replaces
  and inode churn, at the cost of up to one `pollMs` of refresh latency. A
  `fs.watch` fast-path (with a poll fallback) is a possible optimization.
- **`sed -i`-style replaces with identical size can dodge the stat check.**
  Change detection is `(mtimeMs, size)`; a same-size rewrite landing within the
  filesystem's mtime granularity could be missed. Rare in practice (mtimeMs is
  sub-second on APFS/ext4), but a content-hash fallback would close it.
- **No `didClose`/reopen races covered.** Rapid open/close/rename sequences are
  not exercised.
- **Validated on one client version.** The behavior model comes from Claude
  Code v2.1.207 headless runs (`../lsp-wiretap/FINDINGS.md`); re-tap after major
  Claude Code releases in case edit-sync behavior changes.

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
