# claude-lsps

LSP plugins for [Claude Code](https://claude.ai/code).

## Plugins

Every plugin launches its language server through a shared proxy (see
[LSP Proxy](#lsp-proxy) below) that keeps diagnostics fresh and papers over
protocol gaps.

| Plugin | LSP Server | Description |
|--------|-----------|-------------|
| `bash-language-server` | `bash-language-server start` | Bash/Shell language server |
| `cue-lsp` | `cue lsp serve` | CUE language server (built into CUE CLI) |
| `pyright` | `pyright-langserver --stdio` | Python type checker and language server |
| `regal-lsp` | `regal language-server` | Rego linter and language server |
| `vtsls` | `vtsls --stdio` | TypeScript/JavaScript language server |

## Installation

Add this marketplace to your Claude Code plugins configuration, then install individual plugins.

Each plugin includes a SessionStart hook that automatically installs the LSP binary if it is not already available. Most plugins install via Homebrew. Concurrent installs are serialized with `flock` to prevent lock conflicts.

## Plugin Notes

### pyright

Pyright auto-discovers a `.venv` in the project root, but projects that install dependencies via `uv run --with` (ephemeral injection) or `uv tool` won't have them visible to Pyright by default. To fix `reportMissingImports` errors, add a `pyrightconfig.json` at the project root pointing to your venv:

```json
{
  "venvPath": ".",
  "venv": ".venv"
}
```

If you don't have a `.venv` yet, create one with the dependencies your scripts need:

```bash
uv venv
uv pip install ruamel.yaml  # or whatever your scripts import
```

### regal-lsp

If your Rego policy files live in a subdirectory (e.g., `policy/`) rather than at the project root, the Regal language server needs a `project.roots` entry in `.regal/config.yaml` to resolve cross-file imports (like `import data.zone_isolation` in test files). Without this, the LSP reports false `unresolved-import` and `opa-fmt` errors because it can't find sibling packages.

```yaml
# .regal/config.yaml
project:
  roots:
    - policy   # path to your Rego files, relative to project root
```

`regal lint policy/` (CLI, whole-directory) works without this because it scans all files together. The LSP processes files individually, so it needs `project.roots` to know where to look for other packages.

## LSP Proxy

Every plugin runs its language server behind a shared proxy (`lsp-proxy.js`,
launched via `node` with `${CLAUDE_PLUGIN_ROOT}` path expansion — no generated
wrappers or PATH dependencies). Each plugin configures it through `proxy.json`.
It provides:

- **Fresh diagnostics on out-of-band edits (all plugins).** Claude Code tells
  the server about its own Edit-tool changes, but edits that land on disk any
  other way — Bash commands (`sed`, `git checkout`, formatters), lint
  auto-fixes, another session or editor — are never reported, so the server
  keeps serving stale diagnostics from the last state it saw. The proxy watches
  open files on disk and injects the missing `didChange`/`didSave` so
  diagnostics refresh within a few hundred milliseconds. Disable per plugin
  with `"sync": false` in `proxy.json`.
- **Blocked-method interception (regal).** Prevents Claude Code's LSP
  client from entering a broken state when a server returns JSON-RPC `-32601`
  for methods it doesn't implement; the proxy answers `null` instead.
- **Server unblocking (all plugins).** Auto-answers server-initiated requests
  Claude Code's client doesn't handle (capability registration, configuration
  fetches, progress tokens) so servers don't deadlock waiting.
- **Warmup (regal).** Opens matching workspace files right after
  initialization so servers that defer indexing until first-open start
  immediately.

## License

MIT
