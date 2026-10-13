# claude-lsps

LSP plugins for Claude Code

Every plugin launches its language server through a shared proxy that keeps diagnostics fresh
and handles protocol gaps. The marketplace ships Bash, CUE, Python, Rego, and TypeScript/JavaScript
plugins for [Claude Code](https://claude.ai/code).

## Table of Contents

- [Install](#install)
- [Usage](#usage)
- [Plugin Notes](#plugin-notes)
- [LSP Proxy](#lsp-proxy)
- [Contributing](#contributing)
- [License](#license)

## Install

Add this marketplace to your Claude Code plugins configuration, then install individual plugins.
From a Claude Code session:

```text
/plugin marketplace add Rubio-Enterprises/claude-lsps
/plugin install pyright@claude-lsps
```

### Dependencies

Claude Code and Node.js on PATH are required. Each plugin includes a SessionStart hook that
automatically installs its LSP binary if it is not already available. Most plugins install via
Homebrew, with npm or direct binary downloads as the alternative when Homebrew is unavailable.
Concurrent installs are serialized with `flock`, or a `mkdir` lock on systems without `flock`,
to prevent lock conflicts.

## Usage

Install the plugins for the languages in your project; their language servers provide diagnostics
and code navigation through Claude Code's LSP integration. For example, add the Rego plugin:

```text
/plugin install regal-lsp@claude-lsps
```

| Plugin | LSP Server | Description |
|--------|-----------|-------------|
| `bash-language-server` | `bash-language-server start` | Bash/Shell language server |
| `cue-lsp` | `cue lsp serve` | CUE language server (built into CUE CLI) |
| `pyright` | `pyright-langserver --stdio` | Python type checker and language server |
| `regal-lsp` | `regal language-server` | Rego linter and language server |
| `vtsls` | `vtsls --stdio` | TypeScript/JavaScript language server |

See [LSP Proxy](#lsp-proxy) for the shared behavior and [Plugin Notes](#plugin-notes)
for project configuration that may be needed.

## Plugin Notes

### pyright

Pyright auto-discovers a `.venv` in the project root, but projects that install dependencies via
`uv run --with` (ephemeral injection) or `uv tool` won't have them visible to Pyright by default.
To fix `reportMissingImports` errors, add a `pyrightconfig.json` at the project root pointing to
your venv:

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

If your Rego policy files live in a subdirectory (e.g., `policy/`) rather than at the project root,
the Regal language server needs a `project.roots` entry in `.regal/config.yaml` to resolve cross-file
imports (like `import data.zone_isolation` in test files). Without this, the LSP reports false
`unresolved-import` and `opa-fmt` errors because it can't find sibling packages.

```yaml
# .regal/config.yaml
project:
  roots:
    - policy   # path to your Rego files, relative to project root
```

`regal lint policy/` (CLI, whole-directory) works without this because it scans all files together.
The LSP processes files individually, so it needs `project.roots` to know where to look for other
packages.

## LSP Proxy

Every plugin runs its language server behind a shared proxy (`lsp-proxy.js`,
launched via `node` with `${CLAUDE_PLUGIN_ROOT}` path expansion — no generated
wrappers or extra proxy executables on PATH). Each plugin configures it through `proxy.json`.
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

## Contributing

Repository changes go through pull requests with a Conventional Commits title and the sections in
[.github/PULL_REQUEST_TEMPLATE.md](.github/PULL_REQUEST_TEMPLATE.md): What, Why, How, Testing,
Feedback, and known dependencies (screenshots when relevant). Use repository issues for questions
and bug reports.

Run `mise install`, `mise run lint`, and `make test` (or `bash tests/run.sh`). The test harness
requires Node.js, Bash, jq, and ShellCheck; live-server cases skip when their binaries are absent.
The rendered `mise run test`, `mise run build`, and `mise run typecheck` tasks delegate to npm,
but this marketplace has no `package.json`; use the repository's `make test` entry point instead
of the rendered test task. Commit hooks also format and check staged Markdown.

## License

[MIT](LICENSE) — Copyright (c) 2026 Rubio Enterprises.
