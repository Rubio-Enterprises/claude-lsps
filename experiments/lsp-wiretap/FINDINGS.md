# Wire-tap findings: how Claude Code actually syncs edits to LSP servers

Empirical validation of the pyright stale-diagnostics diagnosis, captured with
`wiretap.js` wrapped around `pyright-langserver` inside **real Claude Code
v2.1.207** sessions (`claude -p`, macOS). Method: a scratch Python project with
a local marketplace carrying a `pyright-tap` plugin whose `.lsp.json` routes
pyright through the wiretap; three headless sessions drove different edit
paths; the JSONL log records every message on the wire.

## The three runs

### Run 1 — single Edit-tool fix

Prompt: read `app.py` (contains a type error), fix it with the Edit tool.

```text
c2s  initialize → initialized
c2s  textDocument/didOpen   v1  textLen=89   <- the POST-edit (fixed) content
s2c  publishDiagnostics     v1  diagCount=0
c2s  shutdown → exit
```

Findings: the LSP server is spawned **lazily** (the tap process started only
~13s into the session, around edit time), and `didOpen` carried the *fixed*
content — the file was opened fresh after the edit. No `didChange` needed or
seen.

### Run 2 — two sequential Edit-tool edits (introduce error, then fix)

```text
c2s  textDocument/didOpen    v1  textLen=91   <- broken content (after edit #1)
s2c  publishDiagnostics      v1  diagCount=1
c2s  textDocument/didChange  v2  full-text, textLen=89  <- fixed (edit #2)
c2s  textDocument/didSave
s2c  publishDiagnostics      v2  diagCount=0
```

Finding: **Claude Code DOES send `didChange` (full-document) + `didSave` for
its own Edit-tool edits to an already-open document**, and pyright refreshes
correctly. The original premise behind the sync proxy ("the client never sends
`didChange`") was WRONG for Edit-tool edits.

### Run 3 — Edit-tool edit, then an out-of-band `sed` edit

Prompt: edit with the Edit tool (harmless change), then run
`sed -i '' 's/add(3, 4)/add("3", 4)/' app.py` via the Bash tool (introduces a
type error), then read the file to confirm.

```text
c2s  textDocument/didOpen   v1  textLen=89   <- post-Edit-tool content (clean)
s2c  publishDiagnostics     v1  diagCount=0
     ... sed rewrites the file on disk; ~16s of session remain ...
     (nothing: no didChange, no didClose/didOpen, no didChangeWatchedFiles)
c2s  shutdown → exit
```

Finding: **out-of-band disk edits are never synced.** Pyright's last word on
the file stays "0 diagnostics" while the file on disk has a type error —
diagnostics frozen at the last Edit-tool sync point.

## The validated behavior model (Claude Code v2.1.207)

| Edit path | Synced to the LSP? | Mechanism |
|---|---|---|
| Edit tool, first touch of a file | yes | lazy server spawn + `didOpen` with post-edit content |
| Edit tool, subsequent edits | yes | `didChange` (full-text) + `didSave` |
| Bash (`sed`, `git`, formatters, linter auto-fixes) | **no** | nothing sent |
| Other sessions / external editors | **no** | nothing sent |

So "stale pyright errors after they've been fixed" happens when the fix reaches
the file by any path other than this session's Edit tool: `git checkout/rebase`,
lefthook `stage_fixed` formatter rewrites during a commit, `ruff --fix`, a
concurrent Claude session in another worktree, or a human editor. The
diagnostics you then see are frozen at the last Edit-tool sync.

## Supporting probe: pyright ignores version ordering

A direct probe (test client, no Claude Code) sent `didChange` with out-of-order
versions: v1 open → v50 → v2 (regression) → v2 again (repeat). Pyright applied
every change and re-published each time. Version numbers are effectively
informational to pyright — a version "conflict" between proxy-injected and
client-sent didChanges cannot wedge it.

## Design consequences for the sync proxy (../pyright-sync-proxy/)

1. Its purpose is validated — it bridges exactly the unsynced path (out-of-band
   disk edits) and is inert where the client already syncs.
2. Its original "permanent back-off once the client sends `didChange`" was
   wrong: the real client is a HYBRID (didChanges its own edits, never syncs
   Bash edits), so back-off would reopen the stale window on any document the
   client ever edited. Replaced with buffer/version reconciliation: mirror the
   client's full-text didChanges into the proxy's buffer model, keep watching
   disk, inject with `max(version)+1`.

## Reproducing

```bash
# 1. scratch project + local marketplace with a pyright-tap plugin whose
#    .lsp.json runs: node ${CLAUDE_PLUGIN_ROOT}/wiretap.js --log <log> -- pyright-langserver --stdio
claude plugin marketplace add <marketplace-dir> --scope local
claude plugin install pyright-tap@<marketplace-name> --scope local
claude plugin disable pyright@claude-lsps --scope local   # avoid double-attach

# 2. drive an edit scenario headlessly
claude -p "<edit instructions>" --model haiku --permission-mode acceptEdits --allowedTools "Read,Edit"

# 3. read the wire
jq -c 'select(.dir=="c2s" and .method)' <log>
jq -c 'select(.method=="textDocument/publishDiagnostics")' <log>
```

Caveats: single Claude Code version (2.1.207), headless `-p` mode only,
pyright only. Interactive-session behavior was not separately captured (the
plugin/LSP plumbing is shared, but timing may differ).
