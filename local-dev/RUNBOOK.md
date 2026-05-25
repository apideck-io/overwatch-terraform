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

---

## Extract prod secrets (REQUIRED -- short version, full in Phase 8)

`ENCRYPTION_KEY` and `JWT_SECRET` MUST come from a live prod ECS task. Generating fresh keys corrupts every encrypted column in the restored dump (resource credentials, OAuth refresh tokens, Vault entries become unreadable).

```sh
# Find a running retool task in the prod cluster
aws ecs list-tasks --cluster overwatch-ecs --service-name overwatch-retool

aws ecs execute-command \
  --cluster overwatch-ecs \
  --task <task-id> \
  --container retool \
  --interactive \
  --command "/bin/sh"

# Inside the container:
printenv ENCRYPTION_KEY JWT_SECRET
```

Paste both values into `local-dev/.env`. Same values used for the entire walk. **Never log, never commit, never paste into Slack.**

## Pulling a dump from Aurora (short version, full in Phase 8)

1. AWS Console -> RDS -> Snapshots -> snapshot the prod Aurora cluster.
2. Restore to a temporary RDS instance.
3. From a host with VPC access (bastion or `aws ssm start-session` + port forward):
   ```sh
   pg_dump --format=custom --no-owner --no-privileges \
     --host=<temp-restore-endpoint> \
     --username=retool \
     --dbname=hammerhead_production \
     --file=prod-$(date +%Y-%m-%d).dump
   ```
4. Move the dump to `local-dev/dumps/`. The directory is gitignored. **Never commit, never push, never upload to a paste service.**

## Aurora-specific dump content

Aurora dumps include AWS-specific objects vanilla `postgres:14.6` refuses:

- `SCHEMA - aws_*` (e.g. `aws_commons`)
- `GRANT .* rdsadmin`, `GRANT .* rds_*`
- `EXTENSION - aws_*`, `EXTENSION - pg_buffercache`

`restore-dump.sh` filters these via `pg_restore --list` -> `grep -v` -> `--use-list`. If the filter strips more than 50 lines, the script aborts and asks the operator to inspect `logs/restore-<ts>.toc.raw`. Pass `--max-delta N` to raise the threshold once unexpected content is reviewed.

Override with `--skip-aurora-filter` only if you have manually pre-stripped the dump.

## Mid-walk recovery (preview -- full in Phase 8)

If a hop fails:

1. Inspect `logs/hop-fail-<tag>.log` and `docker compose logs jobs-runner`.
2. Fast path -- restore from snapshot of last green hop (Phase 5 will create `data-snapshots/<tag>/`):
   ```sh
   docker compose --env-file .env -f compose/compose.3-24.yml down -v
   rm -rf data && cp -R data-snapshots/<last-green-tag>/ data/
   scripts/run-all-hops.sh --from <next-hop-after-last-green>
   ```
3. Full reset -- back to known-good dump state:
   ```sh
   docker compose --env-file .env -f compose/compose.3-24.yml down -v
   scripts/restore-dump.sh --dump dumps/prod-<date>.dump
   scripts/run-all-hops.sh
   ```

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
