---
date: '2026-05-25 09:57:56 +0100'
researcher: 'Samir AMZANI'
git_commit: 'eeea98ace0c9fe5c4d0bfceb6ea868336f6ea649'
branch: 'main'
topic: "Local Retool dev environment for testing 3.24.6 → 3.334.x upgrade"
tags: [research, retool, local-dev, docker-compose, upgrade-testing, code-executor]
status: complete
---

# Local Retool Dev Environment for Upgrade Testing

## Research Question

> How to create a local dev env for Retool so I can test the upgrade described in `thoughts/research/2026-05-22-retool-upgrade-3-24-to-latest.md` (3.24.6 → latest)?

Goal: stand up a local stack on macOS (darwin) that reproduces enough of the production deployment topology to dry-run the `3.24.6 → 3.334.x` upgrade path (and the intermediate stops it implies) before touching Terraform/ECS.

## Summary

Retool ships **one** official local stack: a Docker Compose setup in `tryretool/retool-onpremise` (GitHub). The repo's `master` branch hosts the **current-version** compose (`compose.yaml`, multi-stage Dockerfile, includes `temporal.yaml`, ships `code-executor`, `agent-worker`, `agent-eval-worker`, `workflows-backend`, `workflows-worker`, plus `https-portal` and two `postgres:16.8` instances). The compose at the time of `3.24.6` is a different file (`docker-compose.yml`, Compose v1, separate `CodeExecutor.Dockerfile`, `postgres:11.13`, no Temporal, no agent services) — it lives at commit `1dfa911` (March 2024) in the same repo.

For multi-year upgrade testing this means **two different compose layouts are involved**, not one:

| Stage | Compose source | Why |
|---|---|---|
| Boot the **starting state** (`3.24.6`) | `retool-onpremise@1dfa911` (March 2024 commit) | Period-correct compose for pre-Stable era; no code-executor enforcement, separate CodeExecutor.Dockerfile, postgres:11.13 |
| Run **intermediate hops** (`3.33` → `3.196`) | `retool-onpremise@master` with backend image pin overridden, OR period-correct compose commits matching each line | Modern compose works back to ~`3.196` for the code-executor side; below that the `tryretool/code-executor-service` Docker Hub repo has no tags (oldest stable tag is `3.196.0-stable`) |
| Run **target state** (`3.284`+ / `3.334.x`) | `retool-onpremise@master` (current `compose.yaml`) | code-executor service required from `3.251`; current compose ships it correctly |

The current Terraform deploys **only 2 of the 8** services in the official compose (main `api` + `jobs-runner`). The other six (`workflows-backend`, `workflows-worker`, `agent-worker`, `agent-eval-worker`, `code-executor`, `temporal`) are not in production. For a faithful upgrade dry-run the **minimum local stack** is `api` + `jobs-runner` + `postgres` for `3.24.6` boot, plus `code-executor` (and only the code-executor) from the hop that crosses `3.251`. Workflows/agents containers and Temporal are not needed to reproduce the prod migration path.

Production-specific config translates to compose env vars 1-to-1 for everything **except** AWS-managed values. The mapping is in §3 below.

Key constraints documented in this research (not recommendations):

- **macOS**: README states the stack is tested on Ubuntu only. Apple Silicon (`darwin/arm64`) requires `platform: linux/amd64` on every service and three additional env vars (`IGNORE_CODE_EXECUTOR_STARTUP_CHECK`, `DISABLE_IPTABLES_SECURITY_CONFIGURATION`, `CONTAINER_UNPRIVILEGED_MODE`). This guidance is community-only, not in Retool docs.
- **Free license keys** from `my.retool.com` do not expire and unlock all free-plan features.
- The `install.sh` placeholder `EXPIRED-LICENSE-KEY-TRIAL` lets the stack boot but is undocumented; for upgrade testing across `3.251+` (LICENSE_KEY tied to multiplayer in Q3 2026), a real free license is the documented path.
- **`code-executor` Docker Hub tags only start at `3.196.0-stable`** — there is no published `code-executor-service` image for the `3.33`, `3.114`, `3.148` lines. Stepped hops through those lines either skip `code-executor` (it was enforced only from `3.251`) or run `code-executor` from a backend-bundled script (older compose pattern).
- No Retool-official tooling for stepped upgrades exists. `upgrade.sh` is 3 lines (`build`, `up -d`, `image prune`) and handles a single hop.

## Detailed Findings

### 1. `tryretool/retool-onpremise` repo layout

Current `master` branch:

- `compose.yaml` — multi-service compose (renamed from `docker-compose.yml` in May 2025, PR #245, commit `5d404d6`)
- `Dockerfile` — single multi-stage; pins both `tryretool/code-executor-service:${VERSION}` and `tryretool/backend:${VERSION}` from the same `ARG VERSION=X.Y.Z-stable` (PR #238, commit `94de87f`, April 2025)
- `temporal.yaml` — included via `include:` in `compose.yaml`; runs `tryretool/one-offs:retool-temporal-1.1.6`
- `install.sh` — interactive script: prompts for `LICENSE_KEY`, `DOMAIN`; generates `ENCRYPTION_KEY=$(random 64)` and `JWT_SECRET=$(random 256)`; writes `docker.env` + `retooldb.env`
- `upgrade.sh` — three commands: `docker compose build`, `docker compose up -d`, `docker image prune -a -f`
- `appArmor/` — `usr.bin.nsjail` profile (installed by `install.sh` on Ubuntu 24.04+ only)
- `cloudformation/`, `kubernetes/`, `kubernetes-with-temporal/` — non-compose deployment templates
- `README.md` — Docker Compose quickstart only

Source: https://github.com/tryretool/retool-onpremise (master), https://github.com/tryretool/retool-onpremise/blob/master/README.md

README verbatim: *"We test and support running on Ubuntu. If on a different platform, you may need to manually install requirements like Docker."*

### 2. Services in the current `compose.yaml`

| Service | Image / build target | `SERVICE_TYPE` env | Ports | Networks | depends_on |
|---|---|---|---|---|---|
| `api` | build (`tryretool/backend`) | `MAIN_BACKEND,DB_CONNECTOR,DB_SSH_CONNECTOR` | `3000:3000` | frontend, backend, code-executor | postgres |
| `jobs-runner` | build | `JOBS_RUNNER` | — | backend | postgres |
| `workflows-backend` | build | `WORKFLOW_BACKEND,DB_CONNECTOR,DB_SSH_CONNECTOR` | — | backend, code-executor | postgres |
| `workflows-worker` | build | `WORKFLOW_TEMPORAL_WORKER` + `NODE_OPTIONS=--max_old_space_size=1024` | — | backend, code-executor | postgres |
| `agent-worker` | build | `WORKFLOW_TEMPORAL_WORKER` + `WORKER_TEMPORAL_TASKQUEUE=agent` | — | backend, code-executor | (added Sep 2025 PR #253) |
| `agent-eval-worker` | build | `AGENT_EVAL_TEMPORAL_WORKER` + `WORKER_TEMPORAL_TASKQUEUE=agent-eval` | — | backend, code-executor | (added Sep 2025) |
| `code-executor` | build target `code-executor` (= `tryretool/code-executor-service:${VERSION}`) | n/a | — | code-executor | `privileged: true` by default; commented alternative: `user: retool_user` + `ALLOW_UNSAFE_CODE_EXECUTION=true` |
| `postgres` | `postgres:16.8` | n/a | — | backend | volume `data` |
| `retooldb-postgres` | `postgres:16.8` | n/a | — | backend | volume `retooldb-data`, env from `retooldb.env` |
| `https-portal` | `tryretool/https-portal:latest` | n/a | `80:80`, `443:443` | frontend | `STAGE: local` by default |
| `temporal` (via `temporal.yaml` include) | `tryretool/one-offs:retool-temporal-1.1.6` | n/a | `7233:7233` | backend, temporal | optional Enterprise can skip by commenting `include:` |

Volumes: `data`, `retooldb-data`. Networks: `frontend`, `backend`, `code-executor`, `temporal`.

### 3. Production env vars → local docker.env mapping

The current Terraform injects **35 env vars** into both the main `retool` and `jobs_runner` tasks (only `SERVICE_TYPE` differs) and **3 secrets** into the main task / **1 secret** into `jobs_runner`. Sourced from [`modules/aws_ecs_fargate/locals.tf:2-46`](../../modules/aws_ecs_fargate/locals.tf#L2) and [`main.tf:34-86`](../../main.tf#L34).

Full env-var catalog (production value → local equivalent):

| Env var | Prod value source | Local docker.env value |
|---|---|---|
| `NODE_ENV` | hardcoded `production` ([locals.tf:6-7](../../modules/aws_ecs_fargate/locals.tf#L6)) | `production` (matches install.sh) |
| `FORCE_DEPLOYMENT` | `false` ([locals.tf:10-12](../../modules/aws_ecs_fargate/locals.tf#L10)) | `false` |
| `POSTGRES_DB` | literal `hammerhead_production` ([locals.tf:14-16](../../modules/aws_ecs_fargate/locals.tf#L14)) | `hammerhead_production` (install.sh default matches) |
| `POSTGRES_HOST` | Aurora cluster endpoint ([locals.tf:18-20](../../modules/aws_ecs_fargate/locals.tf#L18)) | `postgres` (compose service name) |
| `POSTGRES_SSL_ENABLED` | `true` ([locals.tf:22-24](../../modules/aws_ecs_fargate/locals.tf#L22)) | `false` (local postgres container has no TLS) |
| `POSTGRES_PORT` | `5432` ([locals.tf:26-28](../../modules/aws_ecs_fargate/locals.tf#L26)) | `5432` |
| `POSTGRES_USER` | `var.rds_username` default `retool` ([variables.tf:112-116](../../modules/aws_ecs_fargate/variables.tf#L112)) | `retool_internal_user` (install.sh default) or `retool` |
| `POSTGRES_PASSWORD` | `random_string.rds_password.result` 48 chars ([secrets.tf:1-4](../../modules/aws_ecs_fargate/secrets.tf#L1)) | install.sh `$(random 64)` |
| `JWT_SECRET` | `random_string.jwt_secret.result` 48 chars ([secrets.tf:28-31](../../modules/aws_ecs_fargate/secrets.tf#L28)) | install.sh `$(random 256)` |
| `ENCRYPTION_KEY` | `random_string.encryption_key.result` 48 chars ([secrets.tf:45-47](../../modules/aws_ecs_fargate/secrets.tf#L45)) | install.sh `$(random 64)` |
| `DOMAINS` | `overwatch.${local.domain_name}` ([main.tf:35-36](../../main.tf#L35)) | `localhost -> http://api:3000` (install.sh pattern) |
| `BASE_DOMAIN` | `https://overwatch.${local.domain_name}` ([main.tf:38-39](../../main.tf#L38)) | `https://localhost` or `http://localhost:3000` |
| `DISABLE_INTERCOM` | `true` ([main.tf:41-42](../../main.tf#L41)) | `true` |
| `DISABLE_USER_PASS_LOGIN` | `true` ([main.tf:44-45](../../main.tf#L44)) | `false` for local (enables admin bootstrap without SSO) |
| `RESTRICTED_DOMAIN` | `apideck.com` ([main.tf:47-48](../../main.tf#L47)) | `apideck.com` if SSO tested, blank otherwise |
| `HIDE_PROD_AND_STAGING_TOGGLES` | `true` ([main.tf:50-51](../../main.tf#L50)) | `true` |
| `DISABLE_GIT_SYNCING` | `true` ([main.tf:53-54](../../main.tf#L53)) | `true` |
| `TRIGGER_OAUTH_2_SSO_LOGIN_AUTOMATICALLY` | `true` ([main.tf:56-57](../../main.tf#L56)) | `false` for local (so admin bootstrap works) |
| `CUSTOM_OAUTH2_SSO_CLIENT_ID` | `var.client_id` default `495594039277-u8690qm5okuca05c4upfehie6mqrtcvv.apps.googleusercontent.com` ([variables.tf:19-23](../../modules/aws_ecs_fargate/variables.tf#L19)) | required only if testing SSO locally; needs `http://localhost:3000/oauth2sso/callback` added in Google Cloud Console |
| `CUSTOM_OAUTH2_SSO_SCOPES` | `openid email profile https://www.googleapis.com/auth/userinfo.profile` ([main.tf:62-63](../../main.tf#L62)) | same |
| `CUSTOM_OAUTH2_SSO_AUTH_URL` | `https://accounts.google.com/o/oauth2/v2/auth?access_type=offline&prompt=consent` ([main.tf:65-66](../../main.tf#L65)) | same |
| `CUSTOM_OAUTH2_SSO_TOKEN_URL` | `https://oauth2.googleapis.com/token` ([main.tf:68-69](../../main.tf#L68)) | same |
| `CUSTOM_OAUTH2_SSO_JWT_EMAIL_KEY` | `idToken.email` ([main.tf:71-72](../../main.tf#L71)) | same |
| `CUSTOM_OAUTH2_SSO_JWT_FIRST_NAME_KEY` | `idToken.given_name` ([main.tf:74-75](../../main.tf#L74)) | same |
| `CUSTOM_OAUTH2_SSO_JWT_LAST_NAME_KEY` | `idToken.family_name` ([main.tf:77-78](../../main.tf#L77)) | same |
| `CUSTOM_OAUTH2_SSO_ACCESS_TOKEN_LIFESPAN_MINUTES` | `45` ([main.tf:80-81](../../main.tf#L80)) | `45` |
| `DATABASE_MIGRATIONS_TIMEOUT_SECONDS` | `900` ([main.tf:83-84](../../main.tf#L83)) | `900` (or higher for stepped upgrades; docs name no canonical value) |
| `SERVICE_TYPE` (main) | `MAIN_BACKEND,DB_CONNECTOR` ([main.tf:167-169](../../modules/aws_ecs_fargate/main.tf#L167)) | `MAIN_BACKEND,DB_CONNECTOR,DB_SSH_CONNECTOR` (current compose adds DB_SSH_CONNECTOR) |
| `SERVICE_TYPE` (jobs_runner) | `JOBS_RUNNER` ([main.tf:110-112](../../modules/aws_ecs_fargate/main.tf#L110)) | `JOBS_RUNNER` |
| `COOKIE_INSECURE` | `var.cookie_insecure` default `true` (stringified) ([variables.tf:142-146](../../modules/aws_ecs_fargate/variables.tf#L142)) | `true` (README: required for HTTP login locally) |

Container-level secrets (must come from somewhere local):

| Container secret | Prod source | Local source |
|---|---|---|
| `LICENSE_KEY` (both tasks) | SSM `/overwatch/${stage}/RETOOL_LICENSE_KEY` via `data.aws_ssm_parameter.retool_license_key` ([main.tf:1-3](../../modules/aws_ecs_fargate/main.tf#L1), [main.tf:179-180](../../modules/aws_ecs_fargate/main.tf#L179)) | Free key from `my.retool.com` (does not expire) OR `EXPIRED-LICENSE-KEY-TRIAL` placeholder for boot-only testing |
| `CUSTOM_OAUTH2_SSO_CLIENT_SECRET` (main task) | SSM `/${var.deployment_name}/${var.stage}/GOOGLE_OAUTH2_SSO_CLIENT_SECRET` ([secrets.tf:61-63](../../modules/aws_ecs_fargate/secrets.tf#L61)) | only if testing SSO locally |
| `RETOOL_EXPOSED_MANAGEMENT_API_KEY` (main task) | SSM `/unify/${stage}/API_GATEWAY_API_KEY` ([main.tf:4-6](../../modules/aws_ecs_fargate/main.tf#L4)) | any string; only used by Retool's management API features |

External AWS dependencies the local env does NOT need to stub for an upgrade dry-run: ALB ([loadbalancers.tf:1-54](../../modules/aws_ecs_fargate/loadbalancers.tf#L1)), ACM certs, target groups, security groups, IAM roles, CloudWatch log group, Aurora-specific monitoring. These are AWS-only and the upgrade migration runs purely against Postgres + the backend image.

### 4. macOS specifics (community-documented, not Retool-official)

Source: https://community.retool.com/t/successfully-running-retool-on-premise-on-apple-silicon-with-rancher-desktop-architecture-compatibility-issue/62058

On Apple Silicon (`darwin/arm64`):

- Add `platform: linux/amd64` to every service in `compose.yaml` and `temporal.yaml`.
- Set on `code-executor`:
  - `IGNORE_CODE_EXECUTOR_STARTUP_CHECK=true`
  - `DISABLE_IPTABLES_SECURITY_CONFIGURATION=true`
  - `CONTAINER_UNPRIVILEGED_MODE=true`
- Tested on Rancher Desktop; Docker Desktop on macOS not explicitly covered by the community thread but uses the same emulation layer.

For Intel macOS (`darwin/amd64`), the `platform:` override is not needed. The three code-executor env vars are still applicable on any macOS host because `nsjail` requires Linux kernel features Docker Desktop does not expose.

The `appArmor/usr.bin.nsjail` profile that `install.sh` installs is Ubuntu-only and does not apply on macOS.

### 5. `code-executor` enforcement timeline + Docker Hub tag landscape

| Backend version | `code-executor` requirement | `tryretool/code-executor-service` tag availability |
|---|---|---|
| `3.24.6` | not required; sandbox runs inside backend | repo has no matching tag (no stable below `3.196`) |
| `3.33` … `3.196` | optional / pre-enforcement | repo's oldest stable tag = `3.196.0-stable` |
| `3.251+` | **required** — backend stops sandboxing in-process (community post #61195) | tags follow backend version |
| `3.284`, `3.300`, `3.334` | required | `3.284.0-stable` … `3.334.15-stable` available |

Sources: https://hub.docker.com/r/tryretool/code-executor-service/tags , https://community.retool.com/t/self-hosted-deployments-require-a-container-running-the-code-executor-service/61195 , https://docs.retool.com/releases/stable/2025

This means during a stepped upgrade, the **code-executor service only needs to exist starting at the hop that crosses `3.251`** (e.g., `3.196` → `3.284`). Earlier hops (`3.24.6` → `3.33` → `3.114` → `3.148` → `3.163` → `3.196`) can run with the simple 2-service stack (`api` + `jobs-runner` + `postgres`).

### 6. Privileged mode / sandbox flags

Two parallel flag names appear in Retool's own materials and don't reconcile:

- `compose.yaml` comment-block alternative: `ALLOW_UNSAFE_CODE_EXECUTION=true`
- Security docs: `CONTAINER_UNPRIVILEGED_MODE=true`, plus `DISABLE_IPTABLES_SECURITY_CONFIGURATION=true`

Sources: https://docs.retool.com/self-hosted/guides/code-executor-security-privileges , `compose.yaml` master.

Privileged mode (default in compose) runs nsjail; unprivileged mode disables nsjail and runs the container as `retool_user`. For local upgrade testing the unprivileged path is the only one that works on macOS.

### 7. Intermediate Stable image tags available on Docker Hub

For a stepped upgrade path between `3.24.6` and `3.334.x`:

| Stable line | First confirmed tag | Suffix | Notes |
|---|---|---|---|
| `3.24.x` | `3.24.1` … `3.24.24` | none (pre-Stable era) | Current production |
| `3.33.x` | first ever Stable (Feb 27 2024) | `-stable` introduced here | PgBouncer breaking change |
| `3.52.x` | Jun 2024 | `-stable` | |
| `3.75.x` | Aug 2024 | `-stable` | |
| `3.114.x` | `3.114.1-stable` … `3.114.28-stable` | `-stable` | samlify fix |
| `3.148.x` | Jan 2025 | `-stable` | samlify fix |
| `3.163.x` | Apr 2025 | `-stable` | Node.js 20.18 backend runtime |
| `3.196.x` | `3.196.1-stable` … `3.196.33-stable` | `-stable` | First code-executor-service stable tag |
| `3.253.x` | `3.253.7-stable` … `3.253.29-stable` | `-stable` | crosses 3.251 enforcement |
| `3.284.x` | `3.284.0-stable` … `3.284.30-stable` | `-stable` | currently supported |
| `3.300.x` | `3.300.0-stable` … `3.300.30-stable` | `-stable` | currently supported |
| `3.334.x` | `3.334.0-stable` … `3.334.15-stable` | `-stable` or `-stable-hardened` | latest as of 2026-05-20 |

Source: https://hub.docker.com/r/tryretool/backend/tags , https://docs.retool.com/releases/stable/2024 , /2025 , /2026

Each line also has an `-edge` variant; Retool only supports the latest Edge tag.

### 8. Upgrade-testing data flow

The migration test that matters is: load a Postgres dump that mirrors prod schema/data into a local postgres volume, then point each successive `jobs-runner` image at it and observe migrations run cleanly.

Production Postgres (catalog from §3): Aurora PostgreSQL `14.6`, db `hammerhead_production`, parameter group sets `log_statement = ddl` ([rds.tf:11-15](../../modules/aws_ecs_fargate/rds.tf#L11)). Local compose ships `postgres:16.8` — newer than prod. Retool docs require `>=13.7`, so `16.8` is in-range, but the upgrade dry-run would not exercise behaviour on `14.6` specifically unless the local `postgres` image is pinned to `postgres:14.6` to match.

The `uuid-ossp` extension and Read Committed isolation (Retool requirements) are not configured by the current Terraform's RDS parameter group — they were enabled at DB creation time and would need to be enabled the same way on the local Postgres volume after first boot (or shipped in the dump).

### 9. README upgrade procedure

The repo README and [README.md:18-21](../../README.md#L18) document the upgrade as:

1. Bump `ecs_retool_image` in `main.tf`.
2. `terraform apply`.

There is no documented stepped-upgrade procedure for this repo, and no `upgrade.sh` equivalent. For the local stack, `upgrade.sh` in `retool-onpremise` is:

```
docker compose build
docker compose up -d
docker image prune -a -f
```

— a single-hop pattern, applied N times for N hops.

## Code References

- [main.tf:23](../../main.tf#L23) — image pin `tryretool/backend:3.24.6`
- [main.tf:34-86](../../main.tf#L34) — `additional_env_vars` (SSO + domain + migration timeout + feature flags)
- [main.tf:1-6](../../main.tf#L1) — SSM data sources for `LICENSE_KEY` and management API key
- [modules/aws_ecs_fargate/locals.tf:2-46](../../modules/aws_ecs_fargate/locals.tf#L2) — core env vars passed to both task definitions
- [modules/aws_ecs_fargate/main.tf:65-125](../../modules/aws_ecs_fargate/main.tf#L65) — jobs_runner task definition (SERVICE_TYPE=JOBS_RUNNER, 512/1024)
- [modules/aws_ecs_fargate/main.tf:126-194](../../modules/aws_ecs_fargate/main.tf#L126) — main retool task definition (SERVICE_TYPE=MAIN_BACKEND,DB_CONNECTOR, 2048/4096)
- [modules/aws_ecs_fargate/main.tf:177-190](../../modules/aws_ecs_fargate/main.tf#L177) — main task secrets block (LICENSE_KEY, CUSTOM_OAUTH2_SSO_CLIENT_SECRET, RETOOL_EXPOSED_MANAGEMENT_API_KEY)
- [modules/aws_ecs_fargate/main.tf:116-121](../../modules/aws_ecs_fargate/main.tf#L116) — jobs_runner secrets block (LICENSE_KEY)
- [modules/aws_ecs_fargate/secrets.tf:1-59](../../modules/aws_ecs_fargate/secrets.tf#L1) — generated POSTGRES_PASSWORD / JWT_SECRET / ENCRYPTION_KEY (each `random_string` of 48 chars)
- [modules/aws_ecs_fargate/secrets.tf:61-63](../../modules/aws_ecs_fargate/secrets.tf#L61) — SSM data source for Google OAuth2 client secret
- [modules/aws_ecs_fargate/rds.tf:1-15](../../modules/aws_ecs_fargate/rds.tf#L1) — Aurora Postgres 14.6, parameter group with `log_statement = ddl`
- [modules/aws_ecs_fargate/rds.tf:33-34](../../modules/aws_ecs_fargate/rds.tf#L33) — pre-existing DB subnet group `apideck-production` (AWS-only, irrelevant locally)
- [modules/aws_ecs_fargate/rds.tf:49-52](../../modules/aws_ecs_fargate/rds.tf#L49) — Serverless v2 scaling (0.5–5 ACU; irrelevant locally)
- [modules/aws_ecs_fargate/variables.tf:85](../../modules/aws_ecs_fargate/variables.tf#L85) — stale module default `tryretool/backend:2.69.18` (unused at root)
- [modules/aws_ecs_fargate/variables.tf:112-116](../../modules/aws_ecs_fargate/variables.tf#L112) — `rds_username` default `retool`
- [modules/aws_ecs_fargate/variables.tf:142-146](../../modules/aws_ecs_fargate/variables.tf#L142) — `cookie_insecure` default `true`
- [README.md:18-21](../../README.md#L18) — current upgrade procedure (image bump + tf apply)

External (Retool-shipped):

- https://github.com/tryretool/retool-onpremise/blob/master/compose.yaml
- https://github.com/tryretool/retool-onpremise/blob/master/Dockerfile
- https://github.com/tryretool/retool-onpremise/blob/master/install.sh
- https://github.com/tryretool/retool-onpremise/blob/master/upgrade.sh
- https://github.com/tryretool/retool-onpremise/blob/master/temporal.yaml
- https://github.com/tryretool/retool-onpremise/blob/1dfa911/docker-compose.yml (period-correct compose for 3.24 era)

## Architecture Documentation

Two layouts in play during a stepped upgrade:

**Layout A — `3.24.6` boot (period-correct compose, March 2024 commit)**

```
+---------+   +---------------+   +-----------+
|   api   |--+  jobs-runner   +-->| postgres  |
|  :3000  |   | (1 replica)   |   | 11.13     |
+---------+   +---------------+   +-----------+
   |                  |
   +--- nsjail sandbox inside backend (no separate code-executor)
```

Services: `api`, `jobs-runner`, `postgres`. No code-executor service. No workflows. No agents. No temporal.

**Layout B — `3.251+` / target state (current master compose)**

```
+----------+   +--------------+   +------------+
|   api    |--+ jobs-runner   +-->|  postgres  |
|  :3000   |   | (1 replica)  |   |  16.8      |
+----------+   +--------------+   +------------+
     |
     +-----> +----------------+
             | code-executor  |  (separate image; nsjail or unprivileged)
             +----------------+
```

Optional in current compose: `workflows-backend`, `workflows-worker`, `agent-worker`, `agent-eval-worker`, `temporal`, `https-portal`, `retooldb-postgres`. None of these run in production today, so reproducing them locally is not required for a faithful upgrade dry-run.

The transition between Layout A and Layout B happens at one of two boundaries during the upgrade:

- **At `3.196`** (first hop where `tryretool/code-executor-service` has a stable tag), or
- **At `3.284`** (first supported Stable release line, requires code-executor).

A staged dry-run does not need code-executor for the early hops; it only becomes mandatory at the hop that crosses `3.251`.

## Historical Context

- Retool's compose layout changed substantially between `3.24` and current: file rename (`docker-compose.yml` → `compose.yaml`), version syntax (`version: "2"` removed), code-executor Dockerfile consolidation (April 2025), addition of `agent-worker` / `agent-eval-worker` services (Sept 2025), `temporal.yaml` inclusion.
- The `tryretool/code-executor-service` Docker Hub repo only began publishing stable tags at `3.196`. For hops below that, the older compose's `CodeExecutor.Dockerfile` is the canonical local source.
- The current Terraform repo has only ever deployed `api` + `jobs-runner`. No prior commit references `code-executor`, `workflows-backend`, agents, or Temporal. The README's two-line upgrade procedure has been valid for image bumps within the deployed two-service topology.
- Retool's release-channel split (Stable vs Edge) was introduced at `3.33` (Feb 27 2024). The `3.24.6` deployment predates the channel concept; its image tag has no `-stable` suffix.

## Related Research

- [thoughts/research/2026-05-22-retool-upgrade-3-24-to-latest.md](2026-05-22-retool-upgrade-3-24-to-latest.md) — version landscape, breaking changes, prod topology, Open Questions list (this document complements that one with the local-dev side).

## Open Questions

1. **`ENCRYPTION_KEY` / `USE_GCM_ENCRYPTION` in production.** Not visible in this Terraform. If the production stack relies on the backend image's default (which has changed between 3.24 and 3.334), a local-clone test against a production dump may decrypt resources differently than prod does. Source of truth needs locating before any production cutover. Also flagged as Open Question #2 in the upgrade research doc.
2. **Postgres dump for realistic dry-run.** Aurora Postgres `14.6` in prod vs `postgres:16.8` shipped in current compose — exercising the migration against `14.6` requires pinning the local `postgres` image to `14.6` (or `aurora-postgresql:14.6` is not on Docker Hub; the OSS `postgres:14.6` may behave differently from Aurora's fork on edge cases). A faithful dry-run requires deciding which.
3. **`uuid-ossp` extension on local Postgres.** Not enabled by the official compose's `postgres` container by default. Either ship a dump that already has it, or run `CREATE EXTENSION IF NOT EXISTS "uuid-ossp";` on first boot.
4. **License key for upgrade-spanning testing.** Free key from `my.retool.com` works for all hops. Whether the production `LICENSE_KEY` (in SSM) is also valid locally is undocumented; reusing prod-issued keys across environments may violate license terms — verify with Retool.
5. **`DATABASE_MIGRATIONS_TIMEOUT_SECONDS` value for stepped upgrades.** Retool docs say "set higher when upgrading major versions" but name no number. `900` (current) may or may not suffice when a single hop encompasses many months of migrations.
6. **Unprivileged code-executor flag name.** `ALLOW_UNSAFE_CODE_EXECUTION` (in compose.yaml comments) vs `CONTAINER_UNPRIVILEGED_MODE` (in security docs) — Retool docs do not reconcile these. Choose one when configuring local; behaviour difference (if any) is undocumented.
7. **macOS Apple Silicon emulation overhead.** Running `linux/amd64` images under emulation on `darwin/arm64` is slow; whether migration timeouts that are fine on Fargate trip locally is an empirical question.
8. **SSO callback URL for local Google OAuth2 client.** The existing client ID (`495594039277-…apideck.com`) has `https://overwatch.${domain}/oauth2sso/callback` registered, not localhost. Testing SSO locally requires either a second OAuth2 client with localhost callback or skipping SSO locally (`DISABLE_USER_PASS_LOGIN=false` + `TRIGGER_OAUTH_2_SSO_LOGIN_AUTOMATICALLY=false`).

## Sources

Documentation pages and Docker Hub queries verified:

- https://github.com/tryretool/retool-onpremise
- https://github.com/tryretool/retool-onpremise/blob/master/README.md
- https://github.com/tryretool/retool-onpremise/blob/master/compose.yaml
- https://github.com/tryretool/retool-onpremise/blob/master/Dockerfile
- https://github.com/tryretool/retool-onpremise/blob/master/install.sh
- https://github.com/tryretool/retool-onpremise/blob/master/upgrade.sh
- https://github.com/tryretool/retool-onpremise/blob/master/temporal.yaml
- https://github.com/tryretool/retool-onpremise/blob/1dfa911/docker-compose.yml
- https://github.com/tryretool/deprecated-onpremise
- https://docs.retool.com/self-hosted/quickstarts/docker
- https://docs.retool.com/self-hosted/concepts/update-deployment
- https://docs.retool.com/self-hosted/concepts/temporal
- https://docs.retool.com/self-hosted/guides/code-executor-security-privileges
- https://docs.retool.com/self-hosted/reference/environment-variables
- https://docs.retool.com/self-hosted/self-managed/reference/environment-variables/storage-database
- https://docs.retool.com/sso/tutorials/google/oidc
- https://docs.retool.com/releases/stable/2024
- https://docs.retool.com/releases/stable/2025
- https://docs.retool.com/releases/stable/2026
- https://hub.docker.com/r/tryretool/backend/tags
- https://hub.docker.com/r/tryretool/code-executor-service/tags
- https://community.retool.com/t/self-hosted-deployments-require-a-container-running-the-code-executor-service/61195
- https://community.retool.com/t/upgrade-to-latest-version-from-2-117-21-to-latest/52023
- https://community.retool.com/t/self-hosted-upgrade/25155
- https://community.retool.com/t/is-free-license-plan-limited-by-a-certain-time/25680
- https://community.retool.com/t/successfully-running-retool-on-premise-on-apple-silicon-with-rancher-desktop-architecture-compatibility-issue/62058
- https://unattributed.blog/self-hosting/2025/04/17/guide-retool-self-hosting-installation-guide.html (community / unofficial)
- https://www.toolpioneers.com/post/self-hosted-retool-upgrade-strategy (community / unofficial)
