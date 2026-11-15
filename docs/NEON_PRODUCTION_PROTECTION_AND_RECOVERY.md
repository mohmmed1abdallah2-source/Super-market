# Neon Production Protection and Recovery Runbook

**Project:** `supermarket-erp` (`long-smoke-94048943`)  
**Database:** `neondb`  
**Production branch:** `production` (`br-empty-brook-bab988pu`)  
**Engine:** PostgreSQL 18  
**Last inspected:** 2026-11-15 UTC

## 1. Current verified state

| Control | Verified state |
|---|---|
| Production branch | Default and primary |
| Protected branch | No — enable request rejected by plan limit (HTTP 422) |
| PITR history retention | 21,600 seconds (6 hours) |
| Automatic snapshot schedule | Empty — schedule creation unavailable on this project (HTTP 404) |
| Manual baseline snapshot | Created successfully; ID below |
| Restore rehearsal | Not performed |
| Production migration 007 | Not applied |

### Baseline snapshot

- Name: `pre-iteration3-migration-baseline-2026-11-15`
- Snapshot ID: `snap-hidden-shadow-bagbpujg`
- Source branch: `br-empty-brook-bab988pu`
- Created: `2026-11-15T12:41:20Z`
- Type: manual Neon snapshot.

This snapshot is a recovery point inside the same Neon project. It is **not** an independently stored offsite export. Do not assume it is restorable until a restore-to-new-branch rehearsal succeeds.

## 2. Actions attempted and outcomes

1. Read production branch/project settings and existing snapshots before changing settings.
2. Created the manual baseline snapshot successfully.
3. Tried to set `production.protected = true`; Neon rejected it with HTTP 422 because the account reached its protected-branch limit. No other branch was unprotected to make room.
4. Tried to configure daily snapshots at 03:00 UTC with 7-day retention; Neon rejected it with HTTP 404 because scheduled backup creation is not enabled for this project.
5. Left PITR retention unchanged at 6 hours. No project settings were silently weakened or changed.

## 3. Required account-level follow-up

- Review/upgrade the Neon plan or otherwise obtain protected-branch capacity, then protect `production` and verify the branch record reports `protected: true`.
- Enable an automatic snapshot schedule if the plan supports it; verify the returned schedule by reading it back. A proposed baseline is daily at 03:00 UTC with at least 7 days retention, subject to plan support and cost.
- Review whether PITR history retention can be increased beyond 6 hours and what the associated plan/cost implications are.
- Arrange an independent logical backup/export stored outside this Neon project, with restricted access and a documented retention policy. This has not been created by this run.

## 4. Restore procedure — safe rehearsal first

**Never restore directly over production as the first test.**

1. Confirm the snapshot still exists and record its metadata.
2. Restore snapshot `snap-hidden-shadow-bagbpujg` to a **new branch**, not to `br-empty-brook-bab988pu`; keep the restored branch separate from application traffic.
3. Verify the restored branch is ready, database `neondb` opens, expected schemas/tables/constraints exist, and row counts match the snapshot's intended point in time.
4. Run read-only integrity checks and application compatibility checks against the restored branch. Do not run pending migrations during the restore rehearsal.
5. Record the rehearsal time, branch ID, checks, and result here and in `DEVELOPMENT_LOG.md`.
6. If a production recovery is ever required, first stop or quiesce writers, establish the exact recovery timestamp and acceptable data-loss window, compare the restored branch, update application connection routing only under a separately approved change plan, and verify sync/idempotency behavior.
7. Require a separate, explicit user approval before finalizing a restore/cutover onto production. Keep the original production branch available until the restored service is verified and the rollback window is accepted.

## 5. Iteration 3 migration gate

- Migrations 007/008 were validated on a disposable child branch only. The successful disposable test does not authorize production application.
- Before production migration: confirm branch protection or equivalent safeguards, establish a fresh verified recovery point, rehearse restore, review application write-path readiness, schedule a maintenance window, and define rollback/cutover ownership.
- No production DDL/DML has been performed as part of this preparation.

## 6. Related records

- `DEVELOPMENT_LOG.md`
- `docs/ITERATION_03_HANDOVER_AND_STATE.md`
- `docs/neon/007_fefo_inventory_and_purchases_schema.sql`
- `docs/neon/008_inventory_branch_isolation_tests.sql`
