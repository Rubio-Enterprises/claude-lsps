# Agent context

This repo follows Rubio-Enterprises standards. Run `/audit-standards` from a Claude Code session to check conformance, or `/onboard-repo` for greenfield setup.

Repo-specific context (in-progress migrations, gotchas, agent guidance):

## What this repo is

A Claude Code plugin **marketplace** that ships six LSP plugins (`ansible-language-server`, `bash-language-server`, `cue-lsp`, `pyright`, `regal-lsp`, `vtsls`). There is no application to build — the "product" is the directory tree itself, consumed by Claude Code via `.claude-plugin/marketplace.json`.

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
  .lsp.json                    # how Claude Code launches the LSP
  hooks/hooks.json             # SessionStart hook entry
  hooks/check-<binary>.sh      # idempotent installer (Homebrew → npm/binary fallback)
  lsp-proxy.js                 # ONLY for proxy plugins (ansible, regal)
  proxy.json                   # ONLY for proxy plugins
```

`.lsp.json` paths to in-repo files MUST use `${CLAUDE_PLUGIN_ROOT}/...` — `tests/cases/02-consistency.sh::tc_lsp_paths_are_safe` rejects absolute paths and any other variable. Same constraint applies to `hooks/hooks.json` command strings.

### Two plugin variants

There are exactly two shapes a plugin can have, and the test suite enforces the dichotomy (`tc_proxy_consistency`):

1. **Direct** (`bash-language-server`, `cue-lsp`, `pyright`, `vtsls`): `.lsp.json` invokes the LSP binary directly. No `lsp-proxy.js`, no `proxy.json`.
2. **Proxied** (`ansible-language-server`, `regal-lsp`): `.lsp.json` invokes `node ${CLAUDE_PLUGIN_ROOT}/lsp-proxy.js --config ${CLAUDE_PLUGIN_ROOT}/proxy.json`. `proxy.json` lists the real server command and blocked LSP methods.

The **why** for proxy plugins: when an LSP server returns JSON-RPC `-32601` (method not found) for things like `textDocument/documentSymbol`, Claude Code's LSP client enters an unrecoverable broken state. The proxy intercepts those client→server requests and synthesizes a `null` result. It **also** auto-acks server→client requests the client can't handle (`client/registerCapability`, `client/unregisterCapability`, `workspace/configuration`, `window/workDoneProgress/create`) so the server doesn't deadlock waiting for a response.

### Two proxies, two responsibilities

- `ansible-language-server/lsp-proxy.js` — bare proxy. Blocks listed methods, auto-acks server-initiated requests, forwards everything else byte-for-byte.
- `regal-lsp/lsp-proxy.js` — superset. Adds a **warmup** phase: after the client's `initialized` notification, recursively walks `rootUri` for files matching `proxy.warmup.extensions`, skips `proxy.warmup.exclude` directory names, and sends synthetic `textDocument/didOpen` notifications so servers that defer indexing until first-open (like Regal) start indexing immediately.

If you change one proxy's wire-handling logic (framing, auto-ack list, blocked-method response shape), strongly consider mirroring the change to the other — they diverged only because warmup needed extra state.

### Installer scripts (`hooks/check-*.sh`)

All six follow the same template:

1. If `BINARY` is already on PATH, exit 0 (idempotent — re-runs are free).
2. Pick install method: `brew` if available, else `npm` (for Node-shipped servers) or direct binary download (for `cue-lsp`, `regal-lsp`). The exact fallback varies per plugin.
3. Acquire a **process-wide lock** (`/tmp/claude-lsp-brew.lock`, `/tmp/claude-lsp-npm.lock`, or `/tmp/claude-lsp-binary.lock`) so concurrent SessionStart hooks from different plugins don't fight Homebrew/npm. Uses `flock`; falls back to a `mkdir`-loop on macOS where `flock` isn't standard.
4. Re-check `command -v $BINARY` **inside** the critical section before installing — this is what makes parallel SessionStart hooks safe (second caller short-circuits).

When editing an installer: keep the `BINARY=` line as a `KEY="value"` assignment on its own — `tests/cases/02-consistency.sh::_installer_binary` greps for it with `awk -F'=' '/^BINARY=/'` and uses the result to verify `.lsp.json` / `proxy.json` agree on which command they're invoking.

### Marketplace / plugin coupling

`/.claude-plugin/marketplace.json` is the source of truth. The test suite derives `PLUGINS=(…)` from `.plugins[].source` in `tests/run.sh`, so **adding a plugin to the marketplace automatically enrolls it in the test suite** — there is no parallel list to keep in sync. Per-plugin fields must match `plugin.json` (`name`, `version`, `description`, `author.name`); the marketplace also requires `category` and a non-empty `tags` array.

## Test suite structure

Eight case files under `tests/cases/`, run in lexical order:

| File | What it guards |
|---|---|
| `01-manifests.sh` | JSON validity + schema of `plugin.json`, `.lsp.json`, `hooks.json`, `proxy.json`, `marketplace.json` |
| `02-consistency.sh` | Cross-file invariants: `.lsp.json` ↔ installer `BINARY` ↔ `proxy.json` `server[0]`; hooks.json commands resolve to real files |
| `03-installer-lint.sh` | `bash -n` + `shellcheck --severity=warning` on every `check-*.sh` |
| `04-installer-behavior.sh` | Per-plugin: noop when binary present, brew path, npm path, binary path, failure propagation, post-install missing-binary check. Uses sandboxed `PATH` with mocked `brew`/`npm`/`curl`/`tar`/`uname` from `tests/helpers/mock-bin.sh` |
| `05-installer-concurrency.sh` | Two parallel invocations → exactly one install call (flock branch AND mkdir-fallback branch) |
| `06-proxy.sh` | Wire-level proxy behavior via `tests/helpers/proxy-suite.js` + `stub-server.js` |
| `07-warmup.sh` | Regal warmup: files opened, empty tree, no warmup section, multi-extension |
| `99-coverage.sh` | V8 coverage gate: ≥80% on every `*/lsp-proxy.js`. Collected via `NODE_V8_COVERAGE` exported by `run.sh` |

The harness **sources** case files into `run.sh` (doesn't exec them), so a syntax error in any case body would silently skip later assertions if `set -euo pipefail` weren't in `run.sh`. Don't remove it.

### Sandboxing

`tests/helpers/mock-bin.sh::new_sandbox` creates `$TMP_DIR/sandbox/<tag>/` with `bin/`, `home/.local/bin/`, `tmp/`, then symlinks **only** a curated set of real tools (`bash`, `flock`, `mkdir`, `sleep`, `uname`, …) — `/usr/bin` is deliberately excluded from `PATH` so installers can't accidentally use the real `brew`/`npm`. `patch_installer` rewrites the installer's hard-coded `/tmp/claude-lsp-*.lock` paths to live inside the sandbox.

## Adding a new plugin

1. Create `<plugin>/.claude-plugin/plugin.json`, `.lsp.json`, `hooks/hooks.json`, `hooks/check-<binary>.sh` matching the patterns above.
2. If the LSP returns `-32601` for any method Claude Code requests, also add `lsp-proxy.js` + `proxy.json` (copy from `ansible-language-server/` or `regal-lsp/`).
3. Add an entry to `.claude-plugin/marketplace.json` (`source: "./<plugin>"`, `name`, `version`, `description`, `category`, `tags`, `author.name`).
4. Run `bash tests/run.sh` — every cross-file invariant test self-extends to the new plugin, but per-plugin behavior tests in `04-installer-behavior.sh` and `05-installer-concurrency.sh` are explicitly registered. Add new `tc_install_*` cases there matching the install strategy (brew / npm / binary).

## Conventions worth knowing

- README plugin notes (`pyright` venv discovery, `regal` `project.roots`) document **end-user-visible quirks**, not repo internals — keep that distinction when adding documentation.
- The `lsp-proxy.js` files are the only non-trivial executable code. They are deliberately dependency-free (Node stdlib only) and use stdio framing by hand. Don't introduce `npm install` — there is no `package.json` and the install hooks don't run one.
- Trailing-comment notes inside test cases (e.g. "cue's pipefail bug is a known issue, separate from this test PR") are real TODOs — read them before "fixing" what looks like an oversight.
