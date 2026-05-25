# Retool Production Upgrade Runbook — 3.24.6 → 3.334.15-stable

Production sequel to `local-dev/RUNBOOK.md`. The local dry-run validated each
hop on a prod-data restore. This runbook executes the same 8 hops against the
real Aurora cluster + ECS services.

> Read `local-dev/RUNBOOK.md` first. Do not start a prod hop unless the same
> hop passed locally and `hop-report.tsv` shows the migration timing.

> **Terraform state status matters.** The default per-hop procedure assumes a
> working shared Terraform state in `s3://apideck-terraform-s3/terraform/overwatch`.
> The initial apply for this stack was run from an ex-engineer's laptop and
> the state was never migrated to S3. **Until state is reconciled, follow
> "Appendix A — Console-only fallback" instead of the Terraform steps below.**

---

## Scope

- AWS account: `apideck-production` (708245472192), region `eu-central-1`
- ECS cluster: `overwatch-ecs`
  - service `overwatch-main-service` — Retool api/web (task def family `retool`)
  - service `overwatch-jobs-runner-service` — Retool workflow worker
- Aurora cluster: `overwatch` (writer `overwatch-one`, engine `aurora-postgresql 14.20`)
- Terraform driver: `modules/aws_ecs_fargate` consumed from `main.tf:23` (`ecs_retool_image`)

---

## Hop sequence

Pinned to match the local dry-run. Do **not** skip versions — Retool's
migration runner only supports forward steps from each release line's stable
tip.

```
3.24.6                 (current baseline)
3.33.9-stable
3.114.28-stable
3.148.13-stable
3.196.33-stable        # code-executor service starts here
3.253.29-stable
3.284.30-stable
3.334.15-stable        (target)
```

Each hop = one Terraform change + one ECS rolling deploy + one validation
pass. Allocate one maintenance window per hop based on local
`hop-report.tsv` migration_seconds plus a 3× safety margin.

---

## Prerequisites (once, before hop 1)

1. **Local dry-run complete and green.** `local-dev/hop-report.tsv` has all 8
   rows with `status=pass`. Failed hops were investigated and root-caused
   before touching prod.
2. **Maintenance windows scheduled** with stakeholders. Hop 3.148 → 3.196 is
   the largest gap; budget the longest window there.
3. **CloudWatch dashboards open** for the cluster:
   - `/aws/ecs/overwatch-ecs/overwatch-main-service`
   - `/aws/ecs/overwatch-ecs/overwatch-jobs-runner-service`
   - RDS metrics for cluster `overwatch` (CPU, FreeableMemory, DatabaseConnections, DeadlocksCount)
4. **AWS CLI** profile `apideck-production` configured with `ecs:*`,
   `rds:CreateDBClusterSnapshot`, `rds:RestoreDBClusterFromSnapshot`,
   `ssm:StartSession` on the bastion.
5. **Terraform state lock free.** Run `terraform plan` cold; expect "no
   changes" before starting.
6. **Bastion reachable** for direct Aurora access if you need to inspect
   schema between hops: `i-01ef4ffc684abc638` via SSM port-forward to
   `overwatch.cluster-cloetgx9dx8v.eu-central-1.rds.amazonaws.com:5432`.

---

## Per-hop procedure

Repeat the block below for each hop in the sequence. `<from>` and `<to>` are
the version tags.

### 1. Pre-flight

```sh
# Confirm cluster + services healthy and on <from> tag
aws ecs describe-services \
  --cluster overwatch-ecs \
  --services overwatch-main-service overwatch-jobs-runner-service \
  --profile apideck-production \
  --query 'services[*].{Name:serviceName,Status:status,Running:runningCount,Desired:desiredCount,TaskDef:taskDefinition}'

# Verify Aurora cluster available
aws rds describe-db-clusters \
  --db-cluster-identifier overwatch \
  --profile apideck-production \
  --query 'DBClusters[0].Status'
```

### 2. Snapshot Aurora (mandatory)

```sh
SNAP_ID="overwatch-pre-retool-<to>-$(date -u +%Y%m%d-%H%M)"
aws rds create-db-cluster-snapshot \
  --db-cluster-identifier overwatch \
  --db-cluster-snapshot-identifier "$SNAP_ID" \
  --profile apideck-production

# Wait for available
aws rds wait db-cluster-snapshot-available \
  --db-cluster-snapshot-identifier "$SNAP_ID" \
  --profile apideck-production

echo "$SNAP_ID" >> snapshots.log
```

`snapshots.log` is the audit trail. Snapshots are the only rollback path
once migrations begin — Retool migrations are not reversible in-place.

### 3. Bump version in Terraform

Edit `main.tf:23`:

```hcl
ecs_retool_image = "tryretool/backend:<to>"
```

For hop 3.196.33-stable: also add the `code-executor` ECS service.
The local-dev `compose.3-196.yml` shows the env vars the new task needs
(`CODE_EXECUTOR_INGRESS_DOMAIN`, `WORKFLOW_BACKEND_HOST`,
`IGNORE_CODE_EXECUTOR_STARTUP_CHECK`, etc). The module must grow a new
`code-executor` ECS service with its own task def, target group, and
security group. Land that module change in a separate PR **before** the
3.196 hop window so the apply is mechanical.

### 4. Plan + review

```sh
terraform plan -out=hop-<to>.tfplan
```

Expected diff:
- `aws_ecs_task_definition.retool` — new revision with image tag bumped
- `aws_ecs_service.retool_main_service` — `task_definition` ref bumped
- `aws_ecs_service.retool_jobs_runner_service` — `task_definition` ref bumped
- (3.196 hop only) new code-executor task def + service + sg + tg

If the plan touches anything else (IAM, RDS, networking), **stop**. Do not
apply unrelated drift in a maintenance window.

### 5. Apply

```sh
terraform apply hop-<to>.tfplan
```

ECS will start the rolling deploy automatically. Default deployment config
on this module: max 200% / min 100% so the old task stays up while the new
one boots.

### 6. Watch migrations

`overwatch-main-service` runs migrations on first new task boot. Tail the
log group:

```sh
aws logs tail /aws/ecs/overwatch-ecs/overwatch-main-service \
  --follow --since 1m \
  --profile apideck-production
```

Watch for:
- `Database migrations are up to date.` → migrations finished
- `[Worker] Worker NN started and listening on 3001` → HTTP up
- Any line containing `error`, `FATAL`, `migration failed` → **stop**, see Rollback

Expected wall-clock per hop (from local `hop-report.tsv` × ~3 because prod
Aurora has more data + ECS Fargate isn't Apple Silicon emulation):

| Hop                 | Local seconds | Prod estimate    |
|---------------------|---------------|------------------|
| 3.24.6 → 3.33.9     | (fill in)     | (fill × 3)       |
| 3.33.9 → 3.114.28   |               |                  |
| 3.114.28 → 3.148.13 |               |                  |
| 3.148.13 → 3.196.33 |               | **largest gap**  |
| 3.196.33 → 3.253.29 |               |                  |
| 3.253.29 → 3.284.30 |               |                  |
| 3.284.30 → 3.334.15 |               |                  |

Fill the table from `local-dev/hop-report.tsv` after the dry-run.

### 7. Wait for ECS steady state

```sh
aws ecs wait services-stable \
  --cluster overwatch-ecs \
  --services overwatch-main-service overwatch-jobs-runner-service \
  --profile apideck-production
```

Returns when both services have `runningCount == desiredCount` with the
new task definition and the old tasks have drained.

### 8. Validate

```sh
# ALB health endpoint
curl -fsS https://overwatch.<domain>/api/checkHealth
# expect: {"status":"HEALTHY","version":"<to>"}

# Service task counts
aws ecs describe-services \
  --cluster overwatch-ecs \
  --services overwatch-main-service overwatch-jobs-runner-service \
  --profile apideck-production \
  --query 'services[*].{Name:serviceName,Running:runningCount,Desired:desiredCount,TaskDef:taskDefinition}'

# Schema sanity — connect via bastion SSM port-forward then:
psql -h 127.0.0.1 -p 5433 -U retool -d hammerhead_production \
  -c 'SELECT count(*) FROM "SequelizeMeta";' \
  -c "SELECT max(id) FROM \"SequelizeMeta\";"
```

`SequelizeMeta` count must be **greater than or equal to** the pre-hop
count (migrations only add rows). A decrease means the migration runner
rolled back — investigate before continuing.

### 9. Smoke test (manual, 5 min)

- Open `https://overwatch.<domain>` in a browser, log in via SSO.
- Open one Retool app you know well — verify it loads and queries run.
- Trigger one workflow that has historical runs — verify it completes.
- Open the audit log page — verify recent events render.

If any of the above fails: **stop**, run Rollback.

### 10. Mark hop complete

Append to `prod-hop-report.tsv`:

```
ts_start	ts_end	from_version	to_version	snapshot_id	migration_seconds	status	notes
```

Commit Terraform changes + the row to the repo.

---

## Rollback

Triggered by any of:
- Migration log shows `error` or `FATAL`
- `/api/checkHealth` returns non-2xx after 10 min
- `services-stable` wait times out
- Smoke test fails on a feature that worked pre-hop
- `SequelizeMeta` count decreased

### Fast rollback (image only — migrations did **not** run)

If the new task crashed before migrations applied (rare; check
CloudWatch for `Database migrations are up to date.`), revert the
Terraform change and re-apply:

```sh
git checkout main.tf
terraform plan -out=rollback.tfplan
terraform apply rollback.tfplan
```

ECS rolls back. No data restore needed.

### Full rollback (migrations partially or fully applied)

Retool DDL migrations are not reversible. Restore Aurora from the snapshot
taken in step 2.

1. **Stop ECS services** (drain traffic, prevent further writes):
   ```sh
   aws ecs update-service --cluster overwatch-ecs --service overwatch-main-service --desired-count 0 --profile apideck-production
   aws ecs update-service --cluster overwatch-ecs --service overwatch-jobs-runner-service --desired-count 0 --profile apideck-production
   ```

2. **Restore cluster** to a new identifier (Aurora does not support in-place restore):
   ```sh
   aws rds restore-db-cluster-from-snapshot \
     --db-cluster-identifier overwatch-rollback-$(date -u +%Y%m%d-%H%M) \
     --snapshot-identifier "$SNAP_ID" \
     --engine aurora-postgresql \
     --vpc-security-group-ids sg-0c3090909698ce2b7 \
     --profile apideck-production
   ```
   Add a writer instance, wait for `available`.

3. **Repoint application** — either:
   - Update the Terraform module's Aurora endpoint var to the new cluster, plan/apply, OR
   - Rename clusters (delete old, rename restored to `overwatch`) — slower, riskier.
   The endpoint-swap path is the documented one.

4. **Revert Terraform image tag** to the pre-hop version, plan/apply.

5. **Scale services back up**:
   ```sh
   aws ecs update-service --cluster overwatch-ecs --service overwatch-main-service --desired-count 1 --profile apideck-production
   aws ecs update-service --cluster overwatch-ecs --service overwatch-jobs-runner-service --desired-count 1 --profile apideck-production
   ```

6. **Validate** as in step 8 above, against the pre-hop version.

7. **Post-mortem** — do not retry the hop until the root cause is understood
   and reproduced + fixed in local-dev.

---

## Watch list across all hops

- **DatabaseConnections** on Aurora — Retool default is conservative; a hop
  that opens many parallel migration connections can spike this. Alert if
  it exceeds the cluster instance's `max_connections` − 20.
- **DeadlocksCount** — non-zero during a migration usually means concurrent
  app traffic; ECS rolling deploy keeps the old task serving while the new
  one migrates. If a migration takes locks the old task needs, you'll see
  deadlocks. Mitigation: scale main-service to 0 before applying that hop
  and back to 1 after (causes downtime; only use if predicted by local
  dry-run).
- **FreeableMemory** on Aurora — large index rebuilds (likely between 3.148
  and 3.196) drop this fast. If it goes below ~500 MB, the writer may stall
  — abort the hop, scale Aurora instance class up, retry.
- **ECS task health** — if the new task fails ALB health check three times,
  ECS rolls back automatically. Verify the rollback returned to the old
  task def; the snapshot stays in place either way.

---

## Special hop: 3.148 → 3.196 (largest gap)

- No stable patch exists between 3.148 and 3.196 — confirmed against Docker
  Hub during the local dry-run.
- Introduces the `code-executor` service. Terraform module must include
  the new ECS service **before** this hop's image bump applies.
- Expect the longest migration window. Local dry-run's `migration_seconds`
  for this hop is the headline number — multiply by ~3 for prod time.

Land the module change for `code-executor` in a separate PR + apply during
a maintenance window before flipping the image tag. Two ECS services on
the old Retool version is harmless; one service on the new version with
no code-executor will fail health checks.

---

## After the final hop

1. Confirm `/api/checkHealth` returns `{"status":"HEALTHY","version":"3.334.15-stable"}`.
2. Run full smoke suite (all critical Retool apps + workflows).
3. Keep all hop snapshots for **30 days** before deletion — gives time for
   delayed-discovery rollback.
4. Update `local-dev/RUNBOOK.md` baseline from `3.24.6` to `3.334.15-stable`
   for the next upgrade cycle.
5. Delete `local-dev/dumps/prod-*.dump` from operator laptops (gitignored
   but still local-only secret material).

---

## Appendix A — Console-only fallback (Terraform state unavailable)

Use this path while the shared Terraform state is being reconciled. Every
console action bypasses Terraform; once state is fixed, expect drift on
`terraform plan` and update `main.tf:23` in the same PR that reconciles
state.

### A.1 When to use this path

- `terraform plan` cannot run because state is missing from
  `s3://apideck-terraform-s3/terraform/overwatch`, OR
- `terraform plan` runs but proposes to **create** resources that already
  exist in AWS (state empty / divergent), OR
- A maintenance window cannot wait for the state reconciliation work.

### A.2 What the console path can and cannot do

| Hop                       | Console-safe? | Reason                                                  |
|---------------------------|---------------|---------------------------------------------------------|
| 3.24.6 → 3.33.9-stable    | yes           | image tag bump only                                     |
| 3.33.9 → 3.114.28-stable  | yes           | image tag bump only                                     |
| 3.114.28 → 3.148.13-stable| yes           | image tag bump only                                     |
| 3.148.13 → 3.196.33-stable| **no**        | adds `code-executor` ECS service — needs IaC for safety |
| 3.196.33 → 3.253.29-stable| conditional   | only after code-executor exists in TF + state           |
| 3.253.29 → 3.284.30-stable| conditional   | same                                                    |
| 3.284.30 → 3.334.15-stable| conditional   | same                                                    |

**Plan:** ship hops 1-3 via the console while state reconciliation work
runs in parallel. Pause before hop 3.196; finish state work + add
`code-executor` service via Terraform; resume with the standard
Terraform-driven procedure from hop 3.196 onward.

### A.3 Per-hop console procedure

Replaces steps 3-7 of the main per-hop procedure. Steps 1-2 (pre-flight,
Aurora snapshot) and 8-10 (validate, smoke, record) are unchanged.

#### A.3.1 Create new task definition revision

1. AWS Console → **ECS** → **Task definitions** → click the `retool` family
2. Select the latest revision → **Create new revision**
3. Scroll to **Container definitions** → click the Retool container
4. Change **Image URI** from `tryretool/backend:<from>` to
   `tryretool/backend:<to>`
5. Do not change anything else (CPU, memory, env vars, secrets, ports must
   stay identical to the current revision)
6. Scroll to the bottom → **Create**
7. Note the new revision number (e.g. `retool:42`)

Both `overwatch-main-service` and `overwatch-jobs-runner-service` share the
`retool` task definition family — one new revision is reused by both.

#### A.3.2 Update `overwatch-main-service`

1. ECS → **Clusters** → click `overwatch-ecs`
2. Click `overwatch-main-service`
3. Click **Update service** (top right)
4. **Revision**: pick the new revision number from A.3.1
5. Check **Force new deployment**
6. Leave everything else at current values (deployment config, networking,
   load balancing)
7. Click **Update**

ECS starts a rolling deploy. Default config: max 200% / min 100% so the
old task keeps serving until the new task is healthy.

#### A.3.3 Update `overwatch-jobs-runner-service`

Repeat A.3.2 for `overwatch-jobs-runner-service`, picking the same new
revision number. Do this **after** `overwatch-main-service` has reached
steady state — the api service runs migrations on first boot; the
jobs-runner just consumes the migrated schema.

#### A.3.4 Watch migration

ECS console → `overwatch-ecs` → `overwatch-main-service` → **Logs** tab
shows the live task logs. Watch for:

- `Database migrations are up to date.` — migrations finished
- `[Worker] Worker NN started and listening on 3001` — HTTP up
- Any line containing `error`, `FATAL`, `migration failed` — **stop**, run
  console rollback (A.4)

CLI equivalent if you prefer:

```sh
aws logs tail /aws/ecs/overwatch-ecs/overwatch-main-service \
  --follow --since 1m \
  --profile apideck-production
```

#### A.3.5 Wait for steady state

Service detail page → **Deployments** tab. Wait until the new deployment
shows `PRIMARY` with `Desired = Running` and the old deployment shows
`Desired = 0, Running = 0` (drained).

CLI equivalent:

```sh
aws ecs wait services-stable \
  --cluster overwatch-ecs \
  --services overwatch-main-service overwatch-jobs-runner-service \
  --profile apideck-production
```

### A.4 Console rollback

If validation (step 8 in the main procedure) fails:

#### A.4.1 Fast rollback (image only)

1. ECS → `overwatch-ecs` → click each service in turn
2. **Update service** → **Revision**: pick the **prior** revision number
3. Check **Force new deployment** → Update
4. Wait for steady state on the old revision

This works only if migrations did **not** run successfully on the new
image. If `Database migrations are up to date.` appeared in the new
task's logs, schema may already be changed — use A.4.2.

#### A.4.2 Full rollback (migrations applied)

Retool migrations are not reversible. Restore Aurora from the snapshot
taken in step 2 of the main procedure.

1. RDS → **Snapshots** → select the snapshot from this hop's step 2
2. Actions → **Restore snapshot**
3. **DB cluster identifier**: `overwatch-rollback-<date>` (new name; cannot
   reuse `overwatch` while the original cluster still exists)
4. **VPC**: same as `overwatch`. **Subnet group + security group**: pick
   the existing `overwatch` ones from the dropdowns
5. **DB instance class**: same as current writer (check `overwatch-one`)
6. Restore → wait for `Available` (~10-20 min)
7. Add a writer instance to the restored cluster if Restore did not create
   one automatically (Actions → Add reader/writer)
8. **Stop ECS services** to prevent further writes against the broken
   cluster:
   - ECS → each service → Update service → **Desired tasks = 0** → Update
9. **Re-point app to restored cluster.** Two options:
   - **Endpoint swap (recommended):** the task def reads the DB endpoint
     from an env var or SSM parameter. Update the SSM parameter (or the
     task def env var) to point at the restored cluster's writer
     endpoint. Create a new task def revision with the updated value;
     update both services to use it.
   - **Rename (riskier):** delete the broken `overwatch` cluster → rename
     the restored cluster to `overwatch`. AWS does not natively rename
     clusters; this is "create snapshot of restored → restore again as
     `overwatch`". Long, error-prone. Avoid unless endpoint swap is not
     possible.
10. Create a new task def revision with the **prior** Retool image tag
    (the `<from>` of this hop)
11. Update both services to this prior-image task def + scale back to
    `Desired tasks = 1` each
12. Validate against the prior version

### A.5 Per-hop checklist (printable)

Tick each box during the maintenance window:

- [ ] Local-dev dry-run hop `<from> → <to>` passed (`hop-report.tsv`)
- [ ] Stakeholders notified, maintenance window started
- [ ] CloudWatch + RDS dashboards open
- [ ] Aurora snapshot taken; snapshot ID logged
- [ ] New `retool` task def revision created with `<to>` image
- [ ] `overwatch-main-service` updated → new revision, force deploy
- [ ] `overwatch-main-service` reached steady state on new revision
- [ ] `Database migrations are up to date.` seen in api logs
- [ ] `overwatch-jobs-runner-service` updated → same new revision
- [ ] `overwatch-jobs-runner-service` reached steady state
- [ ] `curl /api/checkHealth` returns `{"status":"HEALTHY","version":"<to>"}`
- [ ] `SequelizeMeta` count >= pre-hop count
- [ ] Manual smoke: login + one app + one workflow + audit log page
- [ ] Hop logged in `prod-hop-report.tsv` (snapshot ID, timing, validator
      name, notes)

### A.6 After the last console-only hop

When state is reconciled and the Terraform-driven procedure resumes:

1. Update `main.tf:23` to the **current live** image tag (the one set via
   console in the last console-only hop)
2. Run `terraform plan` — expect "0 to add, 0 to change, 0 to destroy" if
   the import / state-reconciliation step was clean
3. If plan shows the image-tag diff only, that confirms state is in sync
   with everything except the console-applied bumps; apply the plan with
   `-replace` flag is **not** needed — the new task def revision already
   exists in AWS, TF will just adopt it into state on next apply.
4. Resume from hop 3.196 via the standard Terraform-driven per-hop
   procedure.
