# Secrets — claude-lsps

This repo follows the Rubio-Enterprises sops + age standard (§6.10 of standards-design.md).

## File layout

- `.sops.yaml` — recipient rules (Copier-synced; do not edit ad-hoc — use `scripts/rotate-sops-recipients.sh` from `Rubio-Enterprises/.github`).
- `secrets/example.yaml` — committed shape doc. **No real values.**
- `secrets.staging.enc.yaml` — encrypted env for `staging`. Decryptable by org admin, backup, and CI keys.
- `secrets.prod.enc.yaml` — encrypted env for `prod`. Decryptable by org admin, backup, and per-host deploy keys ONLY (CI is NEVER a prod recipient).
- `.env`, `secrets.local.*` — **gitignored**, plaintext, developer-machine only.

## Local workflow

```bash
sops secrets.staging.enc.yaml                          # create or edit
sops -d secrets.staging.enc.yaml                       # decrypt to stdout
sops exec-env secrets.staging.enc.yaml 'mise run dev'  # run with env populated
```

direnv users: `use sops secrets.staging.enc.yaml` is in `.envrc` — `direnv allow` to enable.

## Recovery

Lost laptop, lost key: see §6.10 recovery scenario in `standards-design.md`. Backup recovery key (PGP-encrypted age key on paper) is in the safe deposit box.

## Secret-scan false positives

The `standards` workflow's `trufflehog` job (scheduled weekly + `workflow_dispatch`) runs trufflehog in `--results=verified,unknown` mode so unverifiable-but-format-matching dev credentials still surface (literal `password` defaults in upstream-fork docker-compose files, placeholder tokens in fixtures, etc.).

When trufflehog flags a path you've confirmed is a false positive (placeholder credentials in dev-only fixtures, upstream-convention literals in inherited fork files), drop a `.trufflehogignore` at the repo root. `secret-scan.yml` auto-detects it and passes `--exclude-paths=.trufflehogignore` — no workflow edit needed.

**Audit-then-add rule (load-bearing):** add an entry **only after empirically confirming** trufflehog flags that path. Defensive padding (paths that *look* like they could trip a detector but don't) is anti-pattern — bloats reviewer surface and conceals which entries do real work. Verify with:

```bash
trufflehog git file://. --results=verified,unknown --json \
  | jq -r '"\(.DetectorName) | \(.SourceMetadata.Data.Git.file)"' | sort -u
```

Only entries that appear in that output should land in `.trufflehogignore`. Full pattern reference and what-NOT-to-do guidance lives in [`Rubio-Enterprises/.github` `docs/opt-outs.md`](https://github.com/Rubio-Enterprises/.github/blob/main/docs/opt-outs.md#secret-scanyml-trufflehog--per-path-false-positive-suppression-via-trufflehogignore).
