# Retool Local Dev Runbook -- 3.24.6 → 3.334.x Upgrade Dry-Run

Drive the prod upgrade entirely offline before touching real infra:
boot `tryretool/backend:3.24.6` against a restored Aurora dump, walk 8
stepped image upgrades to `3.334.15-stable`, log a row per hop to
`hop-report.tsv`.

> Local-only. No Terraform changes. No prod writes.

---

## Prerequisites

- **Docker Desktop** (macOS Apple Silicon or Intel). Allocate at least:
  - 8 GB RAM
  - 4 CPU
  - 50 GB disk for the postgres data dir + per-hop snapshots
  - Apple Silicon will run the linux/amd64 containers under emulation;
    expect **2-5× longer migrations** than on Intel.
- **AWS CLI** with credentials that can `ecs:ExecuteCommand` against
  the `overwatch-ecs` cluster (to extract prod secrets).
- **Aurora dump** (custom format) pulled from prod (see "Pulling a fresh
  dump from Aurora" below). Local-only, gitignored.
- **Free Retool license** from <https://my.retool.com>. Free keys do not
  expire and are not bound to the prod licence.
- `jq`, `curl`, `openssl`, `python3` on host PATH.

---

## Extract prod secrets (REQUIRED)

`ENCRYPTION_KEY` and `JWT_SECRET` **MUST** come from a live prod ECS
task. The Aurora dump's encrypted columns (resource credentials, OAuth
refresh tokens, Vault entries) are encrypted with the prod
`ENCRYPTION_KEY`. Generating a fresh key locally corrupts every
encrypted value and produces a dry-run with invalid signal.

```sh
# 1. Find a running retool task.
aws ecs list-tasks --cluster overwatch-ecs --service-name overwatch-retool

# 2. Open a shell inside the task's retool container.
aws ecs execute-command \
  --cluster overwatch-ecs \
  --task <task-id-from-step-1> \
  --container retool \
  --interactive \
  --command "/bin/sh"

# 3. Inside the container -- read both env vars.
printenv ENCRYPTION_KEY JWT_SECRET
```

Copy both values into `local-dev/.env`. **Never log them, never commit
them, never paste them into Slack or a chat assistant.** Same values
used for the entire walk.

---

## License key boundary (DO NOT copy prod's)

The free Retool key at <https://my.retool.com> is the only correct
source. **Do NOT** copy the prod `LICENSE_KEY` from SSM
(`/overwatch/${stage}/RETOOL_LICENSE_KEY`):

- The prod licence's terms may prohibit cross-environment reuse.
- A second active instance under the same key counts against prod's
  seat allocation.
- Auditing prod licence activity becomes ambiguous.

If `EXPIRED-LICENSE-KEY-TRIAL` is sufficient for boot-only testing
(no UI use), that string also works -- but you cannot exercise apps
or workflows.

---

## First-time setup

From the repo root:

```sh
cd local-dev

# 1. Seed .env from the template.
cp .env.example .env

# 2. Generate POSTGRES_PASSWORD (gen-secrets.sh refuses to touch
#    ENCRYPTION_KEY / JWT_SECRET -- those must be pasted from prod).
scripts/gen-secrets.sh

# 3. Paste prod ENCRYPTION_KEY + JWT_SECRET into .env
#    (see "Extract prod secrets" above).

# 4. Paste free LICENSE_KEY into .env.

# 5. Drop a fresh Aurora dump into dumps/ (see below).

# 6. Verify everything is in place.
scripts/check-prereqs.sh
```

`check-prereqs.sh` exits non-zero with a clear diagnostic until every
required value is populated and a dump file exists.

---

## Pulling a fresh dump from Aurora

The prod cluster lives inside the VPC. Pulling the dump needs network
access to the cluster endpoint.

1. AWS Console → RDS → Snapshots → create a manual snapshot of the
   prod Aurora cluster (or use the latest automated daily snapshot).
2. Restore the snapshot to a temporary RDS instance (`db.t4g.medium` is
   enough for a one-shot dump). Use a security group that lets you
   reach it from your bastion / SSM session host.
3. From a host with VPC access (bastion or
   `aws ssm start-session --target <instance-id>` with port forward):
   ```sh
   pg_dump --format=custom --no-owner --no-privileges \
     --host=<temp-restore-endpoint> \
     --username=retool \
     --dbname=hammerhead_production \
     --file=prod-$(date +%Y-%m-%d).dump
   ```
4. SCP the file to your laptop and place it under `local-dev/dumps/`.
   The directory is gitignored. **Never commit, never push, never
   upload to a paste service.**
5. Delete the temporary RDS restore once the dump is on your laptop.

---

## Aurora-specific dump content

Vanilla `postgres:14.6` refuses several Aurora-specific objects.
`restore-dump.sh` filters them via `pg_restore --list → grep -v →
--use-list`:

| Pattern stripped                         | Why                                |
|------------------------------------------|------------------------------------|
| `SCHEMA - aws_*`                         | AWS-managed namespaces             |
| `GRANT .* rdsadmin`, `GRANT .* rds_*`    | Aurora-only roles                  |
| `EXTENSION - aws_*`                      | Aurora-only extensions             |
| `EXTENSION - pg_buffercache`             | Available in Aurora; absent on community Postgres without contrib |

If the filter strips more than **50 lines** the restore aborts. Inspect
`logs/restore-<ts>.toc.raw` to see what unexpected Aurora content
appeared, decide whether to extend the filter or raise the threshold
with `--max-delta N`.

Override with `--skip-aurora-filter` only after you have manually
pre-stripped the dump.

---

## Running the walk

```sh
# Verify pinned Docker Hub tags still exist. (Retool occasionally pulls
# patches; this catches the failure mode before pulling images.)
scripts/check-tags.sh

# Walk all 8 hops end-to-end. Halts on first failure.
scripts/run-all-hops.sh
```

The walk:

1. Restores prod dump (already done in setup).
2. Boots `tryretool/backend:3.24.6` against the restored volume.
3. For each subsequent hop:
   - Pulls the new image.
   - Restarts api + jobs-runner (postgres volume persists).
   - Waits for `jobs-runner` to log migration completion.
   - Runs `validate.sh` -- HTTP `/api/checkHealth`, knex_migrations
     count, row-count spot checks.
   - Snapshots `data/` to `data-snapshots/<tag>/` on success (enables
     mid-walk resumption without re-restoring the dump).

Each hop appends one row to `hop-report.tsv`. Column meaning:

| column              | meaning                                          |
|---------------------|--------------------------------------------------|
| `ts_start/ts_end`   | UTC bounds of the hop's validate run             |
| `version`           | the tag the stack was just upgraded to           |
| `migration_seconds` | seconds from compose `up` to migration log line  |
| `status`            | `pass` / `fail`                                  |
| `knex_count`        | rows in `knex_migrations` after the hop          |
| `users_count` etc.  | row count in `users`, `apps`, `pages`, `resources` |
| `notes`             | semicolon-separated annotations (errors, warnings) |

The walk's **first failure** halts the script with state left intact for
inspection. Re-run with `--from <tag>` after fixing.

### The HOPS list

Pinned in `scripts/run-all-hops.sh` (latest stable of each line as of
2026-05-25, reconciled with live Docker Hub during Phase 7
implementation):

```
3.24.6
3.33.9-stable
3.114.28-stable
3.148.13-stable
3.196.33-stable      # code-executor service starts here
3.253.29-stable
3.284.30-stable
3.334.15-stable
```

Notes:

- `3.33.39-stable` (in the original plan) does not exist on Docker
  Hub. The 3.33 line only got 9 stable patches. Pinned to `3.33.9-stable`.
- `3.163` (in the original plan) was published only on Edge; no Stable
  release exists for that line. **The walk does 3.148 → 3.196 in one
  hop.** This is the largest gap in the sequence and the most likely
  place for a migration failure.
- `tryretool/code-executor-service` has no stable image before
  `3.196.0`. The walk does not add the service before that hop.

---

## Mid-walk failure recovery

Look at:

- `logs/hop-fail-<tag>.log` -- snapshot of api + jobs-runner logs.
- `docker compose logs jobs-runner` -- the live tail.
- `hop-report.tsv` -- the last `fail` row's `notes=` column.

### Fast path -- resume from snapshot

Use this when an earlier hop succeeded and you want to retry the
failing one without restoring the dump.

```sh
docker compose --env-file .env -f compose/compose.3-24.yml -p local-dev down -v
rm -rf data
cp -R data-snapshots/<last-green-tag> data

scripts/run-all-hops.sh --from <failing-tag>
```

`run-all-hops.sh --from` looks up the preceding green hop in HOPS and
restores from its snapshot automatically -- the manual `cp -R` above is
only needed if `--from` cannot find the snapshot.

### Full reset -- back to dump

Use this when snapshots are unusable or you want a clean baseline.

```sh
docker compose --env-file .env -f compose/compose.3-24.yml -p local-dev down -v
scripts/restore-dump.sh --dump dumps/prod-<date>.dump
scripts/run-all-hops.sh
```

---

## Rollback story (for the eventual prod cutover plan)

Retool publishes no documented rollback path. Recovery is:

1. **Restore Postgres** to a known-good snapshot. In prod that is
   Aurora PITR within the 35-day retention window
   (`modules/aws_ecs_fargate/rds.tf:63`).
2. **Redeploy the previous image tag** via Terraform image-pin
   (`main.tf:23`) + `tf apply`.

Locally we test this story by walking back: after reaching
`3.334.x`, run

```sh
docker compose --env-file .env -f compose/compose.3-24.yml -f compose/compose.3-196.yml -p local-dev down -v
scripts/restore-dump.sh --dump dumps/prod-<date>.dump
scripts/upgrade-hop.sh --to 3.24.6
```

A successful return to the 3.24.6 baseline proves the prod recovery
sequence is achievable end-to-end.

---

## After the walk

Fill in `thoughts/research/YYYY-MM-DD-retool-upgrade-dryrun-results.md`
(template scaffolded in `thoughts/research/`) before the prod cutover
plan is written. The findings doc captures per-hop migration duration,
warnings encountered, sandbox flag reconciliation, and pinned target
versions for the prod cutover.

## References

- `thoughts/plans/2026-05-25-retool-local-dev-env.md`
- `thoughts/research/2026-05-25-retool-local-dev-env.md`
- `thoughts/research/2026-05-22-retool-upgrade-3-24-to-latest.md`
- `main.tf:23` -- prod image pin
- `modules/aws_ecs_fargate/loadbalancers.tf:46-54` -- prod ALB health endpoint
- <https://docs.retool.com/self-hosted/concepts/update-deployment>
- <https://docs.retool.com/self-hosted/guides/code-executor-security-privileges>
- <https://hub.docker.com/r/tryretool/backend/tags>
- <https://hub.docker.com/r/tryretool/code-executor-service/tags>
