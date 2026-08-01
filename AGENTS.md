# Agent context

This repo follows Rubio-Enterprises standards. Run `/audit-standards` from a Claude Code session to check conformance, or `/onboard-repo` for greenfield setup.

Repo-specific context (in-progress migrations, gotchas, agent guidance):

## What this repo is

A Claude Code plugin **marketplace** that ships five LSP plugins (`bash-language-server`, `cue-lsp`, `pyright`, `regal-lsp`, `vtsls`). There is no application to build — the "product" is the directory tree itself, consumed by Claude Code via `.claude-plugin/marketplace.json`.

The repo is rendered against the standards template with `archetype: bare` (no language toolchain — see `${CLAUDE_PLUGIN_ROOT}/spec/bare.md`). Only the cross-cutting org floor applies; there is no `package.json`, `tsconfig.json`, or `biome.json` and audit checks for those files do not fire.

## Test commands

The whole suite is a single bash entry point:

```bash
bash tests/run.sh
```

Required tools (the runner aborts if any are missing): `node`, `bash`, `jq`, `shellcheck`. CI pins `shellcheck v0.10.0` and Node `22.11.0` — match these locally if you hit a green-locally / red-in-CI mismatch.

Running a **single test** is not first-class. Two reliable options:

- Run a single test *case file* by sourcing it directly: edit `tests/run.sh` to glob a narrower pattern (`tests/cases/06-proxy.sh`), or run that file's helper directly, e.g. `node tests/helpers/proxy-suite.js passthrough` for proxy tests, or `node tests/helpers/warmup-suite.js files-opened` for warmup.
- Comment out unwanted `register_test` lines temporarily. The runner iterates whatever was registered.

Do **not** invent flags like `--filter` — the framework in `tests/lib/framework.sh` is intentionally tiny (just `register_test` + `run_all`) and has no selection mechanism.

## Architecture: where to look first

### Per-plugin layout

Every plugin directory follows the same shape:

```
<plugin>/
  .claude-plugin/plugin.json   # name, version, description, license, author
  .lsp.json                    # launches the unified proxy (node lsp-proxy.js --config proxy.json)
  hooks/hooks.json             # SessionStart hook entry
  hooks/check-<binary>.sh      # idempotent installer (Homebrew → npm/binary fallback)
  lsp-proxy.js                 # unified proxy — byte-identical copy in EVERY plugin
  proxy.json                   # per-plugin proxy config (server cmd, blocked, warmup, sync)
```

`.lsp.json` paths to in-repo files MUST use `${CLAUDE_PLUGIN_ROOT}/...` — `tests/cases/02-consistency.sh::tc_lsp_paths_are_safe` rejects absolute paths and any other variable. Same constraint applies to `hooks/hooks.json` command strings.

### The unified proxy (standard wrapper)

Every plugin routes its server through the same `lsp-proxy.js`; there are no
"direct" plugins (`tc_proxy_consistency` fails a plugin without the proxy).
Behavior is driven per-plugin by `proxy.json`:

- **`blocked`** — client→server requests the server would answer with JSON-RPC
  `-32601`, which puts Claude Code's LSP client into an unrecoverable broken
  state. The proxy synthesizes `{result: null}` instead. (regal)
- **auto-ack** (always on) — answers server→client requests Claude Code's
  client can't handle (`client/registerCapability`, `client/unregisterCapability`,
  `workspace/configuration`, `window/workDoneProgress/create`) so the server
  doesn't deadlock. `workspace/configuration` gets the spec-correct per-item
  null array, not a bare null — pyright/vtsls index into it.
- **`warmup`** — after the client's `initialized`, walks `rootUri` for matching
  files and sends synthetic `textDocument/didOpen` so servers that defer
  indexing until first-open (Regal) start immediately. (regal)
- **`sync`** (default ON; `"sync": false` to disable) — **disk-sync**: Claude
  Code sends `didChange`+`didSave` for its own Edit-tool writes but NOTHING for
  out-of-band disk edits (Bash `sed`/git/formatters/other sessions) — validated
  by wire-tapping real sessions, `experiments/lsp-wiretap/FINDINGS.md`. The
  proxy tracks open documents (client didOpens AND warmup opens), polls disk
  (stat tuple mtime+ctime+size+ino) with a one-tick stability gate, and
  injects full-text `didChange`+`didSave` when disk diverges from the last
  known buffer. Client didChanges are reconciled (mirrored into buffer/version
  state), never backed off from; a client didChange whose version lags the
  proxy's injections is rebased to tracked+1 (version monotonicity); an
  incremental (range-based) client didChange disables sync for that document.
  A deleted tracked file gets a synthetic `didClose` (clears diagnostics) and
  is reopened if it reappears (e.g. git branch switches).

**Editing the proxy:** all five copies must stay byte-identical
(`consistency/proxy-copies-identical` enforces it — plugin installs copy each
plugin dir verbatim, so a shared file or symlink can't work). Edit one copy,
then fan out: `for p in */lsp-proxy.js; do cp <edited-copy> "$p"; done`.

### Installer scripts (`hooks/check-*.sh`)

All five follow the same template:

1. If `BINARY` is already on PATH, exit 0 (idempotent — re-runs are free).
2. Pick install method: `brew` if available, else `npm` (for Node-shipped servers) or direct binary download (for `cue-lsp`, `regal-lsp`). The exact fallback varies per plugin.
3. Acquire a **process-wide lock** (`/tmp/claude-lsp-brew.lock`, `/tmp/claude-lsp-npm.lock`, or `/tmp/claude-lsp-binary.lock`) so concurrent SessionStart hooks from different plugins don't fight Homebrew/npm. Uses `flock`; falls back to a `mkdir`-loop on macOS where `flock` isn't standard.
4. Re-check `command -v $BINARY` **inside** the critical section before installing — this is what makes parallel SessionStart hooks safe (second caller short-circuits).

When editing an installer: keep the `BINARY=` line as a `KEY="value"` assignment on its own — `tests/cases/02-consistency.sh::_installer_binary` greps for it with `awk -F'=' '/^BINARY=/'` and uses the result to verify `.lsp.json` / `proxy.json` agree on which command they're invoking.

### Marketplace / plugin coupling

`/.claude-plugin/marketplace.json` is the source of truth. The test suite derives `PLUGINS=(…)` from `.plugins[].source` in `tests/run.sh`, so **adding a plugin to the marketplace automatically enrolls it in the test suite** — there is no parallel list to keep in sync. Per-plugin fields must match `plugin.json` (`name`, `version`, `description`, `author.name`); the marketplace also requires `category` and a non-empty `tags` array.

## Test suite structure

Nine case files under `tests/cases/`, run in lexical order:

| File | What it guards |
|---|---|
| `01-manifests.sh` | JSON validity + schema of `plugin.json`, `.lsp.json`, `hooks.json`, `proxy.json`, `marketplace.json` |
| `02-consistency.sh` | Cross-file invariants: `.lsp.json` ↔ installer `BINARY` ↔ `proxy.json` `server[0]`; hooks.json commands resolve to real files |
| `03-installer-lint.sh` | `bash -n` + `shellcheck --severity=warning` on every `check-*.sh` |
| `04-installer-behavior.sh` | Per-plugin: noop when binary present, brew path, npm path, binary path, failure propagation, post-install missing-binary check. Uses sandboxed `PATH` with mocked `brew`/`npm`/`curl`/`tar`/`uname` from `tests/helpers/mock-bin.sh` |
| `05-installer-concurrency.sh` | Two parallel invocations → exactly one install call (flock branch AND mkdir-fallback branch) |
| `06-proxy.sh` | Wire-level proxy behavior via `tests/helpers/proxy-suite.js` + `stub-server.js`: passthrough, blocked methods, auto-ack, disk-sync (inject / reconcile / incremental-disable / didClose / sync:false / warmup-tracked) |
| `07-warmup.sh` | Regal warmup: files opened, empty tree, no warmup section, multi-extension |
| `08-live.sh` | Real-server end-to-end scenarios (skipped per-binary when not installed), incl. `pyright-refresh` (didChange refresh) and `pyright-disksync` (disk-only edit refresh through the proxy) |
| `99-coverage.sh` | V8 coverage gate: ≥80% on `*/lsp-proxy.js`, with byte-identical copies grouped by content hash and gated on their coverage union (the wire suite spreads scenarios across copies) |

The harness **sources** case files into `run.sh` (doesn't exec them), so a syntax error in any case body would silently skip later assertions if `set -euo pipefail` weren't in `run.sh`. Don't remove it.

### Sandboxing

`tests/helpers/mock-bin.sh::new_sandbox` creates `$TMP_DIR/sandbox/<tag>/` with `bin/`, `home/.local/bin/`, `tmp/`, then symlinks **only** a curated set of real tools (`bash`, `flock`, `mkdir`, `sleep`, `uname`, …) — `/usr/bin` is deliberately excluded from `PATH` so installers can't accidentally use the real `brew`/`npm`. `patch_installer` rewrites the installer's hard-coded `/tmp/claude-lsp-*.lock` paths to live inside the sandbox.

## Adding a new plugin

1. Create `<plugin>/.claude-plugin/plugin.json`, `.lsp.json`, `hooks/hooks.json`, `hooks/check-<binary>.sh` matching the patterns above.
2. Copy the unified proxy from any existing plugin (`cp pyright/lsp-proxy.js <plugin>/lsp-proxy.js` — the identity test rejects anything else) and write a `proxy.json`: `server` = the real server command, `blocked` = methods the server `-32601`s (empty array if none), plus `warmup` if the server defers indexing until first-open. `.lsp.json` invokes `node ${CLAUDE_PLUGIN_ROOT}/lsp-proxy.js --config ${CLAUDE_PLUGIN_ROOT}/proxy.json`.
3. Add an entry to `.claude-plugin/marketplace.json` (`source: "./<plugin>"`, `name`, `version`, `description`, `category`, `tags`, `author.name`).
4. Run `bash tests/run.sh` — every cross-file invariant test self-extends to the new plugin, but per-plugin behavior tests in `04-installer-behavior.sh` and `05-installer-concurrency.sh` are explicitly registered. Add new `tc_install_*` cases there matching the install strategy (brew / npm / binary).

## Conventions worth knowing

- README plugin notes (`pyright` venv discovery, `regal` `project.roots`) document **end-user-visible quirks**, not repo internals — keep that distinction when adding documentation.
- The unified `lsp-proxy.js` is the only non-trivial executable code. It is deliberately dependency-free (Node stdlib only) and uses stdio framing by hand. Don't introduce `npm install` — there is no `package.json` and the install hooks don't run one.
- `experiments/` holds the design history: `lsp-wiretap/` (transparent tap + `FINDINGS.md`, the wire-level evidence behind disk-sync) and `pyright-sync-proxy/` (the prototype that became the unified proxy's sync feature, with a standalone A/B demo). Not shipped, not under the coverage gate; re-tap after major Claude Code releases to revalidate the edit-sync behavior model.
- There is a perf harness separate from the pass/fail suite: `bash tests/perf.sh` prints per-LSP spawn→ready / first-diagnostic latency medians (`PERF_ITERS` to change sampling).
- Trailing-comment notes inside test cases (e.g. "cue's pipefail bug is a known issue, separate from this test PR") are real TODOs — read them before "fixing" what looks like an oversight.
