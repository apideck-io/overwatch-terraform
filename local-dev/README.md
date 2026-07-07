# local-dev/

Scripted local Retool stack used to dry-run the 3.24.6 → 3.334.x upgrade
before touching prod.

**This directory is for upgrade testing only.** It does not deploy to
any environment. Production runs through Terraform at the repo root.

## Quick start

See [RUNBOOK.md](./RUNBOOK.md) for the full operator runbook.

```sh
cd local-dev
cp .env.example .env

# Generate POSTGRES_PASSWORD; refuses to touch the prod-sourced secrets.
scripts/gen-secrets.sh

# Paste ENCRYPTION_KEY + JWT_SECRET into .env from a live prod ECS task.
# Paste a free LICENSE_KEY from https://my.retool.com.
# Drop a fresh Aurora dump into dumps/.

scripts/check-prereqs.sh                              # verify setup
scripts/restore-dump.sh --dump dumps/prod-<date>.dump # restore Postgres
scripts/check-tags.sh                                 # verify Docker Hub tags
scripts/run-all-hops.sh                               # walk all 8 hops
```

## What ships in this directory

| Path                              | Purpose                                              |
|-----------------------------------|------------------------------------------------------|
| `.env.example`                    | All 35 prod env vars; populate to `.env`             |
| `RUNBOOK.md`                      | Operator runbook                                     |
| `compose/compose.3-24.yml`        | Base 3-service stack (postgres + api + jobs-runner)  |
| `compose/compose.3-196.yml`       | Overlay adding code-executor at hops ≥ 3.196         |
| `compose/compose.override.yml`    | Apple Silicon linux/amd64 override                   |
| `scripts/check-prereqs.sh`        | Verify `.env`, dump, docker before any walk          |
| `scripts/gen-secrets.sh`          | Generate POSTGRES_PASSWORD only                      |
| `scripts/init-postgres.sh`        | `uuid-ossp` install + isolation check                |
| `scripts/restore-dump.sh`         | Aurora-filtered `pg_restore` into the local volume   |
| `scripts/upgrade-hop.sh`          | Single-hop image bump + validate + snapshot          |
| `scripts/validate.sh`             | Per-hop smoke test, appends to `hop-report.tsv`      |
| `scripts/check-tags.sh`           | Pre-flight: every pinned tag still exists on Hub     |
| `scripts/run-all-hops.sh`         | Stepped walk orchestrator                            |

Everything under `dumps/`, `data/`, `data-snapshots/`, `logs/`,
`hop-report.tsv`, and `.env` is gitignored.
