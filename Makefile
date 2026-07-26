# Canonical test entry point for the repository-local test gate
# (rubio-standards ADR-0020, Rubio-Enterprises/standards#387).
#
# Why this file exists: the gate's recognized-command allowlist accepts
# `make test`, but not `bash tests/run.sh`. The template-owned `.mise.toml`
# `test` task delegates to `npm run test`, and this repo has no package.json
# (it is a plugin marketplace of bash/node LSP proxies, not an npm package),
# so `mise run test` cannot be the entry point either.
#
# Keep this a thin dispatcher: the harness itself lives in tests/run.sh, which
# stays the thing developers run directly.
.PHONY: test
test:
	bash tests/run.sh
