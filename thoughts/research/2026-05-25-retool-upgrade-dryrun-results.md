---
status: template
related_plan: thoughts/plans/2026-05-25-retool-local-dev-env.md
related_research:
  - thoughts/research/2026-05-25-retool-local-dev-env.md
  - thoughts/research/2026-05-22-retool-upgrade-3-24-to-latest.md
---

# Retool Upgrade Dry-Run Results — TEMPLATE

> **Operator: fill in this file after running `local-dev/scripts/run-all-hops.sh`.**
> Each section has placeholders. Replace `TODO:` lines with the actual results.
> Once complete, change `status: template` to `status: final` in the frontmatter.

This doc captures the empirical results of the local upgrade walk so the
prod cutover plan (the eventual successor to the dry-run plan) can be
written against real measurements instead of estimates.

---

## Sanitized hop report

Round all row counts to the nearest 100 (PII shape leakage).

| ts (UTC)    | version              | migration_seconds | status | knex_count | users (~100) | apps (~100) | pages (~100) | resources (~100) | notes |
|-------------|----------------------|-------------------|--------|------------|--------------|-------------|--------------|------------------|-------|
| TODO        | 3.24.6 (empty-db)    | TODO              | TODO   | TODO       | TODO         | TODO        | TODO         | TODO             | TODO  |
| TODO        | 3.24.6 (restored)    | TODO              | TODO   | TODO       | TODO         | TODO        | TODO         | TODO             | TODO  |
| TODO        | 3.33.9-stable        | TODO              | TODO   | TODO       | TODO         | TODO        | TODO         | TODO             | TODO  |
| TODO        | 3.114.28-stable      | TODO              | TODO   | TODO       | TODO         | TODO        | TODO         | TODO             | TODO  |
| TODO        | 3.148.13-stable      | TODO              | TODO   | TODO       | TODO         | TODO        | TODO         | TODO             | TODO  |
| TODO        | 3.196.33-stable      | TODO              | TODO   | TODO       | TODO         | TODO        | TODO         | TODO             | TODO  |
| TODO        | 3.253.29-stable      | TODO              | TODO   | TODO       | TODO         | TODO        | TODO         | TODO             | TODO  |
| TODO        | 3.284.30-stable      | TODO              | TODO   | TODO       | TODO         | TODO        | TODO         | TODO             | TODO  |
| TODO        | 3.334.15-stable      | TODO              | TODO   | TODO       | TODO         | TODO        | TODO         | TODO             | TODO  |

---

## Per-hop notes

### 3.24.6 (restored baseline)
- Migration duration: TODO
- Warnings: TODO
- Operator intervention: TODO

### 3.33.9-stable
- Migration duration: TODO
- Warnings: TODO

### 3.114.28-stable
- Migration duration: TODO
- Warnings: TODO

### 3.148.13-stable
- Migration duration: TODO
- Warnings: TODO

### 3.196.33-stable (code-executor service introduced)
- Migration duration: TODO
- Warnings: TODO
- code-executor boot: TODO (success / which flags actually mattered)

### 3.253.29-stable
- Migration duration: TODO
- Warnings: TODO

### 3.284.30-stable
- Migration duration: TODO
- Warnings: TODO

### 3.334.15-stable (final)
- Migration duration: TODO
- Warnings: TODO
- Total walk duration: TODO

**3.148 → 3.196 single hop:** This is the largest gap in the walk (3.163
line was Edge-only on Docker Hub so we could not stop there). Note any
migration anomalies here -- if it succeeded cleanly, that is a positive
signal for the prod cutover; if it failed, the prod plan needs an
intermediate Edge image or an alternate path.

---

## Resolutions for Open Questions

Reference: `thoughts/research/2026-05-25-retool-local-dev-env.md` §Open Questions.

1. **ENCRYPTION_KEY source** — confirmed extraction path via `aws ecs execute-command` works? TODO (yes/no, surprises)
2. **`uuid-ossp` presence** — verified after dump restore? TODO
3. **License-key boundary** — free key from `my.retool.com` worked end-to-end? TODO
4. **Migration timeout sufficiency** — `DATABASE_MIGRATIONS_TIMEOUT_SECONDS=1800` enough? TODO. Largest single hop took TODO seconds.
5. **Sandbox flag reconciliation** — which mattered: `ALLOW_UNSAFE_CODE_EXECUTION` or `CONTAINER_UNPRIVILEGED_MODE`? TODO. Behavior observed: TODO.
6. **ARM emulation overhead** — duration multiplier vs Intel reference? TODO (e.g. 2.5× on Apple Silicon).
7. **Postgres 14.6 vs Aurora 14.6 edge cases** — any extensions or operators that behaved differently? TODO.
8. **Aurora filter line count** — `pg_restore --list` delta after filtering. TODO (vs the 50-line threshold).

---

## Recommendations for the prod cutover plan

To be assembled into a new plan after this dry-run.

- **Pinned target tag**: TODO (e.g. `3.334.15-stable` if the final hop is stable).
- **Prod `DATABASE_MIGRATIONS_TIMEOUT_SECONDS`**: TODO (raise from 900 to X based on observed migration durations).
- **code-executor ECS service shape**:
  - Image: `tryretool/code-executor-service:<pinned-tag>`
  - Sandbox flags: TODO (`CONTAINER_UNPRIVILEGED_MODE` vs `nsjail` -- which runs on Fargate?)
  - Network reachability: TODO (`CODE_EXECUTOR_INGRESS_DOMAIN` value in prod)
  - Resource sizing: TODO
- **Hop strategy in prod**: single-shot vs stepped. Recommendation: TODO based on what the walk surfaced.
- **Rollback test result**: TODO (was 3.334 → 3.24.6 restore-from-dump path confirmed?).

---

## Open follow-ups

Items the dry-run could not resolve and that need attention before
prod cutover:

- TODO

---

## Walk environment

- Host: TODO (Apple Silicon M-series / Intel)
- Docker Desktop: TODO version
- Dump source: TODO (snapshot ID, date)
- Dump size: TODO MB
- ENCRYPTION_KEY source task: TODO (ECS task ARN at time of extraction)
- Walk start: TODO (UTC)
- Walk end: TODO (UTC)
