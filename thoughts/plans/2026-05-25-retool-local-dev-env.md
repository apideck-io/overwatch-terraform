---
status: implemented
related_research:
  - thoughts/research/2026-05-25-retool-local-dev-env.md
  - thoughts/research/2026-05-22-retool-upgrade-3-24-to-latest.md
---

# Plan — Local Retool Dev Environment for 3.24.6 → 3.334.x Upgrade Dry-Run

## Pattern Decisions

The deliverable is a **runbook + scripted local stack inside this repo**, not feature code. TDD red/green/refactor cycles are reshaped into **boot/validate/promote** cycles per upgrade hop: write the smoke-validation script first (RED — fails against a stack that hasn't booted), boot the stack (GREEN — validation passes), then promote to next hop (REFACTOR — image bump, no logic change).

Decisions taken before planning (locked by user):

- **Data fidelity:** raw Aurora dump restored locally, strict local-only handling (never commit dump, never push).
- **Postgres image:** pin `postgres:14.6` to match prod Aurora 14.6 major.
- **Hop granularity:** full stepped path: `3.24.6 → 3.33 → 3.114 → 3.148 → 3.163 → 3.196 → 3.253 → 3.284 → 3.334`.
- **SSO:** skipped locally. `DISABLE_USER_PASS_LOGIN=false`, `TRIGGER_OAUTH_2_SSO_LOGIN_AUTOMATICALLY=false`. Bootstrap admin via email/password.

Decisions taken during plan verification (locked by iterate cycle):

- **`ENCRYPTION_KEY` + `JWT_SECRET`:** **never auto-generated locally**. Both pulled from a live prod ECS task via `aws ecs execute-command` and pasted into `local-dev/.env`. `gen-secrets.sh` refuses to touch them. Without prod's `ENCRYPTION_KEY`, the restored dump's encrypted columns (resource credentials, OAuth refresh tokens, Vault entries) become unreadable and the dry-run produces invalid signal.
- **`LICENSE_KEY`:** free key from `my.retool.com` only. Hard rail against copying the prod `LICENSE_KEY` from SSM.
- **Aurora dump filtering:** `pg_restore --list` → strip `aws_*` schemas, `rdsadmin`/`rds_*` grants, Aurora-only extensions → `--use-list`. Vanilla `postgres:14.6` refuses RDS-specific objects.
- **Image tag pinning:** specific patches pinned at plan time (latest stable of each line as of 2026-05-25). `check-tags.sh` verifies tags still exist on Docker Hub before walk starts.
- **Per-hop snapshots:** `data-snapshots/<tag>/` after each successful hop. Mid-walk failure resumes from last green hop instead of full dump restore.

Workspace lives under `local-dev/` at repo root. Everything in it is `.gitignore`d except templates and scripts.

## Overview

Stand up a self-contained local Retool stack on macOS that:

1. Boots `tryretool/backend:3.24.6` against a restored production Postgres dump (Aurora 14.6 → local `postgres:14.6`).
2. Walks through 8 stepped image upgrades up to `tryretool/backend:3.334.15-stable`, running migrations and validating boot at each hop.
3. Adds `tryretool/code-executor-service` at the hop that crosses `3.251` (the enforcement boundary).
4. Logs migration time, image, and validation result per hop for the eventual prod cutover plan.

Output is a `local-dev/` directory containing compose files, env templates, dump-restore tooling, a hop orchestrator script, and a runbook. No Terraform changes in this plan.

## Current State Analysis

**Repo state (commit `eeea98a`, branch `main`):**

- Image pin `tryretool/backend:3.24.6` at [main.tf:23](../../main.tf#L23).
- Module deploys two ECS services: `retool` (main) at [modules/aws_ecs_fargate/main.tf:31-50](../../modules/aws_ecs_fargate/main.tf#L31) and `jobs_runner` at [modules/aws_ecs_fargate/main.tf:52-63](../../modules/aws_ecs_fargate/main.tf#L52).
- Backed by Aurora PostgreSQL 14.6 at [modules/aws_ecs_fargate/rds.tf:1-4](../../modules/aws_ecs_fargate/rds.tf#L1), serverless v2 0.5–5 ACU, db `hammerhead_production`, 35-day backup retention.
- 35 env vars + 3 secrets cataloged in [thoughts/research/2026-05-25-retool-local-dev-env.md §3](../research/2026-05-25-retool-local-dev-env.md).
- No `local-dev/` directory exists. No docker-compose anywhere in repo. No local validation tooling.
- README upgrade procedure ([README.md:18-21](../../README.md#L18)) is image-bump + `tf apply`. No precedent for local dry-runs.

**Retool's local-dev stack (external):**

- `tryretool/retool-onpremise` master: 8-service compose + Temporal. Far more than prod needs.
- Period-correct compose for `3.24` era: commit `1dfa911` (March 2024), `docker-compose.yml`, `postgres:11.13`, separate `CodeExecutor.Dockerfile`, no Temporal/agents.
- `tryretool/code-executor-service` oldest stable tag: `3.196.0-stable`. No published image for `3.33`/`3.114`/`3.148`/`3.163`.

## Desired End State

After all phases:

- `local-dev/` contains compose templates, `.env.example`, `restore-dump.sh`, `validate.sh`, `upgrade-hop.sh`, `run-all-hops.sh`, and `RUNBOOK.md`.
- Running `local-dev/upgrade-hop.sh 3.24.6` from a fresh dump boots the stack and passes validation.
- Running `local-dev/run-all-hops.sh` walks every hop end-to-end and produces `local-dev/hop-report.tsv` with image, migration duration, validation pass/fail, and notes per hop.
- The walk reaches `3.334.15-stable` cleanly OR halts at the first failing hop with diagnostic output.
- `local-dev/RUNBOOK.md` documents prerequisites (Docker Desktop, dump file location, license key source), how to fetch a dump from Aurora, how to interpret hop reports, and the rollback story.
- `.gitignore` excludes `local-dev/.env`, `local-dev/dumps/`, `local-dev/data/`, `local-dev/data-snapshots/`, `local-dev/hop-report.tsv`, `local-dev/logs/`.

## What We're NOT Doing

- **No Terraform changes.** The eventual `code-executor` ECS service, image-pin bump, and module updates are a separate plan, written after this dry-run produces evidence.
- **No workflows / agents / Temporal containers.** Prod doesn't run them. Including them inflates the stack and obscures what fails.
- **No SSO testing locally.** Email/password admin bootstrap only.
- **No prod write-path testing.** Local stack is read-only mirror of prod schema/data. No license re-issuance, no SSO state mutation that touches prod.
- **No CI integration.** Hop runner is operator-driven, not automated.
- **No Edge channel.** Only Stable line images.
- **No `retooldb-postgres`** (the user-data DB Retool ships in compose). Prod doesn't use Retool DB; one less moving part locally.

## Implementation Approach

Eight phases. Each phase is independently committable. RED step writes/extends the validation script (Phase 2); GREEN step adds the compose/script/config that makes validation pass (Phase 3); REFACTOR consolidates env templates or extracts helpers. The hop-runner pattern emerges incrementally: dump restore in Phase 4, single-hop runner in Phase 5, code-executor wiring in Phase 6, multi-hop orchestrator in Phase 7, runbook in Phase 8.

Each phase produces a script or compose file in `local-dev/`. The runbook (Phase 8) is written last because the steps stabilize as earlier phases bake in.

---

## Phase 1 — Scaffold `local-dev/` workspace

**Goal:** create directory layout, `.gitignore` entries, env template, license key handling.

### Tasks

1. Create `local-dev/` with subdirs `compose/`, `scripts/`, `dumps/`, `data/`, `data-snapshots/`, `logs/`.
2. Add `local-dev/.env.example` covering all 35 env vars from research §3. Group: postgres, secrets, domain, OAuth2 (commented out), feature flags, service-type. Two env vars require explicit operator action and MUST NOT be auto-generated locally:
   - `ENCRYPTION_KEY` — comment: `# REQUIRED: paste live value from prod ECS task (see RUNBOOK § Extract prod secrets). Generating a fresh key corrupts every encrypted column in the restored dump.`
   - `JWT_SECRET` — comment: `# REQUIRED: paste live value from prod ECS task (see RUNBOOK). Mismatch invalidates existing sessions but does not corrupt data — still pull prod's for fidelity.`
   - `LICENSE_KEY` — comment: `# Get a free key from https://my.retool.com. DO NOT copy the prod LICENSE_KEY from SSM /overwatch/${stage}/RETOOL_LICENSE_KEY — license terms may prohibit cross-environment reuse.`
3. Add `local-dev/RUNBOOK.md` (stub — fill in Phase 8).
4. Append to repo `.gitignore`:
   ```
   local-dev/.env
   local-dev/dumps/
   local-dev/data/
   local-dev/data-snapshots/
   local-dev/logs/
   local-dev/hop-report.tsv
   ```
5. Add `local-dev/scripts/check-prereqs.sh`: verify Docker Desktop running, `docker compose` available, `.env` exists, `ENCRYPTION_KEY` and `JWT_SECRET` are populated (non-empty AND not equal to the literal placeholder strings from `.env.example`), dump file present in `dumps/`.

### Success Criteria

- `tree local-dev/ -L 2` shows the layout.
- `cp local-dev/.env.example local-dev/.env && local-dev/scripts/check-prereqs.sh` exits **non-zero** with a clear "ENCRYPTION_KEY/JWT_SECRET not populated — see RUNBOOK § Extract prod secrets" message. After operator pastes both values and adds a dump, the same command exits 0.
- `git status` shows only `local-dev/.env.example`, `local-dev/RUNBOOK.md`, `local-dev/scripts/check-prereqs.sh`, and `.gitignore` changes — no dumps, no `.env`, no data dir, no data-snapshots dir.

---

## Phase 2 — Validation script (RED)

**Goal:** smoke-test script that proves a running stack is functional. Written before stack boots — must fail against `nothing`.

### Tasks

1. `local-dev/scripts/validate.sh` accepts `--version <tag>` and runs the following checks. **Hard checks** (any failure → exit non-zero); **soft checks** (failure → log a `notes=` annotation but do not fail the run).

   **Hard checks** (stable across all 8 hops):
   - `docker compose ps --services --filter status=running` — both `api` and `jobs-runner` present (and `code-executor` for hops ≥ 3.196).
   - All running services exited 0 on their healthcheck path (`docker inspect --format='{{.State.Health.Status}}'`).
   - `curl -fsS http://localhost:3000/api/checkHealth` returns 200 (prod's ALB healthcheck per [modules/aws_ecs_fargate/loadbalancers.tf:46-54](../../modules/aws_ecs_fargate/loadbalancers.tf#L46)).
   - **`knex_migrations` row count delta**: read row count from previous hop's report line; current count must be **≥ previous**. Row count never decreases on a clean upgrade. Persist count in `hop-report.tsv`.
   - **Data row-count spot-check** (catches silent migration data loss): query `SELECT count(*) FROM users`, `apps`, `pages`, `resources`. Each must be **≥ previous hop's count** (Retool migrations never drop user-visible rows). On first hop, just record baseline.

   **Soft checks** (log to `notes=` field, do not fail):
   - `docker compose logs jobs-runner 2>&1 | grep -E "migration.*(complete|done|finished)"` — log-format wording varies across 2.5 years of releases; if it matches, record `migrations_logged=yes`, otherwise `migrations_logged=no`.
   - `docker compose logs api 2>&1 | grep -iE "(error|fatal|panic)"` — if non-empty, record `error_lines=<count>` for operator review; do not fail (false-positives high across versions).

2. Output structured TSV line appended to `local-dev/hop-report.tsv`:
   ```
   ts_start \t ts_end \t version \t migration_seconds \t status \t knex_count \t users_count \t apps_count \t pages_count \t resources_count \t notes
   ```

3. Exit non-zero on any **hard** check failure.

### Success Criteria

- Run against an empty workspace: `validate.sh --version test` exits non-zero with clear "container not running" diagnostic. **(RED — proves the script detects a broken stack.)**
- TSV header line written on first invocation; subsequent invocations append.

---

## Phase 3 — Period-correct compose for 3.24 boot (GREEN for Phase 2)

**Goal:** boot `tryretool/backend:3.24.6` against an empty `postgres:14.6`, prove validation passes.

### Tasks

1. `local-dev/compose/compose.3-24.yml` — minimal 3-service compose modelled on `retool-onpremise@1dfa911` but reduced to prod's 2-service topology:
   - `postgres`: `postgres:14.6`, volume `./data:/var/lib/postgresql/data`, env from `.env`, `command: ["postgres", "-c", "log_statement=ddl"]` (matches prod parameter group at [modules/aws_ecs_fargate/rds.tf:11-15](../../modules/aws_ecs_fargate/rds.tf#L11)), exposes 5432 on localhost.
   - `api`: `tryretool/backend:3.24.6`, `platform: linux/amd64` (mandatory on Apple Silicon), env from `.env`, `SERVICE_TYPE=MAIN_BACKEND,DB_CONNECTOR`, ports `3000:3000`, depends_on postgres, command `./docker_scripts/start_api.sh` (matches prod at [modules/aws_ecs_fargate/main.tf:142-144](../../modules/aws_ecs_fargate/main.tf#L142)).
   - `jobs-runner`: same image, `platform: linux/amd64`, `SERVICE_TYPE=JOBS_RUNNER`, no ports, depends_on postgres, command `./docker_scripts/start_api.sh`.
2. `local-dev/compose/compose.override.yml` — Apple Silicon overlay if needed (no-op on Intel).
3. `local-dev/scripts/init-postgres.sh` — runs `CREATE EXTENSION IF NOT EXISTS "uuid-ossp"` and confirms Read Committed isolation against the local postgres container. Required by Retool docs (research §3.1). Idempotent.
4. Update `.env.example` defaults: `POSTGRES_HOST=postgres`, `POSTGRES_SSL_ENABLED=false`, `POSTGRES_PORT=5432`, `POSTGRES_DB=hammerhead_production`, `POSTGRES_USER=retool`, `POSTGRES_PASSWORD=<generate-via-runbook>`, `JWT_SECRET=<256 chars>`, `ENCRYPTION_KEY=<64 chars>`, `LICENSE_KEY=<from-my.retool.com>`, `COOKIE_INSECURE=true`, `DISABLE_USER_PASS_LOGIN=false`, `TRIGGER_OAUTH_2_SSO_LOGIN_AUTOMATICALLY=false`, `BASE_DOMAIN=http://localhost:3000`, `DOMAINS=localhost -> http://api:3000`, `DATABASE_MIGRATIONS_TIMEOUT_SECONDS=1800` (raised from prod's 900 for stepped hops).
5. `local-dev/scripts/gen-secrets.sh` — one-shot generator for `POSTGRES_PASSWORD` only, using `openssl rand`. **Refuses to touch `ENCRYPTION_KEY` and `JWT_SECRET`** — those must be pasted from prod (see RUNBOOK Phase 8). If either is blank when `gen-secrets.sh` runs, exits non-zero with the same "see RUNBOOK § Extract prod secrets" message that `check-prereqs.sh` emits.
6. **Pre-flight empty-postgres smoke** (suggestion #1 from verification): before any dump work, the operator boots the stack against an empty `postgres:14.6` and runs `validate.sh --version 3.24.6-emptydb`. This proves Docker / Apple Silicon emulation / compose wiring is healthy, isolating environment failures from data-shape failures in Phase 4. The TSV row from this smoke is the baseline for Phase 4's row-count delta check (counts are 0 / signup-page only).

### Success Criteria

- `cd local-dev && docker compose -f compose/compose.3-24.yml up -d`.
- `scripts/init-postgres.sh` exits 0; `uuid-ossp` shown in `SELECT * FROM pg_extension`.
- After ~2 min: `scripts/validate.sh --version 3.24.6-emptydb` exits 0, appends a `status=pass` line to `hop-report.tsv`. Row counts recorded as baselines.
- `http://localhost:3000` loads Retool signup page; admin account creatable via email/password.
- `gen-secrets.sh` invoked with blank `ENCRYPTION_KEY` exits non-zero (proves the rail works).

---

## Phase 4 — Postgres dump restore tooling

**Goal:** swap the empty postgres volume for one restored from a production Aurora dump. After this phase, the same 3.24.6 stack boots against real prod schema+data **and can decrypt encrypted columns** because `.env` carries the live prod `ENCRYPTION_KEY`.

### Tasks

1. `local-dev/scripts/restore-dump.sh` accepts `--dump <path>` and runs in order:
   - **Pre-check `.env`**: hard-fail if `ENCRYPTION_KEY` or `JWT_SECRET` is blank or equal to the `.env.example` placeholder. Without prod's `ENCRYPTION_KEY`, every encrypted column (resource credentials, OAuth refresh tokens, Vault entries) in the restored dump becomes unreadable — the dry-run would produce **invalid signal**. Refuse to proceed.
   - Refuses to run if `local-dev/data/` is non-empty (prevents accidental clobber). On mid-walk failure, operator must `docker compose down -v` first — documented in RUNBOOK § Mid-walk recovery.
   - Stops compose: `docker compose -f compose/compose.3-24.yml down -v` (`-v` drops the postgres volume).
   - **Filter Aurora-specific objects from dump** before restore. Aurora dumps may include `aws_*` schemas, `rdsadmin` role grants, and Aurora-only extensions that fail on vanilla `postgres:14.6`. Steps:
     ```
     pg_restore --list <dump> > restore.toc.raw
     grep -vE "(SCHEMA - aws_|GRANT .* rdsadmin|GRANT .* rds_|EXTENSION - aws_|EXTENSION - pg_buffercache)" restore.toc.raw > restore.toc
     pg_restore --use-list=restore.toc --clean --if-exists --no-owner --no-privileges -d hammerhead_production <dump>
     ```
     Logs unfiltered vs filtered line counts; abort if delta > 50 (unexpected Aurora content needs operator review).
   - Runs `init-postgres.sh` to confirm `uuid-ossp`.
   - Logs to `local-dev/logs/restore-<timestamp>.log`.
2. `local-dev/RUNBOOK.md` — add sections (full content lands in Phase 8):
   - **Extract prod secrets** (NEW, required for blocker fix): step-by-step `aws ecs execute-command --cluster overwatch-ecs --task <task-id> --container retool --interactive --command "/bin/sh"` then `printenv ENCRYPTION_KEY JWT_SECRET`. Paste both into `local-dev/.env`. Same values used for entire walk.
   - **Pull a dump from Aurora**: AWS Console snapshot → restore to temporary RDS → `pg_dump --format=custom --no-owner --no-privileges --dbname=hammerhead_production` from a host with VPC access (bastion or `aws ssm start-session` + port forward). `dumps/` is gitignored — **never commit, never push**.
   - **Aurora-specific dump content**: known objects filtered (`aws_*` schemas, `rdsadmin`/`rds_*` grants, Aurora extensions). If `restore-dump.sh` reports filter delta > 50, inspect `restore.toc.raw` for unfamiliar Aurora objects before proceeding.

### Success Criteria

- `restore-dump.sh --dump dumps/prod-2026-05-25.dump` exits 0.
- Running `restore-dump.sh` with blank `ENCRYPTION_KEY` exits non-zero before touching the volume.
- `docker compose -f compose/compose.3-24.yml up -d` against restored volume.
- `validate.sh --version 3.24.6-restored` passes — Retool boots, login works with an existing prod user via email/password (or admin row inserted per RUNBOOK).
- `docker compose exec postgres psql -U retool -d hammerhead_production -c "SELECT count(*) FROM users"` returns prod's user count.
- **Encryption check**: open an existing Retool app that uses a database resource; confirm the resource loads (proves `ENCRYPTION_KEY` correctly decrypts credentials). If resources show `decryption failed`, abort — the pasted `ENCRYPTION_KEY` is wrong.

---

## Phase 5 — Single-hop upgrade runner

**Goal:** script that bumps the image to a target tag, restarts the stack, waits for jobs-runner migrations, runs validation, snapshots the postgres volume on success.

### Tasks

1. `local-dev/scripts/upgrade-hop.sh` accepts `--to <tag>` and:
   - Writes `RETOOL_VERSION=<tag>` to `.env` (sed-replace).
   - `docker compose -f compose/compose.3-24.yml pull` (idempotent).
   - `docker compose -f compose/compose.3-24.yml up -d` — restarts api + jobs-runner with new image, postgres volume persists.
   - Polls `docker compose logs jobs-runner` for migration completion or timeout (read from `DATABASE_MIGRATIONS_TIMEOUT_SECONDS` + 60s buffer).
   - On migration completion: runs `validate.sh --version <tag>`.
   - **On successful validation**: snapshot postgres volume — `docker compose stop postgres && cp -R data/ data-snapshots/<tag>/ && docker compose start postgres`. Enables mid-walk failure resumption (suggestion #3 from verification). Disk cost: prod DB size × N successful hops; operator may prune older snapshots manually.
   - On timeout or validation failure: dump logs to `logs/hop-fail-<tag>.log` and exit non-zero. Volume left intact for inspection.
2. Compose now reads image from env: change `image: tryretool/backend:3.24.6` to `image: tryretool/backend:${RETOOL_VERSION}` in `compose.3-24.yml` for both `api` and `jobs-runner`.
3. Add `--skip-snapshot` flag for operators who want to save disk and trust the dump-restore recovery path instead.

### Success Criteria

- Starting from a 3.24.6 stack (Phase 4 state), running `upgrade-hop.sh --to 3.33.39-stable` completes.
- `hop-report.tsv` shows two rows: `3.24.6 pass` and `3.33.39-stable pass` with row-count deltas populated.
- `local-dev/data-snapshots/3.33.39-stable/` exists and contains the postgres data dir.
- Login still works with existing prod users; resources still decrypt.
- Idempotent: running `upgrade-hop.sh --to 3.33.39-stable` a second time is a no-op (image already current, snapshot already exists — script detects and skips).

---

## Phase 6 — Add `code-executor` at the 3.196 hop

**Goal:** introduce the separate `code-executor` container at the boundary where Retool starts publishing `tryretool/code-executor-service` images. Required for hops `3.253+`.

### Tasks

1. `local-dev/compose/compose.3-196.yml` — extends `compose.3-24.yml` (via `extends:` or a second `-f`) with:
   - `code-executor` service: `tryretool/code-executor-service:${RETOOL_VERSION}`, `platform: linux/amd64`, env `IGNORE_CODE_EXECUTOR_STARTUP_CHECK=true`, `DISABLE_IPTABLES_SECURITY_CONFIGURATION=true`, `CONTAINER_UNPRIVILEGED_MODE=true`, `ALLOW_UNSAFE_CODE_EXECUTION=true` (research §3.6 notes both flag names appear in Retool's own materials; set both for safety).
   - On `api` service: env `CODE_EXECUTOR_INGRESS_DOMAIN=http://code-executor:3004`, `WORKFLOW_BACKEND_HOST=http://api:3000` (matches install.sh defaults).
2. `upgrade-hop.sh` learns a `--compose <file>` flag (or auto-selects compose file based on target version: `<3.196` → `compose.3-24.yml`, `>=3.196` → `compose.3-196.yml`).
3. Extend `validate.sh` to additionally check (on `compose.3-196.yml`): `docker compose ps code-executor` running.

### Success Criteria

- Hop `3.163.x → 3.196.x` switches compose file mid-walk: tear down old compose (`down` without `-v` — preserve postgres volume), bring up new compose with same `.env`.
- `validate.sh --version 3.196.x` passes; `code-executor` container running.
- Postgres volume not touched (verified via `docker volume inspect`).
- Test code execution in Retool UI (paste a JS code block in a test app) returns expected output — confirms `code-executor` is wired.

---

## Phase 7 — Stepped walk orchestrator

**Goal:** drive all 8 hops in sequence with a single command, halt cleanly on first failure.

### Tasks

1. `local-dev/scripts/run-all-hops.sh` — declares the hop list as an array. Patches **pinned at plan time** (latest of each line as of 2026-05-25 per research §7). Operator must verify each tag still exists on https://hub.docker.com/r/tryretool/backend/tags before invoking `run-all-hops.sh` and bump any patch that's been superseded (Retool sometimes pulls patches).
   ```bash
   HOPS=(
     "3.24.6"
     "3.33.39-stable"
     "3.114.28-stable"
     "3.148.13-stable"
     "3.163.39-stable"
     "3.196.33-stable"   # compose switch happens here (code-executor on)
     "3.253.29-stable"
     "3.284.30-stable"
     "3.334.15-stable"
   )
   ```
2. `local-dev/scripts/check-tags.sh` (NEW) — pre-flight that queries `https://hub.docker.com/v2/repositories/tryretool/backend/tags?page_size=100&name=<line>` via curl, parses with `jq`, confirms each pinned tag in `HOPS` still exists. Run automatically at start of `run-all-hops.sh`; exits non-zero if any tag is gone.
3. For each hop: call `upgrade-hop.sh --to <tag>`. On failure: print last 200 lines of `jobs-runner` log, exit non-zero, leave state intact for inspection.
4. After successful walk: print summary table from `hop-report.tsv`.
5. `--from <tag>` flag to resume from a specific hop (skips earlier ones AND restores postgres volume from `data-snapshots/<previous-tag>/` if present — wires suggestion #3).
6. `--dry-run` flag to print the hop sequence + tag-existence status without executing.

### Success Criteria

- `check-tags.sh` exits 0 with all 9 tags listed as "exists".
- `run-all-hops.sh` from a freshly restored 3.24.6 stack walks all 8 hops to `3.334.15-stable`.
- `hop-report.tsv` shows 10 rows (emptydb baseline + restored + 8 hops), all `status=pass` with row-count deltas non-negative.
- Total migration duration logged per hop; outliers (>5 min) flagged in summary.
- Login still works with original prod users after `3.334.x` reached; resources decrypt.
- `--from 3.196.33-stable` resumes correctly: restores postgres from `data-snapshots/3.163.39-stable/`, then runs only 3.196 → 3.334 hops.

---

## Phase 8 — Runbook + rollback procedure + findings doc

**Goal:** write the operator-facing documentation that makes the dry-run reproducible, AND emit a findings doc that captures the walk's results for the eventual prod cutover plan.

### Tasks

1. Flesh out `local-dev/RUNBOOK.md` with these sections:
   - **Prerequisites:** Docker Desktop (allocate ≥8GB RAM, ≥4 CPU), free Retool license from `my.retool.com`, fresh Aurora dump in `dumps/`, Apple Silicon vs Intel notes (Apple Silicon: emulation slow, expect 2-5× longer migrations).
   - **Extract prod secrets** (resolves verification blocker #1): step-by-step
     ```
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
   - **License key boundary** (resolves verification warning #3): use a free key from https://my.retool.com. **DO NOT** copy the prod `LICENSE_KEY` from SSM `/overwatch/${stage}/RETOOL_LICENSE_KEY` — license terms may prohibit cross-environment reuse and the local instance would count against prod's seat allocation.
   - **First-time setup:** `gen-secrets.sh` (generates `POSTGRES_PASSWORD` only), copy `.env.example` to `.env`, paste prod secrets, paste free license, place dump in `dumps/`, run `check-prereqs.sh`.
   - **Pulling a fresh dump from Aurora:** AWS Console snapshot → restore to temporary RDS instance → `pg_dump --format=custom --no-owner --no-privileges --dbname=hammerhead_production` from a host with VPC access (bastion or `aws ssm start-session` + port forward). Reference [research §3.4](../research/2026-05-25-retool-local-dev-env.md).
   - **Aurora-specific dump content** (resolves verification warning #1): known filtered objects (`aws_*` schemas, `rdsadmin`/`rds_*` grants, Aurora-only extensions). If `restore-dump.sh` reports filter delta > 50 lines, inspect `restore.toc.raw` before proceeding.
   - **Running the walk:** `check-tags.sh` first, then `run-all-hops.sh`; how to read `hop-report.tsv`; what row-count deltas mean.
   - **Mid-walk failure recovery** (resolves verification warning #6): inspect `logs/hop-fail-<tag>.log` and `docker compose logs jobs-runner`. Two recovery paths:
     1. **Fast path** — restore from snapshot of last green hop:
        ```
        docker compose down -v
        rm -rf data && cp -R data-snapshots/<last-green-tag>/ data/
        run-all-hops.sh --from <next-hop-after-last-green>
        ```
     2. **Full reset** — back to known-good dump state:
        ```
        docker compose down -v
        restore-dump.sh --dump dumps/prod-<date>.dump
        run-all-hops.sh
        ```
   - **Rollback story:** Retool has no documented rollback. Recovery = restore Postgres backup + redeploy old image tag. In prod this is Aurora PITR (35-day window per [modules/aws_ecs_fargate/rds.tf:63](../../modules/aws_ecs_fargate/rds.tf#L63)) + Terraform image-pin bump back. Per [research §Rollback](../research/2026-05-22-retool-upgrade-3-24-to-latest.md).
2. After the dry-run completes, write findings to a new file `thoughts/research/YYYY-MM-DD-retool-upgrade-dryrun-results.md` (resolves verification warning #5). Content:
   - Sanitized copy of `hop-report.tsv` (no row counts that leak PII shape — round to nearest 100).
   - Per-hop notes: migration duration, warnings encountered, whether `DATABASE_MIGRATIONS_TIMEOUT_SECONDS=1800` was sufficient, anything operator had to fix mid-walk.
   - Resolutions for the 8 Open Questions from [research §Open Questions](../research/2026-05-25-retool-local-dev-env.md#open-questions): `ENCRYPTION_KEY` source (confirmed extraction path works), `uuid-ossp` presence (verified), license-key boundary (free key worked), migration timeout sufficiency, sandbox flag-name reconciliation (`ALLOW_UNSAFE_CODE_EXECUTION` vs `CONTAINER_UNPRIVILEGED_MODE` — which actually mattered), ARM emulation overhead (duration multiplier observed), Postgres `14.6` vs Aurora 14.6 edge cases.
   - **Recommendations for prod cutover plan** (the eventual successor to this plan): pinned target tag, prod-equivalent `DATABASE_MIGRATIONS_TIMEOUT_SECONDS` value, code-executor ECS service shape, whether `nsjail` vs unprivileged mode runs on Fargate.
3. Add `local-dev/README.md` (short, ≤30 lines) pointing at `RUNBOOK.md` and noting `local-dev/` is for dry-run testing only — not production.

### Success Criteria

- A teammate following `RUNBOOK.md` from scratch (with a fresh dump + prod secret extraction access) reproduces a successful walk without further questions.
- `thoughts/research/YYYY-MM-DD-retool-upgrade-dryrun-results.md` exists with sanitized hop report and Open Question resolutions.
- All 8 Open Questions from [research §Open Questions](../research/2026-05-25-retool-local-dev-env.md#open-questions) have a "resolved during dry-run: [answer]" or "still open: [follow-up needed]" entry in the findings doc.
- `RUNBOOK.md` references both research docs by relative path.
- `RUNBOOK.md` explicit "DO NOT copy prod LICENSE_KEY" + "ENCRYPTION_KEY/JWT_SECRET must come from live prod task" rails present.

---

## Testing Strategy

This plan has no unit tests — the deliverable is a shell-driven stack. The validation layer is:

- **Per-hop validation:** `validate.sh` runs after every image swap. Failure halts the walk.
- **End-to-end validation:** the full walk from `3.24.6` → `3.334.15-stable` against a real prod dump constitutes the integration test.
- **Manual UI smoke:** at the final hop, log in as a prod user, open one existing app, confirm it renders. Documented in `RUNBOOK.md`.
- **Rollback validation:** after reaching `3.334.x`, run `docker compose down -v && restore-dump.sh && upgrade-hop.sh --to 3.24.6` and confirm the original state is recoverable.

Out of scope: workflows execution, agents, Temporal interactions — those services aren't deployed in prod and aren't local.

## References

### Research

- [thoughts/research/2026-05-25-retool-local-dev-env.md](../research/2026-05-25-retool-local-dev-env.md) — env var catalog, compose layouts, macOS specifics, code-executor flags.
- [thoughts/research/2026-05-22-retool-upgrade-3-24-to-latest.md](../research/2026-05-22-retool-upgrade-3-24-to-latest.md) — version landscape, breaking changes, prod topology.

### Production Terraform

- [main.tf:23](../../main.tf#L23) — current image pin.
- [main.tf:34-86](../../main.tf#L34) — additional_env_vars source of truth.
- [modules/aws_ecs_fargate/locals.tf:2-46](../../modules/aws_ecs_fargate/locals.tf#L2) — core env vars.
- [modules/aws_ecs_fargate/main.tf:65-194](../../modules/aws_ecs_fargate/main.tf#L65) — both task definitions.
- [modules/aws_ecs_fargate/secrets.tf](../../modules/aws_ecs_fargate/secrets.tf) — generated JWT_SECRET, ENCRYPTION_KEY, POSTGRES_PASSWORD.
- [modules/aws_ecs_fargate/rds.tf:1-15](../../modules/aws_ecs_fargate/rds.tf#L1) — Aurora 14.6 + parameter group.
- [modules/aws_ecs_fargate/loadbalancers.tf:46-54](../../modules/aws_ecs_fargate/loadbalancers.tf#L46) — `/api/checkHealth` health endpoint.

### External

- https://github.com/tryretool/retool-onpremise (master `compose.yaml`)
- https://github.com/tryretool/retool-onpremise/blob/1dfa911/docker-compose.yml (period-correct 3.24 era)
- https://hub.docker.com/r/tryretool/backend/tags
- https://hub.docker.com/r/tryretool/code-executor-service/tags
- https://docs.retool.com/self-hosted/concepts/update-deployment
- https://docs.retool.com/self-hosted/guides/code-executor-security-privileges
- https://community.retool.com/t/successfully-running-retool-on-premise-on-apple-silicon-with-rancher-desktop-architecture-compatibility-issue/62058
