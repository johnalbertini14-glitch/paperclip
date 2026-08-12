# REVA-30407 rollout and read-path evidence

Date: 2026-08-11 UTC  
Source checkout: `reva-30327-issue-run-context-index`  
Representative database: isolated local PostgreSQL database `reva30407_evidence_20260811` on the Paperclip embedded PostgreSQL 18.1 instance.

## Implementation verified

- Migrations 0128 and 0129 use valid `CREATE INDEX CONCURRENTLY IF NOT EXISTS` syntax.
- `packages/db/src/client.ts` detects concurrent-index statements, executes those DDL statements in autocommit mode, and records migration history separately. Ordinary migrations remain inside the existing `BEGIN/COMMIT` wrapper. Empty-database bootstrap paths use the same runner.
- `activity_log_company_entity_run_idx` is declared in `packages/db/src/schema/activity_log.ts` with the matching partial predicate.
- `MAX_ISSUE_COMMENT_PAGE_LIMIT = 500` is canonical in `server/src/services/issues.ts`; direct service callers and the default GET `/api/issues/:id/comments` route both apply it.

## Migration and lock-safety verification

The updated runner applied all 130 migrations to the isolated database without a transaction error. Catalog read-back:

```
activity_log_company_entity_run_idx |
  CREATE INDEX ... ON public.activity_log
  USING btree (company_id, entity_type, entity_id, run_id)
  WHERE (run_id IS NOT NULL)
heartbeat_runs_company_context_issue_created_idx |
  CREATE INDEX ... ON public.heartbeat_runs
  USING btree (company_id, ((context_snapshot ->> 'issueId')), created_at, id)

activity_log_company_entity_run_idx|indisvalid=t|indisready=t
heartbeat_runs_company_context_issue_created_idx|indisvalid=t|indisready=t
```

The concurrent DDL completed outside the migration transaction, so the production-data rollout does not hold the table write lock for the index build. The explicit catalog flags confirm both indexes finished valid and ready.

## EXPLAIN ANALYZE

The isolated benchmark contained 10,001 issues, 110,000 comments for the target issue, 10,000 heartbeat runs, and activity rows across two companies. The comments workload intentionally puts all 110,000 rows on one issue to exercise the hard page cap.

- Issue detail, existing ID: `Index Scan using issues_pkey`; execution time **0.081 ms**.
- Default comments page: `Limit ... rows=500`; execution time **25.334 ms**. PostgreSQL chose a parallel sequential scan because all 110,000 synthetic comments matched the target issue; the query still stopped after the bounded top-500 page.
- Heartbeat context expression lookup: `Index Scan Backward using heartbeat_runs_company_context_issue_created_idx`; 10 rows; execution time **0.392 ms**.
- Activity attribution lookup with company/entity/run predicate: `Index Only Scan using activity_log_company_entity_run_idx`; 10 rows; execution time **0.481 ms**.
- Nonexistent issue ID control: `Index Scan using issues_pkey`, zero rows; execution time **0.021 ms**.

## Live API bounded timings

Five authenticated GET samples against the configured Paperclip API (`https://paperclip.signatiq.com`) returned the expected status codes. Values below are milliseconds from curl `time_total`.

| Path | Statuses | Samples (ms) | Range |
|---|---:|---:|---:|
| issue detail | 200 × 5 | 203.907, 223.089, 256.489, 125.021, 104.573 | 104.573–256.489 |
| default comments | 200 × 5 | 140.922, 125.413, 213.188, 174.022, 88.710 | 88.710–213.188 |
| heartbeat-context | 200 × 5 | 267.893, 335.355, 163.640, 138.178, 71.429 | 71.429–335.355 |
| nonexistent issue control | 404 × 5 | 90.530, 98.644, 88.992, 109.967, 100.273 | 88.992–109.967 |

The live default comments response for REVA-30407 contained 9 rows; the >500 regression is covered by the embedded-Postgres route test added to `server/src/__tests__/issue-comment-redaction.test.ts`.

## Verification commands

- `pnpm --filter @paperclipai/db typecheck`: passed, including migration numbering.
- `pnpm exec vitest run packages/db/src/client.test.ts --pool=threads --maxWorkers=1`: passed, 1 file / 9 tests.
- `git diff --check`: passed.
- The server route regression could not be executed in this checkout because `express` and workspace dependency links are unavailable to the server test runner; this is the existing environment limitation recorded on the issue.
- Standalone `tsc -p server/tsconfig.json` was not actionable for the same missing workspace/Node dependency links and produced broad unrelated module-resolution errors.
