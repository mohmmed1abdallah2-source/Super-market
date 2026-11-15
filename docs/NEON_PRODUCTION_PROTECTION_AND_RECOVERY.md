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


## 7. Restore rehearsal record — 2026-11-15

### Result

- Restored from snapshot: `snap-hidden-shadow-bagbpujg`.
- Restored branch ID: `br-summer-violet-baexllh2`.
- Final rehearsal name: `restore-rehearsal-pre-iteration3-20261115`.
- Final status: ready; non-primary; non-default.
- Console: https://console.neon.tech/app/projects/long-smoke-94048943/branches/br-summer-violet-baexllh2

### Important provider behavior and correction

The restore call was finalized immediately by the provider and temporarily made the restored branch the branch named/defaulted `production`, while the original branch ID `br-empty-brook-bab988pu` was renamed. No SQL write or migration was run during this interval. The branch roles were immediately corrected: the original ID was made default again and renamed `production`; the restored ID was renamed to the rehearsal name above. Final branch listing and default-branch lookup confirmed the original ID is again `production` and default.

### Verification performed

- Restored branch is ready and queryable; Neon returned 18 public tables/views in `neondb`.
- Read-only counts on both original production and restored rehearsal branch:

| Table | Production | Restored rehearsal |
|---|---:|---:|
| branches | 0 | 0 |
| products | 0 | 0 |
| parties | 0 | 0 |
| sales_invoices | 0 | 0 |
| journal_entries | 0 | 0 |
| journal_lines | 0 | 0 |
| stock_movements | 0 | 0 |
| users | 0 | 0 |

These checks establish queryability, schema visibility, and equality for the selected counts only. They do not prove byte-for-byte equality, full application recovery, or successful application connectivity.

### Current safety state

- Original production ID `br-empty-brook-bab988pu`: name `production`, ready, primary, default, unprotected.
- Restored rehearsal ID `br-summer-violet-baexllh2`: name `restore-rehearsal-pre-iteration3-20261115`, ready, non-primary, non-default.
- No production DDL/DML or migration 007 was executed.
- The rehearsal branch is intentionally retained; cleanup requires separate explicit approval.
- Branch protection remains blocked by the plan's protected-branch limit; automatic snapshot scheduling remains unavailable; PITR retention remains 6 hours.


## 8. Endpoint association follow-up — pending approval

The post-restore endpoint audit returned:

| Branch | Endpoint | Created | Current association |
|---|---|---|---|
| `br-empty-brook-bab988pu` (`production`) | `ep-floral-term-badqa5er` | 2026-11-15 | Current production read-write endpoint, created by restore finalization |
| `br-summer-violet-baexllh2` (restore rehearsal) | `ep-young-scene-bab6kmsp` | 2026-11-11 | Original read-write endpoint, now attached to the rehearsal branch |

If the deployed application still uses the original endpoint host, it may now connect to the rehearsal branch. The application environment was not inspected, so actual runtime routing remains unknown.

**Do not claim application connectivity is restored.** No endpoint was deleted, moved, suspended or restarted. To reattach the original endpoint to production, Neon requires the production branch to have no existing read-write endpoint. The proposed correction is to remove the newly created endpoint `ep-floral-term-badqa5er`, then move `ep-young-scene-bab6kmsp` back to `br-empty-brook-bab988pu`. This will interrupt active database connections briefly and requires explicit approval before execution.


## 9. Endpoint association correction — completed 2026-11-15

The pending endpoint correction in section 8 was executed only after explicit user approval.

| Item | Final verified state |
|---|---|
| Original production branch | `br-empty-brook-bab988pu`, name `production`, ready, primary, default |
| Original read-write endpoint | `ep-young-scene-bab6kmsp` attached to `br-empty-brook-bab988pu` |
| Original endpoint host | `ep-young-scene-bab6kmsp.c-8.eu-central-1.aws.neon.tech` |
| Temporary endpoint created by restore finalization | `ep-floral-term-badqa5er`, deleted |
| Restore rehearsal branch | `br-summer-violet-baexllh2`, retained, non-default |
| Audit branch | `br-odd-term-ba2iavg0`, retained, non-default |

### Execution and verification

1. Re-read the project's endpoint list before changing anything; it confirmed the temporary endpoint was on production and the original endpoint was on the restore rehearsal branch.
2. Deleted `ep-floral-term-badqa5er` to leave production without a read-write endpoint.
3. Updated `ep-young-scene-bab6kmsp` to target `br-empty-brook-bab988pu`.
4. Re-read all endpoints, branches, and the project's default branch. The original endpoint now targets production; the production branch remains ready, primary, and default.

The endpoint was reported idle/suspended at the pre-change inspection. The operation can interrupt active connections; no application outage was independently observed or measured. The original hostname was preserved, but deployment environment variables and application-level database connectivity were not inspected or tested. Therefore this verifies Neon control-plane endpoint association only, not end-to-end application connectivity.

No SQL statement, production migration, or production row-data change was performed during this correction. Sections 8's pending action is superseded by this completed record. Production remains unprotected due to the plan limit, automatic snapshot scheduling remains unavailable, and PITR retention remains six hours.
