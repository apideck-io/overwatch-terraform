---
date: '2026-05-22 16:15:40 +01'
researcher: 'Samir AMZANI'
git_commit: 'eeea98ace0c9fe5c4d0bfceb6ea868336f6ea649'
branch: 'main'
topic: "Retool self-hosted upgrade from 3.24.6 to latest"
tags: [research, retool, upgrade, terraform, ecs-fargate, self-hosted]
status: complete
---

# Retool Self-Hosted Upgrade: 3.24.6 → Latest

## Research Question

> We want to upgrade Retool to the latest version. Current version is 3.24.6 (Docker image `tryretool/backend:3.24.6`). The user believes latest is 3.30.0 or 3.33.4. What is the actual impact of the upgrade? Can it be done safely? What is the recommended approach?
>
> Reference: https://docs.retool.com/self-hosted/self-managed/concepts/update-deployment

## Summary

The upgrade premise has a versioning misunderstanding. Retool self-hosted versions look like `MAJOR.MINOR.PATCH` where `MAJOR.MINOR` is one release line. The release line numbers `3.24`, `3.33`, `3.114`, `3.300`, `3.334` are distinct lines — `3.33` is NOT close to `3.334`. They are nearly two years apart.

Current state (2026-05-22):

- **Repo image pin:** `tryretool/backend:3.24.6` ([main.tf:23](../../main.tf#L23))
- **Default in module variable:** `tryretool/backend:2.69.18` ([modules/aws_ecs_fargate/variables.tf:85](../../modules/aws_ecs_fargate/variables.tf#L85))
- **Latest Stable on Docker Hub:** `tryretool/backend:3.334.15-stable` (released ~2 days ago)
- **Supported Stable lines (six-month window each):** `3.334` (Mar 3 2026), `3.300` (Dec 3 2025), `3.284` (Oct 21 2025)
- **`3.33.x`** is from February 2024 — **first ever Stable release**, no longer supported
- **`3.24.x`** is from late 2023 — pre-Stable channel ("legacy"), unsupported

The Retool docs say *"if your current version is more than 10 versions behind, upgrade incrementally."* Going `3.24` → `3.334` crosses that bar by a huge margin: ~310 MINOR-line increments and ~2.5 years of changes.

Three discrete breaking-change events sit between current and latest, and at least one (the `code-executor` mandatory container at `3.251`) requires a new ECS service that the current Terraform does not provision:

1. **PgBouncer statement_timeout handling** introduced at `3.33` (Feb 2024). N/A here — no PgBouncer in the stack (direct RDS Aurora).
2. **Backend runtime upgraded to Node.js v20.18** at `3.163` (Apr 2025). No operator action documented.
3. **`code-executor` becomes a required separate container** at `3.251` (Aug/Sept 2025). The user's current Terraform has no `code-executor` ECS service.

Additional facts that matter for this specific deployment:

- The repo runs **2 ECS Fargate services** (`retool` main + `jobs_runner`) — no workflows/agents/code-executor.
- Aurora Postgres 14.6 — above documented minimum (Postgres 13.7); supported.
- No rollback procedure is documented by Retool; recovery means restoring the Postgres backup + redeploying old image tag.
- `DATABASE_MIGRATIONS_TIMEOUT_SECONDS` already set to `900` ([main.tf:83-84](../../main.tf#L83)) — above Retool's default of `0`, but the docs do not name `900` (or any number) as canonical.
- `jobs_runner` must remain a single task. It runs the migration. Current ECS service has `desired_count = 1` ([modules/aws_ecs_fargate/main.tf:55](../../modules/aws_ecs_fargate/main.tf#L55)) — already correct.

## Detailed Findings

### Current deployment topology

- **Module:** `./modules/aws_ecs_fargate` (root [main.tf:9](../../main.tf#L9))
- **ECS cluster:** `overwatch-ecs`, capacity provider FARGATE only ([modules/aws_ecs_fargate/main.tf:11-24](../../modules/aws_ecs_fargate/main.tf#L11))
- **Services:**
  - `aws_ecs_service.retool` — runs `MAIN_BACKEND,DB_CONNECTOR` ([modules/aws_ecs_fargate/main.tf:31-50](../../modules/aws_ecs_fargate/main.tf#L31), env at [main.tf:168](../../modules/aws_ecs_fargate/main.tf#L168))
  - `aws_ecs_service.jobs_runner` — runs `JOBS_RUNNER`, `desired_count = 1` ([modules/aws_ecs_fargate/main.tf:52-63](../../modules/aws_ecs_fargate/main.tf#L52))
- **Task sizes:**
  - main: `cpu = 2048`, `memory = 4096` ([modules/aws_ecs_fargate/main.tf:131-132](../../modules/aws_ecs_fargate/main.tf#L131))
  - jobs runner: `cpu = 512`, `memory = 1024` ([modules/aws_ecs_fargate/main.tf:71-72](../../modules/aws_ecs_fargate/main.tf#L71))
- **DB:** Aurora PostgreSQL **14.6** ([modules/aws_ecs_fargate/rds.tf:1-4](../../modules/aws_ecs_fargate/rds.tf#L1)), Serverless v2 `0.5–5 ACU`, db name `hammerhead_production`, backup retention 35 days
- **Secrets:** `LICENSE_KEY` (SSM `/overwatch/${stage}/RETOOL_LICENSE_KEY`), `RETOOL_EXPOSED_MANAGEMENT_API_KEY` from Unify API gateway key, `CUSTOM_OAUTH2_SSO_CLIENT_SECRET`
- **Auth:** Google OAuth2 SSO (`CUSTOM_OAUTH2_SSO_*` env vars at [main.tf:55-81](../../main.tf#L55)), `RESTRICTED_DOMAIN=apideck.com`, `TRIGGER_OAUTH_2_SSO_LOGIN_AUTOMATICALLY=true`, `DISABLE_USER_PASS_LOGIN=true`
- **Terraform:** AWS provider `~> 4.0`, Terraform `>= 0.13` ([terraform.tf:18-37](../../terraform.tf#L18))
- **Image pin:** hardcoded `tryretool/backend:3.24.6` at root ([main.tf:23](../../main.tf#L23)); module default is the much older `2.69.18` ([modules/aws_ecs_fargate/variables.tf:85](../../modules/aws_ecs_fargate/variables.tf#L85))

**Containers NOT deployed** by this Terraform (compared to documented Retool architecture):

- `workflows-backend` (SERVICE_TYPE=`WORKFLOW_BACKEND`)
- `workflows-worker` (SERVICE_TYPE=`WORKFLOW_TEMPORAL_WORKER`)
- `code-executor` (separate image `tryretool/code-executor-service`, not a SERVICE_TYPE)
- `agent-worker` (SERVICE_TYPE=`AGENT_TEMPORAL_WORKER`)
- `agent-eval-worker` (SERVICE_TYPE=`AGENT_EVAL_TEMPORAL_WORKER`)
- Temporal cluster (external dependency for workflows + agents)

### Version landscape (verified 2026-05-22)

| Release line | Date | Channel | Support state | Notes |
|---|---|---|---|---|
| `2.69.18` | mid-2023 | pre-Stable | EOL | Module default; not in use at root |
| `3.24.x` | late 2023 | pre-Stable ("legacy") | EOL | **Currently deployed (3.24.6)** |
| `3.33.x` | Feb 27 2024 | **first Stable release** | EOL (support window expired) | What user mistook for latest |
| `3.114.x` | mid 2024 | Stable | EOL | samlify SAML fix landed at `3.114.24` |
| `3.148.x` | late 2024 | Stable | EOL | samlify SAML fix landed at `3.148.13` |
| `3.163.x` | Apr 30 2025 | Stable | EOL | **Node.js v20.18 backend runtime** |
| `3.251.x` | Aug/Sept 2025 | Stable | EOL | **`code-executor` becomes required container** |
| `3.284.x` | Oct 21 2025 | Stable | supported (six months) | |
| `3.300.x` | Dec 3 2025 | Stable | supported (six months) | |
| **`3.334.x`** | **Mar 3 2026** | **Stable** | **current latest, supported** | Latest tag `3.334.15-stable`, also `3.334.15-stable-hardened` (multi-arch amd64+arm64) |
| `3.391.0-edge` | 2026 | Edge | latest Edge only | Weekly cadence |

Release-channel rules (from [docs.retool.com/self-hosted/release-notes](https://docs.retool.com/self-hosted/release-notes)):

- **Stable**: quarterly, supported for 6 months, ~4 versions behind cloud at release time.
- **Edge**: weekly, only the latest Edge is supported.
- **No LTS channel** documented.
- **Cross-channel switches** (Edge→Stable, Stable→Edge) "risk regression or loss of functionality" per Retool.
- Tag suffix `-stable` introduced at `3.33`; `3.24.x` tags lack it.
- Image tag for current deployment: switch from bare `3.24.6` to suffixed `3.334.15-stable` (or chosen target) when upgrading.

### Breaking changes between 3.24.6 and 3.334.x

Documented hard-edges (sources cited):

1. **PgBouncer `statement_timeout` startup parameter** — required from `3.33` Stable (Feb 27 2024). Upgrade migrations introduced default statement timeouts; PgBouncer must include `ignore_startup_parameters = statement_timeout` or migration fails. Source: https://docs.retool.com/changelog/pgbouncer-ignore-statement-timeout. **Not applicable** here — the Terraform uses direct Aurora Postgres connection, no PgBouncer.
2. **Backend runtime: Node.js 18.17 → 20.18** at release line `3.163` (Apr 30 2025). No operator action documented; container ships with the runtime. Source: https://docs.retool.com/changelog/runtime-node-20-18.
3. **`code-executor` becomes a required separate container** at release line `3.251` (Aug/Sept 2025). Image: `tryretool/code-executor-service`. By default uses `nsjail` sandboxing. Source: https://docs.retool.com/changelog/code-executor-required. **Applies** here — current Terraform has no `code-executor` ECS service or task definition.
4. **samlify SAML login bug** — patches in `3.114.24` and `3.148.13`. Not applicable (Google OAuth2 SSO used, not SAML).
5. **MS SQL Server v1/v2 source deprecation** — announced for Q3 2026 Stable. Not applicable (no MSSQL resources known).
6. **`LICENSE_KEY` required for multiplayer** — announced for Q3 2026. The repo already supplies `LICENSE_KEY` as a container secret ([modules/aws_ecs_fargate/main.tf:117-120](../../modules/aws_ecs_fargate/main.tf#L117)).

Per-version notes between `3.25` and `3.32` were not published as standalone changelog pages (Stable channel didn't exist yet). Per-version notes between `3.34` and `3.333` exist but were not exhaustively enumerated — Retool ships several hundred MINOR releases per year and the docs are organized by year (`/releases/stable/2024`, `/releases/stable/2025`, `/releases/stable/2026`).

### Required upgrade actions

From [docs.retool.com/self-hosted/self-managed/concepts/update-deployment](https://docs.retool.com/self-hosted/self-managed/concepts/update-deployment):

1. **Back up the Postgres database** before upgrading. Aurora point-in-time-recovery counts. Current setup has `backup_retention_period = 35` days ([modules/aws_ecs_fargate/rds.tf:63](../../modules/aws_ecs_fargate/rds.tf#L63)).
2. **Preserve `ENCRYPTION_KEY` and `USE_GCM_ENCRYPTION`** exactly. The current Terraform generates `JWT_SECRET` via `aws_secretsmanager_secret` ([modules/aws_ecs_fargate/secrets.tf:35](../../modules/aws_ecs_fargate/secrets.tf#L35)); `ENCRYPTION_KEY` and `USE_GCM_ENCRYPTION` were not located in the repo and may be auto-set inside the image or set elsewhere — verify before upgrading.
3. **Upgrade incrementally if more than 10 versions behind.** `3.24` → `3.334` crosses this threshold.
4. **Sandbox test recommended** when current version is "2+ months old". Current `3.24.6` is ~2.5 years old.
5. **`jobs-runner` must not be replicated.** Already true here (`desired_count = 1` at [modules/aws_ecs_fargate/main.tf:55](../../modules/aws_ecs_fargate/main.tf#L55)).
6. **`DATABASE_MIGRATIONS_TIMEOUT_SECONDS`** — Retool: *"set a higher value if you're upgrading to another major version… or… changes from multiple minor versions."* Currently `900` ([main.tf:83](../../main.tf#L83)). Default in docs is `0`. Docs name no canonical number.
7. **Sandbox env-var overrides** if a temporary instance shares Temporal task queues with prod: `TEMPORAL_TASKQUEUE_WORKFLOW=sandbox-test`, `WORKER_TEMPORAL_TASKQUEUE=sandbox-test`. Not applicable (no Temporal/workflows containers deployed).

### Rollback

Retool docs contain no rollback section. The update-deployment pages do not use the words "rollback", "downgrade", or "revert." Implicit recovery path: restore the pre-upgrade Postgres backup and redeploy the previous image tag. Aurora PITR (35-day retention) supports this.

### Postgres compatibility

- **Documented minimum:** PostgreSQL 13.7. Current Aurora Postgres **14.6** is above the minimum.
- **Required extension:** `uuid-ossp` (must be enabled).
- **Required isolation:** Read Committed.
- **Required privilege:** the Retool DB user needs superuser privileges to run migrations.
- Sources: https://docs.retool.com/self-hosted/guides/storage-database

The Terraform configures the Aurora parameter group with `log_statement = ddl` only ([modules/aws_ecs_fargate/rds.tf:11-15](../../modules/aws_ecs_fargate/rds.tf#L11)). `uuid-ossp` enablement and DB-user privileges are not visible in Terraform — they were configured at the database level at initial setup; this needs verification before the upgrade if there is any doubt.

### Code-executor service (the gap)

At release line `3.251` (Aug/Sept 2025), Retool changed `code-executor` from optional to required for all Retool deployments. It is a separate container image (`tryretool/code-executor-service`), not a `SERVICE_TYPE` on the backend image. By default it uses `nsjail` for sandboxing user code blocks executed in the platform.

Implications for this Terraform:

- A new ECS task definition + service is needed for `code-executor`, pointing at `tryretool/code-executor-service:<version>`.
- `nsjail` is the default sandbox; on Fargate, the documented sandbox compatibility is non-trivial (community reports note that `nsjail` requires kernel features Fargate doesn't always expose). Retool's documentation on running `code-executor` on Fargate specifically was not located in this research — gap noted.
- Network / security-group entries for the new service.
- A new env var or service-discovery target on the main backend pointing the API to the code-executor host.

The specific env var name(s) the main backend uses to reach `code-executor`, and the documented Fargate-compatible launch configuration, are **gaps** — see Open Questions.

### Repo files that change for the upgrade

Minimum change for image bump only:

- [main.tf:23](../../main.tf#L23) — change `ecs_retool_image = "tryretool/backend:3.24.6"` to the target tag (note: stable tags from `3.33` onward carry a `-stable` suffix, e.g. `tryretool/backend:3.334.15-stable`).
- [modules/aws_ecs_fargate/variables.tf:85](../../modules/aws_ecs_fargate/variables.tf#L85) — module default of `2.69.18` is unused at the root but stale; may be updated for consistency.

To add `code-executor` (required at `3.251+`):

- New file under `modules/aws_ecs_fargate/` (e.g. `code_executor.tf`) with `aws_ecs_task_definition` + `aws_ecs_service`.
- New ingress rule or service-discovery entry between main backend and code-executor.
- New env var on `aws_ecs_task_definition.retool` pointing to the code-executor endpoint.
- New variable for the `code-executor` image tag in [modules/aws_ecs_fargate/variables.tf](../../modules/aws_ecs_fargate/variables.tf).

### Git history of past upgrades

```
fb49126 Upgrade retool                      <- most recent on main (the 3.24.6 bump)
84eab46 Update README.md
3514af6 Update README.md
02cf259 Enable drop_invalid_header_fields for overwatch alb
eeea98a Merge pull request #1 from apideck-io/feat/CSD-193590
d82d143 Make it work in new vpc
a79eb99 Upgrade and disable SSL
2662a7a Upgrade overwatch
48f3a0b Upgrade postgres and overwatch
cb4fc1f Upgrade
```

Past upgrades are bare image-tag bumps. No prior commit addresses adding `code-executor` or any workflows/agents service.

## Code References

- [main.tf:23](../../main.tf#L23) — image pin (`tryretool/backend:3.24.6`)
- [main.tf:34-86](../../main.tf#L34) — `additional_env_vars` (SSO, DOMAINS, migration timeout)
- [main.tf:83-84](../../main.tf#L83) — `DATABASE_MIGRATIONS_TIMEOUT_SECONDS=900`
- [modules/aws_ecs_fargate/main.tf:31-50](../../modules/aws_ecs_fargate/main.tf#L31) — main ECS service
- [modules/aws_ecs_fargate/main.tf:52-63](../../modules/aws_ecs_fargate/main.tf#L52) — jobs_runner service (`desired_count = 1`)
- [modules/aws_ecs_fargate/main.tf:65-125](../../modules/aws_ecs_fargate/main.tf#L65) — jobs_runner task definition (SERVICE_TYPE=JOBS_RUNNER)
- [modules/aws_ecs_fargate/main.tf:126-194](../../modules/aws_ecs_fargate/main.tf#L126) — main retool task definition (SERVICE_TYPE=MAIN_BACKEND,DB_CONNECTOR)
- [modules/aws_ecs_fargate/main.tf:117-120](../../modules/aws_ecs_fargate/main.tf#L117) — `LICENSE_KEY` secret reference
- [modules/aws_ecs_fargate/main.tf:182-189](../../modules/aws_ecs_fargate/main.tf#L182) — `CUSTOM_OAUTH2_SSO_CLIENT_SECRET` + `RETOOL_EXPOSED_MANAGEMENT_API_KEY` secrets
- [modules/aws_ecs_fargate/variables.tf:85](../../modules/aws_ecs_fargate/variables.tf#L85) — stale module default `tryretool/backend:2.69.18`
- [modules/aws_ecs_fargate/rds.tf:1-4](../../modules/aws_ecs_fargate/rds.tf#L1) — Aurora Postgres 14.6 engine pin
- [modules/aws_ecs_fargate/rds.tf:50-57](../../modules/aws_ecs_fargate/rds.tf#L50) — Serverless v2 0.5-5 ACU
- [modules/aws_ecs_fargate/rds.tf:63](../../modules/aws_ecs_fargate/rds.tf#L63) — 35-day backup retention
- [README.md:18-21](../../README.md#L18) — current upgrade procedure (image bump + `tf apply`)

## Architecture Documentation

Retool's documented production architecture (from https://docs.retool.com/self-hosted/concepts/architecture):

| Container | Image | SERVICE_TYPE(s) | Purpose |
|---|---|---|---|
| `api` | `tryretool/backend` | `MAIN_BACKEND`, `DB_CONNECTOR`, `DB_SSH_CONNECTOR` | Frontend, app hosting, user mgmt |
| `jobs-runner` | `tryretool/backend` | `JOBS_RUNNER` | Background tasks, **DB migrations**, source control. *Must not be replicated.* |
| `workflows-backend` | `tryretool/backend` | `WORKFLOW_BACKEND`, `DB_CONNECTOR`, `DB_SSH_CONNECTOR` | Workflow request processing |
| `workflows-worker` | `tryretool/backend` | `WORKFLOW_TEMPORAL_WORKER` | Polls Temporal for workflow tasks |
| `agent-worker` | `tryretool/backend` | `AGENT_TEMPORAL_WORKER` | Polls Temporal for agent runs |
| `agent-eval-worker` | `tryretool/backend` | `AGENT_EVAL_TEMPORAL_WORKER` | Polls Temporal for agent eval runs |
| `code-executor` | `tryretool/code-executor-service` | (separate image; no SERVICE_TYPE) | Executes Workflow code blocks; nsjail sandbox. **Required from `3.251`.** |
| `postgres` | n/a | n/a | Platform DB (`uuid-ossp` + Read Committed) |

External dependency: **Temporal cluster** (only needed if workflows or agents are used).

This repo deploys only `api` (as `retool`) and `jobs-runner`. The five other containers and Temporal are not provisioned.

## Historical Context

- 3.24.6 was deployed via commit `fb49126 Upgrade retool` (most recent change to `main.tf`).
- The repo's `README.md` upgrade procedure is two lines: bump the version, run `tf apply`. That procedure was valid for image-tag bumps within a release-channel range; it does not cover the architecture change at `3.251`.
- Past upgrade commits (`Upgrade overwatch`, `Upgrade postgres and overwatch`, `Upgrade and disable SSL`, `Upgrade retool`) show the pattern is bare image-tag bumps; no prior precedent for adding a new ECS service for the upgrade.
- The Stable / Edge channel split is itself a post-`3.24` change (introduced Feb 27 2024 at `3.33`). The current `3.24.6` predates the channel concept.

## Related Research

- None located in `thoughts/research/` (this is the first research document in the directory).

## Open Questions

1. **`code-executor` on Fargate compatibility.** The default `nsjail` sandbox requires kernel features that may not be exposed on Fargate. Confirm with Retool support whether `tryretool/code-executor-service` runs on Fargate, what task-role / network requirements apply, and whether sandbox mode can be disabled or substituted.
2. **`ENCRYPTION_KEY` and `USE_GCM_ENCRYPTION` source.** Not visible in the Terraform — verify where they are set (image default, AWS Secret, parameter store) so they can be preserved across the upgrade. If they are image defaults that have changed between `3.24` and `3.334`, data encrypted under the old key may be unreadable.
3. **`uuid-ossp` extension on Aurora Postgres.** Confirm the extension is enabled on `hammerhead_production`. Not visible in Terraform.
4. **`code-executor` endpoint env var name** on the main backend (newer versions): exact env var name(s) needed to point `MAIN_BACKEND` at the code-executor service. Not located in this research.
5. **Per-version notes between `3.34` and `3.334`.** This research did not enumerate the ~300 release-line changelog pages. Other minor-line breaking changes may exist; the Retool docs Releases page is the authoritative source per stable line.
6. **Cumulative DB migration count and duration.** Not documented publicly. A multi-year jump runs a large stack of migrations on first boot of the new `jobs-runner`; the `DATABASE_MIGRATIONS_TIMEOUT_SECONDS=900` may need raising.
7. **Multiplayer dependency on `LICENSE_KEY`** at Q3 2026 — confirm the license key in SSM (`/overwatch/${stage}/RETOOL_LICENSE_KEY`) is current and not expired before the upgrade.
8. **Hardened image variant.** Retool publishes `-stable-hardened` tags (e.g. `3.334.15-stable-hardened`, multi-arch). Whether to adopt this variant is a separate decision; the differences vs. plain `-stable` are not documented in this research.

## Sources

Documentation pages fetched and verified:

- https://docs.retool.com/self-hosted/self-managed/concepts/update-deployment (the user-supplied URL — 200, content current)
- https://docs.retool.com/self-hosted/concepts/update-deployment (mirror of the above)
- https://docs.retool.com/self-hosted/concepts/architecture
- https://docs.retool.com/self-hosted/release-notes (release-channel info; replaces `/concepts/releases` which is now 404)
- https://docs.retool.com/self-hosted/reference/environment-variables
- https://docs.retool.com/self-hosted/guides/storage-database
- https://docs.retool.com/releases/stable/2024
- https://docs.retool.com/releases/stable/2025
- https://docs.retool.com/releases/stable/2026
- https://docs.retool.com/changelog/self-hosted-retool-333-stable
- https://docs.retool.com/changelog/self-hosted-retool-release-channels
- https://docs.retool.com/changelog/pgbouncer-ignore-statement-timeout
- https://docs.retool.com/changelog/runtime-node-20-18
- https://docs.retool.com/changelog/code-executor-required
- https://docs.retool.com/changelog/samlify-upgrade-breaks-login
- https://hub.docker.com/r/tryretool/backend/tags
- https://github.com/tryretool/retool-onpremise

URLs noted as 404 (link rot): `https://docs.retool.com/docs/updating-retool-on-premise`, `https://docs.retool.com/self-hosted/concepts/releases`.
