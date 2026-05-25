# Retool Local Dev Runbook

> **Stub** -- full content lands in Phase 8.
> Goal: walk `tryretool/backend:3.24.6` -> `3.334.15-stable` against a restored prod Aurora dump, log per-hop validation to `hop-report.tsv`.

## Sections (filled in Phase 8)

- Prerequisites (Docker Desktop, dump, license)
- Extract prod secrets (`aws ecs execute-command` -> `printenv ENCRYPTION_KEY JWT_SECRET`)
- License key boundary (free key from `my.retool.com`, **never** copy prod's)
- First-time setup
- Pulling a fresh dump from Aurora
- Aurora-specific dump content (filter `aws_*`, `rdsadmin`, Aurora extensions)
- Running the walk
- Mid-walk failure recovery (snapshot path / full-reset path)
- Rollback story

## Quick start (rough sketch)

```sh
cd local-dev
cp .env.example .env
scripts/gen-secrets.sh                 # generates POSTGRES_PASSWORD only
# Then: paste ENCRYPTION_KEY + JWT_SECRET from prod ECS task (see Phase 8 docs).
# Then: paste free LICENSE_KEY from https://my.retool.com.
# Then: place fresh prod dump in dumps/.
scripts/check-prereqs.sh               # verifies env + dump + docker
scripts/restore-dump.sh --dump dumps/prod-YYYY-MM-DD.dump
scripts/check-tags.sh                  # verifies pinned Docker Hub tags still exist
scripts/run-all-hops.sh                # walks all 8 hops, writes hop-report.tsv
```
